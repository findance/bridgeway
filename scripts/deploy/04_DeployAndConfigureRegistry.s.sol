// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/core/ClearcrestRegistry.sol";
import "../../contracts/libraries/ClearcrestChainConfig.sol";

/// @title 04_DeployAndConfigureRegistry
/// @notice Deploys a chain-local ClearcrestRegistry and seeds approved token/feed configs.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   REGISTRY_OWNER
///
/// Supported chains:
///   Arbitrum One: 42161
///   Base: 8453
contract DeployAndConfigureRegistry is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address registryOwner = vm.envAddress("REGISTRY_OWNER");

        ClearcrestChainConfig.AssetSeed[] memory seeds = ClearcrestChainConfig.seeds(block.chainid);

        vm.startBroadcast(deployer);

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
