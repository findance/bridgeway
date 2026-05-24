// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IClearcrestSpoke {
    /// @notice Current confirmed spoke value, normalized to USDC 6 decimals.
    function totalAssets() external view returns (uint256);

    /// @notice Current confirmed spoke value, normalized to USDC 6 decimals.
    function totalAssetsUSDC() external view returns (uint256);

    /// @notice Build a signed/relayed report payload for the hub.
    function buildReport() external view returns (bytes memory);
}
