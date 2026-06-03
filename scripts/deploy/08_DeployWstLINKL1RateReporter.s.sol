// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestL1RateReporter.sol";

/// @title 08_DeployWstLINKL1RateReporter
/// @notice Deploys the Ethereum-side wstLINK rate reporter.
///
/// Run on Ethereum mainnet.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   RATE_REPORTER_OWNER
///   ETH_CCIP_ROUTER
///   WSTLINK_L1
///   WSTLINK_L2
///   ARBITRUM_CCIP_SELECTOR
contract DeployWstLINKL1RateReporter is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address reporterOwner = vm.envAddress("RATE_REPORTER_OWNER");
        address ethRouter = vm.envAddress("ETH_CCIP_ROUTER");
        address wstLinkL1 = vm.envAddress("WSTLINK_L1");
        address wstLinkL2 = vm.envAddress("WSTLINK_L2");
        uint64 arbitrumSelector = uint64(vm.envUint("ARBITRUM_CCIP_SELECTOR"));

        vm.startBroadcast(deployer);

        ClearcrestL1RateReporter reporter =
            new ClearcrestL1RateReporter(deployer, ethRouter, wstLinkL1, wstLinkL2, arbitrumSelector);
        console.log("ClearcrestL1RateReporter:", address(reporter));

        if (reporterOwner != deployer) {
            reporter.transferOwnership(reporterOwner);
        }

        vm.stopBroadcast();
    }
}
