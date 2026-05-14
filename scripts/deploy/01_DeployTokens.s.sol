// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";

/// @title  01_DeployTokens
/// @notice Deploy BGWToken and BGWGovToken.
///         Run BEFORE 02_DeployVault.s.sol.
///
///         Output (save these addresses for script 02):
///           BGWToken:       $BGW_TOKEN
///           BGWGovToken:    $GOV_TOKEN
///
/// @dev    Set env vars before running:
///           DEPLOYER_PRIVATE_KEY   = founder wallet private key
///           FOUNDER_ADDRESS        = founder EOA / multisig / treasury
///           ARBITRUM_RPC           = https://arb1.arbitrum.io/rpc  (or Alchemy)
///
///         Command:
///           forge script scripts/deploy/01_DeployTokens.s.sol \
///             --rpc-url $ARBITRUM_RPC \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
contract DeployTokens is Script {

    function run() external {
        uint256 deployerKey   = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founderAddr   = vm.envAddress("FOUNDER_ADDRESS");

        vm.startBroadcast(deployerKey);

        // 1. Deploy BGWToken (admin = founder)
        BGWToken bgwToken = new BGWToken(founderAddr);
        console.log("BGWToken:      ", address(bgwToken));

        // 2. Deploy BGWGovToken (inflationary, minted by the vault on deposit).
        BGWGovToken govToken = new BGWGovToken(
            founderAddr,
            address(bgwToken),
            founderAddr
        );
        console.log("BGWGovToken:   ", address(govToken));

        bgwToken.setGovernanceCompanion(address(govToken));
        console.log("Set BGW-GOV companion on BGWToken");

        vm.stopBroadcast();

        // Print summary for script 02
        console.log("\n=== Save these for script 02 ===");
        console.log("BGW_TOKEN=",      address(bgwToken));
        console.log("GOV_TOKEN=",      address(govToken));
    }
}
