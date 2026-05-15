// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../interfaces/IBridgewayHubNAV.sol";
import "../interfaces/ICCIPReceiver.sol";

/// @title BridgewayCCIPNAVReceiver
/// @notice Hub-chain CCIP entry point for confirmed spoke NAV reports.
///         The receiver validates Chainlink router provenance, source chain
///         selector, and source sender bytes before forwarding to BridgewayHubNAV.
contract BridgewayCCIPNAVReceiver is ICCIPReceiver, Ownable2Step, Pausable {
    struct SourceConfig {
        uint64 spokeChainId;
        bytes32 senderHash;
        bool enabled;
    }

    address public immutable ccipRouter;
    IBridgewayHubNAV public immutable hubNAV;

    mapping(uint64 => SourceConfig) public sourceConfigs;

    event SourceConfigured(
        uint64 indexed ccipSourceChainSelector,
        uint64 indexed spokeChainId,
        bytes32 indexed senderHash,
        bool enabled
    );
    event CCIPNAVReportReceived(
        bytes32 indexed messageId,
        uint64 indexed ccipSourceChainSelector,
        uint64 indexed spokeChainId,
        uint256 navUsd18,
        uint64 nonce
    );

    error ZeroAddress();
    error InvalidChainSelector();
    error InvalidSourceSender();
    error InvalidRouter();
    error SourceDisabled(uint64 ccipSourceChainSelector);
    error SourceChainMismatch(uint64 expectedSpokeChainId, uint64 reportedSpokeChainId);

    constructor(address owner_, address ccipRouter_, address hubNAV_) Ownable(owner_) {
        if (owner_ == address(0) || ccipRouter_ == address(0) || hubNAV_ == address(0)) revert ZeroAddress();
        ccipRouter = ccipRouter_;
        hubNAV = IBridgewayHubNAV(hubNAV_);
    }

    function configureSource(
        uint64 ccipSourceChainSelector,
        uint64 spokeChainId,
        bytes calldata sourceSender,
        bool enabled
    ) external onlyOwner {
        if (ccipSourceChainSelector == 0 || spokeChainId == 0) revert InvalidChainSelector();
        if (sourceSender.length == 0) revert InvalidSourceSender();

        bytes32 senderHash = keccak256(sourceSender);
        sourceConfigs[ccipSourceChainSelector] = SourceConfig({
            spokeChainId: spokeChainId,
            senderHash: senderHash,
            enabled: enabled
        });

        emit SourceConfigured(ccipSourceChainSelector, spokeChainId, senderHash, enabled);
    }

    function ccipReceive(Any2EVMMessage calldata message) external whenNotPaused {
        if (msg.sender != ccipRouter) revert InvalidRouter();

        SourceConfig memory config = sourceConfigs[message.sourceChainSelector];
        if (!config.enabled) revert SourceDisabled(message.sourceChainSelector);
        if (keccak256(message.sender) != config.senderHash) revert InvalidSourceSender();

        (uint64 spokeChainId, uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce) =
            abi.decode(message.data, (uint64, uint256, uint256, uint256, uint64));
        if (spokeChainId != config.spokeChainId) revert SourceChainMismatch(config.spokeChainId, spokeChainId);

        hubNAV.reportSpokeNAV(spokeChainId, navUsd18, reportedAt, sourceBlockNumber, nonce);

        emit CCIPNAVReportReceived(
            message.messageId,
            message.sourceChainSelector,
            spokeChainId,
            navUsd18,
            nonce
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
