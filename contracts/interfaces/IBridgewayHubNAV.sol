// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBridgewayHubNAV {
    /// @notice Accept a confirmed spoke NAV report.
    function reportSpokeNAV(
        uint64 chainId,
        uint256 navUsd18,
        uint256 reportedAt,
        uint256 sourceBlockNumber,
        uint64 nonce
    ) external;

    /// @notice Confirmed aggregate spoke NAV, normalized to USDC 6 decimals.
    function totalSpokeNAVUSDC() external view returns (uint256);
}
