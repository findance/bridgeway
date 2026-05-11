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
        // Vault address isn't known yet — use a placeholder.
        // We'll fix this by calling govToken.grantRole after deploying vault.
        // For now pass address(1) as vault placeholder; we'll update in script 03.
        address vaultPlaceholder = address(1);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BGWToken (admin = founder)
        BGWToken bgwToken = new BGWToken(founderAddr);
        console.log("BGWToken:      ", address(bgwToken));

        // 2. Deploy FounderVesting (needs govToken address — deploy first, then wire)
        //    We use a 2-step: deploy vesting with a placeholder, then deploy gov.
        //    Actually: gov needs vesting address, so deploy vesting shell first.
        //    But vesting needs gov token — circular dependency resolved by:
        //      a) Deploy FounderVesting with a placeholder govToken
        //      b) Deploy BGWGovToken with real vestingAddress
        //      c) FounderVesting has no immutable govToken — it takes it as constructor arg
        //         so we pass the deployed gov address. But gov hasn't been deployed yet.
        //
        //    Solution: Deploy in this order:
        //      1. Deploy FounderVesting with a temporary address (upgradeable pattern not used)
        //         → Actually FounderVesting takes govToken as immutable, so we need gov first.
        //
        //    Correct order:
        //      1. Pre-compute gov address using CREATE2 or accept the circular dep:
        //         → Simplest MVP: deploy BGWGovToken with address(0) vesting (not possible due to check)
        //         → Use a 2-deploy pattern: deploy a minimal proxy, then the real contract.
        //         → SIMPLEST: Deploy FounderVesting with the DEPLOYER address temporarily,
        //           then deploy BGWGovToken pointing to FounderVesting.
        //           After: FounderVesting already has govToken immutable set, so we need
        //           govToken deployed first with a known vesting address.
        //
        //    PRACTICAL SOLUTION for a small closed system:
        //      Since FounderVesting holds the tokens but the tokens are minted by BGWGovToken,
        //      just compute the next nonce to predict FounderVesting address, then deploy gov.

        // Predict FounderVesting address (it will be deployed at nonce+1)
        address deployerEOA     = vm.addr(deployerKey);
        uint256 currentNonce    = vm.getNonce(deployerEOA);
        // FounderVesting will be the NEXT contract deployed (nonce = currentNonce + 1)
        address predictedVesting = computeCreateAddress(deployerEOA, currentNonce + 1);

        // 2. Deploy BGWGovToken (mints 70M to predictedVesting, 30M to vaultPlaceholder)
        //    vault placeholder is address(1) — we update DISTRIBUTOR_ROLE in script 03
        BGWGovToken govToken = new BGWGovToken(
            predictedVesting,
            vaultPlaceholder,
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
