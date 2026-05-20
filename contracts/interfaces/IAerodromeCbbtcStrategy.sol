// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IAerodromeCbbtcStrategy
/// @notice Strategy wrapper used by the Base cbBTC sleeve adapter. The wrapper
///         owns Aerodrome-specific liquidity/range/reward logic and exposes a
///         cbBTC-denominated surface to the sleeve.
interface IAerodromeCbbtcStrategy {
    function asset() external view returns (address);

    function deposit(uint256 cbbtcAmount) external;

    function withdraw(uint256 cbbtcAmount, address receiver) external returns (uint256 cbbtcReturned);

    function withdrawAll(address receiver) external returns (uint256 cbbtcReturned);

    function harvestToCbbtc(address receiver) external returns (uint256 cbbtcHarvested);

    function totalAssetsCbbtc() external view returns (uint256);

    function netApyBps() external view returns (uint256);

    function lastMarkAt() external view returns (uint256);

    function maxMarkStale() external view returns (uint256);
}
