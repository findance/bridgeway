// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/Pausable.sol";

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

contract MockPendleMarket {
    uint256 public immutable expiry;

    constructor(uint256 expiry_) {
        expiry = expiry_;
    }
}

contract MockPendleRouter {
    MockERC20 public immutable pt;
    MockERC20 public immutable usdc;
    uint256 public spendPt;
    uint256 public mintUsdc;
    uint256 public spendUsdc;
    uint256 public mintPt;

    constructor(MockERC20 pt_, MockERC20 usdc_) {
        pt = pt_;
        usdc = usdc_;
    }

    function setSwap(uint256 spendPt_, uint256 mintUsdc_) external {
        spendPt = spendPt_;
        mintUsdc = mintUsdc_;
    }

    function setBuy(uint256 spendUsdc_, uint256 mintPt_) external {
        spendUsdc = spendUsdc_;
        mintPt = mintPt_;
    }

    function swap() external {
        pt.transferFrom(msg.sender, address(this), spendPt);
        usdc.mint(msg.sender, mintUsdc);
    }

    function buy() external {
        usdc.transferFrom(msg.sender, address(this), spendUsdc);
        pt.mint(msg.sender, mintPt);
    }
}

contract MockPendleRollRouter {
    MockERC20 public immutable oldPt;
    MockERC20 public immutable nextPt;
    MockERC20 public immutable usdc;
    uint256 public spendOldPt;
    uint256 public mintUsdc;
    uint256 public spendUsdc;
    uint256 public mintNextPt;

    constructor(MockERC20 oldPt_, MockERC20 nextPt_, MockERC20 usdc_) {
        oldPt = oldPt_;
        nextPt = nextPt_;
        usdc = usdc_;
    }

    function setRedeem(uint256 spendOldPt_, uint256 mintUsdc_) external {
        spendOldPt = spendOldPt_;
        mintUsdc = mintUsdc_;
    }

    function setBuy(uint256 spendUsdc_, uint256 mintNextPt_) external {
        spendUsdc = spendUsdc_;
        mintNextPt = mintNextPt_;
    }

    function redeem() external {
        oldPt.transferFrom(msg.sender, address(this), spendOldPt);
        usdc.mint(msg.sender, mintUsdc);
    }

    function buy() external {
        usdc.transferFrom(msg.sender, address(this), spendUsdc);
        nextPt.mint(msg.sender, mintNextPt);
    }
}

