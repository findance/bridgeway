// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/adapters/ERC4626NativeStakingAdapter.sol";
import "../../contracts/core/ClearcrestNativeSpokePortfolio.sol";

/// @title 07_DeployNativeERC4626Spoke
/// @notice Deploys one native-chain spoke portfolio plus one ERC4626 staking
///         adapter for an approved native asset strategy.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   SPOKE_OWNER
///   SPOKE_CHAIN_ID
///   ASSET
///   STAKING_VAULT
///   PRICE_FEED
///
/// Optional env vars:
///   MAX_STALE_SECONDS (defaults inside adapter when omitted from manual deploy)
///
/// For multi-asset spokes, deploy additional adapters and call
/// ClearcrestNativeSpokePortfolio.setAdapters() with the full adapter list.
contract DeployNativeERC4626Spoke is Script {
    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        address spokeOwner = vm.envAddress("SPOKE_OWNER");
        uint64 spokeChainId = uint64(vm.envUint("SPOKE_CHAIN_ID"));
        address asset = vm.envAddress("ASSET");
        address stakingVault = vm.envAddress("STAKING_VAULT");
        address priceFeed = vm.envAddress("PRICE_FEED");
        uint256 maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));

        vm.startBroadcast(deployer);

        ClearcrestNativeSpokePortfolio portfolio = new ClearcrestNativeSpokePortfolio(deployer, spokeChainId);
        ERC4626NativeStakingAdapter adapter =
            new ERC4626NativeStakingAdapter(deployer, address(portfolio), asset, stakingVault, priceFeed, maxStale);

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        portfolio.setAdapters(adapters);

        if (spokeOwner != deployer) {
            adapter.transferOwnership(spokeOwner);
            portfolio.transferOwnership(spokeOwner);
        }

        vm.stopBroadcast();

        console.log("ClearcrestNativeSpokePortfolio:", address(portfolio));
        console.log("ERC4626NativeStakingAdapter:", address(adapter));
    }
}
