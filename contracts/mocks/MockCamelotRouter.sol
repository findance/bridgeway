// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

// Simulates a Camelot (Uniswap V2-style) router.
// Returns amountIn * rate BGW for every USDC swap.
// rate = 1e12 means 1 USDC (6 dec) → 1 BGW (18 dec) at a 1:1 price.
contract MockCamelotRouter {
    using SafeERC20 for IERC20;

    address public immutable bgwToken;
    uint256 public immutable rate; // BGW units out per 1 USDC unit in

    constructor(address _bgwToken, uint256 _rate) {
        bgwToken = _bgwToken;
        rate     = _rate;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address, // referrer (unused)
        uint256  // deadline (unused in mock)
    ) external returns (uint256[] memory amounts) {
        require(path.length >= 2, "invalid path");

        // Pull USDC from caller
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = amountIn * rate;
        require(amountOut >= amountOutMin, "insufficient output");

        // Send BGW to recipient
        IERC20(bgwToken).safeTransfer(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
