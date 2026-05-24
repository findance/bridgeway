// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock Camelot router for tests.
///         Implements the ICamelotRouter interface used by ClearcrestVault.
///         Swap logic: pulls USDC from caller, transfers existing CCR from this
///         contract's balance to recipient (simulating market liquidity).
///         Rate: 1e12 → 1 USDC (6 dec) = 1 CCR (18 dec) at $1.00 per CCR.
///         Tests must pre-fund this address with CCR before triggering swaps.
contract MockCamelotRouter {
    using SafeERC20 for IERC20;

    address public immutable ccrToken;
    uint256 public immutable rate;

    constructor(address _ccrToken, uint256 _rate) {
        ccrToken = _ccrToken;
        rate = _rate;
    }

    // ── ICamelotRouter (used by ClearcrestVault) ────────────────────────────────────

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountIn * rate;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer
        uint256 // deadline
    ) external {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn * rate;
        require(amountOut >= amountOutMin, "MockCamelot: slippage");

        // Transfer existing CCR from this contract's balance (pre-funded in test setUp).
        // Using transfer instead of mint keeps swap simulations supply-neutral.
        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer
        uint256 // deadline
    ) external returns (uint256[] memory amounts) {
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn * rate;
        require(amountOut >= amountOutMin, "MockCamelot: slippage");

        IERC20(path[path.length - 1]).safeTransfer(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
