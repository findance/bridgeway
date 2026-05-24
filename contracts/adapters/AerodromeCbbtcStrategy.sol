// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../interfaces/IAerodromeCbbtcStrategy.sol";
import "../interfaces/IAerodromeSlipstream.sol";
import "../interfaces/IChainlinkAggregator.sol";

/// @title AerodromeCbbtcStrategy
/// @notice Aerodrome Slipstream strategy wrapper for the Base cbBTC spoke.
///         It manages one concentrated-liquidity NFT and exposes a conservative
///         cbBTC-denominated surface to BaseCBBTCYieldAdapter.
contract AerodromeCbbtcStrategy is IAerodromeCbbtcStrategy, Ownable2Step, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant DEFAULT_MAX_MARK_STALE = 24 hours;
    uint256 public constant MAX_MARK_STALE_LIMIT = 72 hours;
    uint256 public constant MAX_MARK_DELTA_BPS = 1_000; // 10%

    IERC20Metadata public immutable cbbtc;
    IERC20Metadata public immutable usdc;
    IERC20Metadata public immutable aero;
    IAerodromeNonfungiblePositionManager public immutable positionManager;
    IAerodromeSwapRouter public immutable swapRouter;
    IAerodromeCLGauge public immutable gauge;
    IChainlinkAggregator public immutable btcUsdFeed;

    address public controller;
    address public keeper;
    address public immutable token0;
    address public immutable token1;
    int24 public tickSpacing;
    int24 public tickLower;
    int24 public tickUpper;
    bool public immutable cbbtcIsToken0;

    uint256 public tokenId;
    uint256 public markedTotalAssetsCbbtc;
    uint256 public netApyBps;
    uint256 public lastMarkAt;
    uint256 public maxMarkStale = DEFAULT_MAX_MARK_STALE;
    uint256 public slippageBps = 100;
    uint256 public cbbtcToUsdcBps = 5_000;
    uint256 public deadlineDelay = 10 minutes;
    bytes public aeroToCbbtcPath;
    uint256 public minAeroToCbbtcOut;

    struct ConstructorParams {
        address owner;
        address controller;
        address keeper;
        address cbbtc;
        address usdc;
        address aero;
        address positionManager;
        address swapRouter;
        address gauge;
        address btcUsdFeed;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
    }

    event ControllerSet(address indexed controller);
    event KeeperSet(address indexed keeper);
    event RangeSet(int24 tickSpacing, int24 tickLower, int24 tickUpper);
    event SlippageSet(uint256 slippageBps);
    event CbbtcToUsdcBpsSet(uint256 cbbtcToUsdcBps);
    event MaxMarkStaleSet(uint256 maxMarkStale);
    event AeroToCbbtcPathSet(bytes path);
    event MinAeroToCbbtcOutSet(uint256 minAmountOut);
    event MarkedToMarket(uint256 totalAssetsCbbtc, uint256 netApyBps);
    event Deposited(uint256 cbbtcAmount, uint256 tokenId);
    event Withdrawn(uint256 requestedCbbtc, uint256 returnedCbbtc, address indexed receiver);
    event Harvested(uint256 cbbtcBalance, uint256 usdcBalance, uint256 aeroBalance);
    event EmergencyWithdrawn(uint256 cbbtcReturned, address indexed receiver);

    error ZeroAddress();
    error OnlyController();
    error OnlyKeeperOrOwner();
    error InvalidPair();
    error InvalidBps();
    error InvalidRange();
    error MarkStale();
    error MarkMoveTooLarge();

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        _;
    }

    constructor(ConstructorParams memory params) Ownable(params.owner) {
        if (
            params.owner == address(0) || params.cbbtc == address(0) || params.usdc == address(0)
                || params.aero == address(0) || params.positionManager == address(0) || params.swapRouter == address(0)
                || params.btcUsdFeed == address(0)
        ) {
            revert ZeroAddress();
        }

        cbbtc = IERC20Metadata(params.cbbtc);
        usdc = IERC20Metadata(params.usdc);
        aero = IERC20Metadata(params.aero);
        positionManager = IAerodromeNonfungiblePositionManager(params.positionManager);
        swapRouter = IAerodromeSwapRouter(params.swapRouter);
        gauge = IAerodromeCLGauge(params.gauge);
        btcUsdFeed = IChainlinkAggregator(params.btcUsdFeed);
        controller = params.controller;
        keeper = params.keeper;

        if (params.cbbtc < params.usdc) {
            token0 = params.cbbtc;
            token1 = params.usdc;
            cbbtcIsToken0 = true;
        } else {
            token0 = params.usdc;
            token1 = params.cbbtc;
            cbbtcIsToken0 = false;
        }
        _setRange(params.tickSpacing, params.tickLower, params.tickUpper);
    }

    function asset() external view returns (address) {
        return address(cbbtc);
    }

    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit ControllerSet(controller_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setRange(int24 tickSpacing_, int24 tickLower_, int24 tickUpper_) external onlyOwner {
        if (tokenId != 0) revert InvalidRange();
        _setRange(tickSpacing_, tickLower_, tickUpper_);
    }

    function setSlippageBps(uint256 slippageBps_) external onlyOwner {
        if (slippageBps_ > 1_000) revert InvalidBps();
        slippageBps = slippageBps_;
        emit SlippageSet(slippageBps_);
    }

    function setCbbtcToUsdcBps(uint256 cbbtcToUsdcBps_) external onlyOwner {
        if (cbbtcToUsdcBps_ > BPS_DENOM) revert InvalidBps();
        cbbtcToUsdcBps = cbbtcToUsdcBps_;
        emit CbbtcToUsdcBpsSet(cbbtcToUsdcBps_);
    }

    function setMaxMarkStale(uint256 maxMarkStale_) external onlyOwner {
        maxMarkStale = _normalizeMaxMarkStale(maxMarkStale_);
        emit MaxMarkStaleSet(maxMarkStale);
    }

    function setAeroToCbbtcPath(bytes calldata path) external onlyOwner {
        aeroToCbbtcPath = path;
        emit AeroToCbbtcPathSet(path);
    }

    /// @notice One-shot minimum output for the next AERO reward conversion.
    ///         If unset, AERO rewards are left idle rather than swapped with a
    ///         zero slippage floor.
    function setMinAeroToCbbtcOut(uint256 minAmountOut) external onlyKeeperOrOwner {
        minAeroToCbbtcOut = minAmountOut;
        emit MinAeroToCbbtcOutSet(minAmountOut);
    }

    function markToMarket(uint256 totalAssetsCbbtc_, uint256 netApyBps_) external onlyKeeperOrOwner {
        _checkMarkMove(totalAssetsCbbtc_);
        markedTotalAssetsCbbtc = totalAssetsCbbtc_;
        netApyBps = netApyBps_;
        lastMarkAt = block.timestamp;
        emit MarkedToMarket(totalAssetsCbbtc_, netApyBps_);
    }

    function deposit(uint256 cbbtcAmount) external onlyController nonReentrant {
        if (cbbtcAmount == 0) return;
        cbbtc.safeTransferFrom(msg.sender, address(this), cbbtcAmount);

        uint256 swapAmount = Math.mulDiv(cbbtcAmount, cbbtcToUsdcBps, BPS_DENOM);
        if (swapAmount > 0) {
            _swap(address(cbbtc), address(usdc), swapAmount, _minUsdcOut(swapAmount));
        }

        _addLiquidity();
        markedTotalAssetsCbbtc += cbbtcAmount;
        if (lastMarkAt == 0) lastMarkAt = block.timestamp;

        emit Deposited(cbbtcAmount, tokenId);
    }

    function withdraw(uint256 cbbtcAmount, address receiver)
        external
        onlyController
        nonReentrant
        returns (uint256 cbbtcReturned)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (cbbtcAmount == 0) return 0;

        uint256 markReduction = cbbtcAmount > markedTotalAssetsCbbtc ? markedTotalAssetsCbbtc : cbbtcAmount;
        _removeProRata(cbbtcAmount);
        _convertIdleToCbbtc();

        uint256 available = cbbtc.balanceOf(address(this));
        cbbtcReturned = available > cbbtcAmount ? cbbtcAmount : available;
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);

        if (markedTotalAssetsCbbtc > markReduction) markedTotalAssetsCbbtc -= markReduction;
        else markedTotalAssetsCbbtc = 0;

        emit Withdrawn(cbbtcAmount, cbbtcReturned, receiver);
    }

    function withdrawAll(address receiver) external onlyController nonReentrant returns (uint256 cbbtcReturned) {
        if (receiver == address(0)) revert ZeroAddress();
        _removeAllLiquidity();
        _convertIdleToCbbtc();

        cbbtcReturned = cbbtc.balanceOf(address(this));
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
        markedTotalAssetsCbbtc = 0;

        emit EmergencyWithdrawn(cbbtcReturned, receiver);
    }

    function harvestToCbbtc(address receiver) external onlyController nonReentrant returns (uint256 cbbtcHarvested) {
        if (receiver == address(0)) revert ZeroAddress();
        _claimRewardsAndFees();
        _convertIdleToCbbtc();
        cbbtcHarvested = cbbtc.balanceOf(address(this));
        if (cbbtcHarvested > 0) cbbtc.safeTransfer(receiver, cbbtcHarvested);
        emit Harvested(cbbtc.balanceOf(address(this)), usdc.balanceOf(address(this)), aero.balanceOf(address(this)));
    }

    function totalAssetsCbbtc() external view returns (uint256) {
        return markedTotalAssetsCbbtc;
    }

    function currentLiquidity() public view returns (uint128 liquidity) {
        if (tokenId == 0) return 0;
        (,,,,,,, liquidity,,,,) = positionManager.positions(tokenId);
    }

    /// @notice Owner-triggered break-glass unwind. Funds are routed back to
    ///         the immutable `controller` (= BaseCBBTCYieldAdapter), which
    ///         in turn routes back to the SleeveACbbtcWrapper, which in turn
    ///         swaps to USDC and ships to the vault. This guarantees an
    ///         emergency unwind terminates at the vault (L-01) instead of
    ///         a runtime-named receiver.
    function emergencyWithdrawAll() external onlyOwner nonReentrant returns (uint256 cbbtcReturned) {
        address receiver = controller;
        if (receiver == address(0)) revert ZeroAddress();
        _removeAllLiquidity();
        _convertIdleToCbbtc();

        cbbtcReturned = cbbtc.balanceOf(address(this));
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
        markedTotalAssetsCbbtc = 0;

        emit EmergencyWithdrawn(cbbtcReturned, receiver);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert InvalidPair();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _setRange(int24 tickSpacing_, int24 tickLower_, int24 tickUpper_) internal {
        if (tickSpacing_ <= 0 || tickLower_ >= tickUpper_) revert InvalidRange();
        if (tickLower_ % tickSpacing_ != 0 || tickUpper_ % tickSpacing_ != 0) revert InvalidRange();
        tickSpacing = tickSpacing_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        emit RangeSet(tickSpacing_, tickLower_, tickUpper_);
    }

    function _addLiquidity() internal {
        uint256 amount0 = IERC20Metadata(token0).balanceOf(address(this));
        uint256 amount1 = IERC20Metadata(token1).balanceOf(address(this));
        if (amount0 == 0 || amount1 == 0) return;

        _unstakeIfNeeded();
        IERC20Metadata(token0).forceApprove(address(positionManager), amount0);
        IERC20Metadata(token1).forceApprove(address(positionManager), amount1);

        uint256 min0 = Math.mulDiv(amount0, BPS_DENOM - slippageBps, BPS_DENOM);
        uint256 min1 = Math.mulDiv(amount1, BPS_DENOM - slippageBps, BPS_DENOM);
        if (tokenId == 0) {
            (tokenId,,,) = positionManager.mint(
                IAerodromeNonfungiblePositionManager.MintParams({
                    token0: token0,
                    token1: token1,
                    tickSpacing: tickSpacing,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: min0,
                    amount1Min: min1,
                    recipient: address(this),
                    deadline: _deadline(),
                    sqrtPriceX96: 0
                })
            );
        } else {
            positionManager.increaseLiquidity(
                IAerodromeNonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0,
                    amount1Desired: amount1,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: _deadline()
                })
            );
        }
        _stakeIfConfigured();
    }

    function _removeProRata(uint256 cbbtcAmount) internal {
        if (tokenId == 0 || markedTotalAssetsCbbtc == 0) return;
        uint128 liquidity = currentLiquidity();
        if (liquidity == 0) return;

        uint256 numerator = cbbtcAmount > markedTotalAssetsCbbtc ? markedTotalAssetsCbbtc : cbbtcAmount;
        uint128 liquidityToRemove =
            SafeCast.toUint128(Math.mulDiv(uint256(liquidity), numerator, markedTotalAssetsCbbtc));
        if (liquidityToRemove == 0) return;

        _decreaseAndCollect(liquidityToRemove, numerator);
    }

    function _removeAllLiquidity() internal {
        uint128 liquidity = currentLiquidity();
        if (liquidity > 0) _decreaseAndCollect(liquidity, markedTotalAssetsCbbtc);
    }

    function _decreaseAndCollect(uint128 liquidity, uint256 cbbtcValueToRemove) internal {
        _unstakeIfNeeded();
        (uint256 amount0Min, uint256 amount1Min) = _decreaseLiquidityMinimums(cbbtcValueToRemove);
        positionManager.decreaseLiquidity(
            IAerodromeNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: _deadline()
            })
        );
        _collect();
        _stakeIfConfigured();
    }

    function _claimRewardsAndFees() internal {
        if (tokenId == 0) return;
        if (address(gauge) != address(0) && gauge.stakedContains(address(this), tokenId)) {
            gauge.getReward(tokenId);
        }
        _unstakeIfNeeded();
        _collect();
        _stakeIfConfigured();
    }

    function _collect() internal {
        if (tokenId == 0) return;
        positionManager.collect(
            IAerodromeNonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    function _stakeIfConfigured() internal {
        if (address(gauge) == address(0) || tokenId == 0) return;
        if (gauge.stakedContains(address(this), tokenId)) return;
        positionManager.approve(address(gauge), tokenId);
        gauge.deposit(tokenId);
    }

    function _unstakeIfNeeded() internal {
        if (address(gauge) == address(0) || tokenId == 0) return;
        if (gauge.stakedContains(address(this), tokenId)) gauge.withdraw(tokenId);
    }

    function _convertIdleToCbbtc() internal {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcBalance > 0) {
            _swap(address(usdc), address(cbbtc), usdcBalance, _minCbbtcOut(usdcBalance));
        }

        uint256 aeroBalance = aero.balanceOf(address(this));
        if (aeroBalance > 0 && aeroToCbbtcPath.length > 0) {
            uint256 minimumOut = minAeroToCbbtcOut;
            if (minimumOut == 0) return;
            minAeroToCbbtcOut = 0;
            aero.forceApprove(address(swapRouter), aeroBalance);
            swapRouter.exactInput(
                IAerodromeSwapRouter.ExactInputParams({
                    path: aeroToCbbtcPath,
                    recipient: address(this),
                    deadline: _deadline(),
                    amountIn: aeroBalance,
                    amountOutMinimum: minimumOut
                })
            );
        }
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMinimum)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        IERC20Metadata(tokenIn).forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            IAerodromeSwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: _deadline(),
                amountIn: amountIn,
                amountOutMinimum: amountOutMinimum,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _minUsdcOut(uint256 cbbtcAmount) internal view returns (uint256) {
        uint256 price = _btcUsdPrice();
        uint256 expected =
            Math.mulDiv(cbbtcAmount, price * (10 ** usdc.decimals()), 10 ** (cbbtc.decimals() + btcUsdFeed.decimals()));
        return Math.mulDiv(expected, BPS_DENOM - slippageBps, BPS_DENOM);
    }

    function _minCbbtcOut(uint256 usdcAmount) internal view returns (uint256) {
        uint256 price = _btcUsdPrice();
        uint256 expected =
            Math.mulDiv(usdcAmount, 10 ** (cbbtc.decimals() + btcUsdFeed.decimals()), price * (10 ** usdc.decimals()));
        return Math.mulDiv(expected, BPS_DENOM - slippageBps, BPS_DENOM);
    }

    function _btcUsdPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = btcUsdFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId || updatedAt == 0) revert MarkStale();
        return SafeCast.toUint256(answer);
    }

    function _decreaseLiquidityMinimums(uint256 cbbtcValueToRemove)
        internal
        view
        returns (uint256 amount0Min, uint256 amount1Min)
    {
        if (cbbtcValueToRemove == 0) return (0, 0);

        uint256 minCbbtc = Math.mulDiv(cbbtcValueToRemove, BPS_DENOM - cbbtcToUsdcBps, BPS_DENOM);
        minCbbtc = Math.mulDiv(minCbbtc, BPS_DENOM - slippageBps, BPS_DENOM);

        uint256 usdcValue = _minUsdcOut(Math.mulDiv(cbbtcValueToRemove, cbbtcToUsdcBps, BPS_DENOM));
        if (cbbtcIsToken0) {
            return (minCbbtc, usdcValue);
        }
        return (usdcValue, minCbbtc);
    }

    function _normalizeMaxMarkStale(uint256 stale) internal pure returns (uint256) {
        if (stale == 0) return DEFAULT_MAX_MARK_STALE;
        if (stale > MAX_MARK_STALE_LIMIT) revert MarkStale();
        return stale;
    }

    function _checkMarkMove(uint256 newMark) internal view {
        uint256 oldMark = markedTotalAssetsCbbtc;
        if (oldMark == 0 || lastMarkAt == 0) {
            // N-06: the zero-mark branch must only be reachable when the
            // strategy actually holds no LP value. Otherwise a single keeper
            // call after a withdrawAll could set an inflated "first" mark.
            if (currentLiquidity() != 0) revert MarkMoveTooLarge();
            if (cbbtc.balanceOf(address(this)) != 0) revert MarkMoveTooLarge();
            return;
        }
        // N-01: when the mark is stale, allow unrestricted *downward* marks
        // so a catastrophic LP drawdown reflects in one keeper call instead
        // of needing three. Upward marks remain capped at MAX_MARK_DELTA_BPS.
        if (newMark < oldMark && block.timestamp > lastMarkAt + maxMarkStale) return;
        uint256 delta = newMark > oldMark ? newMark - oldMark : oldMark - newMark;
        if (delta > Math.mulDiv(oldMark, MAX_MARK_DELTA_BPS, BPS_DENOM)) revert MarkMoveTooLarge();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + deadlineDelay;
    }
}
