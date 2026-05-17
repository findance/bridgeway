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
    uint256 public constant CONFIG_TIMELOCK_DELAY = 48 hours;

    struct SourceConfig {
        uint64 spokeChainId;
        bytes32 senderHash;
        bool enabled;
    }

    struct PendingSourceConfig {
        SourceConfig config;
        uint256 executableAt;
        bool exists;
    }

    address public immutable ccipRouter;
    IBridgewayHubNAV public immutable hubNAV;

    mapping(uint64 => SourceConfig) public sourceConfigs;
    mapping(uint64 => PendingSourceConfig) public pendingSourceConfigs;
    bool public bootstrapMode = true;

    event SourceConfigured(
        uint64 indexed ccipSourceChainSelector,
        uint64 indexed spokeChainId,
        bytes32 indexed senderHash,
        bool enabled
    );
    event SourceConfigProposed(
        uint64 indexed ccipSourceChainSelector,
        uint64 indexed spokeChainId,
        bytes32 indexed senderHash,
        bool enabled,
        uint256 executableAt
    );
    event SourceConfigCancelled(uint64 indexed ccipSourceChainSelector);
    event BootstrapFinalized(uint256 timestamp);
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
    error BootstrapActive();
    error ConfigurationFinalized();
    error BootstrapAlreadyFinalized();
    error NoPendingConfig(uint64 ccipSourceChainSelector);
    error TimelockNotReady(uint64 ccipSourceChainSelector, uint256 executableAt);

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
        if (!bootstrapMode) revert ConfigurationFinalized();
        SourceConfig memory config = _validateSourceConfig(ccipSourceChainSelector, spokeChainId, sourceSender, enabled);
        _applySourceConfig(ccipSourceChainSelector, config);
    }

    function finalizeConfiguration() external onlyOwner {
        if (!bootstrapMode) revert BootstrapAlreadyFinalized();
        bootstrapMode = false;
        emit BootstrapFinalized(block.timestamp);
    }

    function proposeSourceConfig(
        uint64 ccipSourceChainSelector,
        uint64 spokeChainId,
        bytes calldata sourceSender,
        bool enabled
    ) external onlyOwner returns (uint256 executableAt) {
        if (bootstrapMode) revert BootstrapActive();
        SourceConfig memory config = _validateSourceConfig(ccipSourceChainSelector, spokeChainId, sourceSender, enabled);

        executableAt = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingSourceConfigs[ccipSourceChainSelector] = PendingSourceConfig({
            config: config,
            executableAt: executableAt,
            exists: true
        });

        emit SourceConfigProposed(
            ccipSourceChainSelector,
            config.spokeChainId,
            config.senderHash,
            config.enabled,
            executableAt
        );
    }

    function executeSourceConfig(uint64 ccipSourceChainSelector) external onlyOwner {
        PendingSourceConfig memory pending = pendingSourceConfigs[ccipSourceChainSelector];
        if (!pending.exists) revert NoPendingConfig(ccipSourceChainSelector);
        if (block.timestamp < pending.executableAt) {
            revert TimelockNotReady(ccipSourceChainSelector, pending.executableAt);
        }

        delete pendingSourceConfigs[ccipSourceChainSelector];
        _applySourceConfig(ccipSourceChainSelector, pending.config);
    }

    function cancelSourceConfig(uint64 ccipSourceChainSelector) external onlyOwner {
        if (!pendingSourceConfigs[ccipSourceChainSelector].exists) revert NoPendingConfig(ccipSourceChainSelector);
        delete pendingSourceConfigs[ccipSourceChainSelector];
        emit SourceConfigCancelled(ccipSourceChainSelector);
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

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICCIPReceiver).interfaceId || interfaceId == 0x01ffc9a7;
    }

    function _validateSourceConfig(
        uint64 ccipSourceChainSelector,
        uint64 spokeChainId,
        bytes calldata sourceSender,
        bool enabled
    ) internal pure returns (SourceConfig memory config) {
        if (ccipSourceChainSelector == 0 || spokeChainId == 0) revert InvalidChainSelector();
        if (sourceSender.length == 0) revert InvalidSourceSender();

        config = SourceConfig({
            spokeChainId: spokeChainId,
            senderHash: keccak256(sourceSender),
            enabled: enabled
        });
    }

    function _applySourceConfig(uint64 ccipSourceChainSelector, SourceConfig memory config) internal {
        sourceConfigs[ccipSourceChainSelector] = config;
        emit SourceConfigured(
            ccipSourceChainSelector,
            config.spokeChainId,
            config.senderHash,
            config.enabled
        );
    }
}
