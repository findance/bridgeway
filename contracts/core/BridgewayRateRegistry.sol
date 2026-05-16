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
    uint256 public constant DEFAULT_MAX_STALENESS = 24 hours;
    uint256 public constant MIN_RATE = 1e18;
    uint256 public constant MAX_REASONABLE_RATE = 2e18;

    struct RateData {
        uint256 rate;
        uint256 lastUpdated;
        uint256 l1BlockNumber;
        uint256 l1Timestamp;
    }

    address public immutable ccipRouter;
    address public immutable expectedSourceSender;
    uint64 public immutable sourceChainSelector;

    mapping(address => RateData) public assetRates;
    mapping(address => bool) public isApprovedRateAsset;
    mapping(address => bool) public isAssetPaused;
    mapping(address => uint256) public maxStalenessThreshold;

    event RateUpdated(address indexed asset, uint256 rate, uint256 l1BlockNumber, uint256 l1Timestamp);
    event ApprovedAssetStatusChanged(address indexed asset, bool approved);
    event AssetPauseStatusChanged(address indexed asset, bool paused);
    event StalenessThresholdChanged(address indexed asset, uint256 seconds_);

    error ZeroAddress();
    error InvalidChainSelector();
    error InvalidRouter();
    error InvalidSourceChain();
    error InvalidSourceSender();
    error UnsupportedPayloadVersion(uint8 version);
    error UnapprovedRateAsset(address asset);
    error RateBelowBaseline(uint256 rate);
    error RateExceedsMaximum(uint256 rate);
    error AssetRatePaused(address asset);
    error NoRateData(address asset);
    error StaleRate(address asset);
    error InvalidDuration();

    constructor(address owner_, address router_, address sourceSender_, uint64 sourceSelector_) Ownable(owner_) {
        if (owner_ == address(0) || router_ == address(0) || sourceSender_ == address(0)) revert ZeroAddress();
        if (sourceSelector_ == 0) revert InvalidChainSelector();

        ccipRouter = router_;
        expectedSourceSender = sourceSender_;
        sourceChainSelector = sourceSelector_;
    }

    function setApprovedRateAsset(address asset, bool approved) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
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
        maxStalenessThreshold[asset] = seconds_;
        emit StalenessThresholdChanged(asset, seconds_);
    }

    function ccipReceive(Any2EVMMessage calldata message) external whenNotPaused {
        if (msg.sender != ccipRouter) revert InvalidRouter();
        if (message.sourceChainSelector != sourceChainSelector) revert InvalidSourceChain();
        if (abi.decode(message.sender, (address)) != expectedSourceSender) revert InvalidSourceSender();

        (uint8 version, address targetL2Asset, uint256 incomingRate, uint256 l1Block, uint256 l1Time) =
            abi.decode(message.data, (uint8, address, uint256, uint256, uint256));

        if (version != EXPECTED_VERSION) revert UnsupportedPayloadVersion(version);
        if (!isApprovedRateAsset[targetL2Asset]) revert UnapprovedRateAsset(targetL2Asset);
        if (incomingRate < MIN_RATE) revert RateBelowBaseline(incomingRate);
        if (incomingRate > MAX_REASONABLE_RATE) revert RateExceedsMaximum(incomingRate);

        assetRates[targetL2Asset] = RateData({
            rate: incomingRate,
            lastUpdated: block.timestamp,
            l1BlockNumber: l1Block,
            l1Timestamp: l1Time
        });

        emit RateUpdated(targetL2Asset, incomingRate, l1Block, l1Time);
    }

    function getValidatedRate(address asset) external view returns (uint256) {
        if (!isApprovedRateAsset[asset]) revert UnapprovedRateAsset(asset);
        if (isAssetPaused[asset]) revert AssetRatePaused(asset);

        RateData memory data = assetRates[asset];
        if (data.rate == 0) revert NoRateData(asset);

        uint256 threshold = maxStalenessThreshold[asset];
        if (threshold == 0) threshold = DEFAULT_MAX_STALENESS;
        if (block.timestamp - data.lastUpdated > threshold) revert StaleRate(asset);

        return data.rate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
