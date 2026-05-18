// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/SleeveBStableYieldAdapter.sol";
import "../contracts/mocks/MockAToken.sol";
import "../contracts/mocks/MockAaveV3Pool.sol";
import "../contracts/mocks/MockERC4626Vault.sol";
import "../contracts/mocks/MockUSDC.sol";

contract SleeveBStableYieldAdapterTest is Test {
    MockUSDC usdc;
    MockAToken aUsdc;
    MockAaveV3Pool aavePool;
    MockERC4626Vault morphoVault;
    SleeveBStableYieldAdapter adapter;

    address vault = address(this);
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken("Aave USDC", "aUSDC", 6);
        aavePool = new MockAaveV3Pool(address(usdc), address(aUsdc));
        aUsdc.setMinter(address(aavePool));
        morphoVault = new MockERC4626Vault(usdc, "Morpho USDC", "mUSDC");

        adapter = new SleeveBStableYieldAdapter(
            vault, owner, address(usdc), address(aavePool), address(aUsdc), address(morphoVault)
        );
    }

    function test_DeployAllocatesSeventyThirtyAndReportsNAV() public {
        usdc.mint(address(adapter), 1_000e6);

        adapter.deploy(1_000e6);

        assertEq(aUsdc.balanceOf(address(adapter)), 700e6);
        assertEq(morphoVault.convertToAssets(morphoVault.balanceOf(address(adapter))), 300e6);
        assertEq(adapter.totalAssetsUSDC(), 1_000e6);
    }

    function test_WithdrawUsesAaveLiquidityBeforeMorpho() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 returned = adapter.withdraw(800e6);

        assertEq(returned, 800e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 800e6);
        assertEq(aUsdc.balanceOf(address(adapter)), 0);
        assertEq(adapter.totalAssetsUSDC(), 200e6);
    }

    function test_RebalanceRestoresSeventyThirtyAfterYield() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        usdc.mint(address(aavePool), 100e6);
        vm.prank(address(aavePool));
        aUsdc.mint(address(adapter), 100e6);

        adapter.rebalance();

        assertEq(adapter.totalAssetsUSDC(), 1_100e6);
        assertApproxEqAbs(aUsdc.balanceOf(address(adapter)), 770e6, 1);
        assertApproxEqAbs(morphoVault.convertToAssets(morphoVault.balanceOf(address(adapter))), 330e6, 1);
    }

    function test_HarvestOnlyReturnsIdleUSDCBecauseStableYieldCompounds() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);
        usdc.mint(address(adapter), 12e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 harvested = adapter.harvest();

        assertEq(harvested, 12e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 12e6);
        assertEq(adapter.totalAssetsUSDC(), 1_000e6);
    }

    function test_OnlyVaultCanMoveFunds() public {
        vm.startPrank(stranger);
        vm.expectRevert(SleeveBStableYieldAdapter.OnlyVault.selector);
        adapter.deploy(1e6);
        vm.expectRevert(SleeveBStableYieldAdapter.OnlyVault.selector);
        adapter.withdraw(1e6);
        vm.expectRevert(SleeveBStableYieldAdapter.OnlyVault.selector);
        adapter.harvest();
        vm.stopPrank();
    }
}
