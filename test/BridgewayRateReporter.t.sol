// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayL1RateReporter.sol";
import "../contracts/core/BridgewayRateRegistry.sol";
import "../contracts/interfaces/ICCIPReceiver.sol";
import "../contracts/interfaces/ICCIPRouterClient.sol";

contract MockWstLinkRateSource {
    uint256 public rate = 1.222761515949738428e18;
    bool public shouldRevert;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function getUnderlyingByWrapped(uint256 amount) external view returns (uint256) {
        require(!shouldRevert, "rate source paused");
        return amount * rate / 1e18;
    }
}

contract MockCCIPRouter is ICCIPRouterClient {
    uint256 public fee = 0.005 ether;
    uint64 public lastDestinationChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    bytes public lastExtraArgs;
    uint256 public lastValue;

    function setFee(uint256 fee_) external {
        fee = fee_;
    }

    function getFee(uint64, EVM2AnyMessage calldata) external view returns (uint256) {
        return fee;
    }

    function ccipSend(uint64 destinationChainSelector, EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32 messageId)
    {
        lastDestinationChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastExtraArgs = message.extraArgs;
        lastValue = msg.value;
        messageId = keccak256(abi.encode(destinationChainSelector, message.receiver, message.data, msg.value));
    }
}

contract BridgewayRateReporterTest is Test {
    uint64 constant ETH_SELECTOR = 5_009_297_550_715_157_269;
    uint64 constant ARB_SELECTOR = 4_949_039_107_694_359_620;

    address owner = address(this);
    address wstLinkL2 = 0x3106E2e148525b3DB36795b04691D444c24972fB;
    address keeper = makeAddr("keeper");

    MockWstLinkRateSource source;
    MockCCIPRouter router;
    BridgewayL1RateReporter reporter;
    BridgewayRateRegistry registry;

    function setUp() public {
        source = new MockWstLinkRateSource();
        router = new MockCCIPRouter();
        reporter = new BridgewayL1RateReporter(owner, address(router), address(source), wstLinkL2, ARB_SELECTOR);
        registry = new BridgewayRateRegistry(owner, address(router), address(reporter), ETH_SELECTOR);
        reporter.setReceiver(address(registry));
        registry.setApprovedRateAsset(wstLinkL2, true);
        vm.deal(address(reporter), 1 ether);
    }

    function test_ReportRateBuildsVersionedPayloadAndPaysRouterFee() public {
        vm.warp(1 hours);

        vm.prank(keeper);
        bytes32 messageId = reporter.reportRate();

        assertEq(router.lastDestinationChainSelector(), ARB_SELECTOR);
        assertEq(abi.decode(router.lastReceiver(), (address)), address(registry));
        assertEq(router.lastValue(), 0.005 ether);
        assertEq(reporter.lastReportedTimestamp(), block.timestamp);

        (uint8 version, address asset, uint256 rate, uint256 l1Block, uint256 l1Time) =
            abi.decode(router.lastData(), (uint8, address, uint256, uint256, uint256));
        assertEq(version, reporter.PAYLOAD_VERSION());
        assertEq(asset, wstLinkL2);
        assertEq(rate, source.rate());
        assertEq(l1Block, block.number);
        assertEq(l1Time, block.timestamp);
        assertTrue(messageId != bytes32(0));
    }

    function test_ReportRateRejectsCooldownAndInsufficientFees() public {
        vm.warp(1 hours);
        reporter.reportRate();

        vm.expectRevert(BridgewayL1RateReporter.CooldownActive.selector);
        reporter.reportRate();

        vm.warp(block.timestamp + 1 hours);
        reporter.withdrawETH(payable(makeAddr("sink")), address(reporter).balance);
        router.setFee(0.004 ether);
        vm.expectRevert(BridgewayL1RateReporter.InsufficientFees.selector);
        reporter.reportRate();
    }

    function test_ReportRateGuardsPauseIntervalAndFeeCeiling() public {
        vm.expectRevert(BridgewayL1RateReporter.InvalidUpdateInterval.selector);
        reporter.proposeMinUpdateInterval(5 minutes - 1);

        uint256 tooLongInterval = reporter.MAX_UPDATE_INTERVAL() + 1;
        vm.expectRevert(BridgewayL1RateReporter.InvalidUpdateInterval.selector);
        reporter.proposeMinUpdateInterval(tooLongInterval);

        vm.warp(1 hours);
        router.setFee(0.006 ether);
        vm.expectRevert(
            abi.encodeWithSelector(BridgewayL1RateReporter.FeeExceedsMaximum.selector, 0.006 ether, 0.005 ether)
        );
        reporter.reportRate();

        router.setFee(0.01 ether);
        reporter.pause();
        vm.expectRevert();
        reporter.reportRate();
    }

    function test_ReportRateTimelocksReceiverAndMinUpdateInterval() public {
        address newReceiver = makeAddr("newReceiver");

        vm.expectRevert(BridgewayL1RateReporter.ReceiverAlreadyConfigured.selector);
        reporter.setReceiver(newReceiver);

        reporter.proposeReceiverUpdate(newReceiver);
        vm.expectRevert();
        reporter.executeReceiverUpdate();
        vm.warp(block.timestamp + reporter.CONFIG_TIMELOCK_DELAY());
        reporter.executeReceiverUpdate();
        assertEq(reporter.receiverOnL2(), newReceiver);

        reporter.proposeMinUpdateInterval(2 hours);
        vm.expectRevert();
        reporter.executeMinUpdateInterval();
        vm.warp(block.timestamp + reporter.CONFIG_TIMELOCK_DELAY());
        reporter.executeMinUpdateInterval();
        assertEq(reporter.minUpdateInterval(), 2 hours);

        reporter.clearReceiver();
        assertEq(reporter.receiverOnL2(), address(0));
    }

    function test_ReportRateTimelocksAndBoundsFeeCap() public {
        vm.expectRevert(BridgewayL1RateReporter.InvalidFeeCap.selector);
        reporter.proposeMaxFeePerReport(0);

        vm.expectRevert(BridgewayL1RateReporter.InvalidFeeCap.selector);
        reporter.proposeMaxFeePerReport(0.051 ether);

        reporter.proposeMaxFeePerReport(0.01 ether);
        vm.expectRevert();
        reporter.executeMaxFeePerReport();

        vm.warp(block.timestamp + reporter.CONFIG_TIMELOCK_DELAY());
        reporter.executeMaxFeePerReport();
        assertEq(reporter.maxFeePerReport(), 0.01 ether);
    }

    function test_ReportRateFailedReadCountsAgainstCooldown() public {
        vm.warp(1 hours);
        source.setShouldRevert(true);

        bytes32 messageId = reporter.reportRate();
        assertEq(messageId, bytes32(0));
        assertEq(reporter.lastReportedTimestamp(), block.timestamp);

        vm.expectRevert(BridgewayL1RateReporter.CooldownActive.selector);
        reporter.reportRate();
    }

    function test_RateRegistryAcceptsTrustedMessageAndReturnsRate() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + registry.minRateSettleTime());
        assertEq(registry.getValidatedRate(wstLinkL2), rate);
        (uint256 storedRate, uint256 lastUpdated, uint256 l1BlockNumber, uint256 l1Timestamp) =
            registry.getValidatedRateData(wstLinkL2);
        assertEq(storedRate, rate);
        assertEq(lastUpdated, updatedAt);
        assertEq(l1BlockNumber, 123);
        assertEq(l1Timestamp, 456);
    }

    function test_RateRegistryReportsNonRevertingStatusForFrontend() public {
        (,,,,,, BridgewayRateRegistry.RateState state) = registry.rateStatus(makeAddr("unknown"));
        assertEq(uint256(state), uint256(BridgewayRateRegistry.RateState.Unapproved));

        address approvedNoData = makeAddr("approvedNoData");
        registry.setApprovedRateAsset(approvedNoData, true);
        (,,,,,, state) = registry.rateStatus(approvedNoData);
        assertEq(uint256(state), uint256(BridgewayRateRegistry.RateState.NoData));

        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        (uint256 statusRate, uint256 lastUpdated, uint256 settlesAt, uint256 staleAt, uint256 l1Block, uint256 l1Time, BridgewayRateRegistry.RateState statusState) =
            registry.rateStatus(wstLinkL2);
        assertEq(statusRate, rate);
        assertEq(lastUpdated, block.timestamp);
        assertEq(settlesAt, block.timestamp + registry.minRateSettleTime());
        assertEq(staleAt, block.timestamp + registry.DEFAULT_MAX_STALENESS());
        assertEq(l1Block, 123);
        assertEq(l1Time, 456);
        assertEq(uint256(statusState), uint256(BridgewayRateRegistry.RateState.Settling));

        vm.warp(settlesAt);
        (,,,,,, statusState) = registry.rateStatus(wstLinkL2);
        assertEq(uint256(statusState), uint256(BridgewayRateRegistry.RateState.Valid));

        registry.setAssetPaused(wstLinkL2, true);
        (,,,,,, statusState) = registry.rateStatus(wstLinkL2);
        assertEq(uint256(statusState), uint256(BridgewayRateRegistry.RateState.Paused));
    }

    function test_RateRegistryRejectsBadRouterSenderAssetAndBounds() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.expectRevert(BridgewayRateRegistry.InvalidRouter.selector);
        registry.ccipReceive(message);

        message = _message(makeAddr("wrongReporter"), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));
        vm.prank(address(router));
        vm.expectRevert(BridgewayRateRegistry.InvalidSourceSender.selector);
        registry.ccipReceive(message);

        address unapprovedAsset = makeAddr("unapproved");
        message = _message(address(reporter), abi.encode(uint8(1), unapprovedAsset, rate, 123, 456));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.UnapprovedRateAsset.selector, unapprovedAsset));
        registry.ccipReceive(message);

        message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, 1e18 - 1, 123, 456));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.RateBelowBaseline.selector, 1e18 - 1));
        registry.ccipReceive(message);

        message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, 2e18 + 1, 123, 456));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.RateExceedsMaximum.selector, 2e18 + 1));
        registry.ccipReceive(message);
    }

    function test_RateRegistryRejectsOutOfOrderRateUpdates() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate + 1, 122, 455));
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.NonIncreasingL1Block.selector, 122, 123));
        registry.ccipReceive(message);

        message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));
        vm.prank(address(router));
        registry.ccipReceive(message);
    }

    function test_RateRegistryTimelockedConfigUpdates() public {
        address newRouter = makeAddr("newRouter");
        address newReporter = makeAddr("newReporter");

        registry.proposeRouterUpdate(newRouter);
        vm.expectRevert();
        registry.executeRouterUpdate();
        vm.warp(block.timestamp + 48 hours);
        registry.executeRouterUpdate();
        assertEq(registry.ccipRouter(), newRouter);

        registry.proposeSourceSenderUpdate(newReporter);
        vm.warp(block.timestamp + 48 hours);
        registry.executeSourceSenderUpdate();
        assertEq(registry.expectedSourceSender(), newReporter);

        registry.proposeRateBounds(1e18 - 1, 3e18);
        vm.warp(block.timestamp + 48 hours);
        registry.executeRateBounds();
        assertEq(registry.minRate(), 1e18 - 1);
        assertEq(registry.maxReasonableRate(), 3e18);

        vm.expectRevert(BridgewayRateRegistry.InvalidSettleTime.selector);
        registry.proposeMinRateSettleTime(0);

        uint256 tooLongSettleTime = registry.MAX_RATE_SETTLE_TIME() + 1;
        vm.expectRevert(BridgewayRateRegistry.InvalidSettleTime.selector);
        registry.proposeMinRateSettleTime(tooLongSettleTime);

        registry.proposeMinRateSettleTime(5 minutes);
        vm.expectRevert();
        registry.executeMinRateSettleTime();
        vm.warp(block.timestamp + 48 hours);
        registry.executeMinRateSettleTime();
        assertEq(registry.minRateSettleTime(), 5 minutes);
    }

    function test_RateRegistryIsolatesPauseAndStalenessByAsset() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        registry.setAssetPaused(wstLinkL2, true);
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.AssetRatePaused.selector, wstLinkL2));
        registry.getValidatedRate(wstLinkL2);

        registry.setAssetPaused(wstLinkL2, false);
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.RateStillSettling.selector, wstLinkL2));
        registry.getValidatedRate(wstLinkL2);

        vm.warp(block.timestamp + registry.minRateSettleTime());
        assertEq(registry.getValidatedRate(wstLinkL2), rate);

        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.StaleRate.selector, wstLinkL2));
        registry.getValidatedRate(wstLinkL2);
    }

    function test_RateRegistryRejectsImpossibleStalenessWindow() public {
        uint256 impossibleWindow = registry.minRateSettleTime() + registry.MIN_VALID_READ_WINDOW();
        vm.expectRevert(BridgewayRateRegistry.InvalidDuration.selector);
        registry.setMaxStaleness(wstLinkL2, impossibleWindow);

        registry.setMaxStaleness(wstLinkL2, impossibleWindow + 1);
    }

    function test_RateRegistryRejectsSettleTimeThatWouldBrickApprovedAsset() public {
        address tightAsset = makeAddr("tightAsset");
        registry.setApprovedRateAsset(tightAsset, true);
        registry.setMaxStaleness(tightAsset, 2 hours);

        registry.proposeMinRateSettleTime(90 minutes);
        vm.warp(block.timestamp + registry.CONFIG_TIMELOCK_DELAY());

        vm.expectRevert(
            abi.encodeWithSelector(
                BridgewayRateRegistry.MisconfiguredStaleness.selector,
                tightAsset,
                90 minutes,
                2 hours
            )
        );
        registry.executeMinRateSettleTime();
    }

    function test_RateRegistryCanForceRevokeSourceSender() public {
        registry.forceRevokeSourceSender();
        assertEq(registry.expectedSourceSender(), address(0));

        ICCIPReceiver.Any2EVMMessage memory message =
            _message(address(reporter), abi.encode(uint8(1), wstLinkL2, source.rate(), 123, 456));

        vm.prank(address(router));
        vm.expectRevert(BridgewayRateRegistry.SourceSenderRevoked.selector);
        registry.ccipReceive(message);
    }

    function _message(address sender, bytes memory data)
        internal
        pure
        returns (ICCIPReceiver.Any2EVMMessage memory message)
    {
        message = ICCIPReceiver.Any2EVMMessage({
            messageId: keccak256(data),
            sourceChainSelector: ETH_SELECTOR,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new ICCIPReceiver.EVMTokenAmount[](0)
        });
    }
}
