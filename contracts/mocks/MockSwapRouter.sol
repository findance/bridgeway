// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test router with configurable pair rates.
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(address => mapping(address => Rate)) public rates;

    function setRate(address tokenIn, address tokenOut, uint256 numerator, uint256 denominator) external {
        require(tokenIn != address(0) && tokenOut != address(0), "MockSwapRouter: zero token");
        require(numerator != 0 && denominator != 0, "MockSwapRouter: zero rate");
        rates[tokenIn][tokenOut] = Rate({numerator: numerator, denominator: denominator});
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; ++i) {
            Rate memory rate = rates[path[i - 1]][path[i]];
            require(rate.numerator != 0, "MockSwapRouter: missing rate");
            amounts[i] = (amounts[i - 1] * rate.numerator) / rate.denominator;
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address,
        uint256
    ) external {
        uint256 amountOut = amountIn;
        for (uint256 i = 1; i < path.length; ++i) {
            Rate memory rate = rates[path[i - 1]][path[i]];
            require(rate.numerator != 0, "MockSwapRouter: missing rate");
            amountOut = (amountOut * rate.numerator) / rate.denominator;
        }
        require(amountOut >= amountOutMin, "MockSwapRouter: slippage");

        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
    }
}
