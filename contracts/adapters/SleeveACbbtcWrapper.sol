// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../interfaces/ISleeveAdapter.sol";
import "../interfaces/IBaseCBBTCYieldAdapter.sol";
import "../interfaces/IAerodromeSlipstream.sol";
import "../interfaces/IChainlinkAggregator.sol";

/// @title SleeveACbbtcWrapper
/// @notice ISleeveAdapter wrapper that bridges the BGWVault (USDC-denominated)
///         to the BaseCBBTCYieldAdapter (cbBTC-denominated, 80% Aave / 20% Aerodrome).
///
///         On deposit:  USDC → swap to cbBTC via Aerodrome → deploy into yield adapter.
///         On withdraw: withdraw cbBTC from yield adapter → swap to USDC → return to vault.
///
///         The wrapper must be set as the `controller` of BaseCBBTCYieldAdapter
///         at deployment time, since that role is immutable.
contract SleeveACbbtcWrapper is ISleeveAdapter, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000;

    address public immutable vault;
    IERC20 public immutable usdc;
    IERC20 public immutable cbbtc;
    IAerodromeSwapRouter public immutable router;
    IChainlinkAggregator public immutable btcUsdFeed;
    uint8 public immutable cbbtcDecimals;
    uint8 public immutable usdcDecimals;
    uint8 public immutable feedDecimals;

    IBaseCBBTCYieldAdapter public yieldAdapter;
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public maxStale;
    int24 public tickSpacing;
    bool public adapterActivated;

    event Deployed(uint256 usdcIn, uint256 cbbtcObtained);
    event Withdrawn(uint256 usdcRequested, uint256 usdcReturned);
    event Harvested(uint256 cbbtcYield);
    event MaxSlippageSet(uint256 maxSlippageBps);
    event MaxStaleSet(uint256 maxStale);
    event TickSpacingSet(int24 tickSpacing);
    event YieldAdapterSet(address adapter);

    error OnlyVault();
    error ZeroAddress();
    error InvalidSlippage();
    error InvalidTickSpacing();
    error StalePrice(address feed);
    error InvalidPrice(address feed);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        address _vault,
        address _owner,
        address _usdc,
        address _cbbtc,
        address _router,
        address _btcUsdFeed,
        int24 _tickSpacing,
        uint256 _maxStale
    ) Ownable(_owner) {
        if (
            _vault == address(0) || _owner == address(0) || _usdc == address(0)
                || _cbbtc == address(0) || _router == address(0) || _btcUsdFeed == address(0)
        ) {
            revert ZeroAddress();
        }
        if (_tickSpacing <= 0) revert InvalidTickSpacing();
        vault = _vault;
        usdc = IERC20(_usdc);
        cbbtc = IERC20(_cbbtc);
        router = IAerodromeSwapRouter(_router);
        btcUsdFeed = IChainlinkAggregator(_btcUsdFeed);
        cbbtcDecimals = IERC20MetadataLike(_cbbtc).decimals();
        usdcDecimals = IERC20MetadataLike(_usdc).decimals();
        feedDecimals = IChainlinkAggregator(_btcUsdFeed).decimals();
        tickSpacing = _tickSpacing;
        maxStale = _maxStale == 0 ? 24 hours : _maxStale;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner configuration
    // ─────────────────────────────────────────────────────────────────────────

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

    function setMaxStale(uint256 newMaxStale) external onlyOwner {
        maxStale = newMaxStale == 0 ? 24 hours : newMaxStale;
        emit MaxStaleSet(maxStale);
    }

    function setTickSpacing(int24 newTickSpacing) external onlyOwner {
        if (newTickSpacing <= 0) revert InvalidTickSpacing();
        tickSpacing = newTickSpacing;
        emit TickSpacingSet(newTickSpacing);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ISleeveAdapter — called by BGWVault
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Vault sends USDC here → swap to cbBTC → deploy into yield adapter.
    function deploy(uint256 usdcAmount) external onlyVault {
        if (usdcAmount == 0 || address(yieldAdapter) == address(0)) return;

        // Swap USDC → cbBTC
        uint256 cbbtcBefore = cbbtc.balanceOf(address(this));
        _swap(address(usdc), address(cbbtc), usdcAmount, _minCbbtcOut(usdcAmount));
        uint256 cbbtcObtained = cbbtc.balanceOf(address(this)) - cbbtcBefore;

        // Forward cbBTC into the 80/20 yield adapter
        if (cbbtcObtained > 0) {
            cbbtc.safeTransfer(address(yieldAdapter), cbbtcObtained);
            yieldAdapter.deploy(cbbtcObtained);
            adapterActivated = true;
        }

        emit Deployed(usdcAmount, cbbtcObtained);
    }

    /// @notice Vault requests USDC ← withdraw cbBTC from yield adapter ← swap to USDC.
    function withdraw(uint256 usdcAmount) external onlyVault returns (uint256 usdcReturned) {
        if (usdcAmount == 0 || address(yieldAdapter) == address(0)) return 0;

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
                _swap(address(cbbtc), address(usdc), cbbtcWithdrawn, _minUsdcOut(cbbtcWithdrawn));
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
        if (!adapterActivated) return usdc.balanceOf(address(this));
        return yieldAdapter.totalAssetsUSDC() + usdc.balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal swap helper
    // ─────────────────────────────────────────────────────────────────────────

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut) internal returns (uint256 amountOut) {
        if (amountIn == 0) return 0;

        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            IAerodromeSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _minUsdcOut(uint256 cbbtcAmount) internal view returns (uint256) {
        uint256 price = _btcUsdPrice();
        uint256 expected =
            Math.mulDiv(cbbtcAmount, price * (10 ** usdcDecimals), 10 ** (cbbtcDecimals + feedDecimals));
        return Math.mulDiv(expected, BPS_DENOM - maxSlippageBps, BPS_DENOM);
    }

    function _minCbbtcOut(uint256 usdcAmount) internal view returns (uint256) {
        uint256 price = _btcUsdPrice();
        uint256 expected =
            Math.mulDiv(usdcAmount, 10 ** (cbbtcDecimals + feedDecimals), price * (10 ** usdcDecimals));
        return Math.mulDiv(expected, BPS_DENOM - maxSlippageBps, BPS_DENOM);
    }

    function _btcUsdPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = btcUsdFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId || updatedAt == 0) revert InvalidPrice(address(btcUsdFeed));
        if (block.timestamp > updatedAt + maxStale) revert StalePrice(address(btcUsdFeed));
        return SafeCast.toUint256(answer);
    }
}

interface IERC20MetadataLike {
    function decimals() external view returns (uint8);
}
