// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";
import "../../contracts/tokens/FounderVesting.sol";

/// @title  01_DeployTokens
/// @notice Deploy BGWToken, FounderVesting, and BGWGovToken.
///         Run BEFORE 02_DeployVault.s.sol.
///
///         Output (save these addresses for script 02):
///           BGWToken:       $BGW_TOKEN
///           FounderVesting: $FOUNDER_VESTING
///           BGWGovToken:    $GOV_TOKEN
///
/// @dev    Set env vars before running:
///           DEPLOYER_PRIVATE_KEY   = founder wallet private key
///           FOUNDER_ADDRESS        = founder EOA / multisig
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

        // Predict FounderVesting address (deployed at nonce+1 from current nonce).
        // BGWGovToken mints 70M to the vesting contract in its constructor, so the
        // vesting address must be known before BGWGovToken is deployed.
        address deployerEOA     = vm.addr(deployerKey);
        uint256 currentNonce    = vm.getNonce(deployerEOA);
        address predictedVesting = computeCreateAddress(deployerEOA, currentNonce + 1);

        // 2. Deploy BGWGovToken (mints 70M to predictedVesting, 30M held by itself
        //    until initVault() is called from script 02).
        BGWGovToken govToken = new BGWGovToken(
            predictedVesting,
            founderAddr
        );
        console.log("BGWGovToken:   ", address(govToken));

        // 3. Deploy FounderVesting (receives 70M BGW-GOV from govToken constructor)
        FounderVesting vesting = new FounderVesting(address(govToken), founderAddr);
        console.log("FounderVesting:", address(vesting));

        // Sanity check: predicted address must match actual
        require(address(vesting) == predictedVesting, "DEPLOY: vesting address mismatch");

        vm.stopBroadcast();

        // Print summary for script 02
        console.log("\n=== Save these for script 02 ===");
        console.log("BGW_TOKEN=",      address(bgwToken));
        console.log("GOV_TOKEN=",      address(govToken));
        console.log("FOUNDER_VESTING=",address(vesting));
    }
}
