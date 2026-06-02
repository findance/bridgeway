// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/ClearcrestPTSpokePortfolio.sol";
import "../contracts/mocks/MockERC20.sol";
import "../contracts/mocks/MockPriceFeed.sol";

contract MockPendlePtOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function getPtToAssetRate(address, uint32) external view returns (uint256) {
        return rate;
    }
}

contract MockPendleRouter {
    MockERC20 public immutable pt;
    MockERC20 public immutable usdc;
    uint256 public spendPt;
    uint256 public mintUsdc;

    constructor(MockERC20 pt_, MockERC20 usdc_) {
        pt = pt_;
        usdc = usdc_;
    }

    function setSwap(uint256 spendPt_, uint256 mintUsdc_) external {
        spendPt = spendPt_;
        mintUsdc = mintUsdc_;
    }

    function swap() external {
        pt.transferFrom(msg.sender, address(this), spendPt);
        usdc.mint(msg.sender, mintUsdc);
    }
}

contract ClearcrestPTSpokePortfolioTest is Test {
    ClearcrestPTSpokePortfolio spoke;
    MockERC20 pt;
    MockERC20 usdc;
    MockPendlePtOracle oracle;
    MockPriceFeed assetUsdFeed;
    MockPendleRouter router;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address recipient = makeAddr("recipient");
    address market = makeAddr("market");

    function setUp() public {
        vm.warp(10 days);

        pt = new MockERC20("PT sUSDe", "PT-sUSDe", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPendlePtOracle();
        assetUsdFeed = new MockPriceFeed(1e8, 8);
        router = new MockPendleRouter(pt, usdc);

        spoke = new ClearcrestPTSpokePortfolio(
            owner,
            operator,
            1,
            address(pt),
            address(usdc),
            market,
            address(oracle),
            address(assetUsdFeed),
            address(router),
            900,
            1 hours,
            1 days
        );
    }

    function test_TotalAssetsUSDCParCapsPtRate() public {
        pt.mint(address(spoke), 100e18);
        oracle.setRate(11e17);

        assertEq(spoke.totalAssetsUSDC(), 100e6);
    }

    function test_PrepareReportUsesExistingSpokeTuple() public {
        pt.mint(address(spoke), 50e18);

        vm.prank(operator);
        bytes memory report = spoke.prepareReport();

        (uint64 sourceChainId, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(report, (uint64, uint256, uint256, uint256, uint64));

        assertEq(sourceChainId, 1);
        assertEq(navUsd18, 50e18);
        assertEq(reportedAt, block.timestamp);
        assertEq(sourceBlockNumber, block.number);
        assertEq(nonce, 1);
    }

    function test_StaleFeedRevertsValuation() public {
        pt.mint(address(spoke), 1e18);
        assetUsdFeed.setStale();

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.StalePrice.selector, address(assetUsdFeed)));
        spoke.totalAssetsUSDC();
    }

    function test_CashSettlementSellsAndRemitsUSDC() public {
        bytes32 claimId = keccak256("claim");
        pt.mint(address(spoke), 10e18);
        router.setSwap(10e18, 9_900_000);

        vm.prank(operator);
        spoke.recordClaim(claimId, recipient, 10e18);

        vm.prank(operator);
        uint256 usdcOut = spoke.sellAndRemit(claimId, abi.encodeWithSelector(MockPendleRouter.swap.selector), 9_800_000);

        assertEq(usdcOut, 9_900_000);
        assertEq(usdc.balanceOf(recipient), 9_900_000);
        assertEq(pt.balanceOf(address(router)), 10e18);
    }

    function test_TimeoutAllowsPermissionlessInKindClaim() public {
        bytes32 claimId = keccak256("claim");
        pt.mint(address(spoke), 3e18);

        vm.prank(operator);
        spoke.recordClaim(claimId, recipient, 3e18);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.TimeoutNotReached.selector, claimId));
        spoke.claimInKindAfterTimeout(claimId);

        vm.warp(block.timestamp + 1 days);
        spoke.claimInKindAfterTimeout(claimId);

        assertEq(pt.balanceOf(recipient), 3e18);
    }
}
