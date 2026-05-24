// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestRegistry.sol";
import "../../contracts/libraries/ClearcrestChainConfig.sol";

/// @title 04_DeployAndConfigureRegistry
/// @notice Deploys a chain-local ClearcrestRegistry and seeds approved token/feed configs.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   REGISTRY_OWNER
///
/// Supported chains:
///   Arbitrum One: 42161
///   Base: 8453
contract DeployAndConfigureRegistry is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address registryOwner = vm.envAddress("REGISTRY_OWNER");

        ClearcrestChainConfig.AssetSeed[] memory seeds = ClearcrestChainConfig.seeds(block.chainid);

        vm.startBroadcast(deployerKey);

        ClearcrestRegistry registry = new ClearcrestRegistry(deployer);
        console.log("ClearcrestRegistry:", address(registry));

        for (uint256 i; i < seeds.length; ++i) {
            ClearcrestChainConfig.AssetSeed memory seed = seeds[i];
            registry.setAsset(
                seed.assetId, seed.token, seed.priceFeed, seed.tokenDecimals, seed.feedDecimals, seed.trusted
            );
            console.logBytes32(seed.assetId);
            console.log("  token:", seed.token);
            console.log("  priceFeed:", seed.priceFeed);
        }

        if (registryOwner != deployer) {
            registry.transferOwnership(registryOwner);
        }
        vm.stopBroadcast();
    }
}
