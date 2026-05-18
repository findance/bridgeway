// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../../contracts/core/BridgewayHubNAV.sol";
import "../../contracts/core/BridgewaySpokeReporter.sol";
import "../../contracts/mocks/MockAToken.sol";
import "../../contracts/mocks/MockAaveV3Pool.sol";
import "../../contracts/mocks/MockAerodromeCbbtcStrategy.sol";
import "../../contracts/mocks/MockERC20.sol";
import "../../contracts/mocks/MockPriceFeed.sol";

contract NavRateFuzzTest is Test {
    uint64 constant BASE_CHAIN_ID = 8453;
    uint64 constant AVAX_CHAIN_ID = 43114;
    uint256 constant BPS_DENOM = 10_000;

    BridgewayHubNAV hub;
    BridgewaySpokeReporter baseSpoke;
    BridgewaySpokeReporter avaxSpoke;

    MockERC20 cbbtc;
    MockAToken aCbbtc;
    MockAaveV3Pool aavePool;
    MockAerodromeCbbtcStrategy aerodrome;
    MockPriceFeed btcUsdFeed;
    BaseCBBTCYieldAdapter cbbtcAdapter;

    function setUp() public {
        hub = new BridgewayHubNAV(address(this));
        baseSpoke = new BridgewaySpokeReporter(address(this), BASE_CHAIN_ID);
        avaxSpoke = new BridgewaySpokeReporter(address(this), AVAX_CHAIN_ID);

        hub.configureSpoke(BASE_CHAIN_ID, address(baseSpoke), 24 hours, 3_000, true, true);
        hub.configureSpoke(AVAX_CHAIN_ID, address(avaxSpoke), 24 hours, 3_000, true, true);

        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        aCbbtc = new MockAToken("Aave Base cbBTC", "aBasCbBTC", 8);
        aavePool = new MockAaveV3Pool(address(cbbtc), address(aCbbtc));
        aCbbtc.setMinter(address(aavePool));
        aerodrome = new MockAerodromeCbbtcStrategy(address(cbbtc), 500);
        btcUsdFeed = new MockPriceFeed(100_000e8, 8);

        cbbtcAdapter = new BaseCBBTCYieldAdapter(
            address(this),
            address(this),
            address(cbbtc),
            address(aavePool),
            address(aCbbtc),
            address(aerodrome),
            address(btcUsdFeed),
            24 hours
        );
    }

    function testFuzz_HubAcceptsBoundedSpokeNAVMove(uint128 startingNav, uint16 moveBps) public {
        startingNav = uint128(bound(uint256(startingNav), 1e18, 1_000_000_000e18));
        moveBps = uint16(bound(uint256(moveBps), 1, 400));

        _report(baseSpoke, BASE_CHAIN_ID, uint256(startingNav));
        uint256 nextNav = uint256(startingNav) + (uint256(startingNav) * moveBps) / BPS_DENOM;
        _report(baseSpoke, BASE_CHAIN_ID, nextNav);

        (uint256 storedNav,,,) = hub.spokeReports(BASE_CHAIN_ID);
        assertEq(storedNav, nextNav);
        assertFalse(hub.circuitBreakerActive());
    }

    function testFuzz_HubRejectsPerSpokeNAVMoveAboveCap(uint128 startingNav, uint16 moveBps) public {
        startingNav = uint128(bound(uint256(startingNav), 1e18, 1_000_000_000e18));
        moveBps = uint16(bound(uint256(moveBps), 3_001, 10_000));

        _report(baseSpoke, BASE_CHAIN_ID, uint256(startingNav));
        uint256 nextNav = uint256(startingNav) + (uint256(startingNav) * moveBps) / BPS_DENOM;

        baseSpoke.updateLocalNAV(nextNav);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.NavMoveTooLarge.selector, BASE_CHAIN_ID));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function testFuzz_GlobalNAVVarianceCircuitBreaker(uint128 baseNav, uint16 moveBps) public {
        baseNav = uint128(bound(uint256(baseNav), 1_000e18, 1_000_000_000e18));
        moveBps = uint16(bound(uint256(moveBps), 501, 2_999));

        _report(baseSpoke, BASE_CHAIN_ID, uint256(baseNav));

        uint256 minDelta = (uint256(baseNav) * moveBps) / BPS_DENOM + 1;
        uint256 nextBaseNav = uint256(baseNav) + minDelta;

        baseSpoke.updateLocalNAV(nextBaseNav);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);

        assertTrue(hub.circuitBreakerActive());
        vm.expectRevert(BridgewayHubNAV.CircuitBreakerActive.selector);
        hub.totalSpokeNAV18();
    }

    function testFuzz_MaterialStaleSpokeBlocksNAV(uint128 navUsd18, uint32 delay) public {
        navUsd18 = uint128(bound(uint256(navUsd18), 1e18, 1_000_000_000e18));
        delay = uint32(bound(uint256(delay), 24 hours + 1, 30 days));

        _report(baseSpoke, BASE_CHAIN_ID, uint256(navUsd18));
        _report(avaxSpoke, AVAX_CHAIN_ID, uint256(navUsd18));

        vm.warp(block.timestamp + delay);

        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.StaleReport.selector, BASE_CHAIN_ID));
        hub.totalSpokeNAV18();
    }

    function testFuzz_CbBtcNAVUsesPriceDecimals(uint128 amountCbbtc, uint128 btcUsdPrice8) public {
        amountCbbtc = uint128(bound(uint256(amountCbbtc), 1, 10_000e8));
        btcUsdPrice8 = uint128(bound(uint256(btcUsdPrice8), 1_000e8, 1_000_000e8));
        btcUsdFeed.setPrice(int256(uint256(btcUsdPrice8)));

        cbbtc.mint(address(cbbtcAdapter), uint256(amountCbbtc));
        cbbtcAdapter.deploy(uint256(amountCbbtc));

        uint256 expectedUsdc =
            (uint256(amountCbbtc) * uint256(btcUsdPrice8) * 1e6) / 1e16;
        assertEq(cbbtcAdapter.totalAssetsUSDC(), expectedUsdc);
    }

    function testFuzz_InverseRateMathRoundTrips(uint128 amount, uint128 ratio) public pure {
        amount = uint128(bound(uint256(amount), 1, 1e30));
        ratio = uint128(bound(uint256(ratio), 1e12, 1e24));

        uint256 underlyingOut = (uint256(amount) * uint256(ratio)) / 1e18;
        uint256 recovered = (underlyingOut * 1e18) / uint256(ratio);

        assertLe(uint256(amount) - recovered, (1e18 / uint256(ratio)) + 1);
    }

    function _report(BridgewaySpokeReporter spoke, uint64 chainId, uint256 navUsd18) internal {
        spoke.updateLocalNAV(navUsd18);
        (, uint256 reportNavUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(spoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(spoke));
        hub.reportSpokeNAV(chainId, reportNavUsd18, reportedAt, sourceBlockNumber, nonce);
    }
}
