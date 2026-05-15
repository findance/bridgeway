// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface INativeStakingAdapter {
    /// @notice Native-chain asset held by the adapter, e.g. WETH, WAVAX, LINK, LBTC.
    function asset() external view returns (address);

    /// @notice Current adapter value in the native asset's own decimals.
    function totalAssetsAsset() external view returns (uint256);

    /// @notice Current adapter value normalized to USDC 6 decimals.
    function totalAssetsUSDC() external view returns (uint256);
}
