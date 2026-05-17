// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/ICCIPRouterClient.sol";
import "../libraries/BridgewayCCIPClient.sol";

interface IStakeLinkWstLink {
    function getUnderlyingByWrapped(uint256 amount) external view returns (uint256);
}

/// @title BridgewayL1RateReporter
/// @notice Ethereum-side CCIP reporter for canonical L1 exchange rates used by
///         hub-chain accounting when the L2 token does not expose a local rate.
contract BridgewayL1RateReporter is Ownable2Step, Pausable, ReentrancyGuard {
    uint8 public constant PAYLOAD_VERSION = 1;
    uint256 public constant RATE_SAMPLE_INPUT = 1e18;
    uint256 public constant DEFAULT_GAS_LIMIT = 250_000;
    uint256 public constant MIN_UPDATE_INTERVAL = 5 minutes;
    uint256 public constant MAX_UPDATE_INTERVAL = 7 days;
    uint256 public constant CONFIG_TIMELOCK_DELAY = 48 hours;
    uint256 public constant MIN_FEE_PER_REPORT = 0.001 ether;
    uint256 public constant MAX_FEE_PER_REPORT = 0.05 ether;
    uint256 public constant FEE_WARNING_BPS = 8_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct PendingFeeChange {
        uint256 maxFeePerReport;
        uint256 executeAfter;
    }

    struct PendingAddressChange {
        address value;
        uint256 executeAfter;
    }

    struct PendingUintChange {
        uint256 value;
        uint256 executeAfter;
    }

    address public immutable ccipRouter;
    address public immutable wstLinkL1;
    address public immutable wstLinkL2;
    uint64 public immutable destinationChainSelector;

    address public receiverOnL2;
    uint256 public lastReportedTimestamp;
    uint256 public minUpdateInterval = 1 hours;
    uint256 public maxFeePerReport = 0.005 ether;
    PendingAddressChange public pendingReceiverChange;
    PendingUintChange public pendingMinUpdateIntervalChange;
    PendingFeeChange public pendingFeeChange;

    event ReceiverUpdated(address indexed receiver);
    event ReceiverUpdateProposed(address indexed receiver, uint256 executeAfter);
    event ReceiverUpdateCancelled();
    event ReceiverCleared(address indexed oldReceiver);
    event MinUpdateIntervalProposed(uint256 interval, uint256 executeAfter);
    event MinUpdateIntervalUpdated(uint256 interval);
    event MinUpdateIntervalCancelled();
    event MaxFeePerReportProposed(uint256 maxFeePerReport, uint256 executeAfter);
    event MaxFeePerReportUpdated(uint256 maxFeePerReport);
    event MaxFeePerReportCancelled();
    event RateReported(
        bytes32 indexed messageId,
        address indexed l2Asset,
        uint256 rate,
        uint256 l1BlockNumber,
        uint256 l1Timestamp,
        uint256 fee
    );
    event ETHWithdrawn(address indexed to, uint256 amount);
    event RateReadFailed(address indexed source);
    event HighFeeWarning(uint256 fee, uint256 maxFeePerReport);

    error ZeroAddress();
    error InvalidChainSelector();
    error CooldownActive();
    error ReceiverNotConfigured();
    error InsufficientFees();
    error FeeExceedsMaximum(uint256 fee, uint256 maxFee);
    error InvalidUpdateInterval();
    error InvalidFeeCap();
    error ReceiverAlreadyConfigured();
    error NoPendingReceiverChange();
    error NoPendingIntervalChange();
    error NoPendingFeeChange();
    error TimelockNotElapsed(uint256 executeAfter);
    error WithdrawalFailed();

    constructor(
        address owner_,
        address router_,
        address wstLinkL1_,
        address wstLinkL2_,
        uint64 destinationChainSelector_
    ) Ownable(owner_) {
        if (owner_ == address(0) || router_ == address(0) || wstLinkL1_ == address(0) || wstLinkL2_ == address(0)) {
            revert ZeroAddress();
        }
        if (destinationChainSelector_ == 0) revert InvalidChainSelector();

        ccipRouter = router_;
        wstLinkL1 = wstLinkL1_;
        wstLinkL2 = wstLinkL2_;
        destinationChainSelector = destinationChainSelector_;
    }

    function setReceiver(address receiver_) external onlyOwner {
        if (receiverOnL2 != address(0)) revert ReceiverAlreadyConfigured();
        if (receiver_ == address(0)) revert ZeroAddress();
        receiverOnL2 = receiver_;
        emit ReceiverUpdated(receiver_);
    }

    function proposeReceiverUpdate(address receiver_) external onlyOwner {
        if (receiver_ == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingReceiverChange = PendingAddressChange({value: receiver_, executeAfter: eta});
        emit ReceiverUpdateProposed(receiver_, eta);
    }

    function executeReceiverUpdate() external onlyOwner {
        PendingAddressChange memory pending = pendingReceiverChange;
        if (pending.executeAfter == 0) revert NoPendingReceiverChange();
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        delete pendingReceiverChange;
        receiverOnL2 = pending.value;
        emit ReceiverUpdated(pending.value);
    }

    function cancelReceiverUpdate() external onlyOwner {
        if (pendingReceiverChange.executeAfter == 0) revert NoPendingReceiverChange();
        delete pendingReceiverChange;
        emit ReceiverUpdateCancelled();
    }

    function clearReceiver() external onlyOwner {
        address oldReceiver = receiverOnL2;
        receiverOnL2 = address(0);
        delete pendingReceiverChange;
        emit ReceiverCleared(oldReceiver);
    }

    function proposeMinUpdateInterval(uint256 interval_) external onlyOwner {
        if (interval_ < MIN_UPDATE_INTERVAL || interval_ > MAX_UPDATE_INTERVAL) revert InvalidUpdateInterval();
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingMinUpdateIntervalChange = PendingUintChange({value: interval_, executeAfter: eta});
        emit MinUpdateIntervalProposed(interval_, eta);
    }

    function executeMinUpdateInterval() external onlyOwner {
        PendingUintChange memory pending = pendingMinUpdateIntervalChange;
        if (pending.executeAfter == 0) revert NoPendingIntervalChange();
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        delete pendingMinUpdateIntervalChange;
        minUpdateInterval = pending.value;
        emit MinUpdateIntervalUpdated(pending.value);
    }

    function cancelMinUpdateInterval() external onlyOwner {
        if (pendingMinUpdateIntervalChange.executeAfter == 0) revert NoPendingIntervalChange();
        delete pendingMinUpdateIntervalChange;
        emit MinUpdateIntervalCancelled();
    }

    function proposeMaxFeePerReport(uint256 maxFeePerReport_) external onlyOwner {
        if (maxFeePerReport_ < MIN_FEE_PER_REPORT || maxFeePerReport_ > MAX_FEE_PER_REPORT) {
            revert InvalidFeeCap();
        }
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingFeeChange = PendingFeeChange({maxFeePerReport: maxFeePerReport_, executeAfter: eta});
        emit MaxFeePerReportProposed(maxFeePerReport_, eta);
    }

    function executeMaxFeePerReport() external onlyOwner {
        PendingFeeChange memory pending = pendingFeeChange;
        if (pending.executeAfter == 0) revert NoPendingFeeChange();
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        delete pendingFeeChange;
        maxFeePerReport = pending.maxFeePerReport;
        emit MaxFeePerReportUpdated(pending.maxFeePerReport);
    }

    function cancelMaxFeePerReport() external onlyOwner {
        if (pendingFeeChange.executeAfter == 0) revert NoPendingFeeChange();
        delete pendingFeeChange;
        emit MaxFeePerReportCancelled();
    }

    /// @notice Permissionless keeper entry point. CCIP fees are paid from this
    ///         contract's ETH balance; any msg.value stays as future fee cushion.
    function reportRate() external payable whenNotPaused returns (bytes32 messageId) {
        if (block.timestamp - lastReportedTimestamp < minUpdateInterval) revert CooldownActive();
        if (receiverOnL2 == address(0)) revert ReceiverNotConfigured();

        uint256 currentRate;
        try IStakeLinkWstLink(wstLinkL1).getUnderlyingByWrapped(RATE_SAMPLE_INPUT) returns (uint256 rate) {
            currentRate = rate;
        } catch {
            lastReportedTimestamp = block.timestamp;
            emit RateReadFailed(wstLinkL1);
            return bytes32(0);
        }
        bytes memory payload = abi.encode(PAYLOAD_VERSION, wstLinkL2, currentRate, block.number, block.timestamp);

        ICCIPRouterClient.EVM2AnyMessage memory message = ICCIPRouterClient.EVM2AnyMessage({
            receiver: abi.encode(receiverOnL2),
            data: payload,
            tokenAmounts: new ICCIPRouterClient.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: BridgewayCCIPClient.argsToBytes(
                BridgewayCCIPClient.GenericExtraArgsV2({
                    gasLimit: DEFAULT_GAS_LIMIT,
                    allowOutOfOrderExecution: true
                })
            )
        });

        ICCIPRouterClient router = ICCIPRouterClient(ccipRouter);
        uint256 fee = router.getFee(destinationChainSelector, message);
        if (fee > maxFeePerReport) revert FeeExceedsMaximum(fee, maxFeePerReport);
        if (fee * BPS_DENOMINATOR >= maxFeePerReport * FEE_WARNING_BPS) {
            emit HighFeeWarning(fee, maxFeePerReport);
        }
        if (address(this).balance < fee) revert InsufficientFees();

        lastReportedTimestamp = block.timestamp;
        messageId = router.ccipSend{value: fee}(destinationChainSelector, message);

        emit RateReported(messageId, wstLinkL2, currentRate, block.number, block.timestamp, fee);
    }

    function withdrawETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool success,) = to.call{value: amount}("");
        if (!success) revert WithdrawalFailed();
        emit ETHWithdrawn(to, amount);
    }

    function getProtocolVersion() external pure returns (uint8) {
        return PAYLOAD_VERSION;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}
