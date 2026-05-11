// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/BGWVault.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";

/// @title  02_DeployVault
/// @notice Deploy BGWVault and wire up token roles.
///         Run AFTER 01_DeployTokens.s.sol.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY
///           FOUNDER_ADDRESS
///           BGW_TOKEN          (from script 01 output)
///           GOV_TOKEN          (from script 01 output)
///           TEAM_WALLET        (real multisig address)
///           HOLDBACK_WALLET    (real multisig address)
///           LP_SEEDING_WALLET  (real multisig address)
///           RESERVE_WALLET     (real multisig address)
///
///         Command:
///           forge script scripts/deploy/02_DeployVault.s.sol \
///             --rpc-url $ARBITRUM_RPC \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
contract DeployVault is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founderAddr = vm.envAddress("FOUNDER_ADDRESS");

        address bgwTokenAddr = vm.envAddress("BGW_TOKEN");
        address govTokenAddr = vm.envAddress("GOV_TOKEN");
        address teamWallet   = vm.envAddress("TEAM_WALLET");
        address holdback     = vm.envAddress("HOLDBACK_WALLET");
        address lpSeeding    = vm.envAddress("LP_SEEDING_WALLET");
        address reserve      = vm.envAddress("RESERVE_WALLET");

        BGWToken    bgwToken = BGWToken(bgwTokenAddr);
        BGWGovToken govToken = BGWGovToken(govTokenAddr);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BGWVault
        BGWVault vault = new BGWVault(
            bgwTokenAddr,
            govTokenAddr,
            teamWallet,
            holdback,
            lpSeeding,
            reserve,
            founderAddr
        );
        console.log("BGWVault:", address(vault));

        // 2. Grant MINTER_ROLE on BGWToken to the vault
        bgwToken.grantRole(bgwToken.MINTER_ROLE(), address(vault));
        console.log("Granted MINTER_ROLE to vault on BGWToken");

        // 3. Grant WHITELIST_ADMIN_ROLE on BGWToken to vault
        //    (so vault.setWhitelisted() can update BGWToken whitelist)
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        console.log("Granted WHITELIST_ADMIN_ROLE to vault on BGWToken");

        // 4. Grant DISTRIBUTOR_ROLE on BGWGovToken to vault
        //    (so vault can distribute community pool on deposit)
        govToken.grantRole(govToken.DISTRIBUTOR_ROLE(), address(vault));
        console.log("Granted DISTRIBUTOR_ROLE to vault on BGWGovToken");

        // 5. Whitelist the founder so they can make the first deposit
        vault.setWhitelisted(founderAddr, true);
        console.log("Whitelisted founder:", founderAddr);

        vm.stopBroadcast();

        // Print summary for script 03
        console.log("\n=== Save these for script 03 ===");
        console.log("VAULT=", address(vault));
    }
}
