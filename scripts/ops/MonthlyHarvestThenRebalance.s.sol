// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

interface IClearcrestAutomation {
    function lastHarvestTime() external view returns (uint256);
    function lastRebalanceTime() external view returns (uint256);
    function performUpkeep(bytes calldata performData) external;
}

/// @title MonthlyHarvestThenRebalance
/// @notice Runs the monthly operator sequence as two production automation
///         actions: HARVEST first, then REBALANCE only after harvest succeeds.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   AUTOMATION
///
/// Suggested schedule:
///   Time-based trigger, Base, monthly during a low-activity window.
///   This replaces separate harvest/rebalance cron jobs when an operator
///   wants deterministic harvest-before-rebalance ordering in one runbook step.
contract MonthlyHarvestThenRebalance is Script {
    bytes32 internal constant ACTION_HARVEST = keccak256("HARVEST");
    bytes32 internal constant ACTION_REBALANCE = keccak256("REBALANCE");

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address automationAddr = vm.envAddress("AUTOMATION");

        IClearcrestAutomation automation = IClearcrestAutomation(automationAddr);

        uint256 harvestBefore = automation.lastHarvestTime();
        uint256 rebalanceBefore = automation.lastRebalanceTime();

        vm.startBroadcast(deployerKey);
        automation.performUpkeep(abi.encode(ACTION_HARVEST));
        vm.stopBroadcast();

        uint256 harvestAfter = automation.lastHarvestTime();
        require(harvestAfter > harvestBefore, "Monthly ops: harvest did not advance");

        vm.startBroadcast(deployerKey);
        automation.performUpkeep(abi.encode(ACTION_REBALANCE));
        vm.stopBroadcast();

        uint256 rebalanceAfter = automation.lastRebalanceTime();
        require(rebalanceAfter > rebalanceBefore, "Monthly ops: rebalance did not advance");

        console.log("Automation:", automationAddr);
        console.log("Harvest before:", harvestBefore);
        console.log("Harvest after:", harvestAfter);
        console.log("Rebalance before:", rebalanceBefore);
        console.log("Rebalance after:", rebalanceAfter);
    }
}
