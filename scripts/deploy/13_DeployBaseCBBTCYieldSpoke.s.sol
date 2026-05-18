// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/core/BridgewayNativeSpokePortfolio.sol";

/// @title 13_DeployBaseCBBTCYieldSpoke
/// @notice Deploys the Base cbBTC spoke portfolio plus the 80% Aave / 20%
///         Aerodrome yield adapter.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY
///   SPOKE_OWNER
///   BASE_CHAIN_ID
///   CBBTC
///   AAVE_POOL
///   A_CBBTC
///   AERODROME_CBBTC_STRATEGY
///   BTC_USD_PRICE_FEED
///
/// Optional env vars:
///   MAX_STALE_SECONDS
///
/// The Aerodrome strategy must expose netApyBps(). The adapter exits that leg
/// back to Aave whenever net APY is below 4.5%.
contract DeployBaseCBBTCYieldSpoke is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address spokeOwner = vm.envAddress("SPOKE_OWNER");
        uint64 baseChainId = uint64(vm.envUint("BASE_CHAIN_ID"));
        address cbbtc = vm.envAddress("CBBTC");
        address aavePool = vm.envAddress("AAVE_POOL");
        address aCbbtc = vm.envAddress("A_CBBTC");
        address aerodromeStrategy = vm.envAddress("AERODROME_CBBTC_STRATEGY");
        address btcUsdPriceFeed = vm.envAddress("BTC_USD_PRICE_FEED");
        uint256 maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));

        vm.startBroadcast(deployerKey);

        BridgewayNativeSpokePortfolio portfolio = new BridgewayNativeSpokePortfolio(deployer, baseChainId);
        BaseCBBTCYieldAdapter adapter = new BaseCBBTCYieldAdapter(
            deployer,
            address(portfolio),
            cbbtc,
            aavePool,
            aCbbtc,
            aerodromeStrategy,
            btcUsdPriceFeed,
            maxStale
        );

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        portfolio.setAdapters(adapters);

        if (spokeOwner != deployer) {
            adapter.transferOwnership(spokeOwner);
            portfolio.transferOwnership(spokeOwner);
        }

        vm.stopBroadcast();

        console.log("BridgewayNativeSpokePortfolio:", address(portfolio));
        console.log("BaseCBBTCYieldAdapter:", address(adapter));
    }
}
