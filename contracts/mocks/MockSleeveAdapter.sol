// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ISleeveAdapter.sol";

/// @notice Test-only sleeve adapter that tracks USDC value without external protocols.
contract MockSleeveAdapter is ISleeveAdapter {
    using SafeERC20 for IERC20;

    address public immutable vault;
    IERC20 public immutable usdc;
    uint256 public totalAssets;

    constructor(address _vault, address _usdc) {
        require(_vault != address(0), "MockSleeveAdapter: zero vault");
        require(_usdc != address(0), "MockSleeveAdapter: zero usdc");
        vault = _vault;
        usdc = IERC20(_usdc);
    }

    modifier onlyVault() {
        require(msg.sender == vault, "MockSleeveAdapter: only vault");
        _;
    }

    function deploy(uint256 usdcAmount) external onlyVault {
        totalAssets += usdcAmount;
    }

    function withdraw(uint256 usdcAmount) external onlyVault returns (uint256 usdcReturned) {
        usdcReturned = usdcAmount > totalAssets ? totalAssets : usdcAmount;
        totalAssets -= usdcReturned;
        usdc.safeTransfer(vault, usdcReturned);
    }

    function harvest() external view onlyVault returns (uint256 yieldUsdc) {
        return 0;
    }

    function totalAssetsUSDC() external view returns (uint256) {
        return totalAssets;
    }

    function setTotalAssets(uint256 newTotalAssets) external {
        totalAssets = newTotalAssets;
    }
}
