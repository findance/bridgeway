// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../contracts/mocks/MockAToken.sol";
import "../contracts/mocks/MockAerodromeCbbtcStrategy.sol";
import "../contracts/mocks/MockAaveV3Pool.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";

contract BaseCBBTCYieldAdapterTest is Test {
    MockERC20 cbbtc;
    MockAToken aCbbtc;
    MockAaveV3Pool aavePool;
    MockAerodromeCbbtcStrategy aerodrome;
    MockPriceFeed btcUsdFeed;
    BaseCBBTCYieldAdapter adapter;

    address controller = address(this);
    address owner = address(this);
    address receiver = makeAddr("receiver");

    function setUp() public {
        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        aCbbtc = new MockAToken("Aave Base cbBTC", "aBasCbBTC", 8);
        aavePool = new MockAaveV3Pool(address(cbbtc), address(aCbbtc));
        aCbbtc.setMinter(address(aavePool));
        aerodrome = new MockAerodromeCbbtcStrategy(address(cbbtc), 500);
        btcUsdFeed = new MockPriceFeed(100_000e8, 8);

        adapter = new BaseCBBTCYieldAdapter(
            owner,
            controller,
            address(cbbtc),
            address(aavePool),
            address(aCbbtc),
            address(aerodrome),
            address(btcUsdFeed),
            receiver,
            24 hours
        );
    }

    function test_DeployAllocatesEightyTwentyWhenAerodromeNetApyIsAboveFloor() public {
        cbbtc.mint(address(adapter), 100e8);

        adapter.deploy(100e8);

        assertEq(aCbbtc.balanceOf(address(adapter)), 80e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 20e8);
        assertEq(adapter.totalAssetsAsset(), 100e8);
        assertEq(adapter.totalAssetsUSDC(), 10_000_000e6);
    }

    function test_DeployUsesAaveOnlyWhenAerodromeNetApyIsBelowFloor() public {
        aerodrome.setNetApyBps(449);
        cbbtc.mint(address(adapter), 100e8);

        adapter.deploy(100e8);

        assertEq(aCbbtc.balanceOf(address(adapter)), 100e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 0);
    }

    function test_DeployUsesAaveOnlyWhenAerodromeMarkIsStale() public {
        aerodrome.setMaxMarkStale(1 hours);
        vm.warp(block.timestamp + 2 hours);
        cbbtc.mint(address(adapter), 100e8);

        adapter.deploy(100e8);

        assertEq(aCbbtc.balanceOf(address(adapter)), 100e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 0);
    }

    function test_RebalanceExitsAerodromeToAaveWhenNetApyDropsBelowFourPointFivePercent() public {
        cbbtc.mint(address(adapter), 100e8);
        adapter.deploy(100e8);

        aerodrome.setNetApyBps(400);
        adapter.rebalance();

        assertEq(aCbbtc.balanceOf(address(adapter)), 100e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 0);
    }

    function test_HarvestCompoundsRewardsAndMaintainsEightyTwentyWhenApyIsHealthy() public {
        cbbtc.mint(address(adapter), 100e8);
        adapter.deploy(100e8);
        cbbtc.mint(address(aerodrome), 1e8);

        uint256 harvested = adapter.harvest();

        assertEq(harvested, 1e8);
        assertEq(adapter.totalAssetsAsset(), 101e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 202_00000000 / 10); // 20.2 cbBTC
        assertEq(aCbbtc.balanceOf(address(adapter)), 808_00000000 / 10); // 80.8 cbBTC
    }

    function test_WithdrawUsesAaveBeforeAerodrome() public {
        cbbtc.mint(address(adapter), 100e8);
        adapter.deploy(100e8);

        uint256 returned = adapter.withdraw(90e8, receiver);

        assertEq(returned, 90e8);
        assertEq(cbbtc.balanceOf(receiver), 90e8);
        assertEq(aCbbtc.balanceOf(address(adapter)), 0);
        assertEq(aerodrome.totalAssetsCbbtc(), 10e8);
    }

    function test_ControllerCanWithdrawAllToReceiver() public {
        cbbtc.mint(address(adapter), 100e8);
        adapter.deploy(100e8);

        uint256 returned = adapter.withdrawAll(receiver);

        assertEq(returned, 100e8);
        assertEq(cbbtc.balanceOf(receiver), 100e8);
        assertEq(adapter.totalAssetsAsset(), 0);
        assertEq(aCbbtc.balanceOf(address(adapter)), 0);
        assertEq(aerodrome.totalAssetsCbbtc(), 0);
    }

    function test_AdapterRejectsStalePrice() public {
        cbbtc.mint(address(adapter), 1e8);
        adapter.deploy(1e8);

        adapter.setMaxStale(1 hours);
        vm.warp(block.timestamp + 3 hours);
        btcUsdFeed.setStale();

        vm.expectRevert(abi.encodeWithSelector(BaseCBBTCYieldAdapter.StalePrice.selector, address(btcUsdFeed)));
        adapter.totalAssetsUSDC();
    }

    /// L-01: emergency funds must converge at the controller (= wrapper),
    /// which then swaps cbBTC to USDC and forwards to the vault. The
    /// `rescueReceiver` field is retained for backward compatibility but is
    /// no longer the emergency destination.
    function test_EmergencyWithdrawAllSendsToController() public {
        cbbtc.mint(address(adapter), 100e8);
        adapter.deploy(100e8);

        uint256 returned = adapter.emergencyWithdrawAll();

        assertEq(returned, 100e8);
        assertEq(cbbtc.balanceOf(controller), 100e8);
        assertEq(cbbtc.balanceOf(receiver), 0);
        assertEq(adapter.rescueReceiver(), receiver);
    }
}
