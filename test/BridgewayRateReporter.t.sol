// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayL1RateReporter.sol";
import "../contracts/core/BridgewayRateRegistry.sol";
import "../contracts/interfaces/ICCIPReceiver.sol";
import "../contracts/interfaces/ICCIPRouterClient.sol";

contract MockWstLinkRateSource {
    uint256 public rate = 1.222761515949738428e18;

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function getUnderlyingByWrapped(uint256 amount) external view returns (uint256) {
        return amount * rate / 1e18;
    }
}

contract MockCCIPRouter is ICCIPRouterClient {
    uint256 public fee = 0.01 ether;
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
        assertEq(router.lastValue(), 0.01 ether);
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
        router.setFee(2 ether);
        vm.expectRevert(BridgewayL1RateReporter.InsufficientFees.selector);
        reporter.reportRate();
    }

    function test_RateRegistryAcceptsTrustedMessageAndReturnsRate() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        assertEq(registry.getValidatedRate(wstLinkL2), rate);
        (uint256 storedRate, uint256 lastUpdated, uint256 l1BlockNumber, uint256 l1Timestamp) =
            registry.assetRates(wstLinkL2);
        assertEq(storedRate, rate);
        assertEq(lastUpdated, block.timestamp);
        assertEq(l1BlockNumber, 123);
        assertEq(l1Timestamp, 456);
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

    function test_RateRegistryIsolatesPauseAndStalenessByAsset() public {
        uint256 rate = source.rate();
        ICCIPReceiver.Any2EVMMessage memory message = _message(address(reporter), abi.encode(uint8(1), wstLinkL2, rate, 123, 456));

        vm.prank(address(router));
        registry.ccipReceive(message);

        registry.setAssetPaused(wstLinkL2, true);
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.AssetRatePaused.selector, wstLinkL2));
        registry.getValidatedRate(wstLinkL2);

        registry.setAssetPaused(wstLinkL2, false);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(BridgewayRateRegistry.StaleRate.selector, wstLinkL2));
        registry.getValidatedRate(wstLinkL2);
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
