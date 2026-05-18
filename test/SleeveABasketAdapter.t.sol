// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/SleeveABasketAdapter.sol";
import "../contracts/core/BridgewayRegistry.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";
import "../contracts/mocks/MockSwapRouter.sol";
import "../contracts/mocks/MockUSDC.sol";

contract SleeveABasketAdapterTest is Test {
    MockUSDC usdc;
    MockSwapRouter router;
    SleeveABasketAdapter adapter;
    BridgewayRegistry registry;

    MockERC20 asset1;
    MockERC20 asset2;
    MockERC20 asset3;
    MockERC20 asset4;

    MockPriceFeed feed1;
    MockPriceFeed feed2;
    MockPriceFeed feed3;
    MockPriceFeed feed4;

    bytes32 constant ASSET_1 = keccak256("ASSET_1");
    bytes32 constant ASSET_2 = keccak256("ASSET_2");
    bytes32 constant ASSET_3 = keccak256("ASSET_3");
    bytes32 constant ASSET_4 = keccak256("ASSET_4");

    address vault = address(this);
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockUSDC();
        router = new MockSwapRouter();
        registry = new BridgewayRegistry(owner);

        asset1 = new MockERC20("Asset 1", "A1", 18);
        asset2 = new MockERC20("Asset 2", "A2", 18);
        asset3 = new MockERC20("Asset 3", "A3", 18);
        asset4 = new MockERC20("Asset 4", "A4", 18);

        feed1 = new MockPriceFeed(100e8, 8);
        feed2 = new MockPriceFeed(50e8, 8);
        feed3 = new MockPriceFeed(25e8, 8);
        feed4 = new MockPriceFeed(10e8, 8);

        adapter = new SleeveABasketAdapter(address(this), owner, address(usdc), address(router));

        _setRates(asset1, 10_000_000_000, 10_000_000_000);
        _setRates(asset2, 20_000_000_000, 20_000_000_000);
        _setRates(asset3, 40_000_000_000, 40_000_000_000);
        _setRates(asset4, 100_000_000_000, 100_000_000_000);

        asset1.mint(address(router), 1_000_000e18);
        asset2.mint(address(router), 1_000_000e18);
        asset3.mint(address(router), 1_000_000e18);
        asset4.mint(address(router), 1_000_000e18);
        usdc.mint(address(router), 1_000_000e6);

        adapter.setAssets(_defaultAssets());
    }

    function test_DeployAllocatesByConfiguredWeightsAndReportsNAV() public {
        usdc.mint(address(adapter), 1_000e6);

        adapter.deploy(1_000e6);

        assertEq(asset1.balanceOf(address(adapter)), 3e18);
        assertEq(asset2.balanceOf(address(adapter)), 6e18);
        assertEq(asset3.balanceOf(address(adapter)), 10e18);
        assertEq(asset4.balanceOf(address(adapter)), 15e18);
        assertEq(adapter.totalAssetsUSDC(), 1_000e6);
    }

    function test_WithdrawSellsPositionsProRataAndReturnsUSDC() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 returned = adapter.withdraw(100e6);

        assertEq(returned, 100e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 100e6);
        assertEq(adapter.totalAssetsUSDC(), 900e6);
    }

    function test_HarvestReturnsIdleUSDCToVault() public {
        usdc.mint(address(adapter), 12e6);

        assertEq(adapter.totalAssetsUSDC(), 12e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 harvested = adapter.harvest();

        assertEq(harvested, 12e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 12e6);
    }

    function test_WithdrawUsesIdleUSDCBeforeSellingAssets() public {
        usdc.mint(address(adapter), 1_012e6);
        adapter.deploy(1_000e6);

        uint256 beforeBalance = usdc.balanceOf(vault);
        uint256 returned = adapter.withdraw(100e6);

        assertEq(returned, 100e6);
        assertEq(usdc.balanceOf(vault) - beforeBalance, 100e6);
        assertEq(adapter.totalAssetsUSDC(), 912e6);
    }

    function test_RebalanceSellsOverweightAndBuysUnderweightAssets() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        feed1.setPrice(200e8);
        router.setRate(address(asset1), address(usdc), 1, 5_000_000_000);

        uint256 asset1Before = asset1.balanceOf(address(adapter));
        uint256 asset2Before = asset2.balanceOf(address(adapter));

        adapter.rebalance();

        assertLt(asset1.balanceOf(address(adapter)), asset1Before);
        assertGt(asset2.balanceOf(address(adapter)), asset2Before);
    }

    function test_EmergencyUnwindAssetDoesNotRequireFreshOracle() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);
        feed1.setStale();

        uint256 asset1Before = asset1.balanceOf(address(adapter));
        adapter.emergencyUnwindAsset(0, asset1Before / 2);

        assertEq(asset1.balanceOf(address(adapter)), asset1Before / 2);
        assertGt(usdc.balanceOf(address(adapter)), 0);
    }

    function test_RejectsIncompleteOracleRound() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        feed1.setIncompleteRound(true);

        vm.expectRevert(abi.encodeWithSelector(SleeveABasketAdapter.InvalidPrice.selector, address(feed1)));
        adapter.totalAssetsUSDC();
    }

    function test_EmergencyUnwindAllConvertsBasketToUSDC() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        adapter.emergencyUnwindAll();

        assertEq(asset1.balanceOf(address(adapter)), 0);
        assertEq(asset2.balanceOf(address(adapter)), 0);
        assertEq(asset3.balanceOf(address(adapter)), 0);
        assertEq(asset4.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 1_000e6);
    }

    function test_SetAssetsRequiresSleeveAWeightPolicy() public {
        SleeveABasketAdapter.AssetInput[] memory assets = _defaultAssets();
        assets[0].weightBps = 3_100;
        assets[1].weightBps = 2_900;

        vm.expectRevert(SleeveABasketAdapter.InvalidWeight.selector);
        adapter.setAssets(assets);
    }

    function test_SetAssetsRejectsDuplicateAssets() public {
        SleeveABasketAdapter.AssetInput[] memory assets = _defaultAssets();
        assets[1].token = assets[0].token;

        vm.expectRevert(SleeveABasketAdapter.DuplicateAsset.selector);
        adapter.setAssets(assets);
    }

    function test_SetAssetsRejectsInvalidSwapPath() public {
        SleeveABasketAdapter.AssetInput[] memory assets = _defaultAssets();
        assets[0].buyPath[0] = address(asset1);

        vm.expectRevert(SleeveABasketAdapter.InvalidSwapPath.selector);
        adapter.setAssets(assets);
    }

    function test_SetAssetsFromRegistryResolvesChainLocalTokenAndFeedConfig() public {
        SleeveABasketAdapter registryAdapter = new SleeveABasketAdapter(address(this), owner, address(usdc), address(router));
        _seedRegistry(true);

        registryAdapter.setRegistry(address(registry));
        registryAdapter.setAssetsFromRegistry(_defaultRegistryAssets());

        SleeveABasketAdapter.AssetConfig memory configured = registryAdapter.assetAt(0);
        assertEq(configured.token, address(asset1));
        assertEq(configured.priceFeed, address(feed1));
        assertEq(configured.tokenDecimals, 18);
        assertEq(configured.weightBps, 3_000);
    }

    function test_SetAssetsFromRegistryRejectsUntrustedAsset() public {
        SleeveABasketAdapter registryAdapter = new SleeveABasketAdapter(address(this), owner, address(usdc), address(router));
        _seedRegistry(false);

        registryAdapter.setRegistry(address(registry));
        vm.expectRevert(abi.encodeWithSelector(SleeveABasketAdapter.AssetNotTrusted.selector, ASSET_1));
        registryAdapter.setAssetsFromRegistry(_defaultRegistryAssets());
    }

    function test_SetAssetsRequiresEmptyAdapter() public {
        usdc.mint(address(adapter), 1_000e6);
        adapter.deploy(1_000e6);

        vm.expectRevert(SleeveABasketAdapter.AdapterNotEmpty.selector);
        adapter.setAssets(_defaultAssets());
    }

    function test_OnlyVaultCanMoveFunds() public {
        vm.startPrank(stranger);
        vm.expectRevert(SleeveABasketAdapter.OnlyVault.selector);
        adapter.deploy(1e6);
        vm.expectRevert(SleeveABasketAdapter.OnlyVault.selector);
        adapter.withdraw(1e6);
        vm.expectRevert(SleeveABasketAdapter.OnlyVault.selector);
        adapter.harvest();
        vm.stopPrank();
    }

    function _defaultAssets() internal view returns (SleeveABasketAdapter.AssetInput[] memory assets) {
        assets = new SleeveABasketAdapter.AssetInput[](4);
        assets[0] = _assetInput(address(asset1), address(feed1), 3_000);
        assets[1] = _assetInput(address(asset2), address(feed2), 3_000);
        assets[2] = _assetInput(address(asset3), address(feed3), 2_500);
        assets[3] = _assetInput(address(asset4), address(feed4), 1_500);
    }

    function _assetInput(address token, address feed, uint16 weightBps)
        internal
        view
        returns (SleeveABasketAdapter.AssetInput memory input)
    {
        address[] memory buyPath = new address[](2);
        buyPath[0] = address(usdc);
        buyPath[1] = token;

        address[] memory sellPath = new address[](2);
        sellPath[0] = token;
        sellPath[1] = address(usdc);

        input = SleeveABasketAdapter.AssetInput({
            token: token,
            priceFeed: feed,
            weightBps: weightBps,
            tokenDecimals: 18,
            maxStale: 1 hours,
            buyPath: buyPath,
            sellPath: sellPath
        });
    }

    function _setRates(MockERC20 asset, uint256 buyRate, uint256 sellDenominator) internal {
        router.setRate(address(usdc), address(asset), buyRate, 1);
        router.setRate(address(asset), address(usdc), 1, sellDenominator);
    }

    function _defaultRegistryAssets()
        internal
        view
        returns (SleeveABasketAdapter.RegistryAssetInput[] memory assets)
    {
        assets = new SleeveABasketAdapter.RegistryAssetInput[](4);
        assets[0] = _registryAssetInput(ASSET_1, address(asset1), 3_000);
        assets[1] = _registryAssetInput(ASSET_2, address(asset2), 3_000);
        assets[2] = _registryAssetInput(ASSET_3, address(asset3), 2_500);
        assets[3] = _registryAssetInput(ASSET_4, address(asset4), 1_500);
    }

    function _registryAssetInput(bytes32 assetId, address token, uint16 weightBps)
        internal
        view
        returns (SleeveABasketAdapter.RegistryAssetInput memory input)
    {
        address[] memory buyPath = new address[](2);
        buyPath[0] = address(usdc);
        buyPath[1] = token;

        address[] memory sellPath = new address[](2);
        sellPath[0] = token;
        sellPath[1] = address(usdc);

        input = SleeveABasketAdapter.RegistryAssetInput({
            assetId: assetId,
            weightBps: weightBps,
            maxStale: 1 hours,
            buyPath: buyPath,
            sellPath: sellPath
        });
    }

    function _seedRegistry(bool trustFirstAsset) internal {
        registry.setAsset(ASSET_1, address(asset1), address(feed1), 18, 8, trustFirstAsset);
        registry.setAsset(ASSET_2, address(asset2), address(feed2), 18, 8, true);
        registry.setAsset(ASSET_3, address(asset3), address(feed3), 18, 8, true);
        registry.setAsset(ASSET_4, address(asset4), address(feed4), 18, 8, true);
    }
}
