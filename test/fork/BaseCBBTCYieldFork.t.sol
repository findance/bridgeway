// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../../contracts/adapters/AerodromeCbbtcStrategy.sol";
import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/interfaces/IAerodromeSlipstream.sol";
import "../../contracts/mocks/MockAerodromeCbbtcStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IAaveV3PoolReserveData {
    struct ReserveConfigurationMap {
        uint256 data;
    }

    struct ReserveData {
        ReserveConfigurationMap configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}

contract BaseCBBTCYieldForkTest is Test {
    uint256 constant BASE_CHAIN_ID = 8453;

    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant BTC_USD_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;

    address constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    address constant AERODROME_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    address constant AERODROME_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant AERODROME_USDC_CBBTC_CL100_POOL = 0x4e962BB3889Bf030368F56810A9c96B83CB3E778;

    uint256 constant SAMPLE_CBBTC = 1e8; // 1 cbBTC

    function testFork_BaseCbbtcAaveAndAerodromeContractsAreLive() public {
        if (!_selectBaseFork()) return;

        assertEq(block.chainid, BASE_CHAIN_ID);
        assertEq(IERC20Metadata(CBBTC).decimals(), 8);
        assertEq(IERC20Metadata(USDC).decimals(), 6);
        assertGt(AAVE_POOL.code.length, 0, "Aave pool missing");
        assertGt(BTC_USD_FEED.code.length, 0, "BTC/USD feed missing");
        assertGt(AERODROME_POSITION_MANAGER.code.length, 0, "Aerodrome NPM missing");
        assertGt(AERODROME_SWAP_ROUTER.code.length, 0, "Aerodrome router missing");
        assertGt(AERODROME_USDC_CBBTC_CL100_POOL.code.length, 0, "Aerodrome cbBTC/USDC pool missing");

        address aCbbtc = _aCbbtc();
        assertGt(aCbbtc.code.length, 0, "Aave cbBTC aToken missing");
        assertEq(IERC20Metadata(aCbbtc).decimals(), 8);
    }

    function testFork_BaseCbbtcAdapterSuppliesAndWithdrawsRealAaveReserve() public {
        if (!_selectBaseFork()) return;

        address aCbbtc = _aCbbtc();
        MockAerodromeCbbtcStrategy aerodrome = new MockAerodromeCbbtcStrategy(CBBTC, 500);
        BaseCBBTCYieldAdapter adapter = new BaseCBBTCYieldAdapter(
            address(this),
            address(this),
            CBBTC,
            AAVE_POOL,
            aCbbtc,
            address(aerodrome),
            BTC_USD_FEED,
            address(this),
            24 hours
        );

        deal(CBBTC, address(adapter), SAMPLE_CBBTC);
        adapter.deploy(SAMPLE_CBBTC);

        assertApproxEqAbs(IERC20Metadata(aCbbtc).balanceOf(address(adapter)), 0.8e8, 2);
        assertEq(aerodrome.totalAssetsCbbtc(), 0.2e8);
        assertGt(adapter.totalAssetsUSDC(), 0);

        address receiver = makeAddr("receiver");
        uint256 returned = adapter.withdraw(0.5e8, receiver);

        assertApproxEqAbs(returned, 0.5e8, 2);
        assertApproxEqAbs(IERC20Metadata(CBBTC).balanceOf(receiver), 0.5e8, 2);
    }

    function testFork_BaseCbbtcAdapterExitsAerodromeToRealAaveWhenNetApyFalls() public {
        if (!_selectBaseFork()) return;

        address aCbbtc = _aCbbtc();
        MockAerodromeCbbtcStrategy aerodrome = new MockAerodromeCbbtcStrategy(CBBTC, 500);
        BaseCBBTCYieldAdapter adapter = new BaseCBBTCYieldAdapter(
            address(this),
            address(this),
            CBBTC,
            AAVE_POOL,
            aCbbtc,
            address(aerodrome),
            BTC_USD_FEED,
            address(this),
            24 hours
        );

        deal(CBBTC, address(adapter), SAMPLE_CBBTC);
        adapter.deploy(SAMPLE_CBBTC);

        aerodrome.setNetApyBps(449);
        adapter.rebalance();

        assertEq(aerodrome.totalAssetsCbbtc(), 0);
        assertApproxEqAbs(IERC20Metadata(aCbbtc).balanceOf(address(adapter)), SAMPLE_CBBTC, 2);
    }

    function testFork_AerodromeCbbtcStrategyConstructsAgainstLiveBaseContracts() public {
        if (!_selectBaseFork()) return;

        AerodromeCbbtcStrategy strategy = new AerodromeCbbtcStrategy(
            AerodromeCbbtcStrategy.ConstructorParams({
                owner: address(this),
                controller: address(this),
                keeper: address(this),
                cbbtc: CBBTC,
                usdc: USDC,
                aero: AERO,
                positionManager: AERODROME_POSITION_MANAGER,
                swapRouter: AERODROME_SWAP_ROUTER,
                gauge: address(0),
                btcUsdFeed: BTC_USD_FEED,
                tickSpacing: 100,
                tickLower: -887200,
                tickUpper: 887200
            })
        );

        strategy.markToMarket(SAMPLE_CBBTC, 500);

        assertEq(strategy.asset(), CBBTC);
        assertEq(strategy.token0(), USDC);
        assertEq(strategy.token1(), CBBTC);
        assertFalse(strategy.cbbtcIsToken0());
        assertEq(strategy.totalAssetsCbbtc(), SAMPLE_CBBTC);
    }

    function test_AerodromeCbbtcStrategyAcceptsPositionNftsOnlyFromPositionManager() public {
        AerodromeCbbtcStrategy strategy = new AerodromeCbbtcStrategy(
            AerodromeCbbtcStrategy.ConstructorParams({
                owner: address(this),
                controller: address(this),
                keeper: address(this),
                cbbtc: CBBTC,
                usdc: USDC,
                aero: AERO,
                positionManager: AERODROME_POSITION_MANAGER,
                swapRouter: AERODROME_SWAP_ROUTER,
                gauge: address(0),
                btcUsdFeed: BTC_USD_FEED,
                tickSpacing: 100,
                tickLower: -887200,
                tickUpper: 887200
            })
        );

        vm.prank(AERODROME_POSITION_MANAGER);
        assertEq(
            strategy.onERC721Received(address(this), address(this), 1, ""),
            IERC721Receiver.onERC721Received.selector
        );

        vm.expectRevert(AerodromeCbbtcStrategy.InvalidPair.selector);
        strategy.onERC721Received(address(this), address(this), 1, "");
    }

    function _selectBaseFork() internal returns (bool selected) {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return false;
        vm.createSelectFork(rpcUrl);
        selected = true;
    }

    function _aCbbtc() internal view returns (address) {
        IAaveV3PoolReserveData.ReserveData memory reserve =
            IAaveV3PoolReserveData(AAVE_POOL).getReserveData(CBBTC);
        return reserve.aTokenAddress;
    }
}
