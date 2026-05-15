// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayRegistry.sol";
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
}
