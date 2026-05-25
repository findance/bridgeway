// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../interfaces/IAerodromeSlipstream.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/ISleeveAdapter.sol";

/// @title SleeveADualMorphoEthWrapper
/// @notice USDC-denominated Sleeve A ETH route. Deposits swap USDC to WETH,
///         then split WETH across two approved ERC4626 Morpho WETH vaults.
///         Yield compounds inside vault share value and is reflected in NAV.
contract SleeveADualMorphoEthWrapper is ISleeveAdapter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant DEFAULT_MAX_STALE = 24 hours;
    uint256 public constant MIGRATION_DELAY = 48 hours;
    uint256 public constant MIN_LEG_BPS = 3_000;

    uint8 public constant LEG_A = 0;
    uint8 public constant LEG_B = 1;

    address public immutable vault;
    IERC20Metadata public immutable usdc;
    IERC20Metadata public immutable weth;
    IAerodromeSwapRouter public immutable router;
    IChainlinkAggregator public immutable ethUsdFeed;
    uint8 public immutable usdcDecimals;
    uint8 public immutable wethDecimals;
    uint8 public immutable feedDecimals;

    IERC4626 public morphoVaultA;
    IERC4626 public morphoVaultB;
    address public pendingMorphoVaultA;
    address public pendingMorphoVaultB;
    uint256 public morphoVaultAEta;
    uint256 public morphoVaultBEta;

    uint256 public legABps = 6_000;
    uint256 public legBBps = 4_000;
    uint256 public maxSlippageBps = 100; // 1%
    uint256 public maxStale;
    int24 public tickSpacing;

    event Deployed(uint256 usdcIn, uint256 wethObtained, uint256 legAAssets, uint256 legBAssets);
    event Withdrawn(uint256 usdcRequested, uint256 usdcReturned);
    event Harvested(uint256 navUsdc);
    event EmergencyWithdrawn(address indexed receiver, uint256 wethReturned);
    event MorphoVaultProposed(uint8 indexed leg, address indexed vault, uint256 executeAfter);
    event MorphoVaultMigrated(uint8 indexed leg, address indexed vault, uint256 wethAssets);
    event MorphoVaultProposalCancelled(uint8 indexed leg, address indexed vault);
    event SplitSet(uint256 legABps, uint256 legBBps);
    event MaxSlippageSet(uint256 maxSlippageBps);
    event MaxStaleSet(uint256 maxStale);
    event TickSpacingSet(int24 tickSpacing);

    error OnlyVault();
    error ZeroAddress();
    error InvalidLeg();
    error InvalidSplit();
    error InvalidSlippage();
    error InvalidTickSpacing();
    error InvalidMorphoAsset();
    error NoPendingMorphoVault(uint8 leg);
    error TimelockNotReady(uint256 executeAfter);
    error Unauthorized();
    error StalePrice(address feed);
    error InvalidPrice(address feed);

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyOwnerOrVault() {
        if (msg.sender != owner() && msg.sender != vault) revert Unauthorized();
        _;
    }

    /// @param vault_ ClearcrestVault address that is allowed to deploy, withdraw, and harvest.
    /// @param owner_ Governance owner for split, migration, stale-price, and emergency controls.
    /// @param usdc_ Base USDC settlement token.
    /// @param weth_ Base WETH asset used by both Morpho ERC4626 vaults.
    /// @param router_ Aerodrome Slipstream router used for USDC/WETH swaps.
    /// @param ethUsdFeed_ Chainlink ETH/USD feed used for NAV and swap slippage floors.
    /// @param morphoVaultA_ First WETH ERC4626 vault, initially Moonwell Flagship ETH.
    /// @param morphoVaultB_ Second WETH ERC4626 vault, initially Gauntlet WETH Core.
    /// @param tickSpacing_ Confirmed Aerodrome USDC/WETH Slipstream pool tick spacing.
    /// @param maxStale_ Max ETH/USD feed age; zero uses the 24 hour default.
    constructor(
        address vault_,
        address owner_,
        address usdc_,
        address weth_,
        address router_,
        address ethUsdFeed_,
        address morphoVaultA_,
        address morphoVaultB_,
        int24 tickSpacing_,
        uint256 maxStale_
    ) Ownable(owner_) {
        if (
            vault_ == address(0) || owner_ == address(0) || usdc_ == address(0) || weth_ == address(0)
                || router_ == address(0) || ethUsdFeed_ == address(0) || morphoVaultA_ == address(0)
                || morphoVaultB_ == address(0)
        ) revert ZeroAddress();
        _validateTickSpacing(tickSpacing_);
        if (IERC4626(morphoVaultA_).asset() != weth_ || IERC4626(morphoVaultB_).asset() != weth_) {
            revert InvalidMorphoAsset();
        }

        vault = vault_;
        usdc = IERC20Metadata(usdc_);
        weth = IERC20Metadata(weth_);
        router = IAerodromeSwapRouter(router_);
        ethUsdFeed = IChainlinkAggregator(ethUsdFeed_);
        morphoVaultA = IERC4626(morphoVaultA_);
        morphoVaultB = IERC4626(morphoVaultB_);
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        wethDecimals = IERC20Metadata(weth_).decimals();
        feedDecimals = IChainlinkAggregator(ethUsdFeed_).decimals();
        tickSpacing = tickSpacing_;
        maxStale = maxStale_ == 0 ? DEFAULT_MAX_STALE : maxStale_;
    }

    function deploy(uint256 usdcAmount) external onlyVault nonReentrant {
        if (usdcAmount == 0) return;

        uint256 wethBefore = weth.balanceOf(address(this));
        _swap(address(usdc), address(weth), usdcAmount, _minWethOut(usdcAmount));
        uint256 wethObtained = weth.balanceOf(address(this)) - wethBefore;

        uint256 legAAssets = Math.mulDiv(wethObtained, legABps, BPS_DENOM);
        uint256 legBAssets = wethObtained - legAAssets;

        _depositMorpho(morphoVaultA, legAAssets);
        _depositMorpho(morphoVaultB, legBAssets);

        emit Deployed(usdcAmount, wethObtained, legAAssets, legBAssets);
    }

    function withdraw(uint256 usdcAmount) external onlyVault nonReentrant returns (uint256 usdcReturned) {
        uint256 navUSDC = totalAssetsUSDC();
        if (usdcAmount == 0 || navUSDC == 0) return 0;

        uint256 fraction = usdcAmount >= navUSDC ? 1e18 : Math.mulDiv(usdcAmount, 1e18, navUSDC);

        uint256 idleWethBefore = weth.balanceOf(address(this));
        _redeemMorphoFraction(morphoVaultA, fraction);
        _redeemMorphoFraction(morphoVaultB, fraction);

        uint256 wethAfterRedeem = weth.balanceOf(address(this));
        uint256 redeemedWeth = wethAfterRedeem - idleWethBefore;
        uint256 wethToSwap = redeemedWeth + Math.mulDiv(idleWethBefore, fraction, 1e18);
        if (usdcAmount >= navUSDC) wethToSwap = wethAfterRedeem;

        if (wethToSwap > 0) {
            uint256 beforeUsdc = usdc.balanceOf(address(this));
            _swap(address(weth), address(usdc), wethToSwap, _minUsdcOut(wethToSwap));
            uint256 swapped = usdc.balanceOf(address(this)) - beforeUsdc;
            usdcReturned = swapped > usdcAmount ? usdcAmount : swapped;
        }

        uint256 idleUsdc = usdc.balanceOf(address(this));
        if (usdcReturned < usdcAmount && idleUsdc > usdcReturned) {
            uint256 availableExtra = idleUsdc - usdcReturned;
            uint256 needed = usdcAmount - usdcReturned;
            usdcReturned += availableExtra > needed ? needed : availableExtra;
        }

        if (usdcReturned > 0) usdc.safeTransfer(vault, usdcReturned);
        emit Withdrawn(usdcAmount, usdcReturned);
    }

    /// @notice Yield compounds inside the ERC4626 shares, so no realised USDC
    ///         is returned. The vault captures growth through totalAssetsUSDC().
    function harvest() external onlyVault nonReentrant returns (uint256 yieldUsdc) {
        emit Harvested(totalAssetsUSDC());
        return 0;
    }

    function totalAssetsUSDC() public view returns (uint256) {
        uint256 wethAssets = weth.balanceOf(address(this)) + morphoVaultA.previewRedeem(_shares(morphoVaultA))
            + morphoVaultB.previewRedeem(_shares(morphoVaultB));
        return usdc.balanceOf(address(this)) + _wethValueUSDC(wethAssets);
    }

    function legAssetsWeth() external view returns (uint256 legAAssets, uint256 legBAssets, uint256 idleWeth) {
        legAAssets = morphoVaultA.previewRedeem(_shares(morphoVaultA));
        legBAssets = morphoVaultB.previewRedeem(_shares(morphoVaultB));
        idleWeth = weth.balanceOf(address(this));
    }

    function setSplit(uint256 newLegABps, uint256 newLegBBps) external onlyOwner {
        if (newLegABps + newLegBBps != BPS_DENOM || newLegABps < MIN_LEG_BPS || newLegBBps < MIN_LEG_BPS) {
            revert InvalidSplit();
        }
        legABps = newLegABps;
        legBBps = newLegBBps;
        emit SplitSet(newLegABps, newLegBBps);
    }

    function setMaxSlippageBps(uint256 newMaxSlippageBps) external onlyOwner {
        if (newMaxSlippageBps > 1_000) revert InvalidSlippage();
        maxSlippageBps = newMaxSlippageBps;
        emit MaxSlippageSet(newMaxSlippageBps);
    }

    function setMaxStale(uint256 newMaxStale) external onlyOwner {
        if (newMaxStale == 0) newMaxStale = DEFAULT_MAX_STALE;
        maxStale = newMaxStale;
        emit MaxStaleSet(newMaxStale);
    }

    function setTickSpacing(int24 newTickSpacing) external onlyOwner {
        _validateTickSpacing(newTickSpacing);
        tickSpacing = newTickSpacing;
        emit TickSpacingSet(newTickSpacing);
    }

    function proposeMorphoVault(uint8 leg, address newVault) external onlyOwner {
        _validateLeg(leg);
        if (newVault == address(0)) revert ZeroAddress();
        if (IERC4626(newVault).asset() != address(weth)) revert InvalidMorphoAsset();

        uint256 eta = block.timestamp + MIGRATION_DELAY;
        if (leg == LEG_A) {
            pendingMorphoVaultA = newVault;
            morphoVaultAEta = eta;
        } else {
            pendingMorphoVaultB = newVault;
            morphoVaultBEta = eta;
        }
        emit MorphoVaultProposed(leg, newVault, eta);
    }

    function cancelMorphoVault(uint8 leg) external onlyOwner {
        _validateLeg(leg);
        address pending;
        if (leg == LEG_A) {
            pending = pendingMorphoVaultA;
            if (pending == address(0)) revert NoPendingMorphoVault(leg);
            pendingMorphoVaultA = address(0);
            morphoVaultAEta = 0;
        } else {
            pending = pendingMorphoVaultB;
            if (pending == address(0)) revert NoPendingMorphoVault(leg);
            pendingMorphoVaultB = address(0);
            morphoVaultBEta = 0;
        }
        emit MorphoVaultProposalCancelled(leg, pending);
    }

    function executeMorphoVault(uint8 leg) external onlyOwner nonReentrant {
        _validateLeg(leg);

        IERC4626 current;
        address pending;
        uint256 eta;
        if (leg == LEG_A) {
            current = morphoVaultA;
            pending = pendingMorphoVaultA;
            eta = morphoVaultAEta;
        } else {
            current = morphoVaultB;
            pending = pendingMorphoVaultB;
            eta = morphoVaultBEta;
        }
        if (pending == address(0)) revert NoPendingMorphoVault(leg);
        if (block.timestamp < eta) revert TimelockNotReady(eta);

        uint256 beforeWeth = weth.balanceOf(address(this));
        _redeemMorphoShares(current, _shares(current));
        uint256 wethAssets = weth.balanceOf(address(this)) - beforeWeth;

        IERC4626 next = IERC4626(pending);
        _depositMorpho(next, wethAssets);

        if (leg == LEG_A) {
            morphoVaultA = next;
            pendingMorphoVaultA = address(0);
            morphoVaultAEta = 0;
        } else {
            morphoVaultB = next;
            pendingMorphoVaultB = address(0);
            morphoVaultBEta = 0;
        }

        emit MorphoVaultMigrated(leg, pending, wethAssets);
    }

    /// @notice Compatibility path for ClearcrestAdmin emergency fan-out. Raw
    ///         WETH is sent to the owner instead of forcing an emergency swap.
    function emergencyWithdrawAll() external onlyOwnerOrVault nonReentrant returns (uint256 wethReturned) {
        wethReturned = _emergencyWithdrawAll(owner());
    }

    /// @notice Break-glass exit. Redeems both Morpho vaults and transfers raw
    ///         WETH to `receiver`; no swap is forced during emergencies.
    function emergencyWithdrawAll(address receiver) external onlyOwner nonReentrant returns (uint256 wethReturned) {
        wethReturned = _emergencyWithdrawAll(receiver);
    }

    function _emergencyWithdrawAll(address receiver) internal returns (uint256 wethReturned) {
        if (receiver == address(0)) revert ZeroAddress();
        _redeemMorphoShares(morphoVaultA, _shares(morphoVaultA));
        _redeemMorphoShares(morphoVaultB, _shares(morphoVaultB));
        wethReturned = weth.balanceOf(address(this));
        if (wethReturned > 0) weth.safeTransfer(receiver, wethReturned);
        emit EmergencyWithdrawn(receiver, wethReturned);
    }

    function _depositMorpho(IERC4626 morphoVault, uint256 amount) internal {
        if (amount == 0) return;
        weth.forceApprove(address(morphoVault), amount);
        morphoVault.deposit(amount, address(this));
    }

    function _redeemMorphoFraction(IERC4626 morphoVault, uint256 fraction) internal returns (uint256 wethAssets) {
        uint256 shares = Math.mulDiv(_shares(morphoVault), fraction, 1e18);
        wethAssets = _redeemMorphoShares(morphoVault, shares);
    }

    function _redeemMorphoShares(IERC4626 morphoVault, uint256 shares) internal returns (uint256 wethAssets) {
        if (shares == 0) return 0;
        uint256 beforeWeth = weth.balanceOf(address(this));
        morphoVault.redeem(shares, address(this), address(this));
        wethAssets = weth.balanceOf(address(this)) - beforeWeth;
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        IERC20Metadata(tokenIn).forceApprove(address(router), amountIn);
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

    function _minUsdcOut(uint256 wethAmount) internal view returns (uint256) {
        uint256 expected = _wethValueUSDC(wethAmount);
        return Math.mulDiv(expected, BPS_DENOM - maxSlippageBps, BPS_DENOM);
    }

    function _minWethOut(uint256 usdcAmount) internal view returns (uint256) {
        uint256 price = _ethUsdPrice();
        uint256 expected = Math.mulDiv(usdcAmount, 10 ** (wethDecimals + feedDecimals), price * (10 ** usdcDecimals));
        return Math.mulDiv(expected, BPS_DENOM - maxSlippageBps, BPS_DENOM);
    }

    /// @dev WETH is 18-decimal and Chainlink ETH/USD is usually 8-decimal.
    ///      USDC value = weiAmount * ethUsdPrice * 1e6 / 10^(18 + feedDecimals).
    function _wethValueUSDC(uint256 wethAmount) internal view returns (uint256) {
        if (wethAmount == 0) return 0;
        uint256 price = _ethUsdPrice();
        return Math.mulDiv(wethAmount, price * (10 ** usdcDecimals), 10 ** (wethDecimals + feedDecimals));
    }

    function _ethUsdPrice() internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = ethUsdFeed.latestRoundData();
        if (answer <= 0 || answeredInRound < roundId || updatedAt == 0) revert InvalidPrice(address(ethUsdFeed));
        if (block.timestamp > updatedAt + maxStale) revert StalePrice(address(ethUsdFeed));
        return SafeCast.toUint256(answer);
    }

    function _shares(IERC4626 morphoVault) internal view returns (uint256) {
        return IERC20Metadata(address(morphoVault)).balanceOf(address(this));
    }

    function _validateLeg(uint8 leg) internal pure {
        if (leg != LEG_A && leg != LEG_B) revert InvalidLeg();
    }

    function _validateTickSpacing(int24 spacing) internal pure {
        if (spacing != 1 && spacing != 50 && spacing != 100 && spacing != 200 && spacing != 2_000) {
            revert InvalidTickSpacing();
        }
    }
}
