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

    /// @notice Yield queued by `simulateYield` to be released on the next
    ///         `harvest()` call. Forwarded to the vault as realised USDC so
    ///         BGWVault can redeploy it according to each sleeve's policy.
    uint256 public pendingHarvest;

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

    function harvest() external onlyVault returns (uint256 yieldUsdc) {
        yieldUsdc = pendingHarvest;
        pendingHarvest = 0;
        if (yieldUsdc > 0) {
            usdc.safeTransfer(vault, yieldUsdc);
        }
    }

    /// @notice L-01: full unwind back to the vault. Mirrors the real adapter
    ///         emergency path used by `BGWVault.emergencyUnwindSleeves`.
    function emergencyWithdrawAll() external returns (uint256 usdcReturned) {
        usdcReturned = totalAssets;
        totalAssets = 0;
        if (usdcReturned > 0) {
            usdc.safeTransfer(vault, usdcReturned);
        }
    }

    function totalAssetsUSDC() external view returns (uint256) {
        return totalAssets;
    }

    function setTotalAssets(uint256 newTotalAssets) external {
        totalAssets = newTotalAssets;
    }

    /// @notice Queue `amount` of USDC yield to be realised on the next harvest.
    ///         Caller funds the mock with the USDC up-front so harvest can
    ///         actually transfer it through.
    function simulateYield(uint256 amount) external {
        pendingHarvest += amount;
    }
}
