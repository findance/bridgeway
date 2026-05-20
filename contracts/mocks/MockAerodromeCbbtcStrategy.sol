// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IAerodromeCbbtcStrategy.sol";

contract MockAerodromeCbbtcStrategy is IAerodromeCbbtcStrategy {
    using SafeERC20 for IERC20;

    IERC20 public immutable cbbtc;
    uint256 public netApyBps;
    uint256 public lastMarkAt;
    uint256 public maxMarkStale = 24 hours;
    uint256 public invested;

    constructor(address cbbtc_, uint256 netApyBps_) {
        cbbtc = IERC20(cbbtc_);
        netApyBps = netApyBps_;
        lastMarkAt = block.timestamp;
    }

    function asset() external view returns (address) {
        return address(cbbtc);
    }

    function setNetApyBps(uint256 netApyBps_) external {
        netApyBps = netApyBps_;
        lastMarkAt = block.timestamp;
    }

    function setLastMarkAt(uint256 lastMarkAt_) external {
        lastMarkAt = lastMarkAt_;
    }

    function setMaxMarkStale(uint256 maxMarkStale_) external {
        maxMarkStale = maxMarkStale_;
    }

    function deposit(uint256 cbbtcAmount) external {
        cbbtc.safeTransferFrom(msg.sender, address(this), cbbtcAmount);
        invested += cbbtcAmount;
    }

    function withdraw(uint256 cbbtcAmount, address receiver) external returns (uint256 cbbtcReturned) {
        cbbtcReturned = cbbtcAmount > invested ? invested : cbbtcAmount;
        invested -= cbbtcReturned;
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
    }

    function withdrawAll(address receiver) external returns (uint256 cbbtcReturned) {
        cbbtcReturned = invested;
        invested = 0;
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
    }

    function harvestToCbbtc(address receiver) external returns (uint256 cbbtcHarvested) {
        uint256 balance = cbbtc.balanceOf(address(this));
        cbbtcHarvested = balance > invested ? balance - invested : 0;
        if (cbbtcHarvested > 0) cbbtc.safeTransfer(receiver, cbbtcHarvested);
    }

    function totalAssetsCbbtc() external view returns (uint256) {
        return invested;
    }
}
