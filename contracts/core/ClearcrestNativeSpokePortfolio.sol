// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "../interfaces/IClearcrestSpoke.sol";
import "../interfaces/INativeStakingAdapter.sol";

/// @title ClearcrestNativeSpokePortfolio
/// @notice Chain-local portfolio aggregator for native staking adapters. The
///         owner prepares monotonic NAV reports that CCIP can relay to the hub.
contract ClearcrestNativeSpokePortfolio is IClearcrestSpoke, Ownable2Step {
    uint256 public constant MAX_ADAPTERS = 10;

    uint64 public immutable sourceChainId;
    INativeStakingAdapter[] private _adapters;

    uint256 public navUsd18;
    uint256 public reportedAt;
    uint256 public sourceBlockNumber;
    uint64 public nonce;

    event AdaptersConfigured(uint256 count);
    event ReportPrepared(uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce);

    error ZeroAddress();
    error InvalidChainId();
    error InvalidAdapterCount();
    error DuplicateAdapter();

    constructor(address owner_, uint64 sourceChainId_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (sourceChainId_ == 0) revert InvalidChainId();
        sourceChainId = sourceChainId_;
    }

    function setAdapters(address[] calldata adapters_) external onlyOwner {
        uint256 count = adapters_.length;
        if (count == 0 || count > MAX_ADAPTERS) revert InvalidAdapterCount();

        for (uint256 i; i < count; ++i) {
            if (adapters_[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < count; ++j) {
                if (adapters_[i] == adapters_[j]) revert DuplicateAdapter();
            }
        }

        delete _adapters;
        for (uint256 i; i < count; ++i) {
            _adapters.push(INativeStakingAdapter(adapters_[i]));
        }

        emit AdaptersConfigured(count);
    }

    function adapterCount() external view returns (uint256) {
        return _adapters.length;
    }

    function adapterAt(uint256 index) external view returns (address) {
        return address(_adapters[index]);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsUSDC();
    }

    function totalAssetsUSDC() public view returns (uint256 totalUsdc) {
        uint256 count = _adapters.length;
        for (uint256 i; i < count; ++i) {
            totalUsdc += _adapters[i].totalAssetsUSDC();
        }
    }

    /// @notice Snapshot current adapter NAV and increment nonce for CCIP relay.
    function prepareReport() external onlyOwner returns (bytes memory report) {
        navUsd18 = totalAssetsUSDC() * 1e12;
        reportedAt = block.timestamp;
        sourceBlockNumber = block.number;
        nonce += 1;

        emit ReportPrepared(navUsd18, reportedAt, sourceBlockNumber, nonce);
        return _encodedReport();
    }

    function buildReport() external view returns (bytes memory) {
        return _encodedReport();
    }

    function _encodedReport() internal view returns (bytes memory) {
        return abi.encode(sourceChainId, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }
}
