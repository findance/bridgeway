// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayHubNAV.sol";
import "../contracts/core/BridgewaySpokeReporter.sol";

contract BridgewayHubSpokeTest is Test {
    BridgewayHubNAV hub;
    BridgewaySpokeReporter baseSpoke;
    BridgewaySpokeReporter avaxSpoke;

    uint64 constant BASE_CHAIN_ID = 8453;
    uint64 constant AVAX_CHAIN_ID = 43114;

    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        hub = new BridgewayHubNAV(owner);
        baseSpoke = new BridgewaySpokeReporter(owner, BASE_CHAIN_ID);
        avaxSpoke = new BridgewaySpokeReporter(owner, AVAX_CHAIN_ID);

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
        vm.expectRevert(BridgewayHubNAV.InvalidReporter.selector);
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_RejectsNonIncreasingNonce() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);

        (uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            hub.spokeReports(BASE_CHAIN_ID);
        vm.prank(address(baseSpoke));
        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.NonceNotIncreasing.selector, BASE_CHAIN_ID));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_RejectsLargeNAVMove() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        baseSpoke.updateLocalNAV(1_250e18);
        (, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(baseSpoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(baseSpoke));
        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.NavMoveTooLarge.selector, BASE_CHAIN_ID));
        hub.reportSpokeNAV(BASE_CHAIN_ID, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function test_MaterialStaleSpokeBlocksAggregateNAV() public {
        _report(baseSpoke, BASE_CHAIN_ID, 1_000e18);
        _report(avaxSpoke, AVAX_CHAIN_ID, 500e18);

        vm.warp(block.timestamp + 25 hours);

        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.StaleReport.selector, BASE_CHAIN_ID));
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

    function _report(BridgewaySpokeReporter spoke, uint64 chainId, uint256 navUsd18) internal {
        spoke.updateLocalNAV(navUsd18);
        (, uint256 reportNavUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(spoke.buildReport(), (uint64, uint256, uint256, uint256, uint64));

        vm.prank(address(spoke));
        hub.reportSpokeNAV(chainId, reportNavUsd18, reportedAt, sourceBlockNumber, nonce);
    }
}
