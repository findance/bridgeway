// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IAaveV3.sol";
import "./MockAToken.sol";

contract MockAaveV3Pool is IAaveV3Pool {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    MockAToken public immutable aUsdc;

    constructor(address _usdc, address _aUsdc) {
        usdc = IERC20(_usdc);
        aUsdc = MockAToken(_aUsdc);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(usdc), "MockAaveV3Pool: asset");
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(usdc), "MockAaveV3Pool: asset");
        uint256 balance = aUsdc.balanceOf(msg.sender);
        uint256 requested = amount == type(uint256).max || amount > balance ? balance : amount;
        aUsdc.burn(msg.sender, requested);
        usdc.safeTransfer(to, requested);
        return requested;
    }

    function getUserAccountData(address) external pure returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, 0, 0, 0, 0);
    }
}
