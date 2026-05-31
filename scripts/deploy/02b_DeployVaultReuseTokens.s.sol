// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/ClearcrestAdmin.sol";
import "../../contracts/core/ClearcrestVault.sol";
import "../../contracts/core/modules/ClearcrestMaintenanceModule.sol";
import "../../contracts/core/modules/ClearcrestRedemptionModule.sol";

/// @title  02b_DeployVaultReuseTokens
/// @notice Deploys a fresh vault/admin/module stack while reusing existing
///         CCR/CGOV token contracts whose admin is controlled by a Safe.
/// @dev    This script deliberately skips token role mutations. After broadcast,
///         the token admin Safe must grant CCR roles and move CGOV's vault
///         reference to the newly deployed vault.
contract DeployVaultReuseTokens is Script {
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
        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");
        if (vaultOwner == deployer) revert VaultOwnerMustNotBeDeployer();

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

        vault.setWhitelisted(address(vault), true);
        console.log("Whitelisted vault for protocol reserve mint-and-burn");

        vault.setWhitelisted(founderTreasury, true);
        console.log("Whitelisted founder treasury:", founderTreasury);

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
        console.log("\n=== Required Safe token wiring ===");
        console.log("1. CCR grant MINTER_ROLE, BURNER_ROLE, WHITELIST_ADMIN_ROLE to VAULT.");
        console.log("2. CGOV proposeVaultReference(VAULT), wait 48h, then executeVaultReference().");
        console.log("3. Admin owner Safe must accept ClearcrestAdmin ownership.");
    }
}
