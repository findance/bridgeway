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
///           TEAM_WALLET
///           HOLDBACK_WALLET
///           LP_SEEDING_WALLET
///           RESERVE_WALLET
///           USDC_ADDRESS
///           CAMELOT_ROUTER
///           ETH_USD_FEED
///
///         Command:
///           forge script scripts/deploy/02_DeployVault.s.sol \
///             --rpc-url $ARBITRUM_RPC \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
contract DeployVault is Script {

    function _deployVault(address founder) internal returns (BGWVault) {
        return new BGWVault(
            vm.envAddress("BGW_TOKEN"),
            vm.envAddress("GOV_TOKEN"),
            vm.envAddress("TEAM_WALLET"),
            vm.envAddress("HOLDBACK_WALLET"),
            vm.envAddress("LP_SEEDING_WALLET"),
            vm.envAddress("RESERVE_WALLET"),
            founder,
            vm.envAddress("USDC_ADDRESS"),
            vm.envAddress("CAMELOT_ROUTER"),
            vm.envAddress("ETH_USD_FEED")
        );
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founderAddr = vm.envAddress("FOUNDER_ADDRESS");

        BGWToken    bgwToken = BGWToken(vm.envAddress("BGW_TOKEN"));
        BGWGovToken govToken = BGWGovToken(vm.envAddress("GOV_TOKEN"));

        vm.startBroadcast(deployerKey);

        BGWVault vault = _deployVault(founderAddr);
        console.log("BGWVault:", address(vault));

        bgwToken.grantRole(bgwToken.MINTER_ROLE(), address(vault));
        console.log("Granted MINTER_ROLE to vault on BGWToken");

        bgwToken.grantRole(bgwToken.BURNER_ROLE(), address(vault));
        console.log("Granted BURNER_ROLE to vault on BGWToken");

        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        console.log("Granted WHITELIST_ADMIN_ROLE to vault on BGWToken");

        vault.setWhitelisted(address(vault), true);
        console.log("Whitelisted vault for protocol reserve mint-and-burn");

        govToken.initVault(address(vault));
        console.log("Initialized vault in BGWGovToken (vault can mint deposit GOV)");

        vault.setWhitelisted(founderAddr, true);
        console.log("Whitelisted founder:", founderAddr);

        vm.stopBroadcast();

        console.log("\n=== Save these for script 03 ===");
        console.log("VAULT=", address(vault));
        console.log("\n=== Optional liquidity step ===");
        console.log("After seeding Camelot BGW/USDC liquidity for secondary-market trading, call:");
        console.log("  vault.bootstrapPair(<camelot_pair_address>)");
        console.log("This whitelists the pair for BGW transfers; buybacks do not require LP liquidity.");
    }
}
