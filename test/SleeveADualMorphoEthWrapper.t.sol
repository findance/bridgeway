// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/SleeveADualMorphoEthWrapper.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockERC4626Vault.sol";
import "../contracts/mocks/MockPriceFeed.sol";
import "../contracts/mocks/MockSwapRouter.sol";

contract SleeveADualMorphoEthWrapperTest is Test {
    MockERC20 usdc;
    MockERC20 weth;
    MockERC4626Vault vaultA;
    MockERC4626Vault vaultB;
    MockERC4626Vault vaultC;
    MockPriceFeed ethFeed;
    MockSwapRouter router;
    SleeveADualMorphoEthWrapper adapter;

    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        vaultA = new MockERC4626Vault(weth, "Moonwell Flagship ETH", "mwETH");
        vaultB = new MockERC4626Vault(weth, "Gauntlet WETH Core", "gtWETHc");
        vaultC = new MockERC4626Vault(weth, "Replacement WETH", "rWETH");
        ethFeed = new MockPriceFeed(3_000e8, 8);
        router = new MockSwapRouter();

        adapter = new SleeveADualMorphoEthWrapper(
            address(this),
            owner,
            address(usdc),
            address(weth),
            address(router),
            address(ethFeed),
            address(vaultA),
            address(vaultB),
            100,
            24 hours
        );

        router.setRate(address(usdc), address(weth), 1e18, 3_000e6);
        router.setRate(address(weth), address(usdc), 3_000e6, 1e18);
        weth.mint(address(router), 1_000e18);
        usdc.mint(address(router), 3_000_000e6);
    }

    function test_DeploySplitsWethSixtyFortyAcrossMorphoVaults() public {
        _fundAdapterUsdc(3_000e6);

        adapter.deploy(3_000e6);

        (uint256 legA, uint256 legB, uint256 idle) = adapter.legAssetsWeth();
        assertEq(legA, 0.6e18);
        assertEq(legB, 0.4e18);
        assertEq(idle, 0);
        assertEq(adapter.totalAssetsUSDC(), 3_000e6);
    }

    function test_OnlyVaultCanDeployWithdrawAndHarvest() public {
        vm.startPrank(attacker);
        vm.expectRevert(SleeveADualMorphoEthWrapper.OnlyVault.selector);
        adapter.deploy(1);
        vm.expectRevert(SleeveADualMorphoEthWrapper.OnlyVault.selector);
        adapter.withdraw(1);
        vm.expectRevert(SleeveADualMorphoEthWrapper.OnlyVault.selector);
        adapter.harvest();
        vm.stopPrank();
    }

    function test_WithdrawRedeemsProRataAndReturnsUsdc() public {
        _fundAdapterUsdc(3_000e6);
        adapter.deploy(3_000e6);

        uint256 beforeUsdc = usdc.balanceOf(address(this));
        uint256 returned = adapter.withdraw(1_500e6);

        assertEq(returned, 1_500e6);
        assertEq(usdc.balanceOf(address(this)) - beforeUsdc, 1_500e6);

        (uint256 legA, uint256 legB,) = adapter.legAssetsWeth();
        assertEq(legA, 0.3e18);
        assertEq(legB, 0.2e18);
        assertEq(adapter.totalAssetsUSDC(), 1_500e6);
    }

    function test_TotalAssetsUsesPreviewRedeemAndCapturesCompounding() public {
        _fundAdapterUsdc(3_000e6);
        adapter.deploy(3_000e6);

        weth.mint(address(vaultA), 0.06e18);
        weth.mint(address(vaultB), 0.04e18);

        assertApproxEqAbs(adapter.totalAssetsUSDC(), 3_300e6, 1);
        assertEq(adapter.harvest(), 0);
    }

    function test_DeployRevertsWhenUsdcToWethSlippageBreachesChainlinkFloor() public {
        router.setRate(address(usdc), address(weth), 97e16, 3_000e6);
        _fundAdapterUsdc(3_000e6);

        vm.expectRevert("MockSwapRouter: slippage");
        adapter.deploy(3_000e6);
    }

    function test_WithdrawRevertsWhenWethToUsdcSlippageBreachesChainlinkFloor() public {
        _fundAdapterUsdc(3_000e6);
        adapter.deploy(3_000e6);
        router.setRate(address(weth), address(usdc), 2_900e6, 1e18);

        vm.expectRevert("MockSwapRouter: slippage");
        adapter.withdraw(1_000e6);
    }

    function test_StalePriceRevertsValuationAndDeploy() public {
        vm.prank(owner);
        adapter.setMaxStale(1 hours);
        vm.warp(block.timestamp + 3 hours);
        ethFeed.setStale();

        weth.mint(address(adapter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(SleeveADualMorphoEthWrapper.StalePrice.selector, address(ethFeed)));
        adapter.totalAssetsUSDC();

        _fundAdapterUsdc(3_000e6);
        vm.expectRevert(abi.encodeWithSelector(SleeveADualMorphoEthWrapper.StalePrice.selector, address(ethFeed)));
        adapter.deploy(3_000e6);
    }

    function test_MorphoVaultMigrationIsTimelockedPerLeg() public {
        _fundAdapterUsdc(3_000e6);
        adapter.deploy(3_000e6);

        uint8 legA = adapter.LEG_A();
        uint256 delay = adapter.MIGRATION_DELAY();
        vm.startPrank(owner);
        adapter.proposeMorphoVault(legA, address(vaultC));
        vm.expectRevert();
        adapter.executeMorphoVault(legA);
        vm.warp(block.timestamp + delay);
        adapter.executeMorphoVault(legA);
        vm.stopPrank();

        assertEq(address(adapter.morphoVaultA()), address(vaultC));
        assertEq(vaultA.balanceOf(address(adapter)), 0);
        assertGt(vaultC.balanceOf(address(adapter)), 0);
        assertEq(address(adapter.morphoVaultB()), address(vaultB));
    }

    function test_SetSplitRequiresBothLegsAtLeastThirtyPercent() public {
        vm.startPrank(owner);
        adapter.setSplit(5_000, 5_000);
        assertEq(adapter.legABps(), 5_000);
        assertEq(adapter.legBBps(), 5_000);

        vm.expectRevert(SleeveADualMorphoEthWrapper.InvalidSplit.selector);
        adapter.setSplit(8_000, 2_000);
        vm.stopPrank();
    }

    function test_EmergencyWithdrawAllSendsRawWethToReceiver() public {
        _fundAdapterUsdc(3_000e6);
        adapter.deploy(3_000e6);

        address receiver = makeAddr("receiver");
        vm.prank(owner);
        uint256 returned = adapter.emergencyWithdrawAll(receiver);

        assertEq(returned, 1e18);
        assertEq(weth.balanceOf(receiver), 1e18);
        assertEq(vaultA.balanceOf(address(adapter)), 0);
        assertEq(vaultB.balanceOf(address(adapter)), 0);
    }

    function _fundAdapterUsdc(uint256 amount) internal {
        usdc.mint(address(adapter), amount);
    }
}
