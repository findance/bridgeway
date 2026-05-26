// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/ClearcrestAdmin.sol";
import "../../contracts/core/ClearcrestVault.sol";
import "../../contracts/core/modules/ClearcrestMaintenanceModule.sol";
import "../../contracts/core/modules/ClearcrestRedemptionModule.sol";
import "../../contracts/tokens/CCRToken.sol";
import "../../contracts/tokens/CGOVToken.sol";

/// @title  02_DeployVault
/// @notice Deploy ClearcrestVault and wire up Clearcrest token roles.
///         Run AFTER 01_DeployTokens.s.sol.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY
///           TOKEN_ADMIN        final token admin Safe
///           VAULT_OWNER        final vault owner Safe
///           FOUNDER_TREASURY
///           CCR_TOKEN          CCR token address from script 01 output
///           CGOV_TOKEN          (from script 01 output)
///           TEAM_WALLET
///           HOLDBACK_WALLET
///           RESERVE_WALLET
///           USDC_ADDRESS
///           USDC_USD_FEED
///
///         Command:
///           forge script scripts/deploy/02_DeployVault.s.sol \
///             --rpc-url $BASE_RPC_URL \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $BASESCAN_API_KEY
contract DeployVault is Script {
    error TokenAdminMustNotBeDeployer();
    error VaultOwnerMustNotBeDeployer();

    function _deployVault(address temporaryOwner) internal returns (ClearcrestVault) {
        return new ClearcrestVault(
            vm.envAddress("CCR_TOKEN"),
            vm.envAddress("CGOV_TOKEN"),
            vm.envAddress("TEAM_WALLET"),
            vm.envAddress("HOLDBACK_WALLET"),
            vm.envAddress("RESERVE_WALLET"),
            temporaryOwner,
            vm.envAddress("USDC_ADDRESS"),
            vm.envAddress("USDC_USD_FEED")
        );
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address tokenAdmin = vm.envAddress("TOKEN_ADMIN");
        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");
        if (tokenAdmin == deployer) revert TokenAdminMustNotBeDeployer();
        if (vaultOwner == deployer) revert VaultOwnerMustNotBeDeployer();

        CCRToken ccrToken = CCRToken(vm.envAddress("CCR_TOKEN"));
        CGOVToken cgovToken = CGOVToken(vm.envAddress("CGOV_TOKEN"));

        vm.startBroadcast(deployerKey);

        ClearcrestVault vault = _deployVault(deployer);
        console.log("ClearcrestVault:", address(vault));

        ClearcrestRedemptionModule redemptionModule = new ClearcrestRedemptionModule(
            vm.envAddress("CCR_TOKEN"),
            vm.envAddress("CGOV_TOKEN"),
            vm.envAddress("USDC_ADDRESS"),
            vm.envAddress("USDC_USD_FEED")
        );
        console.log("ClearcrestRedemptionModule:", address(redemptionModule));

        ClearcrestMaintenanceModule maintenanceModule = new ClearcrestMaintenanceModule(
            vm.envAddress("CCR_TOKEN"),
            vm.envAddress("CGOV_TOKEN"),
            vm.envAddress("USDC_ADDRESS"),
            vm.envAddress("USDC_USD_FEED")
        );
        console.log("ClearcrestMaintenanceModule:", address(maintenanceModule));

        vault.setLogicModules(address(redemptionModule), address(maintenanceModule));
        console.log("Vault logic modules wired");

        ccrToken.grantRole(ccrToken.MINTER_ROLE(), address(vault));
        console.log("Granted MINTER_ROLE to vault on CCR token");

        ccrToken.grantRole(ccrToken.BURNER_ROLE(), address(vault));
        console.log("Granted BURNER_ROLE to vault on CCR token");

        ccrToken.grantRole(ccrToken.WHITELIST_ADMIN_ROLE(), address(vault));
        console.log("Granted WHITELIST_ADMIN_ROLE to vault on CCR token");

        vault.setWhitelisted(address(vault), true);
        console.log("Whitelisted vault for protocol reserve mint-and-burn");

        cgovToken.initVault(address(vault));
        console.log("Initialized vault in CGOV token (vault can mint deposit governance)");

        vault.setWhitelisted(founderTreasury, true);
        console.log("Whitelisted founder treasury:", founderTreasury);

        // Hand final token administration to the Safe and remove deployer token powers.
        ccrToken.grantRole(ccrToken.DEFAULT_ADMIN_ROLE(), tokenAdmin);
        ccrToken.grantRole(ccrToken.PAUSER_ROLE(), tokenAdmin);
        ccrToken.grantRole(ccrToken.BLACKLIST_ADMIN_ROLE(), tokenAdmin);
        ccrToken.grantRole(ccrToken.WHITELIST_ADMIN_ROLE(), tokenAdmin);
        cgovToken.grantRole(cgovToken.DEFAULT_ADMIN_ROLE(), tokenAdmin);

        ccrToken.revokeRole(ccrToken.PAUSER_ROLE(), deployer);
        ccrToken.revokeRole(ccrToken.BLACKLIST_ADMIN_ROLE(), deployer);
        ccrToken.revokeRole(ccrToken.WHITELIST_ADMIN_ROLE(), deployer);
        ccrToken.revokeRole(ccrToken.DEFAULT_ADMIN_ROLE(), deployer);
        cgovToken.revokeRole(cgovToken.DEFAULT_ADMIN_ROLE(), deployer);
        console.log("Token admin handed to:", tokenAdmin);

        ClearcrestAdmin admin = new ClearcrestAdmin(address(vault), deployer, 0);
        console.log("ClearcrestAdmin:", address(admin));

        vault.transferOwnership(address(admin));
        console.log("Vault ownership transferred to admin:", address(admin));

        admin.transferOwnership(vaultOwner);
        console.log("Admin ownership transfer started. Pending owner:", vaultOwner);

        vm.stopBroadcast();

        console.log("\n=== Save these for script 03 ===");
        console.log("VAULT=", address(vault));
        console.log("ADMIN=", address(admin));
        console.log("REDEMPTION_MODULE=", address(redemptionModule));
        console.log("MAINTENANCE_MODULE=", address(maintenanceModule));
        console.log("Admin owner must accept ownership from Safe before Safe-governed configuration.");
        console.log("\n=== Optional liquidity step ===");
        console.log("After seeding CCR/USDC liquidity for secondary-market trading, call:");
        console.log("  vault.setWhitelisted(<pair_address>, true)");
        console.log("This whitelists the pair for CCR transfers; buybacks do not require LP liquidity.");
    }
}
