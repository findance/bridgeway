// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/BridgewayHubNAV.sol";

/// @title 05_DeployHubNAV
/// @notice Deploys the Arbitrum-side confirmed spoke NAV cache.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   HUB_NAV_OWNER
///
/// Optional next step:
///   Configure each spoke with BridgewayHubNAV.configureSpoke(), then wire the
///   resulting Hub NAV address into BGWVault through proposeHubNAVUpdate() and
///   executeHubNAVUpdate() after the vault timelock.
contract DeployHubNAV is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hubOwner = vm.envAddress("HUB_NAV_OWNER");

        vm.startBroadcast(deployerKey);

        BridgewayHubNAV hub = new BridgewayHubNAV(deployer);
        console.log("BridgewayHubNAV:", address(hub));

        if (hubOwner != deployer) {
            hub.transferOwnership(hubOwner);
        }

        vm.stopBroadcast();
    }
}
