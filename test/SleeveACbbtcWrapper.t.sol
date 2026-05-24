// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/BaseCBBTCYieldAdapter.sol";
import "../contracts/adapters/SleeveACbbtcWrapper.sol";
import "../contracts/interfaces/IBaseCBBTCYieldAdapter.sol";
import "../contracts/mocks/MockAToken.sol";
import "../contracts/mocks/MockAerodromeCbbtcStrategy.sol";
import "../contracts/mocks/MockAaveV3Pool.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";
import "../contracts/mocks/MockSwapRouter.sol";

contract SleeveACbbtcWrapperTest is Test {
    MockERC20 usdc;
    MockERC20 cbbtc;
    MockAToken aCbbtc;
    MockAaveV3Pool aavePool;
    MockAerodromeCbbtcStrategy aerodrome;
    MockPriceFeed btcUsdFeed;
    MockSwapRouter router;
    BaseCBBTCYieldAdapter yieldAdapter;
    SleeveACbbtcWrapper wrapper;

    address vault = address(this);
    address owner = address(this);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        cbbtc = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        aCbbtc = new MockAToken("Aave Base cbBTC", "aBasCbBTC", 8);
        aavePool = new MockAaveV3Pool(address(cbbtc), address(aCbbtc));
        aCbbtc.setMinter(address(aavePool));
        aerodrome = new MockAerodromeCbbtcStrategy(address(cbbtc), 500);
        btcUsdFeed = new MockPriceFeed(100_000e8, 8);
        router = new MockSwapRouter();

        router.setRate(address(usdc), address(cbbtc), 1e8, 100_000e6);
        router.setRate(address(cbbtc), address(usdc), 100_000e6, 1e8);
        cbbtc.mint(address(router), 10e8);
        usdc.mint(address(router), 1_000_000e6);

        wrapper = new SleeveACbbtcWrapper(
            vault, owner, address(usdc), address(cbbtc), address(router), address(btcUsdFeed), 100, 24 hours
        );

        yieldAdapter = new BaseCBBTCYieldAdapter(
            owner,
            address(wrapper),
            address(cbbtc),
            address(aavePool),
            address(aCbbtc),
            address(aerodrome),
            address(btcUsdFeed),
            owner,
            24 hours
        );
        wrapper.setYieldAdapter(address(yieldAdapter));
    }

    function test_FreshWrapperTotalAssetsDoesNotRequireMarkedStrategy() public {
        RevertingYieldAdapter revertingAdapter = new RevertingYieldAdapter();
        SleeveACbbtcWrapper fresh = new SleeveACbbtcWrapper(
            vault, owner, address(usdc), address(cbbtc), address(router), address(btcUsdFeed), 100, 24 hours
        );
        fresh.setYieldAdapter(address(revertingAdapter));
        usdc.mint(address(fresh), 123e6);

        assertEq(fresh.totalAssetsUSDC(), 123e6);
    }

    function test_YieldAdapterCanBeSetImmediatelyBeforeTimelockEnabled() public {
        RevertingYieldAdapter replacement = new RevertingYieldAdapter();

        wrapper.setYieldAdapter(address(replacement));

        assertEq(address(wrapper.yieldAdapter()), address(replacement));
    }

    function test_YieldAdapterChangeRequiresTimelockAfterEnabled() public {
        RevertingYieldAdapter replacement = new RevertingYieldAdapter();

        wrapper.enableConfigTimelock();
        vm.expectRevert(SleeveACbbtcWrapper.TimelockActive.selector);
        wrapper.setYieldAdapter(address(replacement));

        wrapper.proposeYieldAdapter(address(replacement));
        vm.expectRevert(SleeveACbbtcWrapper.TimelockNotReady.selector);
        wrapper.executeYieldAdapterProposal();

        vm.warp(block.timestamp + wrapper.CONFIG_DELAY());
        wrapper.executeYieldAdapterProposal();

        assertEq(address(wrapper.yieldAdapter()), address(replacement));
    }

    function test_MaxStaleIsBoundedAtOneDay() public {
        wrapper.setMaxStale(0);
        assertEq(wrapper.maxStale(), 24 hours);

        wrapper.setMaxStale(12 hours);
        assertEq(wrapper.maxStale(), 12 hours);

        vm.expectRevert(SleeveACbbtcWrapper.InvalidMaxStale.selector);
        wrapper.setMaxStale(24 hours + 1);
    }

    function test_TickSpacingMustBeKnownAerodromeSpacing() public {
        wrapper.setTickSpacing(200);
        assertEq(wrapper.tickSpacing(), 200);

        vm.expectRevert(SleeveACbbtcWrapper.InvalidTickSpacing.selector);
        wrapper.setTickSpacing(123);
    }

    function test_ConstructorRejectsUnknownTickSpacingAndTooLargeMaxStale() public {
        vm.expectRevert(SleeveACbbtcWrapper.InvalidTickSpacing.selector);
        new SleeveACbbtcWrapper(
            vault, owner, address(usdc), address(cbbtc), address(router), address(btcUsdFeed), 123, 24 hours
        );

        vm.expectRevert(SleeveACbbtcWrapper.InvalidMaxStale.selector);
        new SleeveACbbtcWrapper(
            vault, owner, address(usdc), address(cbbtc), address(router), address(btcUsdFeed), 100, 24 hours + 1
        );
    }

    function test_DeploySwapsUsdcToCbbtcAndForwardsToYieldAdapter() public {
        usdc.mint(address(wrapper), 100_000e6);

        wrapper.deploy(100_000e6);

        assertTrue(wrapper.adapterActivated());
        assertEq(cbbtc.balanceOf(address(wrapper)), 0);
        assertEq(yieldAdapter.totalAssetsAsset(), 1e8);
        assertEq(wrapper.totalAssetsUSDC(), 100_000e6);
        assertEq(aCbbtc.balanceOf(address(yieldAdapter)), 0.8e8);
        assertEq(aerodrome.totalAssetsCbbtc(), 0.2e8);
    }

    function test_WithdrawReturnsUsdcToVault() public {
        usdc.mint(address(wrapper), 100_000e6);
        wrapper.deploy(100_000e6);

        uint256 vaultBefore = usdc.balanceOf(vault);
        uint256 returned = wrapper.withdraw(50_000e6);

        assertEq(returned, 50_000e6);
        assertEq(usdc.balanceOf(vault) - vaultBefore, 50_000e6);
        assertApproxEqAbs(wrapper.totalAssetsUSDC(), 50_000e6, 2);
    }

    function test_WithdrawReturnsZeroAndKeepsCbbtcAccountedWhenSwapFails() public {
        usdc.mint(address(wrapper), 100_000e6);
        wrapper.deploy(100_000e6);
        router.setPairReverts(address(cbbtc), address(usdc), true);

        uint256 vaultBefore = usdc.balanceOf(vault);
        uint256 returned = wrapper.withdraw(50_000e6);

        assertEq(returned, 0);
        assertEq(usdc.balanceOf(vault), vaultBefore);
        assertGt(cbbtc.balanceOf(address(wrapper)), 0);
        assertApproxEqAbs(wrapper.totalAssetsUSDC(), 100_000e6, 2);
    }

    function test_EmergencyWithdrawAllReturnsUsdcToVault() public {
        usdc.mint(address(wrapper), 100_000e6);
        wrapper.deploy(100_000e6);

        uint256 vaultBefore = usdc.balanceOf(vault);
        uint256 returned = wrapper.emergencyWithdrawAll();

        assertEq(returned, 100_000e6);
        assertEq(usdc.balanceOf(vault) - vaultBefore, 100_000e6);
        assertEq(cbbtc.balanceOf(address(wrapper)), 0);
        assertEq(yieldAdapter.totalAssetsAsset(), 0);
        assertEq(wrapper.totalAssetsUSDC(), 0);
    }

    function test_DeployRejectsStalePrice() public {
        usdc.mint(address(wrapper), 100_000e6);
        wrapper.setMaxStale(1 hours);
        vm.warp(block.timestamp + 3 hours);
        btcUsdFeed.setStale();

        vm.expectRevert(abi.encodeWithSelector(SleeveACbbtcWrapper.StalePrice.selector, address(btcUsdFeed)));
        wrapper.deploy(100_000e6);
    }
}

contract RevertingYieldAdapter is IBaseCBBTCYieldAdapter {
    function deploy(uint256) external pure {}

    function withdraw(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function withdrawAll(address) external pure returns (uint256) {
        return 0;
    }

    function harvest() external pure returns (uint256) {
        return 0;
    }

    function totalAssetsAsset() external pure returns (uint256) {
        revert("unmarked");
    }

    function totalAssetsUSDC() external pure returns (uint256) {
        revert("unmarked");
    }
}
