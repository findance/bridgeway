// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/BGWVault.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";

/// @title  02_DeployVault
/// @notice Deploy BGWVault and wire up Clearcrest token roles.
///         Run AFTER 01_DeployTokens.s.sol.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY
///           TOKEN_ADMIN        final token admin Safe
///           VAULT_OWNER        final vault owner Safe
///           FOUNDER_TREASURY
///           BGW_TOKEN          CCR token address from script 01 output
///           GOV_TOKEN          (from script 01 output)
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
    function _deployVault(address temporaryOwner) internal returns (BGWVault) {
        return new BGWVault(
            vm.envAddress("BGW_TOKEN"),
            vm.envAddress("GOV_TOKEN"),
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
        require(tokenAdmin != deployer, "TOKEN_ADMIN must not be deployer");
        require(vaultOwner != deployer, "VAULT_OWNER must not be deployer");

        BGWToken bgwToken = BGWToken(vm.envAddress("BGW_TOKEN"));
        BGWGovToken govToken = BGWGovToken(vm.envAddress("GOV_TOKEN"));

        vm.startBroadcast(deployerKey);

        BGWVault vault = _deployVault(deployer);
        console.log("BGWVault:", address(vault));

        bgwToken.grantRole(bgwToken.MINTER_ROLE(), address(vault));
        console.log("Granted MINTER_ROLE to vault on CCR token");

        bgwToken.grantRole(bgwToken.BURNER_ROLE(), address(vault));
        console.log("Granted BURNER_ROLE to vault on CCR token");

        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        console.log("Granted WHITELIST_ADMIN_ROLE to vault on CCR token");

        vault.setWhitelisted(address(vault), true);
        console.log("Whitelisted vault for protocol reserve mint-and-burn");

        govToken.initVault(address(vault));
        console.log("Initialized vault in CGOV token (vault can mint deposit governance)");

        vault.setWhitelisted(founderTreasury, true);
        console.log("Whitelisted founder treasury:", founderTreasury);

        // Hand final token administration to the Safe and remove deployer token powers.
        bgwToken.grantRole(bgwToken.DEFAULT_ADMIN_ROLE(), tokenAdmin);
        bgwToken.grantRole(bgwToken.PAUSER_ROLE(), tokenAdmin);
        bgwToken.grantRole(bgwToken.BLACKLIST_ADMIN_ROLE(), tokenAdmin);
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), tokenAdmin);
        govToken.grantRole(govToken.DEFAULT_ADMIN_ROLE(), tokenAdmin);

        bgwToken.revokeRole(bgwToken.PAUSER_ROLE(), deployer);
        bgwToken.revokeRole(bgwToken.BLACKLIST_ADMIN_ROLE(), deployer);
        bgwToken.revokeRole(bgwToken.WHITELIST_ADMIN_ROLE(), deployer);
        bgwToken.revokeRole(bgwToken.DEFAULT_ADMIN_ROLE(), deployer);
        govToken.revokeRole(govToken.DEFAULT_ADMIN_ROLE(), deployer);
        console.log("Token admin handed to:", tokenAdmin);

        vault.transferOwnership(vaultOwner);
        console.log("Vault ownership transfer started. Pending owner:", vaultOwner);

        vm.stopBroadcast();

        console.log("\n=== Save these for script 03 ===");
        console.log("VAULT=", address(vault));
        console.log("Vault owner must accept ownership from Safe before owner-only configuration.");
        console.log("\n=== Optional liquidity step ===");
        console.log("After seeding CCR/USDC liquidity for secondary-market trading, call:");
        console.log("  vault.setWhitelisted(<pair_address>, true)");
        console.log("This whitelists the pair for CCR transfers; buybacks do not require LP liquidity.");
    }
}
