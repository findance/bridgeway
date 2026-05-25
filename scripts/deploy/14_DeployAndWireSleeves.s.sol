// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import "../../contracts/adapters/AerodromeCbbtcStrategy.sol";
import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/adapters/SleeveACbbtcWrapper.sol";
import "../../contracts/adapters/SleeveBStableYieldAdapter.sol";
import "../../contracts/core/ClearcrestAdmin.sol";
import "../../contracts/core/ClearcrestVault.sol";

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
///   ADMIN, AERODROME_GAUGE, STRATEGY_KEEPER, MAX_STALE_SECONDS, AERODROME_ROUTER_V2, RESCUE_RECEIVER
///   INITIAL_AERODROME_NET_APY_BPS, AERO_TO_CBBTC_PATH
contract DeployAndWireSleeves is Script {
    struct Cfg {
        address vault;
        address admin;
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
        bytes aeroToCbbtcPath;
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
        console.log("Aerodrome gauge:", c.gauge);
        strategy.markToMarket(0, c.initialAerodromeNetApyBps);
        if (c.aeroToCbbtcPath.length > 0) {
            strategy.setAeroToCbbtcPath(c.aeroToCbbtcPath);
            console.log("AERO reward compounding path configured.");
        } else {
            console.log("AERO reward compounding path not configured.");
        }

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
        SleeveBStableYieldAdapter sleeveB =
            new SleeveBStableYieldAdapter(c.vault, deployer, c.usdc, c.aavePool, c.aUsdc, c.morphoVault);
        console.log("SleeveBStableYieldAdapter:", address(sleeveB));

        // 6. Wire into vault
        _wireVault(c, address(wrapper), address(sleeveB));

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

    function _wireVault(Cfg memory c, address sleeveA, address sleeveB) internal {
        address[] memory sleeveARoutes = new address[](1);
        sleeveARoutes[0] = sleeveA;
        uint16[] memory sleeveABps = new uint16[](1);
        sleeveABps[0] = 10_000;
        bool[] memory sleeveAActive = new bool[](1);
        sleeveAActive[0] = true;

        address[] memory sleeveBRoutes = new address[](1);
        sleeveBRoutes[0] = sleeveB;
        uint16[] memory sleeveBBps = new uint16[](1);
        sleeveBBps[0] = 10_000;
        bool[] memory sleeveBActive = new bool[](1);
        sleeveBActive[0] = true;

        if (c.admin == address(0)) {
            ClearcrestVault vault = ClearcrestVault(c.vault);
            vault.configureSleeveAdapterRoutes(0, sleeveARoutes, sleeveABps, sleeveAActive);
            vault.configureSleeveAdapterRoutes(1, sleeveBRoutes, sleeveBBps, sleeveBActive);
            vault.setSleeveDepositWeights(6500, 3500, 0);
            vault.setProtectedToken(c.aUsdc, true);
            vault.setProtectedToken(c.morphoVault, true);
            vault.setProtectedToken(c.cbbtc, true);
            vault.setProtectedToken(c.aCbbtc, true);
        } else {
            address[] memory protectedTokens = new address[](4);
            protectedTokens[0] = c.aUsdc;
            protectedTokens[1] = c.morphoVault;
            protectedTokens[2] = c.cbbtc;
            protectedTokens[3] = c.aCbbtc;

            ClearcrestAdmin.Call[] memory calls = new ClearcrestAdmin.Call[](4);
            calls[0] = ClearcrestAdmin.Call({
                target: c.vault,
                data: abi.encodeCall(
                    ClearcrestVault.configureSleeveAdapterRoutes, (0, sleeveARoutes, sleeveABps, sleeveAActive)
                )
            });
            calls[1] = ClearcrestAdmin.Call({
                target: c.vault,
                data: abi.encodeCall(
                    ClearcrestVault.configureSleeveAdapterRoutes, (1, sleeveBRoutes, sleeveBBps, sleeveBActive)
                )
            });
            calls[2] = ClearcrestAdmin.Call({
                target: c.vault, data: abi.encodeCall(ClearcrestVault.setSleeveDepositWeights, (6500, 3500, 0))
            });
            calls[3] = ClearcrestAdmin.Call({
                target: c.admin, data: abi.encodeCall(ClearcrestAdmin.applyProtectedTokenBatch, (protectedTokens, true))
            });
            ClearcrestAdmin(c.admin).executeBootstrapOperation(calls);
        }

        console.log("Sleeves wired: A =", sleeveA, " B =", sleeveB);
        console.log("Deposit weights: 6500 / 3500 / 0");
        console.log("Protected tokens registered.");
    }

    function _load(address deployer) internal view returns (Cfg memory c) {
        c.vault = vm.envAddress("VAULT");
        c.admin = vm.envOr("ADMIN", address(0));
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
        c.aeroToCbbtcPath = vm.envOr("AERO_TO_CBBTC_PATH", bytes(""));
    }
}
