// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ISleeveAdapter
/// @notice Minimal interface every real Clearcrest sleeve strategy must expose.
///         The vault keeps policy and accounting; adapters hold protocol-specific
///         logic for Aave, Morpho, Pendle, GMX, or future venues.
interface ISleeveAdapter {
    /// @notice Deploy USDC already transferred to the adapter.
    function deploy(uint256 usdcAmount) external;

    /// @notice Withdraw USDC-equivalent value back to the vault.
    /// @return usdcReturned Amount of USDC actually returned to the vault.
    function withdraw(uint256 usdcAmount) external returns (uint256 usdcReturned);

    /// @notice Harvest rewards and return realised USDC yield to the vault.
    /// @return yieldUsdc Realised USDC yield sent to the vault.
    function harvest() external returns (uint256 yieldUsdc);

    /// @notice Current adapter position value denominated in USDC (6 decimals).
    function totalAssetsUSDC() external view returns (uint256);
}
