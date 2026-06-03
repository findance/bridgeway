// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestRateRegistry.sol";

/// @title 09_DeployWstLINKRateRegistry
/// @notice Deploys the Arbitrum-side rate registry and allowlists Arbitrum wstLINK.
///
/// Run on Arbitrum One.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   RATE_REGISTRY_OWNER
///   ARBITRUM_CCIP_ROUTER
///   L1_RATE_REPORTER
///   ETHEREUM_CCIP_SELECTOR
///   WSTLINK_L2
///
/// Optional env vars:
///   WSTLINK_MAX_STALENESS_SECONDS (defaults to registry default when omitted or zero)
contract DeployWstLINKRateRegistry is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address registryOwner = vm.envAddress("RATE_REGISTRY_OWNER");
        address arbitrumRouter = vm.envAddress("ARBITRUM_CCIP_ROUTER");
        address l1Reporter = vm.envAddress("L1_RATE_REPORTER");
        uint64 ethereumSelector = uint64(vm.envUint("ETHEREUM_CCIP_SELECTOR"));
        address wstLinkL2 = vm.envAddress("WSTLINK_L2");
        uint256 maxStaleness = vm.envOr("WSTLINK_MAX_STALENESS_SECONDS", uint256(0));

        vm.startBroadcast(deployer);

        ClearcrestRateRegistry registry =
            new ClearcrestRateRegistry(deployer, arbitrumRouter, l1Reporter, ethereumSelector);
        console.log("ClearcrestRateRegistry:", address(registry));

        registry.setApprovedRateAsset(wstLinkL2, true);
        if (maxStaleness != 0) {
            registry.setMaxStaleness(wstLinkL2, maxStaleness);
        }

        if (registryOwner != deployer) {
            registry.transferOwnership(registryOwner);
        }

        vm.stopBroadcast();
    }
}
