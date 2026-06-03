// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestHubNAV.sol";

/// @title 05_DeployHubNAV
/// @notice Deploys the hub-chain confirmed spoke NAV cache.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   HUB_NAV_OWNER
///
/// Optional next step:
///   Configure each spoke with ClearcrestHubNAV.configureSpoke(), then wire the
///   resulting Hub NAV address into ClearcrestVault through setHubNAV() from the
///   vault owner Safe/controller.
contract DeployHubNAV is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address hubOwner = vm.envAddress("HUB_NAV_OWNER");

        vm.startBroadcast(deployer);

        ClearcrestHubNAV hub = new ClearcrestHubNAV(deployer);
        console.log("ClearcrestHubNAV:", address(hub));

        if (hubOwner != deployer) {
            hub.transferOwnership(hubOwner);
        }

        vm.stopBroadcast();
    }
}
