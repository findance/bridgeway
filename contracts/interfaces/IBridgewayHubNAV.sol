// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBridgewayHubNAV {
    /// @notice Confirmed aggregate spoke NAV, normalized to USDC 6 decimals.
    function totalSpokeNAVUSDC() external view returns (uint256);
}
