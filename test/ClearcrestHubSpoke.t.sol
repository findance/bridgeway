// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/ClearcrestHubNAV.sol";
import "../contracts/core/ClearcrestSpokeReporter.sol";

contract ClearcrestHubSpokeTest is Test {
    ClearcrestHubNAV hub;
    ClearcrestSpokeReporter baseSpoke;
    ClearcrestSpokeReporter avaxSpoke;

    event GlobalNAVVarianceBreached(uint256 oldNavUsd18, uint256 newNavUsd18, uint256 varianceBps);

    uint64 constant BASE_CHAIN_ID = 8453;
    uint64 constant AVAX_CHAIN_ID = 43114;

    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        hub = new ClearcrestHubNAV(owner);
        baseSpoke = new ClearcrestSpokeReporter(owner, BASE_CHAIN_ID);
        avaxSpoke = new ClearcrestSpokeReporter(owner, AVAX_CHAIN_ID);

        hub.configureSpoke(BASE_CHAIN_ID, address(baseSpoke), 24 hours, 1_000, true, true);
        hub.configureSpoke(AVAX_CHAIN_ID, address(avaxSpoke), 24 hours, 1_000, true, true);
    }

    function test_SpokeBuildsReportAndHubAcceptsConfirmedNAV() public {
        hub.configureSpoke(AVAX_CHAIN_ID, address(avaxSpoke), 24 hours, 1_000, true, false);
        baseSpoke.updateLocalNAV(1_000e18);
        (uint64 chainId, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        assertEq(chainId, BASE_CHAIN_ID);
        assertEq(navUsd18, 1_000e18);
        assertEq(nonce, 1);

        vm.prank(address(baseSpoke));
        hub.reportSpokeNAV(chainId, navUsd18, reportedAt, sourceBlockNumber, nonce);

        assertEq(hub.totalSpokeNAV18(), 1_000e18);
        assertEq(hub.totalSpokeNAVUSDC(), 1_000e6);
    }

    function test_SpokeConfigRequiresTimelockAfterBootstrapFinalized() public {
        ClearcrestSpokeReporter replacement = new ClearcrestSpokeReporter(owner, BASE_CHAIN_ID);

        vm.expectRevert(ClearcrestHubNAV.BootstrapActive.selector);
        hub.proposeSpokeConfig(BASE_CHAIN_ID, address(replacement), 12 hours, 500, true, true);

        hub.finalizeConfiguration();
        assertFalse(hub.bootstrapMode());

        vm.expectRevert(ClearcrestHubNAV.ConfigurationFinalized.selector);
        hub.configureSpoke(BASE_CHAIN_ID, address(replacement), 12 hours, 500, true, true);

        uint256 executableAt = hub.proposeSpokeConfig(BASE_CHAIN_ID, address(replacement), 12 hours, 500, true, true);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.TimelockNotReady.selector, BASE_CHAIN_ID, executableAt));
        hub.executeSpokeConfig(BASE_CHAIN_ID);

        vm.warp(executableAt);
        hub.executeSpokeConfig(BASE_CHAIN_ID);

        (address reporter, uint256 maxReportAge, uint256 maxNavMoveBps, bool enabled, bool material) =
            hub.spokeConfigs(BASE_CHAIN_ID);
        assertEq(reporter, address(replacement));
        assertEq(maxReportAge, 12 hours);
        assertEq(maxNavMoveBps, 500);
        assertTrue(enabled);
        assertTrue(material);
    }

    function test_SpokeConfigRejectsNavMoveBpsAboveOneHundredPercent() public {
        uint256 tooHigh = hub.MAX_NAV_MOVE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.InvalidNavMoveBps.selector, tooHigh));
        hub.configureSpoke(BASE_CHAIN_ID, address(baseSpoke), 24 hours, tooHigh, true, true);
    }

    function test_HubAggregatesMultipleSpokes() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        assertEq(hub.totalSpokeNAV18(), 1_500e18);
        assertEq(hub.totalSpokeNAVUSDC(), 1_500e6);
    }

    function test_RejectsUnauthorizedReporter() public {
        baseSpoke.updateLocalNAV(1_000e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(stranger);
        vm.expectRevert(ClearcrestHubNAV.InvalidReporter.selector);
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_RejectsNonIncreasingNonce() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);

        (uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            hub.spokeReports(BASE_CHAIN_ID);
        vm.prank(address(baseSpoke));
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.NonceNotIncreasing.selector, BASE_CHAIN_ID));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_RejectsLargeNAVMove() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        baseSpoke.updateLocalNAV(1_250e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.NavMoveTooLarge.selector, BASE_CHAIN_ID));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_GlobalNAVVarianceRejectsReport() public {
        hub.configureSpoke(BASE_CHAIN_ID, address(baseSpoke), 24 hours, 3_000, true, true);
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        baseSpoke.updateLocalNAV(1_100e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(ClearcrestHubNAV.GlobalNavVarianceTooLarge.selector, 1_500e18, 1_600e18, 666)
        );
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);

        assertFalse(hub.circuitBreakerActive());
        assertEq(hub.totalSpokeNAV18(), 1_500e18);
    }

    function test_GlobalNAVVarianceStoresDownwardReportAndTripsCircuitBreaker() public {
        hub.configureSpoke(BASE_CHAIN_ID, address(baseSpoke), 24 hours, 3_000, true, true);
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        baseSpoke.updateLocalNAV(900e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.expectEmit(false, false, false, true);
        emit GlobalNAVVarianceBreached(1_500e18, 1_400e18, 666);
        vm.prank(address(baseSpoke));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);

        (uint256 storedNav,,,) = hub.spokeReports(BASE_CHAIN_ID);
        assertEq(storedNav, 900e18);
        assertTrue(hub.circuitBreakerActive());
        vm.expectRevert(ClearcrestHubNAV.CircuitBreakerActive.selector);
        hub.totalSpokeNAV18();
    }

    function test_WindowNavGrowthRejectsSlowCompounding() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        hub.setMaxGlobalNavMoveBps(3_000);

        vm.warp(block.timestamp + 1 hours);
        baseSpoke.updateLocalNAV(1_100e18);
        _report(baseSpoke, BASE_CHAIN_ID, 1_100e18);

        vm.warp(block.timestamp + 1 hours);
        baseSpoke.updateLocalNAV(1_210e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert(
            abi.encodeWithSelector(ClearcrestHubNAV.WindowNavGrowthTooLarge.selector, BASE_CHAIN_ID, 210e18, 200e18)
        );
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_NavWindowHasBounds() public {
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.InvalidNavWindow.selector, 1 hours - 1));
        hub.setNavWindow(1 hours - 1);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.InvalidNavWindow.selector, 7 days + 1));
        hub.setNavWindow(7 days + 1);

        hub.setNavWindow(2 days);
        assertEq(hub.navWindow(), 2 days);
    }

    function test_ReporterMustBeContract() public {
        address eoaReporter = makeAddr("eoaReporter");
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.ReporterMustBeContract.selector, eoaReporter));
        hub.configureSpoke(BASE_CHAIN_ID, eoaReporter, 24 hours, 1_000, true, true);
    }

    function test_FirstSpokeReportDoesNotTripGlobalCircuitBreaker() public {
        hub.configureSpoke(AVAX_CHAIN_ID, address(avaxSpoke), 24 hours, 1_000, true, false);
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);

        assertFalse(hub.circuitBreakerActive());
        assertEq(hub.totalSpokeNAV18(), 1_000e18);
    }

    function test_GlobalNavMoveCapHasUpperBound() public {
        uint256 tooHigh = hub.MAX_GLOBAL_NAV_MOVE_BPS() + 1;
        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.InvalidNavMoveBps.selector, tooHigh));
        hub.setMaxGlobalNavMoveBps(tooHigh);
    }

    function test_MaterialStaleSpokeBlocksAggregateNAV() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestHubNAV.StaleReport.selector, BASE_CHAIN_ID));
        hub.totalSpokeNAV18();
    }

    function test_NonMaterialStaleSpokeDoesNotBlockAggregateNAV() public {
        hub.configureSpoke(AVAX_CHAIN_ID, address(avaxSpoke), 24 hours, 1_000, true, false);
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        vm.warp(block.timestamp + 25 hours);
        _report(baseSpoke, BASE_CHAIN_ID, 1_001e18);

        assertEq(hub.totalSpokeNAV18(), 1_501e18);
    }

    function test_PauseBlocksNewReports() public {
        hub.pause();
        baseSpoke.updateLocalNAV(1_000e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert();
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function _report(ClearcrestSpokeReporter spoke, uint64 chainId, uint256 navUsd18) internal {
        spoke.updateLocalNAV(navUsd18);
        (, uint256 reportNavUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(spoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(spoke));
        hub.reportSpokeNAV(chainId, reportNavUsd18, reportedAt, sourceBlockNumber, nonce);
    }
}
