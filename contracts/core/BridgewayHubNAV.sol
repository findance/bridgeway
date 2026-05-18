// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BridgewayHubNAV
/// @notice Hub-chain global NAV cache for future hub-and-spoke accounting.
///         CCIP receivers or approved reporters update confirmed spoke NAV.
contract BridgewayHubNAV is Ownable2Step, Pausable {
    using Math for uint256;

    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant VALUE_DECIMALS = 18;
    uint256 public constant DEFAULT_MAX_REPORT_AGE = 24 hours;
    uint256 public constant DEFAULT_MAX_NAV_MOVE_BPS = 1_000; // 10%
    uint256 public constant MAX_NAV_MOVE_BPS = 3_000; // 30%
    uint256 public constant DEFAULT_MAX_GLOBAL_NAV_MOVE_BPS = 500; // 5%
    uint256 public constant MAX_GLOBAL_NAV_MOVE_BPS = 3_000; // 30%
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant CONFIG_TIMELOCK_DELAY = 48 hours;

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

    struct PendingSpokeConfig {
        SpokeConfig config;
        uint256 executableAt;
        bool exists;
    }

    mapping(uint64 => SpokeConfig) public spokeConfigs;
    mapping(uint64 => SpokeReport) public spokeReports;
    mapping(uint64 => PendingSpokeConfig) public pendingSpokeConfigs;
    uint64[] private _spokeChainIds;
    bool public bootstrapMode = true;
    bool public circuitBreakerActive;
    uint256 public maxGlobalNavMoveBps = DEFAULT_MAX_GLOBAL_NAV_MOVE_BPS;

    event SpokeConfigured(
        uint64 indexed chainId,
        address indexed reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material
    );
    event SpokeConfigProposed(
        uint64 indexed chainId,
        address indexed reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material,
        uint256 executableAt
    );
    event SpokeConfigCancelled(uint64 indexed chainId);
    event BootstrapFinalized(uint256 timestamp);
    event GlobalNAVVarianceBreached(uint256 oldNavUsd18, uint256 newNavUsd18, uint256 varianceBps);
    event CircuitBreakerTriggered(bytes32 indexed reason);
    event CircuitBreakerReset(uint256 timestamp);
    event MaxGlobalNavMoveBpsSet(uint256 maxGlobalNavMoveBps);
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
    error CircuitBreakerActive();
    error BootstrapActive();
    error ConfigurationFinalized();
    error BootstrapAlreadyFinalized();
    error NoPendingConfig(uint64 chainId);
    error TimelockNotReady(uint64 chainId, uint256 executableAt);
    error InvalidNavMoveBps(uint256 maxNavMoveBps);

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
        if (!bootstrapMode) revert ConfigurationFinalized();
        SpokeConfig memory config = _validateSpokeConfig(
            chainId,
            reporter,
            maxReportAge,
            maxNavMoveBps,
            enabled,
            material
        );
        _applySpokeConfig(chainId, config);
    }

    function finalizeConfiguration() external onlyOwner {
        if (!bootstrapMode) revert BootstrapAlreadyFinalized();
        bootstrapMode = false;
        emit BootstrapFinalized(block.timestamp);
    }

    function setMaxGlobalNavMoveBps(uint256 maxGlobalNavMoveBps_) external onlyOwner {
        if (maxGlobalNavMoveBps_ == 0) maxGlobalNavMoveBps_ = DEFAULT_MAX_GLOBAL_NAV_MOVE_BPS;
        if (maxGlobalNavMoveBps_ > MAX_GLOBAL_NAV_MOVE_BPS) revert InvalidNavMoveBps(maxGlobalNavMoveBps_);
        maxGlobalNavMoveBps = maxGlobalNavMoveBps_;
        emit MaxGlobalNavMoveBpsSet(maxGlobalNavMoveBps_);
    }

    function triggerCircuitBreaker(bytes32 reason) external onlyOwner {
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(reason);
    }

    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
        emit CircuitBreakerReset(block.timestamp);
    }

    function proposeSpokeConfig(
        uint64 chainId,
        address reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material
    ) external onlyOwner returns (uint256 executableAt) {
        if (bootstrapMode) revert BootstrapActive();
        SpokeConfig memory config = _validateSpokeConfig(
            chainId,
            reporter,
            maxReportAge,
            maxNavMoveBps,
            enabled,
            material
        );

        executableAt = block.timestamp + CONFIG_TIMELOCK_DELAY;
        pendingSpokeConfigs[chainId] = PendingSpokeConfig({
            config: config,
            executableAt: executableAt,
            exists: true
        });

        emit SpokeConfigProposed(
            chainId,
            config.reporter,
            config.maxReportAge,
            config.maxNavMoveBps,
            config.enabled,
            config.material,
            executableAt
        );
    }

    function executeSpokeConfig(uint64 chainId) external onlyOwner {
        PendingSpokeConfig memory pending = pendingSpokeConfigs[chainId];
        if (!pending.exists) revert NoPendingConfig(chainId);
        if (block.timestamp < pending.executableAt) revert TimelockNotReady(chainId, pending.executableAt);

        delete pendingSpokeConfigs[chainId];
        _applySpokeConfig(chainId, pending.config);
    }

    function cancelSpokeConfig(uint64 chainId) external onlyOwner {
        if (!pendingSpokeConfigs[chainId].exists) revert NoPendingConfig(chainId);
        delete pendingSpokeConfigs[chainId];
        emit SpokeConfigCancelled(chainId);
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
        if (circuitBreakerActive) revert CircuitBreakerActive();
        SpokeConfig memory config = spokeConfigs[chainId];
        if (!config.enabled) revert SpokeDisabled(chainId);
        if (msg.sender != config.reporter) revert InvalidReporter();
        if (navUsd18 == 0 || reportedAt == 0 || reportedAt > block.timestamp) revert InvalidReport();
        if (block.timestamp > reportedAt + config.maxReportAge) revert StaleReport(chainId);

        SpokeReport memory previous = spokeReports[chainId];
        if (nonce <= previous.nonce) revert NonceNotIncreasing(chainId);
        if (previous.navUsd18 > 0) {
            uint256 maxMove = Math.mulDiv(previous.navUsd18, config.maxNavMoveBps, BPS_DENOM);
            uint256 delta = navUsd18 > previous.navUsd18 ? navUsd18 - previous.navUsd18 : previous.navUsd18 - navUsd18;
            if (delta > maxMove) revert NavMoveTooLarge(chainId);
        }

        uint256 oldGlobalNav18 = _totalSpokeNAV18(false);
        spokeReports[chainId] = SpokeReport({
            navUsd18: navUsd18,
            reportedAt: reportedAt,
            sourceBlockNumber: sourceBlockNumber,
            nonce: nonce
        });

        if (oldGlobalNav18 > 0 && previous.reportedAt != 0) {
            uint256 newGlobalNav18 = _totalSpokeNAV18(false);
            uint256 globalDelta =
                newGlobalNav18 > oldGlobalNav18 ? newGlobalNav18 - oldGlobalNav18 : oldGlobalNav18 - newGlobalNav18;
            uint256 varianceBps = Math.mulDiv(globalDelta, BPS_DENOM, oldGlobalNav18);
            if (varianceBps > maxGlobalNavMoveBps) {
                circuitBreakerActive = true;
                emit GlobalNAVVarianceBreached(oldGlobalNav18, newGlobalNav18, varianceBps);
                emit CircuitBreakerTriggered(bytes32("GLOBAL_NAV_VARIANCE"));
            }
        }

        emit SpokeReportAccepted(chainId, msg.sender, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function totalSpokeNAVUSDC() external view returns (uint256) {
        return Math.mulDiv(totalSpokeNAV18(), 10 ** USDC_DECIMALS, 10 ** VALUE_DECIMALS);
    }

    function totalSpokeNAV18() public view returns (uint256 totalNav18) {
        if (circuitBreakerActive) revert CircuitBreakerActive();
        return _totalSpokeNAV18(true);
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

    function _totalSpokeNAV18(bool enforceMaterialStaleness) internal view returns (uint256 totalNav18) {
        uint256 count = _spokeChainIds.length;
        for (uint256 i; i < count; ++i) {
            uint64 chainId = _spokeChainIds[i];
            SpokeConfig memory config = spokeConfigs[chainId];
            if (!config.enabled) continue;

            SpokeReport memory report = spokeReports[chainId];
            if (enforceMaterialStaleness && config.material && _isStale(report, config.maxReportAge)) {
                revert StaleReport(chainId);
            }
            totalNav18 += report.navUsd18;
        }
    }

    function _isStale(SpokeReport memory report, uint256 maxReportAge) internal view returns (bool) {
        return report.reportedAt == 0 || block.timestamp > report.reportedAt + maxReportAge;
    }

    function _validateSpokeConfig(
        uint64 chainId,
        address reporter,
        uint256 maxReportAge,
        uint256 maxNavMoveBps,
        bool enabled,
        bool material
    ) internal pure returns (SpokeConfig memory config) {
        if (chainId == 0) revert InvalidChainId();
        if (reporter == address(0)) revert ZeroAddress();
        if (maxReportAge == 0) maxReportAge = DEFAULT_MAX_REPORT_AGE;
        if (maxNavMoveBps == 0) maxNavMoveBps = DEFAULT_MAX_NAV_MOVE_BPS;
        if (maxNavMoveBps > MAX_NAV_MOVE_BPS) revert InvalidNavMoveBps(maxNavMoveBps);

        config = SpokeConfig({
            reporter: reporter,
            maxReportAge: maxReportAge,
            maxNavMoveBps: maxNavMoveBps,
            enabled: enabled,
            material: material
        });
    }

    function _applySpokeConfig(uint64 chainId, SpokeConfig memory config) internal {
        if (spokeConfigs[chainId].reporter == address(0)) {
            _spokeChainIds.push(chainId);
        }

        spokeConfigs[chainId] = config;

        emit SpokeConfigured(
            chainId,
            config.reporter,
            config.maxReportAge,
            config.maxNavMoveBps,
            config.enabled,
            config.material
        );
    }
}
