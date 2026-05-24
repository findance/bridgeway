// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestL1RateReporter.sol";

/// @title 11_ReportWstLINKRate
/// @notice Sends the first or recurring wstLINK rate update from Ethereum to Arbitrum.
///
/// Run on Ethereum mainnet.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   L1_RATE_REPORTER
///
/// Optional env vars:
///   RATE_REPORT_VALUE_WEI (native ETH sent into reportRate as CCIP fee cushion)
contract ReportWstLINKRate is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address reporterAddress = vm.envAddress("L1_RATE_REPORTER");
        uint256 reportValue = vm.envOr("RATE_REPORT_VALUE_WEI", uint256(0));

        vm.startBroadcast(deployerKey);

        bytes32 messageId = ClearcrestL1RateReporter(payable(reporterAddress)).reportRate{value: reportValue}();
        console.logBytes32(messageId);

        vm.stopBroadcast();
    }
}
