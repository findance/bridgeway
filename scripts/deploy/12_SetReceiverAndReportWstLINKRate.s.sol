// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/BridgewayL1RateReporter.sol";

/// @title 12_SetReceiverAndReportWstLINKRate
/// @notice Sets the Arbitrum receiver on the Ethereum reporter, then sends the
///         first wstLINK rate update in the same Ethereum transaction sequence.
///
/// Run on Ethereum mainnet from the reporter owner.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   L1_RATE_REPORTER
///   L2_RATE_REGISTRY
///
/// Optional env vars:
///   RATE_REPORT_VALUE_WEI (native ETH sent into reportRate as CCIP fee cushion)
contract SetReceiverAndReportWstLINKRate is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address reporterAddress = vm.envAddress("L1_RATE_REPORTER");
        address l2Registry = vm.envAddress("L2_RATE_REGISTRY");
        uint256 reportValue = vm.envOr("RATE_REPORT_VALUE_WEI", uint256(0));

        vm.startBroadcast(deployerKey);

        BridgewayL1RateReporter reporter = BridgewayL1RateReporter(payable(reporterAddress));
        reporter.setReceiver(l2Registry);
        bytes32 messageId = reporter.reportRate{value: reportValue}();

        console.log("BridgewayL1RateReporter receiver:", l2Registry);
        console.logBytes32(messageId);

        vm.stopBroadcast();
    }
}
