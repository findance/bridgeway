// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/ClearcrestRegistry.sol";
import "../contracts/libraries/ClearcrestChainConfig.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";

contract ClearcrestRegistryTest is Test {
    ClearcrestRegistry registry;
    MockERC20 weth;
    MockPriceFeed ethFeed;

    bytes32 constant WETH = keccak256("WETH");
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        registry = new ClearcrestRegistry(owner);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethFeed = new MockPriceFeed(3_000e8, 8);
    }

    function test_SetAssetStoresChainLocalConfig() public {
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);

        IClearcrestRegistry.AssetConfig memory config = registry.getAsset(WETH);
        assertEq(config.token, address(weth));
        assertEq(config.priceFeed, address(ethFeed));
        assertEq(config.tokenDecimals, 18);
        assertEq(config.feedDecimals, 8);
        assertTrue(config.trusted);
    }

    function test_SetTrustedUpdatesExistingAsset() public {
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);

        registry.setTrusted(WETH, false);

        IClearcrestRegistry.AssetConfig memory config = registry.getAsset(WETH);
        assertFalse(config.trusted);
    }

    function test_GetAssetRevertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(ClearcrestRegistry.AssetNotConfigured.selector, WETH));
        registry.getAsset(WETH);
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);
    }

    function test_ArbitrumSeedsIncludeCoreSleeveAAssets() public pure {
        ClearcrestChainConfig.AssetSeed[] memory seeds = ClearcrestChainConfig.seeds(ClearcrestChainConfig.ARBITRUM_ONE);

        assertEq(seeds.length, 3);
        assertEq(seeds[1].assetId, ClearcrestChainConfig.ASSET_WETH);
        assertEq(seeds[1].token, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        assertEq(seeds[2].assetId, ClearcrestChainConfig.ASSET_LINK);
        assertEq(seeds[2].token, 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4);
    }

    function test_BaseSeedsIncludeCorePortableAssets() public pure {
        ClearcrestChainConfig.AssetSeed[] memory seeds = ClearcrestChainConfig.seeds(ClearcrestChainConfig.BASE);

        assertEq(seeds.length, 3);
        assertEq(seeds[0].assetId, ClearcrestChainConfig.ASSET_USDC);
        assertEq(seeds[0].token, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(seeds[1].assetId, ClearcrestChainConfig.ASSET_WETH);
        assertEq(seeds[1].token, 0x4200000000000000000000000000000000000006);
        assertEq(seeds[2].assetId, ClearcrestChainConfig.ASSET_LINK);
        assertEq(seeds[2].token, 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196);
    }
}
