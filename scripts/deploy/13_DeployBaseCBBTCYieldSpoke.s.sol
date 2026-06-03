// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/adapters/AerodromeCbbtcStrategy.sol";
import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/core/ClearcrestNativeSpokePortfolio.sol";

/// @title 13_DeployBaseCBBTCYieldSpoke
/// @notice Deploys the Base cbBTC spoke portfolio plus the 80% Aave / 20%
///         Aerodrome yield adapter.
///
/// Required env vars:
///   DEPLOYER  signer address used by --account
///   SPOKE_OWNER
///   BASE_CHAIN_ID
///   CBBTC
///   AAVE_POOL
///   A_CBBTC
///   USDC
///   AERO
///   AERODROME_POSITION_MANAGER
///   AERODROME_SWAP_ROUTER
///   BTC_USD_PRICE_FEED
///   AERODROME_TICK_SPACING
///   AERODROME_TICK_LOWER
///   AERODROME_TICK_UPPER
///
/// Optional env vars:
///   MAX_STALE_SECONDS
///   AERODROME_GAUGE
///   STRATEGY_KEEPER (defaults to deployer)
///   RESCUE_RECEIVER (defaults to SPOKE_OWNER)
///
/// The Aerodrome strategy must expose netApyBps(). The adapter exits that leg
/// back to Aave whenever net APY is below 4.5%.
contract DeployBaseCBBTCYieldSpoke is Script {
    struct Config {
        address spokeOwner;
        uint64 baseChainId;
        address cbbtc;
        address aavePool;
        address aCbbtc;
        address usdc;
        address aero;
        address positionManager;
        address swapRouter;
        address gauge;
        address btcUsdPriceFeed;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        address strategyKeeper;
        address rescueReceiver;
        uint256 maxStale;
    }

    function run() external {
        address deployer = vm.envAddress("DEPLOYER");
        Config memory cfg = _loadConfig(deployer);

        vm.startBroadcast(deployer);

        ClearcrestNativeSpokePortfolio portfolio = new ClearcrestNativeSpokePortfolio(deployer, cfg.baseChainId);
        AerodromeCbbtcStrategy strategy = new AerodromeCbbtcStrategy(
            AerodromeCbbtcStrategy.ConstructorParams({
                owner: deployer,
                controller: deployer,
                keeper: cfg.strategyKeeper,
                cbbtc: cfg.cbbtc,
                usdc: cfg.usdc,
                aero: cfg.aero,
                positionManager: cfg.positionManager,
                swapRouter: cfg.swapRouter,
                gauge: cfg.gauge,
                btcUsdFeed: cfg.btcUsdPriceFeed,
                tickSpacing: cfg.tickSpacing,
                tickLower: cfg.tickLower,
                tickUpper: cfg.tickUpper
            })
        );
        BaseCBBTCYieldAdapter adapter = new BaseCBBTCYieldAdapter(
            deployer,
            address(portfolio),
            cfg.cbbtc,
            cfg.aavePool,
            cfg.aCbbtc,
            address(strategy),
            cfg.btcUsdPriceFeed,
            cfg.rescueReceiver,
            cfg.maxStale
        );
        strategy.setController(address(adapter));

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        portfolio.setAdapters(adapters);

        if (cfg.spokeOwner != deployer) {
            strategy.transferOwnership(cfg.spokeOwner);
            adapter.transferOwnership(cfg.spokeOwner);
            portfolio.transferOwnership(cfg.spokeOwner);
        }

        vm.stopBroadcast();

        console.log("ClearcrestNativeSpokePortfolio:", address(portfolio));
        console.log("AerodromeCbbtcStrategy:", address(strategy));
        console.log("BaseCBBTCYieldAdapter:", address(adapter));
    }

    function _loadConfig(address deployer) internal view returns (Config memory cfg) {
        cfg.spokeOwner = vm.envAddress("SPOKE_OWNER");
        cfg.baseChainId = uint64(vm.envUint("BASE_CHAIN_ID"));
        cfg.cbbtc = vm.envAddress("CBBTC");
        cfg.aavePool = vm.envAddress("AAVE_POOL");
        cfg.aCbbtc = vm.envAddress("A_CBBTC");
        cfg.usdc = vm.envAddress("USDC");
        cfg.aero = vm.envAddress("AERO");
        cfg.positionManager = vm.envAddress("AERODROME_POSITION_MANAGER");
        cfg.swapRouter = vm.envAddress("AERODROME_SWAP_ROUTER");
        cfg.gauge = vm.envOr("AERODROME_GAUGE", address(0));
        cfg.btcUsdPriceFeed = vm.envAddress("BTC_USD_PRICE_FEED");
        cfg.tickSpacing = int24(vm.envInt("AERODROME_TICK_SPACING"));
        cfg.tickLower = int24(vm.envInt("AERODROME_TICK_LOWER"));
        cfg.tickUpper = int24(vm.envInt("AERODROME_TICK_UPPER"));
        cfg.strategyKeeper = vm.envOr("STRATEGY_KEEPER", deployer);
        cfg.rescueReceiver = vm.envOr("RESCUE_RECEIVER", cfg.spokeOwner);
        cfg.maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));
    }
}
