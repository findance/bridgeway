// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/SleeveCAlphaYieldAdapter.sol";
import "../contracts/mocks/MockERC4626Vault.sol";
import "../contracts/mocks/MockUSDC.sol";

contract SleeveCAlphaYieldAdapterTest is Test {
    MockUSDC usdc;
    MockERC4626Vault ethenaLike;
    MockERC4626Vault pendleLike;
    MockERC4626Vault curveLike;
    SleeveCAlphaYieldAdapter adapter;

    address vault = address(this);
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        ethenaLike = new MockERC4626Vault(usdc, "Ethena USDC Wrapper", "eUSDC");
        pendleLike = new MockERC4626Vault(usdc, "Pendle Fixed USDC", "pUSDC");
        curveLike = new MockERC4626Vault(usdc, "Curve USDC Wrapper", "cUSDC");
        adapter = new SleeveCAlphaYieldAdapter(vault, owner, address(usdc));
        adapter.setStrategies(_defaultStrategies());
    }

    function test_DeployAllocatesAcrossCappedStrategiesAndTracksPrincipal() public {
        usdc.mint(address(adapter), 1_000e6);

        adapter.deploy(1_000e6);

        assertEq(ethenaLike.convertToAssets(ethenaLike.balanceOf(address(adapter))), 500e6);
        assertEq(pendleLike.convertToAssets(pendleLike.balanceOf(address(adapter))), 500e6);
        assertEq(adapter.accountingPrincipal(), 1_000e6);
        assertEq(adapter.totalAssetsUSDC(), 1_000e6);
    }

    function test_StrategyWeightCannotExceedFiftyPercent() public {
        SleeveCAlphaYieldAdapter.StrategyInput[] memory strategies = new SleeveCAlphaYieldAdapter.StrategyInput[](2);
        strategies[0] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(ethenaLike), weightBps: 6_000});
        strategies[1] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(pendleLike), weightBps: 4_000});

        vm.expectRevert(SleeveCAlphaYieldAdapter.InvalidStrategyWeight.selector);
        adapter.setStrategies(strategies);
    }

    function test_HarvestRealisesOnlyGrowthAndLeavesPrincipalInSleeveC() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);
        usdc.mint(address(ethenaLike), 50e6);
        usdc.mint(address(pendleLike), 50e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 harvested = adapter.harvest();

        assertApproxEqAbs(harvested, 100e6, 2);
        assertApproxEqAbs(usdc.balanceOf(vault) - beforeBalance, 100e6, 2);
        assertEq(adapter.accountingPrincipal(), 1_000e6);
        assertApproxEqAbs(adapter.totalAssetsUSDC(), 1_000e6, 1);
    }

    function test_WithdrawReducesAccountingPrincipal() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 returned = adapter.withdraw(200e6);

        assertEq(returned, 200e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 200e6);
        assertEq(adapter.accountingPrincipal(), 800e6);
        assertEq(adapter.totalAssetsUSDC(), 800e6);
    }

    function test_SetStrategiesRequiresEmptyAdapter() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        vm.expectRevert(SleeveCAlphaYieldAdapter.AdapterNotEmpty.selector);
        adapter.setStrategies(_defaultStrategies());
    }

    function test_CanReplaceOldStrategyAfterEmergencyWithdraw() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        SleeveCAlphaYieldAdapter.StrategyInput[] memory replacement = _replacementStrategies();
        vm.expectRevert(SleeveCAlphaYieldAdapter.AdapterNotEmpty.selector);
        adapter.setStrategies(replacement);

        uint256 vaultBefore = usdc.balanceOf(vault);
        uint256 returned = adapter.emergencyWithdrawAll();
        adapter.setStrategies(replacement);

        assertEq(returned, 1_000e6);
        assertEq(usdc.balanceOf(vault) - vaultBefore, 1_000e6);
        assertEq(adapter.strategyCount(), 2);
        assertEq(address(adapter.strategyAt(0).vault), address(pendleLike));
        assertEq(address(adapter.strategyAt(1).vault), address(curveLike));
    }

    function test_OnlyVaultCanMoveFunds() public {
        vm.startPrank(stranger);
        vm.expectRevert(SleeveCAlphaYieldAdapter.OnlyVault.selector);
        adapter.deploy(1e6);
        vm.expectRevert(SleeveCAlphaYieldAdapter.OnlyVault.selector);
        adapter.withdraw(1e6);
        vm.expectRevert(SleeveCAlphaYieldAdapter.OnlyVault.selector);
        adapter.harvest();
        vm.stopPrank();
    }

    function _defaultStrategies() internal view returns (SleeveCAlphaYieldAdapter.StrategyInput[] memory strategies) {
        strategies = new SleeveCAlphaYieldAdapter.StrategyInput[](2);
        strategies[0] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(ethenaLike), weightBps: 5_000});
        strategies[1] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(pendleLike), weightBps: 5_000});
    }

    function _replacementStrategies()
        internal
        view
        returns (SleeveCAlphaYieldAdapter.StrategyInput[] memory strategies)
    {
        strategies = new SleeveCAlphaYieldAdapter.StrategyInput[](2);
        strategies[0] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(pendleLike), weightBps: 5_000});
        strategies[1] = SleeveCAlphaYieldAdapter.StrategyInput({vault: address(curveLike), weightBps: 5_000});
    }
}
