// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../contracts/core/BridgewayCCIPNAVReceiver.sol";
import "../contracts/core/BridgewayHubNAV.sol";
import "../contracts/core/BridgewaySpokeReporter.sol";
import "../contracts/interfaces/ICCIPReceiver.sol";

contract BridgewayCCIPNAVReceiverTest is Test {
    BridgewayHubNAV hub;
    BridgewaySpokeReporter spoke;
    BridgewayCCIPNAVReceiver receiver;

    uint64 constant BASE_CHAIN_ID = 8453;
    uint64 constant BASE_CCIP_SELECTOR = 15_971_525_489_660_198_786;

    address owner = address(this);
    address router = makeAddr("ccipRouter");
    address wrongRouter = makeAddr("wrongRouter");
    address remoteSender = makeAddr("remoteSender");
    address wrongSender = makeAddr("wrongSender");

    function setUp() public {
        hub = new BridgewayHubNAV(owner);
        spoke = new BridgewaySpokeReporter(owner, BASE_CHAIN_ID);
        receiver = new BridgewayCCIPNAVReceiver(owner, router, address(hub));

        hub.configureSpoke(BASE_CHAIN_ID, address(receiver), 24 hours, 1_000, true, true);
        receiver.configureSource(BASE_CCIP_SELECTOR, BASE_CHAIN_ID, abi.encode(remoteSender), true);
    }

    function test_CcipReceiverAcceptsVerifiedReportAndUpdatesHub() public {
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), spoke.buildReport());

        vm.prank(router);
        receiver.ccipReceive(message);

        assertEq(hub.totalSpokeNAV18(), 1_000e18);
        assertEq(hub.totalSpokeNAVUSDC(), 1_000e6);
    }

    function test_SourceConfigRequiresTimelockAfterBootstrapFinalized() public {
        address replacementSender = makeAddr("replacementSender");

        vm.expectRevert(BridgewayCCIPNAVReceiver.BootstrapActive.selector);
        receiver.proposeSourceConfig(BASE_CCIP_SELECTOR, BASE_CHAIN_ID, abi.encode(replacementSender), true);

        receiver.finalizeConfiguration();
        assertFalse(receiver.bootstrapMode());

        vm.expectRevert(BridgewayCCIPNAVReceiver.ConfigurationFinalized.selector);
        receiver.configureSource(BASE_CCIP_SELECTOR, BASE_CHAIN_ID, abi.encode(replacementSender), true);

        uint256 executableAt =
            receiver.proposeSourceConfig(BASE_CCIP_SELECTOR, BASE_CHAIN_ID, abi.encode(replacementSender), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                BridgewayCCIPNAVReceiver.TimelockNotReady.selector,
                BASE_CCIP_SELECTOR,
                executableAt
            )
        );
        receiver.executeSourceConfig(BASE_CCIP_SELECTOR);

        vm.warp(executableAt);
        receiver.executeSourceConfig(BASE_CCIP_SELECTOR);

        (uint64 spokeChainId, bytes32 senderHash, bool enabled) = receiver.sourceConfigs(BASE_CCIP_SELECTOR);
        assertEq(spokeChainId, BASE_CHAIN_ID);
        assertEq(senderHash, keccak256(abi.encode(replacementSender)));
        assertTrue(enabled);
    }

    function test_CcipNavReceiverAdvertisesCcipReceiverInterface() public view {
        assertTrue(receiver.supportsInterface(type(ICCIPReceiver).interfaceId));
        assertTrue(receiver.supportsInterface(0x01ffc9a7));
        assertFalse(receiver.supportsInterface(0xffffffff));
    }

    function test_CcipReceiverRejectsWrongRouter() public {
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), spoke.buildReport());

        vm.prank(wrongRouter);
        vm.expectRevert(BridgewayCCIPNAVReceiver.InvalidRouter.selector);
        receiver.ccipReceive(message);
    }

    function test_CcipReceiverRejectsWrongSourceSender() public {
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(wrongSender), spoke.buildReport());

        vm.prank(router);
        vm.expectRevert(BridgewayCCIPNAVReceiver.InvalidSourceSender.selector);
        receiver.ccipReceive(message);
    }

    function test_CcipReceiverRejectsDisabledSourceSelector() public {
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), spoke.buildReport());
        message.sourceChainSelector = BASE_CCIP_SELECTOR + 1;

        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(BridgewayCCIPNAVReceiver.SourceDisabled.selector, BASE_CCIP_SELECTOR + 1)
        );
        receiver.ccipReceive(message);
    }

    function test_CcipReceiverRejectsReportChainMismatch() public {
        BridgewaySpokeReporter avaxSpoke = new BridgewaySpokeReporter(owner, 43114);
        avaxSpoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), avaxSpoke.buildReport());

        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(BridgewayCCIPNAVReceiver.SourceChainMismatch.selector, BASE_CHAIN_ID, 43114)
        );
        receiver.ccipReceive(message);
    }

    function test_CcipReceiverCannotBypassHubStaleChecks() public {
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), spoke.buildReport());
        vm.warp(block.timestamp + 25 hours);

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(BridgewayHubNAV.StaleReport.selector, BASE_CHAIN_ID));
        receiver.ccipReceive(message);
    }

    function test_PauseBlocksCcipReports() public {
        receiver.pause();
        spoke.updateLocalNAV(1_000e18);
        ICCIPReceiver.Any2EVMMessage memory message = _message(abi.encode(remoteSender), spoke.buildReport());

        vm.prank(router);
        vm.expectRevert();
        receiver.ccipReceive(message);
    }

    function _message(bytes memory sender, bytes memory report)
        internal
        pure
        returns (ICCIPReceiver.Any2EVMMessage memory message)
    {
        message = ICCIPReceiver.Any2EVMMessage({
            messageId: keccak256(report),
            sourceChainSelector: BASE_CCIP_SELECTOR,
            sender: sender,
            data: report,
            destTokenAmounts: new ICCIPReceiver.EVMTokenAmount[](0)
        });
    }
}