contract ClearcrestPTSpokePortfolioTest is Test {
    ClearcrestPTSpokePortfolio spoke;
    MockERC20 pt;
    MockERC20 usdc;
    MockPendlePtOracle oracle;
    MockPriceFeed assetUsdFeed;
    MockPriceFeed discountedFeed;
    MockPendleRouter router;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address claimRecorder = makeAddr("claimRecorder");
    address recipient = makeAddr("recipient");
    address market;

    function setUp() public {
        vm.warp(10 days);

        pt = new MockERC20("PT sUSDe", "PT-sUSDe", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockPendlePtOracle();
        assetUsdFeed = new MockPriceFeed(1e8, 8);
        discountedFeed = new MockPriceFeed(0.5e8, 8);
        router = new MockPendleRouter(pt, usdc);
        market = address(new MockPendleMarket(block.timestamp + 30 days));

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

    function test_EmergencyReceiverDefaultsToOwnerAndCanBeChanged() public {
        address nextReceiver = makeAddr("nextReceiver");

        assertEq(spoke.emergencyReceiver(), owner);

        vm.prank(owner);
        spoke.setEmergencyReceiver(nextReceiver);

        assertEq(spoke.emergencyReceiver(), nextReceiver);
    }

    function test_RecordClaimCanMoveToDedicatedRecorder() public {
        bytes32 claimId = keccak256("claim");

        vm.prank(owner);
        spoke.setClaimRecorder(claimRecorder);

        vm.expectRevert(ClearcrestPTSpokePortfolio.OnlyClaimRecorder.selector);
        vm.prank(operator);
        spoke.recordClaim(claimId, recipient, 1e18);

        vm.prank(claimRecorder);
        spoke.recordClaim(claimId, recipient, 1e18);

        (address recordedRecipient, uint256 ptAmount, uint256 positionId,, bool settled) = spoke.claims(claimId);
        assertEq(recordedRecipient, recipient);
        assertEq(ptAmount, 1e18);
        assertEq(positionId, 0);
        assertFalse(settled);
    }

    function test_StaleFeedRevertsValuation() public {
        pt.mint(address(spoke), 1e18);
        assetUsdFeed.setStale();

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.StalePrice.selector, address(assetUsdFeed)));
        spoke.totalAssetsUSDC();
    }

    function test_PositionCanUseDedicatedUsdFeed() public {
        MockERC20 nextPt = new MockERC20("PT RWA", "PT-RWA", 18);
        address nextMarket = makeAddr("nextMarket");

        vm.prank(owner);
        spoke.addPositionWithFeed(address(nextPt), nextMarket, address(discountedFeed), uint64(block.timestamp + 60 days));

        nextPt.mint(address(spoke), 100e18);

        assertEq(spoke.totalAssetsUSDC(), 50e6);

        (,, address positionFeed,,,) = spoke.positionAt(1);
        assertEq(positionFeed, address(discountedFeed));
    }

    function test_PositionCapLimitsValuation() public {
        pt.mint(address(spoke), 100e18);

        vm.prank(owner);
        spoke.setPositionCapUsdc(0, 100e6);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.PositionCapExceeded.selector, 0, 100e6, 99e6));
        vm.prank(owner);
        spoke.setPositionCapUsdc(0, 99e6);
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

    function test_InKindSettlementUsesRecordedPositionToken() public {
        MockERC20 nextPt = new MockERC20("PT RWA", "PT-RWA", 18);
        address nextMarket = makeAddr("nextMarket");
        bytes32 claimId = keccak256("position-claim");

        vm.prank(owner);
        spoke.addPositionWithFeed(address(nextPt), nextMarket, address(discountedFeed), uint64(block.timestamp + 60 days));
        nextPt.mint(address(spoke), 4e18);
        pt.mint(address(spoke), 7e18);

        vm.prank(operator);
        spoke.recordClaimForPosition(claimId, recipient, 1, 4e18);

        vm.prank(operator);
        spoke.fulfillInKind(claimId);

        assertEq(nextPt.balanceOf(recipient), 4e18);
        assertEq(pt.balanceOf(recipient), 0);
        assertEq(pt.balanceOf(address(spoke)), 7e18);
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

    function test_BuyPtWithUsdcRequiresApprovedSubParPrice() public {
        usdc.mint(address(spoke), 1_000e6);
        router.setBuy(990e6, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.PriceAboveLimit.selector, 0.99e18, 0.98e18));
        vm.prank(operator);
        spoke.buyPtWithUsdc(0, 990e6, 1_000e18, 0.98e18, 0, abi.encodeWithSelector(MockPendleRouter.buy.selector));
    }

    function test_BuyPtWithUsdcRequiresMinimumImpliedApy() public {
        usdc.mint(address(spoke), 1_000e6);
        router.setBuy(990e6, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.ImpliedApyTooLow.selector, 1228, 2_000));
        vm.prank(operator);
        spoke.buyPtWithUsdc(0, 990e6, 1_000e18, 0.995e18, 2_000, abi.encodeWithSelector(MockPendleRouter.buy.selector));
    }

    function test_BuyPtWithUsdcAcceptsDiscountedFill() public {
        usdc.mint(address(spoke), 1_000e6);
        router.setBuy(950e6, 1_000e18);

        vm.prank(operator);
        (uint256 usdcSpent, uint256 ptReceived, uint256 actualPrice) =
            spoke.buyPtWithUsdc(0, 950e6, 1_000e18, 0.96e18, 100, abi.encodeWithSelector(MockPendleRouter.buy.selector));

        assertEq(usdcSpent, 950e6);
        assertEq(ptReceived, 1_000e18);
        assertEq(actualPrice, 0.95e18);
        assertEq(pt.balanceOf(address(spoke)), 1_000e18);
    }

    function test_PauseBlocksNormalBuyButAllowsUnpause() public {
        usdc.mint(address(spoke), 1_000e6);
        router.setBuy(950e6, 1_000e18);

        vm.prank(owner);
        spoke.pause();
        assertTrue(spoke.paused());

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(operator);
        spoke.buyPtWithUsdc(0, 950e6, 1_000e18, 0.96e18, 100, abi.encodeWithSelector(MockPendleRouter.buy.selector));

        vm.prank(owner);
        spoke.unpause();
        assertFalse(spoke.paused());
    }

    function test_BuyPtWithUsdcRejectsPositionCapExceeded() public {
        usdc.mint(address(spoke), 1_000e6);
        router.setBuy(950e6, 1_000e18);

        vm.prank(owner);
        spoke.setPositionCapUsdc(0, 900e6);

        vm.expectRevert(abi.encodeWithSelector(ClearcrestPTSpokePortfolio.PositionCapExceeded.selector, 0, 1_000e6, 900e6));
        vm.prank(operator);
        spoke.buyPtWithUsdc(0, 950e6, 1_000e18, 0.96e18, 100, abi.encodeWithSelector(MockPendleRouter.buy.selector));
    }

    function test_RollMaturedRebuysUnderEntryGuard() public {
        MockERC20 nextPt = new MockERC20("PT sUSDe Next", "PT-sUSDe-N", 18);
        MockPendleRollRouter nextRouter = new MockPendleRollRouter(pt, nextPt, usdc);
        address nextMarket = makeAddr("nextMarket");

        vm.prank(owner);
        spoke.addPosition(address(nextPt), nextMarket, uint64(block.timestamp + 180 days));
        vm.prank(owner);
        spoke.setPendleRouter(address(nextRouter));

        pt.mint(address(spoke), 1_000e18);
        vm.warp(block.timestamp + 31 days);
        nextRouter.setRedeem(1_000e18, 1_000e6);
        nextRouter.setBuy(950e6, 1_000e18);

        vm.prank(operator);
        (uint256 usdcReceived, uint256 ptReceived, uint256 actualPrice) = spoke.rollMatured(
            0,
            1,
            1_000e6,
            ClearcrestPTSpokePortfolio.BuyConstraints({
                maxUsdcIn: 0, minPtOut: 1_000e18, maxPtPriceUsdc18: 0.96e18, minImpliedApyBps: 100
            }),
            abi.encodeWithSelector(MockPendleRollRouter.redeem.selector),
            abi.encodeWithSelector(MockPendleRollRouter.buy.selector)
        );

        assertEq(usdcReceived, 1_000e6);
        assertEq(ptReceived, 1_000e18);
        assertEq(actualPrice, 0.95e18);
        assertEq(nextPt.balanceOf(address(spoke)), 1_000e18);
    }

    function test_EmergencyWithdrawAllReturnsPtAndUsdc() public {
        MockERC20 nextPt = new MockERC20("PT RWA", "PT-RWA", 18);
        address nextMarket = makeAddr("nextMarket");
        address receiver = makeAddr("receiver");

        vm.prank(owner);
        spoke.addPositionWithFeed(address(nextPt), nextMarket, address(discountedFeed), uint64(block.timestamp + 60 days));

        pt.mint(address(spoke), 5e18);
        nextPt.mint(address(spoke), 3e18);
        usdc.mint(address(spoke), 12e6);

        vm.prank(owner);
        spoke.setEmergencyReceiver(receiver);

        vm.prank(owner);
        uint256 usdcReturned = spoke.emergencyWithdrawAll();

        assertEq(usdcReturned, 12e6);
        assertEq(pt.balanceOf(receiver), 5e18);
        assertEq(nextPt.balanceOf(receiver), 3e18);
        assertEq(usdc.balanceOf(receiver), 12e6);
        assertEq(spoke.totalAssetsUSDC(), 0);
    }

    function test_EmergencyRedeemPositionWorksWhilePaused() public {
        address receiver = makeAddr("receiver");
        pt.mint(address(spoke), 10e18);
        router.setSwap(10e18, 9_900_000);

        vm.prank(owner);
        spoke.pause();

        vm.prank(owner);
        spoke.setEmergencyReceiver(receiver);

        vm.prank(owner);
        uint256 usdcOut = spoke.emergencyRedeemPosition(0, abi.encodeWithSelector(MockPendleRouter.swap.selector), 9_800_000);

        assertEq(usdcOut, 9_900_000);
        assertEq(usdc.balanceOf(receiver), 9_900_000);
        assertEq(pt.balanceOf(address(router)), 10e18);
    }
}
