// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/adapters/ERC4626NativeStakingAdapter.sol";
import "../contracts/core/ClearcrestCCIPNAVReceiver.sol";
import "../contracts/core/ClearcrestHubNAV.sol";
import "../contracts/core/ClearcrestNativeSpokePortfolio.sol";
import "../contracts/interfaces/ICCIPReceiver.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockERC4626Vault.sol";
import "../contracts/mocks/MockPriceFeed.sol";

contract NativeStakingPhase4Test is Test {
    uint64 constant AVAX_CHAIN_ID = 43114;
    uint64 constant AVAX_CCIP_SELECTOR = 15_971_525_489_660_198_786;

    address owner = address(this);
    address router = makeAddr("ccipRouter");
    address receiverWallet = makeAddr("receiverWallet");

    MockERC20 asset;
    MockERC4626Vault stakingVault;
    MockPriceFeed priceFeed;
    ERC4626NativeStakingAdapter adapter;
    ClearcrestNativeSpokePortfolio portfolio;

    function setUp() public {
        asset = new MockERC20("Wrapped AVAX", "WAVAX", 18);
        stakingVault = new MockERC4626Vault(asset, "Staked Native AVAX", "stkAVAX");
        priceFeed = new MockPriceFeed(20e8, 8);

        portfolio = new ClearcrestNativeSpokePortfolio(owner, AVAX_CHAIN_ID);
        adapter = new ERC4626NativeStakingAdapter(
            owner, address(portfolio), address(asset), address(stakingVault), address(priceFeed), 24 hours
        );

        address[] memory adapters = new address[](1);
        adapters[0] = address(adapter);
        portfolio.setAdapters(adapters);
    }

    function test_ERC4626NativeAdapterStakesAndPricesAssetNAV() public {
        asset.mint(address(adapter), 100e18);

        vm.prank(address(portfolio));
        adapter.deploy(100e18);

        assertEq(adapter.totalAssetsAsset(), 100e18);
        assertEq(adapter.totalAssetsUSDC(), 2_000e6);

        asset.mint(address(stakingVault), 10e18);

        assertApproxEqAbs(adapter.totalAssetsAsset(), 110e18, 1);
        assertApproxEqAbs(adapter.totalAssetsUSDC(), 2_200e6, 1);
    }

    function test_ERC4626NativeAdapterWithdrawsToControllerReceiver() public {
        asset.mint(address(adapter), 100e18);

        vm.prank(address(portfolio));
        adapter.deploy(100e18);

        vm.prank(address(portfolio));
        uint256 returned = adapter.withdraw(25e18, receiverWallet);

        assertEq(returned, 25e18);
        assertEq(asset.balanceOf(receiverWallet), 25e18);
        assertEq(adapter.totalAssetsAsset(), 75e18);
    }

    function test_NativeSpokePortfolioPreparesMonotonicNAVReport() public {
        asset.mint(address(adapter), 100e18);
        vm.prank(address(portfolio));
        adapter.deploy(100e18);

        bytes memory report = portfolio.prepareReport();
        (uint64 chainId, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(report, (uint64, uint256, uint256, uint256, uint64));

        assertEq(chainId, AVAX_CHAIN_ID);
        assertEq(navUsd18, 2_000e18);
        assertEq(reportedAt, block.timestamp);
        assertEq(sourceBlockNumber, block.number);
        assertEq(nonce, 1);
        assertEq(portfolio.totalAssetsUSDC(), 2_000e6);
    }

    function test_NativeSpokeReportRelaysThroughCCIPReceiverToHub() public {
        asset.mint(address(adapter), 100e18);
        vm.prank(address(portfolio));
        adapter.deploy(100e18);

        ClearcrestHubNAV hub = new ClearcrestHubNAV(owner);
        ClearcrestCCIPNAVReceiver receiver = new ClearcrestCCIPNAVReceiver(owner, router, address(hub));
        hub.configureSpoke(AVAX_CHAIN_ID, address(receiver), 24 hours, 1_000, true, true);
        receiver.configureSource(AVAX_CCIP_SELECTOR, AVAX_CHAIN_ID, abi.encode(address(portfolio)), true);

        bytes memory report = portfolio.prepareReport();
        ICCIPReceiver.Any2EVMMessage memory message = ICCIPReceiver.Any2EVMMessage({
            messageId: keccak256(report),
            sourceChainSelector: AVAX_CCIP_SELECTOR,
            sender: abi.encode(address(portfolio)),
            data: report,
            destTokenAmounts: new ICCIPReceiver.EVMTokenAmount[](0)
        });

        vm.prank(router);
        receiver.ccipReceive(message);

        assertEq(hub.totalSpokeNAV18(), 2_000e18);
        assertEq(hub.totalSpokeNAVUSDC(), 2_000e6);
    }

    function test_AdapterRejectsStalePrice() public {
        asset.mint(address(adapter), 100e18);
        vm.prank(address(portfolio));
        adapter.deploy(100e18);

        adapter.setMaxStale(1 hours);
        vm.warp(block.timestamp + 3 hours);
        priceFeed.setStale();

        vm.expectRevert(abi.encodeWithSelector(ERC4626NativeStakingAdapter.StalePrice.selector, address(priceFeed)));
        adapter.totalAssetsUSDC();
    }
}
