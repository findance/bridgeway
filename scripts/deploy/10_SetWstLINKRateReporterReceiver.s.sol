// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestL1RateReporter.sol";

/// @title 10_SetWstLINKRateReporterReceiver
/// @notice Points the Ethereum reporter at the deployed Arbitrum rate registry.
///
/// Run on Ethereum mainnet from the reporter owner.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   L1_RATE_REPORTER
///   L2_RATE_REGISTRY
contract SetWstLINKRateReporterReceiver is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address reporterAddress = vm.envAddress("L1_RATE_REPORTER");
        address l2Registry = vm.envAddress("L2_RATE_REGISTRY");

        vm.startBroadcast(deployer);

        ClearcrestL1RateReporter(payable(reporterAddress)).setReceiver(l2Registry);
        console.log("ClearcrestL1RateReporter receiver:", l2Registry);

        vm.stopBroadcast();
    }
}
