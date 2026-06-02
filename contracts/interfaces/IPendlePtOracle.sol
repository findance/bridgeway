// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Pendle PT oracle surface used by PT spoke portfolios.
interface IPendlePtOracle {
    function getPtToAssetRate(address market, uint32 duration) external view returns (uint256);
}
