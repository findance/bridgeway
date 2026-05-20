// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/ISleeveAdapter.sol";
import "../interfaces/IBaseCBBTCYieldAdapter.sol";
import "../interfaces/ICamelotRouter.sol";

/// @title SleeveACbbtcWrapper
/// @notice ISleeveAdapter wrapper that bridges the BGWVault (USDC-denominated)
///         to the BaseCBBTCYieldAdapter (cbBTC-denominated, 80% Aave / 20% Aerodrome).
///
///         On deposit:  USDC → swap to cbBTC via Aerodrome → deploy into yield adapter.
///         On withdraw: withdraw cbBTC from yield adapter → swap to USDC → return to vault.
///
///         The wrapper must be set as the `controller` of BaseCBBTCYieldAdapter
///         at deployment time (script 13), since that role is immutable.
contract SleeveACbbtcWrapper is ISleeveAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000;

    address public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable cbbtc;
    ICamelotRouter public immutable router;

    IBaseCBBTCYieldAdapter public yieldAdapter;
    uint256 public maxSlippageBps = 100; // 1%

    address[] public usdcToCbbtcPath;
    address[] public cbbtcToUsdcPath;

    event Deployed(uint256 usdcIn, uint256 cbbtcObtained);
    event Withdrawn(uint256 usdcRequested, uint256 usdcReturned);
    event Harvested(uint256 cbbtcYield);
    event MaxSlippageSet(uint256 maxSlippageBps);
    event YieldAdapterSet(address adapter);

    error OnlyVault();
    error ZeroAddress();
    error InvalidSlippage();
    error PathsNotSet();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        address _vault,
        address _owner,
        address _usdc,
        address _cbbtc,
        address _router
    ) Ownable(_owner) {
        if (
            _vault == address(0) || _owner == address(0) || _usdc == address(0)
                || _cbbtc == address(0) || _router == address(0)
        ) {
            revert ZeroAddress();
        }
        vault = _vault;
        usdc = IERC20(_usdc);
        cbbtc = IERC20(_cbbtc);
        router = ICamelotRouter(_router);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner configuration
    // ─────────────────────────────────────────────────────────────────────────

    function setPaths(address[] calldata _usdcToCbbtc, address[] calldata _cbbtcToUsdc) external onlyOwner {
        usdcToCbbtcPath = _usdcToCbbtc;
        cbbtcToUsdcPath = _cbbtcToUsdc;
    }

    function setYieldAdapter(address _adapter) external onlyOwner {
        if (_adapter == address(0)) revert ZeroAddress();
        yieldAdapter = IBaseCBBTCYieldAdapter(_adapter);
        emit YieldAdapterSet(_adapter);
    }

    function setMaxSlippageBps(uint256 newMaxSlippageBps) external onlyOwner {
        if (newMaxSlippageBps > 1_000) revert InvalidSlippage();
        maxSlippageBps = newMaxSlippageBps;
        emit MaxSlippageSet(newMaxSlippageBps);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ISleeveAdapter — called by BGWVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Vault sends USDC here → swap to cbBTC → deploy into yield adapter.
    function deploy(uint256 usdcAmount) external onlyVault {
        if (usdcAmount == 0 || address(yieldAdapter) == address(0)) return;
        if (usdcToCbbtcPath.length < 2) revert PathsNotSet();

        // Swap USDC → cbBTC
        uint256 cbbtcBefore = cbbtc.balanceOf(address(this));
        _swap(usdcToCbbtcPath, usdcAmount);
        uint256 cbbtcObtained = cbbtc.balanceOf(address(this)) - cbbtcBefore;

        // Forward cbBTC into the 80/20 yield adapter
        if (cbbtcObtained > 0) {
            cbbtc.safeTransfer(address(yieldAdapter), cbbtcObtained);
            yieldAdapter.deploy(cbbtcObtained);
        }

        emit Deployed(usdcAmount, cbbtcObtained);
    }

    /// @notice Vault requests USDC ← withdraw cbBTC from yield adapter ← swap to USDC.
    function withdraw(uint256 usdcAmount) external onlyVault returns (uint256 usdcReturned) {
        if (usdcAmount == 0 || address(yieldAdapter) == address(0)) return 0;
        if (cbbtcToUsdcPath.length < 2) revert PathsNotSet();

        uint256 navUSDC = totalAssetsUSDC();
        if (navUSDC == 0) return 0;

        uint256 totalCbbtc = yieldAdapter.totalAssetsAsset();

        // Pro-rata cbBTC needed to cover the requested USDC value
        uint256 cbbtcNeeded = Math.mulDiv(totalCbbtc, usdcAmount, navUSDC);
        if (cbbtcNeeded > totalCbbtc) cbbtcNeeded = totalCbbtc;

        if (cbbtcNeeded > 0) {
            // Withdraw cbBTC from the yield adapter back to this wrapper
            uint256 cbbtcWithdrawn = yieldAdapter.withdraw(cbbtcNeeded, address(this));

            if (cbbtcWithdrawn > 0) {
                // Swap cbBTC → USDC
                uint256 usdcBefore = usdc.balanceOf(address(this));
                _swap(cbbtcToUsdcPath, cbbtcWithdrawn);
                uint256 usdcSwapped = usdc.balanceOf(address(this)) - usdcBefore;

                usdcReturned = usdcSwapped > usdcAmount ? usdcAmount : usdcSwapped;
                usdc.safeTransfer(vault, usdcReturned);
            }
        }

        emit Withdrawn(usdcAmount, usdcReturned);
    }

    /// @notice Harvest Aerodrome rewards via the yield adapter.
    ///         Any idle USDC left in the wrapper is returned to the vault.
    function harvest() external onlyVault returns (uint256 yieldUsdc) {
        if (address(yieldAdapter) != address(0)) {
            uint256 cbbtcHarvested = yieldAdapter.harvest();
            emit Harvested(cbbtcHarvested);
        }

        // Return any idle USDC sitting in this wrapper
        yieldUsdc = usdc.balanceOf(address(this));
        if (yieldUsdc > 0) {
            usdc.safeTransfer(vault, yieldUsdc);
        }
    }

    /// @notice Reports total position value in USDC 6-decimals for NAV accounting.
    function totalAssetsUSDC() public view returns (uint256) {
        if (address(yieldAdapter) == address(0)) return usdc.balanceOf(address(this));
        return yieldAdapter.totalAssetsUSDC() + usdc.balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal swap helper
    // ─────────────────────────────────────────────────────────────────────────

    function _swap(address[] storage path, uint256 amountIn) internal {
        if (path.length == 0 || amountIn == 0) return;

        IERC20(path[0]).forceApprove(address(router), amountIn);

        uint256[] memory quote = router.getAmountsOut(amountIn, path);
        uint256 minOut = Math.mulDiv(quote[quote.length - 1], BPS_DENOM - maxSlippageBps, BPS_DENOM);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), address(0), block.timestamp
        );
    }
}
