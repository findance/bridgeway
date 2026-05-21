// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IBaseCBBTCYieldAdapter
/// @notice Interface for the BaseCBBTCYieldAdapter, used by SleeveACbbtcWrapper
///         to deploy, withdraw, and harvest cbBTC through the 80/20 Aave/Aerodrome strategy.
interface IBaseCBBTCYieldAdapter {
    /// @notice Deploy cbBTC already transferred into the adapter.
    function deploy(uint256 cbbtcAmount) external;

    /// @notice Withdraw cbBTC back to the specified receiver.
    /// @return cbbtcReturned Amount of cbBTC actually returned.
    function withdraw(uint256 cbbtcAmount, address receiver) external returns (uint256 cbbtcReturned);

    /// @notice Withdraw the full cbBTC position back to the specified receiver.
    /// @return cbbtcReturned Amount of cbBTC actually returned.
    function withdrawAll(address receiver) external returns (uint256 cbbtcReturned);

    /// @notice Harvest strategy rewards into cbBTC and redeploy according to policy.
    /// @return cbbtcHarvested Amount of cbBTC harvested from Aerodrome rewards.
    function harvest() external returns (uint256 cbbtcHarvested);

    /// @notice Current adapter value in cbBTC decimals.
    function totalAssetsAsset() external view returns (uint256);

    /// @notice Current adapter value normalized to USDC 6 decimals.
    function totalAssetsUSDC() external view returns (uint256);
}
