// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/BGWVault.sol";

/// @title MonthlyVaultRebalance
/// @notice Runs the vault one-way rebalance policy: Sleeve C -> Sleeve B,
///         then Sleeve B -> Sleeve A, capped by MAX_REBALANCE_MOVE_USDC.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   VAULT
///
/// Optional env vars:
///   MAX_REBALANCE_MOVE_USDC  Defaults to uint256 max.
///
/// Suggested Chainlink Automation schedule:
///   Time-based trigger, Base, every second Monday at 03:30 UTC.
///   That lands on Sunday night in America/Toronto/New York and avoids the
///   busiest weekday windows. If using custom logic instead, call the
///   BridgewayAutomation REBALANCE action.
contract MonthlyVaultRebalance is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address vaultAddr = vm.envAddress("VAULT");
        uint256 maxMoveUsdc = vm.envOr("MAX_REBALANCE_MOVE_USDC", type(uint256).max);

        BGWVault vault = BGWVault(vaultAddr);

        uint256 beforeA = vault.sleeveValue(vault.SLEEVE_A());
        uint256 beforeB = vault.sleeveValue(vault.SLEEVE_B());
        uint256 beforeC = vault.sleeveValue(vault.SLEEVE_C());

        vm.startBroadcast(deployerKey);
        (uint256 movedCToB, uint256 movedBToA) = vault.rebalanceSleevesOneWay(maxMoveUsdc);
        vm.stopBroadcast();

        console.log("Vault:", vaultAddr);
        console.log("Moved C -> B:", movedCToB);
        console.log("Moved B -> A:", movedBToA);
        console.log("Before A:", beforeA);
        console.log("Before B:", beforeB);
        console.log("Before C:", beforeC);
        console.log("After A:", vault.sleeveValue(vault.SLEEVE_A()));
        console.log("After B:", vault.sleeveValue(vault.SLEEVE_B()));
        console.log("After C:", vault.sleeveValue(vault.SLEEVE_C()));
    }
}
