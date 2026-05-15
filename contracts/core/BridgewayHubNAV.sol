// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BridgewayHubNAV
/// @notice Arbitrum-side global NAV cache for future hub-and-spoke accounting.
///         CCIP receivers or approved reporters update confirmed spoke NAV.
contract BridgewayHubNAV is Ownable2Step, Pausable {
    using Math for uint256;

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant VALUE_DECIMALS = 18;
    uint256 public constant DEFAULT_MAX_REPORT_AGE = 24 hours;
    uint256 public constant DEFAULT_MAX_NAV_MOVE_BPS = 1_000; // 10%
    uint256 public constant BPS_DENOM = 10_000;

    struct SpokeConfig {
        address reporter;
        uint256 maxReportAge;
        uint256 maxNavMoveBps;
        bool enabled;
        bool material;
    }

    struct SpokeReport {
        uint256 navUsd18;
        uint256 reportedAt;
        uint256 sourceBlockNumber;
        uint64 nonce;
    }

    mapping(uint64 => SpokeConfig) public spokeConfigs;
    mapping(uint64 => SpokeReport) public spokeReports;
    uint64[] private _spokeChainIds;

    event SpokeConfigured(
        uint64 indexed chainId,
        address indexed reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material
    );
    event SpokeReportAccepted(
        uint64 indexed chainId,
        address indexed reporter,
        uint256 navUsd18,
        uint256 reportedAt,
        uint256 sourceBlockNumber,
        uint64 nonce
    );

    error ZeroAddress();
    error InvalidChainId();
    error InvalidReport();
    error InvalidReporter();
    error StaleReport(uint64 chainId);
    error NavMoveTooLarge(uint64 chainId);
    error NonceNotIncreasing(uint64 chainId);
    error SpokeDisabled(uint64 chainId);

    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
    }

    function configureSpoke(
        uint64 chainId,
        address reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material
    ) external onlyOwner {
        if (chainId == 0) revert InvalidChainId();
        if (reporter == address(0)) revert ZeroAddress();
        if (maxReportAge == 0) maxReportAge = DEFAULT_MAX_REPORT_AGE;
        if (maxNavMoveBps == 0) maxNavMoveBps = DEFAULT_MAX_NAV_MOVE_BPS;

        if (spokeConfigs[chainId].reporter == address(0)) {
            _spokeChainIds.push(chainId);
        }

        spokeConfigs[chainId] = SpokeConfig({
            reporter: reporter,
            maxReportAge: maxReportAge,
            maxNavMoveBps: maxNavMoveBps,
            enabled: enabled,
            material: material
        });

        emit SpokeConfigured(chainId, reporter, maxReportAge, maxNavMoveBps, enabled, material);
    }

    /// @notice Accept confirmed spoke NAV. In production this should be called
    ///         by a CCIP receiver after validating the source chain and sender.
    function reportSpokeNAV(
        uint64 chainId,
        uint256 navUsd18,
        uint256 reportedAt,
        uint256 sourceBlockNumber,
        uint64 nonce
    ) external whenNotPaused {
        SpokeConfig memory config = spokeConfigs[chainId];
        if (!config.enabled) revert SpokeDisabled(chainId);
        if (msg.sender != config.reporter) revert InvalidReporter();
        if (navUsd18 == 0 || reportedAt == 0 || reportedAt > block.timestamp) revert InvalidReport();
        if (block.timestamp > reportedAt + config.maxReportAge) revert StaleReport(chainId);

        SpokeReport memory previous = spokeReports[chainId];
        if (nonce <= previous.nonce) revert NonceNotIncreasing(chainId);
        if (previous.navUsd18 > 0 && config.maxNavMoveBps < BPS_DENOM) {
            uint256 maxMove = Math.mulDiv(previous.navUsd18, config.maxNavMoveBps, BPS_DENOM);
            uint256 delta = navUsd18 > previous.navUsd18 ? navUsd18 - previous.navUsd18 : previous.navUsd18 - navUsd18;
            if (delta > maxMove) revert NavMoveTooLarge(chainId);
        }

        spokeReports[chainId] = SpokeReport({
            navUsd18: navUsd18,
            reportedAt: reportedAt,
            sourceBlockNumber: sourceBlockNumber,
            nonce: nonce
        });

        emit SpokeReportAccepted(chainId, msg.sender, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function totalSpokeNAVUSDC() external view returns (uint256) {
        return Math.mulDiv(totalSpokeNAV18(), 10 ** USDC_DECIMALS, 10 ** VALUE_DECIMALS);
    }

    function totalSpokeNAV18() public view returns (uint256 totalNav18) {
        uint256 count = _spokeChainIds.length;
        for (uint256 i; i < count; ++i) {
            uint64 chainId = _spokeChainIds[i];
            SpokeConfig memory config = spokeConfigs[chainId];
            if (!config.enabled) continue;

            SpokeReport memory report = spokeReports[chainId];
            if (config.material && _isStale(report, config.maxReportAge)) revert StaleReport(chainId);
            totalNav18 += report.navUsd18;
        }
    }

    function spokeChainIds() external view returns (uint64[] memory) {
        return _spokeChainIds;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _isStale(SpokeReport memory report, uint256 maxReportAge) internal view returns (bool) {
        return report.reportedAt == 0 || block.timestamp > report.reportedAt + maxReportAge;
    }
}
