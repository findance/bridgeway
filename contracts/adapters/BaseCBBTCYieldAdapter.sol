// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IAaveV3.sol";
import "../interfaces/IAerodromeCbbtcStrategy.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/INativeStakingAdapter.sol";

/// @title BaseCBBTCYieldAdapter
/// @notice Base spoke adapter for BTC exposure through cbBTC. It keeps 80% in
///         Aave V3 Base cbBTC and at most 20% in a dedicated Aerodrome strategy.
///         If Aerodrome's net APY falls below 4.5%, that leg is exited to Aave.
contract BaseCBBTCYieldAdapter is INativeStakingAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant AAVE_TARGET_BPS = 8_000;
    uint256 public constant AERODROME_TARGET_BPS = 2_000;
    uint256 public constant AERODROME_NET_APY_FLOOR_BPS = 450; // 4.5%
    uint256 public constant USDC_DECIMALS = 6;
    uint256 public constant DEFAULT_MAX_STALE = 24 hours;

    address public immutable controller;
    address public immutable rescueReceiver;
    IERC20Metadata public immutable cbbtc;
    IERC20Metadata public immutable aCbbtc;
    IAaveV3Pool public immutable aavePool;
    IAerodromeCbbtcStrategy public immutable aerodromeStrategy;
    IChainlinkAggregator public immutable priceFeed;
    uint8 public immutable cbbtcDecimals;
    uint8 public immutable feedDecimals;

    uint256 public maxStale;

    event Deployed(uint256 cbbtcAmount, uint256 aaveAmount, uint256 aerodromeAmount);
    event Withdrawn(uint256 requestedCbbtc, uint256 returnedCbbtc, address indexed receiver);
    event Harvested(uint256 cbbtcHarvested, uint256 totalCbbtcAfter);
    event Rebalanced(uint256 totalCbbtcAfter, bool aerodromeEnabled);
    event AerodromeExitedToAave(uint256 cbbtcReturned, uint256 netApyBps);
    event EmergencyWithdrawn(uint256 cbbtcReturned, address indexed receiver);
    event MaxStaleUpdated(uint256 maxStale);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error OnlyController();
    error InvalidStrategyAsset();
    error StalePrice(address feed);
    error InvalidPrice(address feed);
    error AdapterAssetMismatch(address configured, address real);

    modifier onlyController() {
        if (msg.sender != controller) revert OnlyController();
        _;
    }

    constructor(
        address owner_,
        address controller_,
        address cbbtc_,
        address aavePool_,
        address aCbbtc_,
        address aerodromeStrategy_,
        address priceFeed_,
        address rescueReceiver_,
        uint256 maxStale_
    ) Ownable(owner_) {
        if (
            owner_ == address(0) || controller_ == address(0) || cbbtc_ == address(0) || aavePool_ == address(0)
                || aCbbtc_ == address(0) || aerodromeStrategy_ == address(0) || priceFeed_ == address(0)
                || rescueReceiver_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (IAerodromeCbbtcStrategy(aerodromeStrategy_).asset() != cbbtc_) revert InvalidStrategyAsset();
        (,,,,,,,, address realAToken,,,,,,) = IAaveReserveQuery(aavePool_).getReserveData(cbbtc_);
        if (aCbbtc_ != realAToken) revert AdapterAssetMismatch(aCbbtc_, realAToken);
        uint8 cbbtcDecimals_ = IERC20Metadata(cbbtc_).decimals();
        uint8 feedDecimals_ = IChainlinkAggregator(priceFeed_).decimals();

        controller = controller_;
        rescueReceiver = rescueReceiver_;
        cbbtc = IERC20Metadata(cbbtc_);
        aavePool = IAaveV3Pool(aavePool_);
        aCbbtc = IERC20Metadata(aCbbtc_);
        aerodromeStrategy = IAerodromeCbbtcStrategy(aerodromeStrategy_);
        priceFeed = IChainlinkAggregator(priceFeed_);
        cbbtcDecimals = cbbtcDecimals_;
        feedDecimals = feedDecimals_;
        maxStale = maxStale_ == 0 ? DEFAULT_MAX_STALE : maxStale_;
    }

    function asset() external view returns (address) {
        return address(cbbtc);
    }

    /// @notice Deploy cbBTC already transferred into this adapter.
    function deploy(uint256 cbbtcAmount) external onlyController nonReentrant {
        if (cbbtcAmount == 0) return;

        uint256 aerodromeAmount;
        if (_aerodromeEnabled()) {
            aerodromeAmount = Math.mulDiv(cbbtcAmount, AERODROME_TARGET_BPS, BPS_DENOM);
        }
        uint256 aaveAmount = cbbtcAmount - aerodromeAmount;

        _supplyAave(aaveAmount);
        _depositAerodrome(aerodromeAmount);

        emit Deployed(cbbtcAmount, aaveAmount, aerodromeAmount);
    }

    /// @notice Withdraw cbBTC back to the spoke/controller receiver.
    function withdraw(uint256 cbbtcAmount, address receiver)
        external
        onlyController
        nonReentrant
        returns (uint256 cbbtcReturned)
    {
        if (receiver == address(0)) revert ZeroAddress();
        if (cbbtcAmount == 0) return 0;

        cbbtcReturned = _useIdle(cbbtcAmount);
        uint256 remaining = cbbtcAmount - cbbtcReturned;

        if (remaining > 0) {
            uint256 fromAave = _withdrawAave(remaining);
            cbbtcReturned += fromAave;
            remaining -= fromAave;
        }

        if (remaining > 0) {
            cbbtcReturned += aerodromeStrategy.withdraw(remaining, address(this));
        }

        if (cbbtcReturned > cbbtcAmount) cbbtcReturned = cbbtcAmount;
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
        emit Withdrawn(cbbtcAmount, cbbtcReturned, receiver);
    }

    /// @notice Controller-only full exit used by Sleeve A emergency unwinds.
    function withdrawAll(address receiver) external onlyController nonReentrant returns (uint256 cbbtcReturned) {
        if (receiver == address(0)) revert ZeroAddress();

        cbbtcReturned = _withdrawAllTo(receiver);
        emit Withdrawn(type(uint256).max, cbbtcReturned, receiver);
    }

    /// @notice Harvest strategy rewards into cbBTC and redeploy according to policy.
    function harvest() external onlyController nonReentrant returns (uint256 cbbtcHarvested) {
        cbbtcHarvested = aerodromeStrategy.harvestToCbbtc(address(this));
        _rebalance();
        emit Harvested(cbbtcHarvested, totalAssetsAsset());
    }

    function rebalance() external onlyOwner nonReentrant {
        _rebalance();
        emit Rebalanced(totalAssetsAsset(), _aerodromeEnabled());
    }

    function totalAssetsAsset() public view returns (uint256) {
        return cbbtc.balanceOf(address(this)) + _aaveAssets() + aerodromeStrategy.totalAssetsCbbtc();
    }

    function totalAssetsUSDC() public view returns (uint256) {
        uint256 price = _latestPrice();
        return Math.mulDiv(totalAssetsAsset(), price * (10 ** USDC_DECIMALS), 10 ** (cbbtcDecimals + feedDecimals));
    }

    function aerodromeNetApyBps() external view returns (uint256) {
        return aerodromeStrategy.netApyBps();
    }

    function aerodromeEnabled() external view returns (bool) {
        return _aerodromeEnabled();
    }

    function setMaxStale(uint256 newMaxStale) external onlyOwner {
        if (newMaxStale == 0) newMaxStale = DEFAULT_MAX_STALE;
        maxStale = newMaxStale;
        emit MaxStaleUpdated(newMaxStale);
    }

    /// @notice Owner backstop: sweep an arbitrary stuck token to `to`.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20Metadata(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice Owner-triggered break-glass unwind. cbBTC is sent to the
    ///         immutable `controller` (= SleeveACbbtcWrapper) so the wrapper
    ///         can swap to USDC and forward to the vault. L-01: emergency
    ///         funds must converge at the vault, not at `rescueReceiver`.
    function emergencyWithdrawAll() external onlyOwner nonReentrant returns (uint256 cbbtcReturned) {
        cbbtcReturned = _withdrawAllTo(controller);
        emit EmergencyWithdrawn(cbbtcReturned, controller);
    }

    function _withdrawAllTo(address receiver) internal returns (uint256 cbbtcReturned) {
        _withdrawAave(type(uint256).max);
        aerodromeStrategy.withdrawAll(address(this));

        cbbtcReturned = cbbtc.balanceOf(address(this));
        if (cbbtcReturned > 0) cbbtc.safeTransfer(receiver, cbbtcReturned);
    }

    function _rebalance() internal {
        // N-08: only act on the reported netApyBps when the mark is fresh.
        // A stale mark could force an unnecessary full Aerodrome unwind
        // every harvest cycle. If the mark is stale, leave the leg as-is
        // and wait for the keeper to refresh.
        uint256 lastMark = aerodromeStrategy.lastMarkAt();
        uint256 maxStaleAero = aerodromeStrategy.maxMarkStale();
        bool markFresh = lastMark != 0 && block.timestamp <= lastMark + maxStaleAero;

        uint256 netApy = aerodromeStrategy.netApyBps();
        if (markFresh && netApy < AERODROME_NET_APY_FLOOR_BPS) {
            uint256 returned = aerodromeStrategy.withdrawAll(address(this));
            _supplyAave(cbbtc.balanceOf(address(this)));
            emit AerodromeExitedToAave(returned, netApy);
            return;
        }

        uint256 nav = totalAssetsAsset();
        if (nav == 0) return;

        uint256 targetAerodrome = Math.mulDiv(nav, AERODROME_TARGET_BPS, BPS_DENOM);
        uint256 currentAerodrome = aerodromeStrategy.totalAssetsCbbtc();

        if (currentAerodrome > targetAerodrome) {
            aerodromeStrategy.withdraw(currentAerodrome - targetAerodrome, address(this));
            _supplyAave(cbbtc.balanceOf(address(this)));
        } else {
            uint256 shortfall = targetAerodrome - currentAerodrome;
            uint256 idle = cbbtc.balanceOf(address(this));
            uint256 fromIdle = idle > shortfall ? shortfall : idle;
            _depositAerodrome(fromIdle);

            uint256 remainingShortfall = shortfall - fromIdle;
            if (remainingShortfall > 0) {
                uint256 fromAave = _withdrawAave(remainingShortfall);
                _depositAerodrome(fromAave);
            }

            _supplyAave(cbbtc.balanceOf(address(this)));
        }
    }

    function _supplyAave(uint256 amount) internal {
        if (amount == 0) return;
        cbbtc.forceApprove(address(aavePool), amount);
        aavePool.supply(address(cbbtc), amount, address(this), 0);
    }

    function _withdrawAave(uint256 amount) internal returns (uint256 withdrawn) {
        uint256 available = _aaveAssets();
        if (available == 0) return 0;
        uint256 request = amount == type(uint256).max || amount > available ? available : amount;
        uint256 beforeBalance = cbbtc.balanceOf(address(this));
        aavePool.withdraw(address(cbbtc), request, address(this));
        withdrawn = cbbtc.balanceOf(address(this)) - beforeBalance;
    }

    function _depositAerodrome(uint256 amount) internal {
        if (amount == 0) return;
        cbbtc.forceApprove(address(aerodromeStrategy), amount);
        aerodromeStrategy.deposit(amount);
    }

    function _useIdle(uint256 amount) internal view returns (uint256 used) {
        uint256 idle = cbbtc.balanceOf(address(this));
        used = idle > amount ? amount : idle;
    }

    function _aaveAssets() internal view returns (uint256) {
        return aCbbtc.balanceOf(address(this));
    }

    function _aerodromeEnabled() internal view returns (bool) {
        uint256 lastMark = aerodromeStrategy.lastMarkAt();
        if (lastMark == 0 || block.timestamp > lastMark + aerodromeStrategy.maxMarkStale()) return false;
        return aerodromeStrategy.netApyBps() >= AERODROME_NET_APY_FLOOR_BPS;
    }

    function _latestPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId) revert InvalidPrice(address(priceFeed));
        if (block.timestamp > updatedAt + maxStale) revert StalePrice(address(priceFeed));
        return SafeCast.toUint256(answer);
    }
}
