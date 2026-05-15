// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/BridgewayCCIPNAVReceiver.sol";

/// @title 06_DeployCCIPNAVReceiver
/// @notice Deploys the hub-chain CCIP receiver that forwards verified spoke NAV
///         reports into BridgewayHubNAV.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   CCIP_RECEIVER_OWNER
///   CCIP_ROUTER
///   HUB_NAV
///
/// After deployment:
///   1. Call receiver.configureSource(<ccipSelector>, <spokeChainId>, <senderBytes>, true).
///   2. Call hub.configureSpoke(<spokeChainId>, <receiver>, ...).
contract DeployCCIPNAVReceiver is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address receiverOwner = vm.envAddress("CCIP_RECEIVER_OWNER");
        address router = vm.envAddress("CCIP_ROUTER");
        address hubNAV = vm.envAddress("HUB_NAV");

        vm.startBroadcast(deployerKey);

        BridgewayCCIPNAVReceiver receiver = new BridgewayCCIPNAVReceiver(deployer, router, hubNAV);
        console.log("BridgewayCCIPNAVReceiver:", address(receiver));

        if (receiverOwner != deployer) {
            receiver.transferOwnership(receiverOwner);
        }

        vm.stopBroadcast();
    }
}
