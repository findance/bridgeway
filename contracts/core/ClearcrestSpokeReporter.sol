// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IClearcrestSpoke.sol";

/// @title ClearcrestSpokeReporter
/// @notice Chain-local NAV reporter scaffold. Future native-chain adapters can
///         update the spoke value, then CCIP relays buildReport() to the hub.
contract ClearcrestSpokeReporter is IClearcrestSpoke, Ownable2Step {
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant VALUE_DECIMALS = 18;

    uint64 public immutable sourceChainId;
    uint256 public navUsd18;
    uint256 public reportedAt;
    uint256 public sourceBlockNumber;
    uint64 public nonce;

    event LocalNAVUpdated(uint256 navUsd18, uint256 reportedAt, uint256 sourceBlockNumber, uint64 nonce);

    error ZeroAddress();
    error InvalidChainId();
    error InvalidNAV();

    constructor(address owner_, uint64 sourceChainId_) Ownable(owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (sourceChainId_ == 0) revert InvalidChainId();
        sourceChainId = sourceChainId_;
    }

    function updateLocalNAV(uint256 newNavUsd18) external onlyOwner {
        if (newNavUsd18 == 0) revert InvalidNAV();
        navUsd18 = newNavUsd18;
        reportedAt = block.timestamp;
        sourceBlockNumber = block.number;
        nonce += 1;
        emit LocalNAVUpdated(newNavUsd18, reportedAt, sourceBlockNumber, nonce);
    }

    function totalAssetsUSDC() external view returns (uint256) {
        return Math.mulDiv(navUsd18, 10 ** USDC_DECIMALS, 10 ** VALUE_DECIMALS);
    }

    function totalAssets() external view returns (uint256) {
        return Math.mulDiv(navUsd18, 10 ** USDC_DECIMALS, 10 ** VALUE_DECIMALS);
    }

    function buildReport() external view returns (bytes memory) {
        return abi.encode(sourceChainId, navUsd18, reportedAt, sourceBlockNumber, nonce);
    }
}
