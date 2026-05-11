// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice wstETH on Arbitrum (bridged, wraps/unwraps stETH equivalent)
interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256 wstETHAmount);
    function unwrap(uint256 wstETHAmount) external returns (uint256 stETHAmount);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256 stETHAmount);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256 wstETHAmount);
    function stEthPerToken() external view returns (uint256);
}

/// @notice Lido stETH (Ethereum mainnet — referenced for bridging flows)
interface ILidoStETH {
    function submit(address referral) external payable returns (uint256 shares);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 ethAmount) external view returns (uint256);
}
