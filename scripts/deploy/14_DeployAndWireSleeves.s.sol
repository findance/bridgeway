// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/adapters/AerodromeCbbtcStrategy.sol";
import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/adapters/SleeveACbbtcWrapper.sol";
import "../../contracts/adapters/SleeveBStableYieldAdapter.sol";
import "../../contracts/core/BGWVault.sol";

/// @title 14_DeployAndWireSleeves
/// @notice Deploys the full Sleeve A cbBTC yield stack (wrapper → yield adapter →
///         Aerodrome strategy) and Sleeve B (stable yield), then wires both into
///         the vault with 65/35/0 weights and protected-token registration.
///
/// This script merges the cbBTC spoke deployment into the sleeve wiring step
/// because BaseCBBTCYieldAdapter.controller is immutable and must be set to the
/// SleeveACbbtcWrapper address at construction time.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY, VAULT, VAULT_OWNER
///   USDC, CBBTC, AAVE_POOL, A_USDC, A_CBBTC
///   AERO, AERODROME_SWAP_ROUTER, AERODROME_POSITION_MANAGER
///   BTC_USD_PRICE_FEED, AERODROME_TICK_SPACING, AERODROME_TICK_LOWER, AERODROME_TICK_UPPER
///   MORPHO_VAULT
///
/// Optional:
///   AERODROME_GAUGE, STRATEGY_KEEPER, MAX_STALE_SECONDS, AERODROME_ROUTER_V2, RESCUE_RECEIVER
///   INITIAL_AERODROME_NET_APY_BPS
contract DeployAndWireSleeves is Script {
    struct Cfg {
        address vault;
        address vaultOwner;
        address usdc;
        address cbbtc;
        address aavePool;
        address aUsdc;
        address aCbbtc;
        address aero;
        address swapRouter;
        address positionManager;
        address gauge;
        address btcFeed;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        address keeper;
        uint256 maxStale;
        address wrapperRouter;
        address morphoVault;
        address rescueReceiver;
        uint256 initialAerodromeNetApyBps;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        Cfg memory c = _load(deployer);

        vm.startBroadcast(deployerKey);

        // 1. Sleeve A Wrapper (deploy first — address needed as immutable controller)
        SleeveACbbtcWrapper wrapper = new SleeveACbbtcWrapper(
            c.vault, deployer, c.usdc, c.cbbtc, c.wrapperRouter, c.btcFeed, c.tickSpacing, c.maxStale
        );
        console.log("SleeveACbbtcWrapper:", address(wrapper));

        // 2. Aerodrome strategy
        AerodromeCbbtcStrategy strategy = new AerodromeCbbtcStrategy(
            AerodromeCbbtcStrategy.ConstructorParams({
                owner: deployer,
                controller: deployer,
                keeper: c.keeper,
                cbbtc: c.cbbtc,
                usdc: c.usdc,
                aero: c.aero,
                positionManager: c.positionManager,
                swapRouter: c.swapRouter,
                gauge: c.gauge,
                btcUsdFeed: c.btcFeed,
                tickSpacing: c.tickSpacing,
                tickLower: c.tickLower,
                tickUpper: c.tickUpper
            })
        );
        console.log("AerodromeCbbtcStrategy:", address(strategy));
        strategy.markToMarket(0, c.initialAerodromeNetApyBps);

        // 3. cbBTC yield adapter — controller = wrapper (immutable)
        BaseCBBTCYieldAdapter yieldAdapter = new BaseCBBTCYieldAdapter(
            deployer,
            address(wrapper),
            c.cbbtc,
            c.aavePool,
            c.aCbbtc,
            address(strategy),
            c.btcFeed,
            c.rescueReceiver,
            c.maxStale
        );
        console.log("BaseCBBTCYieldAdapter:", address(yieldAdapter));

        strategy.setController(address(yieldAdapter));

        // 4. Configure wrapper
        wrapper.setYieldAdapter(address(yieldAdapter));

        // 5. Sleeve B
        SleeveBStableYieldAdapter sleeveB = new SleeveBStableYieldAdapter(
            c.vault, deployer, c.usdc, c.aavePool, c.aUsdc, c.morphoVault
        );
        console.log("SleeveBStableYieldAdapter:", address(sleeveB));

        // 6. Wire into vault
        _wireVault(BGWVault(c.vault), address(wrapper), address(sleeveB), c.aUsdc, c.morphoVault, c.cbbtc, c.aCbbtc);

        // 7. Transfer ownerships
        if (c.vaultOwner != deployer) {
            wrapper.transferOwnership(c.vaultOwner);
            strategy.transferOwnership(c.vaultOwner);
            yieldAdapter.transferOwnership(c.vaultOwner);
            sleeveB.transferOwnership(c.vaultOwner);
            console.log("Ownership transfers initiated to:", c.vaultOwner);
        }

        vm.stopBroadcast();
    }

    function _wireVault(
        BGWVault vault,
        address sleeveA,
        address sleeveB,
        address aUsdc,
        address morphoVault,
        address cbbtc,
        address aCbbtc
    ) internal {
        vault.setSleeveAdapter(0, sleeveA);
        vault.setSleeveAdapter(1, sleeveB);
        console.log("Sleeves wired: A =", sleeveA, " B =", sleeveB);

        vault.setSleeveDepositWeights(6500, 3500, 0);
        console.log("Deposit weights: 6500 / 3500 / 0");

        address[] memory pt = new address[](4);
        pt[0] = aUsdc;
        pt[1] = morphoVault;
        pt[2] = cbbtc;
        pt[3] = aCbbtc;
        vault.setProtectedTokenBatch(pt, true);
        console.log("Protected tokens registered.");
    }

    function _load(address deployer) internal view returns (Cfg memory c) {
        c.vault = vm.envAddress("VAULT");
        c.vaultOwner = vm.envAddress("VAULT_OWNER");
        c.usdc = vm.envAddress("USDC");
        c.cbbtc = vm.envAddress("CBBTC");
        c.aavePool = vm.envAddress("AAVE_POOL");
        c.aUsdc = vm.envAddress("A_USDC");
        c.aCbbtc = vm.envAddress("A_CBBTC");
        c.aero = vm.envAddress("AERO");
        c.swapRouter = vm.envAddress("AERODROME_SWAP_ROUTER");
        c.positionManager = vm.envAddress("AERODROME_POSITION_MANAGER");
        c.gauge = vm.envOr("AERODROME_GAUGE", address(0));
        c.btcFeed = vm.envAddress("BTC_USD_PRICE_FEED");
        c.tickSpacing = int24(vm.envInt("AERODROME_TICK_SPACING"));
        c.tickLower = int24(vm.envInt("AERODROME_TICK_LOWER"));
        c.tickUpper = int24(vm.envInt("AERODROME_TICK_UPPER"));
        c.keeper = vm.envOr("STRATEGY_KEEPER", deployer);
        c.maxStale = vm.envOr("MAX_STALE_SECONDS", uint256(0));
        c.wrapperRouter = vm.envOr("AERODROME_ROUTER_V2", c.swapRouter);
        c.morphoVault = vm.envAddress("MORPHO_VAULT");
        c.rescueReceiver = vm.envOr("RESCUE_RECEIVER", c.vaultOwner);
        c.initialAerodromeNetApyBps = vm.envOr("INITIAL_AERODROME_NET_APY_BPS", uint256(500));
    }
}
