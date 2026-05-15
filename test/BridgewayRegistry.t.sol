// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayRegistry.sol";
import "../contracts/libraries/BridgewayChainConfig.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";

contract BridgewayRegistryTest is Test {
    BridgewayRegistry registry;
    MockERC20 weth;
    MockPriceFeed ethFeed;

    bytes32 constant WETH = keccak256("WETH");
    address owner = address(this);
    address stranger = makeAddr("stranger");

    function setUp() public {
        registry = new BridgewayRegistry(owner);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        ethFeed = new MockPriceFeed(3_000e8, 8);
    }

    function test_SetAssetStoresChainLocalConfig() public {
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);

        IBridgewayRegistry.AssetConfig memory config = registry.getAsset(WETH);
        assertEq(config.token, address(weth));
        assertEq(config.priceFeed, address(ethFeed));
        assertEq(config.tokenDecimals, 18);
        assertEq(config.feedDecimals, 8);
        assertTrue(config.trusted);
    }

    function test_SetTrustedUpdatesExistingAsset() public {
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);

        registry.setTrusted(WETH, false);

        IBridgewayRegistry.AssetConfig memory config = registry.getAsset(WETH);
        assertFalse(config.trusted);
    }

    function test_GetAssetRevertsWhenMissing() public {
        vm.expectRevert(abi.encodeWithSelector(BridgewayRegistry.AssetNotConfigured.selector, WETH));
        registry.getAsset(WETH);
    }

    function test_OnlyOwnerCanConfigure() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.setAsset(WETH, address(weth), address(ethFeed), 0, 0, true);
    }

    function test_ArbitrumSeedsIncludeCoreSleeveAAssets() public pure {
        BridgewayChainConfig.AssetSeed[] memory seeds =
            BridgewayChainConfig.seeds(BridgewayChainConfig.ARBITRUM_ONE);

        assertEq(seeds.length, 4);
        assertEq(seeds[1].assetId, BridgewayChainConfig.ASSET_WETH);
        assertEq(seeds[1].token, 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
        assertEq(seeds[2].assetId, BridgewayChainConfig.ASSET_WBTC);
        assertEq(seeds[2].token, 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
        assertEq(seeds[3].assetId, BridgewayChainConfig.ASSET_LINK);
        assertEq(seeds[3].token, 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4);
    }

    function test_BaseSeedsIncludeCorePortableAssets() public pure {
        BridgewayChainConfig.AssetSeed[] memory seeds = BridgewayChainConfig.seeds(BridgewayChainConfig.BASE);

        assertEq(seeds.length, 3);
        assertEq(seeds[0].assetId, BridgewayChainConfig.ASSET_USDC);
        assertEq(seeds[0].token, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(seeds[1].assetId, BridgewayChainConfig.ASSET_WETH);
        assertEq(seeds[1].token, 0x4200000000000000000000000000000000000006);
        assertEq(seeds[2].assetId, BridgewayChainConfig.ASSET_CBBTC);
        assertEq(seeds[2].token, 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf);
    }
}
