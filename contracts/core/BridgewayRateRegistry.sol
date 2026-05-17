// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

import "../interfaces/ICCIPReceiver.sol";

/// @title BridgewayRateRegistry
/// @notice Arbitrum-side CCIP receiver for cross-chain rate data used by
///         isolated asset accounting paths such as wstLINK on Arbitrum.
contract BridgewayRateRegistry is ICCIPReceiver, Ownable2Step, Pausable {
    uint8 public constant EXPECTED_VERSION = 1;
    uint256 public constant CONFIG_TIMELOCK_DELAY = 48 hours;
    uint256 public constant DEFAULT_MAX_STALENESS = 24 hours;
    uint256 public constant DEFAULT_MIN_RATE_SETTLE_TIME = 60 seconds;
    uint256 public constant MIN_VALID_READ_WINDOW = 1 hours;
    uint256 public constant MIN_RATE_SETTLE_TIME = 1 seconds;
    uint256 public constant MAX_RATE_SETTLE_TIME = DEFAULT_MAX_STALENESS / 2;
    uint256 public constant DEFAULT_MIN_RATE = 1e18;
    uint256 public constant DEFAULT_MAX_REASONABLE_RATE = 2e18;

    struct RateData {
        uint256 rate;
        uint256 lastUpdated;
        uint256 l1BlockNumber;
        uint256 l1Timestamp;
    }

    struct PendingAddressChange {
        address value;
        uint256 executeAfter;
    }

    struct PendingRateBoundsChange {
        uint256 minRate;
        uint256 maxRate;
        uint256 executeAfter;
    }

    struct PendingUintChange {
        uint256 value;
        uint256 executeAfter;
    }

    enum RateState {
        Valid,
        Settling,
        Stale,
        Paused,
        Unapproved,
        NoData,
        Misconfigured
    }

    address public ccipRouter;
    address public expectedSourceSender;
    uint64 public immutable sourceChainSelector;
    uint256 public minRateSettleTime = DEFAULT_MIN_RATE_SETTLE_TIME;
    uint256 public minRate = DEFAULT_MIN_RATE;
    uint256 public maxReasonableRate = DEFAULT_MAX_REASONABLE_RATE;

    mapping(address => RateData) private _assetRates;
    mapping(address => bool) public isApprovedRateAsset;
    mapping(address => bool) private _rateAssetKnown;
    mapping(address => bool) public isAssetPaused;
    mapping(address => uint256) public maxStalenessThreshold;
    mapping(bytes32 => PendingAddressChange) public pendingAddressChanges;
    PendingRateBoundsChange public pendingRateBoundsChange;
    PendingUintChange public pendingMinRateSettleTimeChange;
    address[] private _rateAssets;

    event RateUpdated(address indexed asset, uint256 rate, uint256 l1BlockNumber, uint256 l1Timestamp);
    event ApprovedAssetStatusChanged(address indexed asset, bool approved);
    event AssetPauseStatusChanged(address indexed asset, bool paused);
    event StalenessThresholdChanged(address indexed asset, uint256 seconds_);
    event MinRateSettleTimeProposed(uint256 seconds_, uint256 executeAfter);
    event MinRateSettleTimeChanged(uint256 seconds_);
    event MinRateSettleTimeCancelled();
    event AddressChangeProposed(bytes32 indexed changeType, address indexed value, uint256 executeAfter);
    event AddressChangeExecuted(bytes32 indexed changeType, address indexed value);
    event AddressChangeCancelled(bytes32 indexed changeType);
    event SourceSenderForceRevoked(address indexed oldSender);
    event RateBoundsProposed(uint256 minRate, uint256 maxRate, uint256 executeAfter);
    event RateBoundsExecuted(uint256 minRate, uint256 maxRate);
    event RateBoundsCancelled();

    error ZeroAddress();
    error InvalidChainSelector();
    error InvalidRouter();
    error InvalidSourceChain();
    error SourceSenderRevoked();
    error InvalidSourceSender();
    error UnsupportedPayloadVersion(uint8 version);
    error UnapprovedRateAsset(address asset);
    error RateBelowBaseline(uint256 rate);
    error RateExceedsMaximum(uint256 rate);
    error NonIncreasingL1Block(uint256 incomingBlock, uint256 storedBlock);
    error AssetRatePaused(address asset);
    error NoRateData(address asset);
    error StaleRate(address asset);
    error RateStillSettling(address asset);
    error InvalidDuration();
    error InvalidSettleTime();
    error MisconfiguredStaleness(address asset, uint256 settleTime, uint256 threshold);
    error InvalidRateBounds();
    error NoPendingChange(bytes32 changeType);
    error TimelockNotElapsed(uint256 executeAfter);

    bytes32 public constant CHANGE_ROUTER = keccak256("CCIP_ROUTER");
    bytes32 public constant CHANGE_SOURCE_SENDER = keccak256("SOURCE_SENDER");

    constructor(address owner_, address router_, address sourceSender_, uint64 sourceSelector_) Ownable(owner_) {
        if (owner_ == address(0) || router_ == address(0) || sourceSender_ == address(0)) revert ZeroAddress();
        if (sourceSelector_ == 0) revert InvalidChainSelector();

        ccipRouter = router_;
        expectedSourceSender = sourceSender_;
        sourceChainSelector = sourceSelector_;
    }

    function setApprovedRateAsset(address asset, bool approved) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (!_rateAssetKnown[asset]) {
            _rateAssetKnown[asset] = true;
            _rateAssets.push(asset);
        }
        isApprovedRateAsset[asset] = approved;
        emit ApprovedAssetStatusChanged(asset, approved);
    }

    function setAssetPaused(address asset, bool paused) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        isAssetPaused[asset] = paused;
        emit AssetPauseStatusChanged(asset, paused);
    }

    function setMaxStaleness(address asset, uint256 seconds_) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (seconds_ == 0) revert InvalidDuration();
        if (seconds_ <= minRateSettleTime + MIN_VALID_READ_WINDOW) revert InvalidDuration();
        maxStalenessThreshold[asset] = seconds_;
        emit StalenessThresholdChanged(asset, seconds_);
    }

    function proposeMinRateSettleTime(uint256 seconds_) external onlyOwner {
        if (seconds_ < MIN_RATE_SETTLE_TIME || seconds_ > MAX_RATE_SETTLE_TIME) revert InvalidSettleTime();
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingMinRateSettleTimeChange = PendingUintChange({value: seconds_, executeAfter: eta});
        emit MinRateSettleTimeProposed(seconds_, eta);
    }

    function executeMinRateSettleTime() external onlyOwner {
        PendingUintChange memory pending = pendingMinRateSettleTimeChange;
        if (pending.executeAfter == 0) revert NoPendingChange(bytes32("MIN_RATE_SETTLE_TIME"));
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        _validateSettleTimeAgainstApprovedAssets(pending.value);
        delete pendingMinRateSettleTimeChange;
        minRateSettleTime = pending.value;
        emit MinRateSettleTimeChanged(pending.value);
    }

    function cancelMinRateSettleTime() external onlyOwner {
        if (pendingMinRateSettleTimeChange.executeAfter == 0) revert NoPendingChange(bytes32("MIN_RATE_SETTLE_TIME"));
        delete pendingMinRateSettleTimeChange;
        emit MinRateSettleTimeCancelled();
    }

    function proposeRouterUpdate(address router_) external onlyOwner {
        _proposeAddressChange(CHANGE_ROUTER, router_);
    }

    function executeRouterUpdate() external onlyOwner {
        ccipRouter = _executeAddressChange(CHANGE_ROUTER);
    }

    function cancelRouterUpdate() external onlyOwner {
        _cancelAddressChange(CHANGE_ROUTER);
    }

    function proposeSourceSenderUpdate(address sourceSender_) external onlyOwner {
        _proposeAddressChange(CHANGE_SOURCE_SENDER, sourceSender_);
    }

    function executeSourceSenderUpdate() external onlyOwner {
        expectedSourceSender = _executeAddressChange(CHANGE_SOURCE_SENDER);
    }

    function cancelSourceSenderUpdate() external onlyOwner {
        _cancelAddressChange(CHANGE_SOURCE_SENDER);
    }

    function forceRevokeSourceSender() external onlyOwner {
        address oldSender = expectedSourceSender;
        expectedSourceSender = address(0);
        delete pendingAddressChanges[CHANGE_SOURCE_SENDER];
        emit SourceSenderForceRevoked(oldSender);
    }

    function proposeRateBounds(uint256 minRate_, uint256 maxRate_) external onlyOwner {
        if (minRate_ == 0 || minRate_ > maxRate_) revert InvalidRateBounds();
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingRateBoundsChange = PendingRateBoundsChange({
            minRate: minRate_,
            maxRate: maxRate_,
            executeAfter: eta
        });
        emit RateBoundsProposed(minRate_, maxRate_, eta);
    }

    function executeRateBounds() external onlyOwner {
        PendingRateBoundsChange memory pending = pendingRateBoundsChange;
        if (pending.executeAfter == 0) revert NoPendingChange(bytes32("RATE_BOUNDS"));
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        delete pendingRateBoundsChange;
        minRate = pending.minRate;
        maxReasonableRate = pending.maxRate;
        emit RateBoundsExecuted(pending.minRate, pending.maxRate);
    }

    function cancelRateBounds() external onlyOwner {
        if (pendingRateBoundsChange.executeAfter == 0) revert NoPendingChange(bytes32("RATE_BOUNDS"));
        delete pendingRateBoundsChange;
        emit RateBoundsCancelled();
    }

    function ccipReceive(Any2EVMMessage calldata message) external whenNotPaused {
        if (msg.sender != ccipRouter) revert InvalidRouter();
        if (message.sourceChainSelector != sourceChainSelector) revert InvalidSourceChain();
        if (expectedSourceSender == address(0)) revert SourceSenderRevoked();
        if (abi.decode(message.sender, (address)) != expectedSourceSender) revert InvalidSourceSender();

        (uint8 version, address targetL2Asset, uint256 incomingRate, uint256 l1Block, uint256 l1Time) =
            abi.decode(message.data, (uint8, address, uint256, uint256, uint256));

        if (version != EXPECTED_VERSION) revert UnsupportedPayloadVersion(version);
        if (!isApprovedRateAsset[targetL2Asset]) revert UnapprovedRateAsset(targetL2Asset);
        if (incomingRate < minRate) revert RateBelowBaseline(incomingRate);
        if (incomingRate > maxReasonableRate) revert RateExceedsMaximum(incomingRate);

        RateData memory previous = _assetRates[targetL2Asset];
        if (incomingRate == previous.rate && l1Block == previous.l1BlockNumber) return;
        if (l1Block <= previous.l1BlockNumber) revert NonIncreasingL1Block(l1Block, previous.l1BlockNumber);

        _assetRates[targetL2Asset] = RateData({
            rate: incomingRate,
            lastUpdated: block.timestamp,
            l1BlockNumber: l1Block,
            l1Timestamp: l1Time
        });

        emit RateUpdated(targetL2Asset, incomingRate, l1Block, l1Time);
    }

    function getValidatedRate(address asset) external view returns (uint256) {
        return _validatedRateData(asset).rate;
    }

    function getValidatedRateData(address asset)
        external
        view
        returns (uint256 rate, uint256 lastUpdated, uint256 l1BlockNumber, uint256 l1Timestamp)
    {
        RateData memory data = _validatedRateData(asset);
        return (data.rate, data.lastUpdated, data.l1BlockNumber, data.l1Timestamp);
    }

    function rateStatus(address asset)
        external
        view
        returns (
            uint256 rate,
            uint256 lastUpdated,
            uint256 settlesAt,
            uint256 staleAt,
            uint256 l1BlockNumber,
            uint256 l1Timestamp,
            RateState state
        )
    {
        if (!isApprovedRateAsset[asset]) return (0, 0, 0, 0, 0, 0, RateState.Unapproved);
        if (isAssetPaused[asset]) return (0, 0, 0, 0, 0, 0, RateState.Paused);

        RateData memory data = _assetRates[asset];
        if (data.rate == 0) return (0, 0, 0, 0, 0, 0, RateState.NoData);

        uint256 threshold = maxStalenessThreshold[asset];
        if (threshold == 0) threshold = DEFAULT_MAX_STALENESS;
        if (threshold <= minRateSettleTime + MIN_VALID_READ_WINDOW) {
            return (0, 0, 0, 0, 0, 0, RateState.Misconfigured);
        }

        rate = data.rate;
        lastUpdated = data.lastUpdated;
        settlesAt = data.lastUpdated + minRateSettleTime;
        staleAt = data.lastUpdated + threshold;
        l1BlockNumber = data.l1BlockNumber;
        l1Timestamp = data.l1Timestamp;

        if (block.timestamp < settlesAt) state = RateState.Settling;
        else if (block.timestamp > staleAt) state = RateState.Stale;
        else state = RateState.Valid;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getProtocolVersion() external pure returns (uint8) {
        return EXPECTED_VERSION;
    }

    function _validatedRateData(address asset) internal view returns (RateData memory data) {
        if (!isApprovedRateAsset[asset]) revert UnapprovedRateAsset(asset);
        if (isAssetPaused[asset]) revert AssetRatePaused(asset);

        data = _assetRates[asset];
        if (data.rate == 0) revert NoRateData(asset);

        uint256 threshold = maxStalenessThreshold[asset];
        if (threshold == 0) threshold = DEFAULT_MAX_STALENESS;
        if (threshold <= minRateSettleTime + MIN_VALID_READ_WINDOW) {
            revert MisconfiguredStaleness(asset, minRateSettleTime, threshold);
        }
        if (block.timestamp - data.lastUpdated > threshold) revert StaleRate(asset);
        if (block.timestamp - data.lastUpdated < minRateSettleTime) revert RateStillSettling(asset);
    }

    function _validateSettleTimeAgainstApprovedAssets(uint256 settleTime) internal view {
        uint256 count = _rateAssets.length;
        for (uint256 i; i < count; ++i) {
            address asset = _rateAssets[i];
            if (!isApprovedRateAsset[asset]) continue;
            uint256 threshold = maxStalenessThreshold[asset];
            if (threshold == 0) threshold = DEFAULT_MAX_STALENESS;
            if (threshold <= settleTime + MIN_VALID_READ_WINDOW) {
                revert MisconfiguredStaleness(asset, settleTime, threshold);
            }
        }
    }

    function _proposeAddressChange(bytes32 changeType, address value) internal {
        if (value == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingAddressChanges[changeType] = PendingAddressChange({value: value, executeAfter: eta});
        emit AddressChangeProposed(changeType, value, eta);
    }

    function _executeAddressChange(bytes32 changeType) internal returns (address value) {
        PendingAddressChange memory pending = pendingAddressChanges[changeType];
        if (pending.executeAfter == 0) revert NoPendingChange(changeType);
        if (block.timestamp < pending.executeAfter) revert TimelockNotElapsed(pending.executeAfter);
        delete pendingAddressChanges[changeType];
        value = pending.value;
        emit AddressChangeExecuted(changeType, value);
    }

    function _cancelAddressChange(bytes32 changeType) internal {
        if (pendingAddressChanges[changeType].executeAfter == 0) revert NoPendingChange(changeType);
        delete pendingAddressChanges[changeType];
        emit AddressChangeCancelled(changeType);
    }
}
