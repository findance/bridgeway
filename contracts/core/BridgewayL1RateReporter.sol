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
    uint256 public constant FEE_WARNING_BPS = 8_000;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    address public immutable ccipRouter;
    address public immutable wstLinkL1;
    address public immutable wstLinkL2;
    uint64 public immutable destinationChainSelector;

    address public receiverOnL2;
    uint256 public lastReportedTimestamp;
    uint256 public minUpdateInterval = 1 hours;
    uint256 public maxFeePerReport = 0.005 ether;

    event ReceiverUpdated(address indexed receiver);
    event MinUpdateIntervalUpdated(uint256 interval);
    event MaxFeePerReportUpdated(uint256 maxFeePerReport);
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
        if (receiver_ == address(0)) revert ZeroAddress();
        receiverOnL2 = receiver_;
        emit ReceiverUpdated(receiver_);
    }

    function setMinUpdateInterval(uint256 interval_) external onlyOwner {
        if (interval_ < MIN_UPDATE_INTERVAL) revert InvalidUpdateInterval();
        minUpdateInterval = interval_;
        emit MinUpdateIntervalUpdated(interval_);
    }

    function setMaxFeePerReport(uint256 maxFeePerReport_) external onlyOwner {
        maxFeePerReport = maxFeePerReport_;
        emit MaxFeePerReportUpdated(maxFeePerReport_);
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
        if (fee * BPS_DENOMINATOR >= maxFeePerReport * FEE_WARNING_BPS) {
            emit HighFeeWarning(fee, maxFeePerReport);
        }
        if (fee > maxFeePerReport) revert FeeExceedsMaximum(fee, maxFeePerReport);
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
