// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../tokens/BGWToken.sol";
import "../tokens/BGWGovToken.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/IAaveV3.sol";
import "../interfaces/ICamelotRouter.sol";
import "../interfaces/IMorphoBlue.sol";
import "../libraries/FeeLib.sol";

/// @title  BGWVault
/// @notice Bridgeway Protocol — standalone vault (no Enzyme).
///
///         Holds all assets across three sleeves:
///           A  70 %  Growth     — top-15 cryptos deployed via Aave/LSTs
///           B  25 %  Stability  — fiat stablecoins deployed via Aave/Morpho
///           C   5 %  Alpha      — Pendle PT, GMX GLP, Morpho Blue, restaking
///
///         BGW share price  = totalNAV / BGW.totalSupply()
///         BGW-GOV issued   = (bgwMinted / newTotalBGW) × communityPool
///
///         Access:
///           • deposit() / redeem() → whitelisted addresses only
///           • harvest / rebalance / buyback → automation contract only
///           • admin functions → owner (founder multisig)
///
/// @dev    NAV is denominated in USDC with 6-decimal precision throughout.
///         BGW and BGW-GOV tokens use 18-decimal precision.
contract BGWVault is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;
    using FeeLib     for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Arbitrum One addresses — verify before mainnet deploy.
    address public constant USDC            = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant WETH            = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address public constant CAMELOT_ROUTER  = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
    address public constant AAVE_POOL       = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant ETH_USD_FEED    = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    /// @dev Chainlink price staleness threshold.
    uint256 public constant ORACLE_STALE_THRESHOLD = 1 hours;

    /// @dev Max slippage allowed on DEX swaps (default 1 %).
    uint256 public constant MAX_SLIPPAGE_BPS = 100;

    // ── BGW-GOV distribution rate ─────────────────────────────────────────────
    // Fixed-rate formula: each depositor gets bgwMinted × (30M / 100M) BGW-GOV.
    // Using a fixed denominator ensures equal governance rate for all depositors
    // regardless of deposit order — the first depositor has no advantage.
    uint256 private constant GOV_COMMUNITY_ALLOC = 30_000_000e18;
    uint256 private constant GOV_TOTAL_SUPPLY    = 100_000_000e18;

    // ─────────────────────────────────────────────────────────────────────────
    // State — tokens
    // ─────────────────────────────────────────────────────────────────────────

    BGWToken    public immutable bgwToken;
    BGWGovToken public immutable govToken;

    // ─────────────────────────────────────────────────────────────────────────
    // State — fee wallets
    // ─────────────────────────────────────────────────────────────────────────

    address public teamWallet;
    address public holdbackWallet;
    address public lpSeedingWallet;
    address public reserveFundWallet;

    // ─────────────────────────────────────────────────────────────────────────
    // State — automation
    // ─────────────────────────────────────────────────────────────────────────

    address public automation;              // BridgewayAutomation contract
    bool    public automationSet;           // can only be set once

    // ─────────────────────────────────────────────────────────────────────────
    // State — portfolio accounting
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total USDC value currently tracked in each sleeve (6 dec).
    ///         Updated on deposit, redemption, rebalance, and harvest.
    uint256 public sleeveAValue;
    uint256 public sleeveBValue;
    uint256 public sleeveCValue;

    /// @notice High-water mark — NAV per BGW at last fee crystallisation (18 dec scale).
    ///         Expressed as USDC per BGW × 1e12 to retain precision.
    ///         E.g., $1.00 NAV/BGW  →  1_000_000 × 1e12 = 1e18.
    uint256 public highWaterMark;   // USD-per-BGW in 18 dec

    /// @notice USDC accumulated for next BGW buyback (6 dec).
    uint256 public buybackAccumulator;

    /// @notice Timestamp of last monthly harvest.
    uint256 public lastHarvestTime;

    // ─────────────────────────────────────────────────────────────────────────
    // State — exit fee
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Normal exit fee in basis points (default 10 = 0.10 %).
    uint256 public exitFeeBps = FeeLib.EXIT_FEE_BPS;

    /// @notice Stress exit fee in basis points (default 75 = 0.75 %).
    uint256 public stressExitFeeBps = FeeLib.STRESS_EXIT_BPS;

    /// @notice When true, stress exit fee is active (set by admin or automation).
    bool public stressModeActive;

    // ─────────────────────────────────────────────────────────────────────────
    // State — whitelist
    // ─────────────────────────────────────────────────────────────────────────

    mapping(address => bool) public whitelist;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(
        address indexed user,
        uint256 usdcAmount,
        uint256 bgwMinted,
        uint256 govDistributed
    );
    event Redeemed(
        address indexed user,
        uint256 bgwBurned,
        uint256 usdcPaid,
        uint256 exitFeeUsdc,
        uint256 perfFeeUsdc
    );
    event HarvestRecorded(
        uint256 netYieldUsdc,
        uint256 perfFeeUsdc,
        uint256 newHighWaterMark
    );
    event BuybackExecuted(uint256 usdcSpent, uint256 bgwBurned);
    event SleeveValuesUpdated(uint256 sleeveA, uint256 sleeveB, uint256 sleeveC);
    event WhitelistUpdated(address indexed account, bool status);
    event StressModeToggled(bool active);
    event AutomationSet(address indexed automation);
    event FeeWalletsUpdated(address team, address holdback, address lp, address reserve);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotWhitelisted(address account);
    error ZeroAmount();
    error SlippageTooHigh(uint256 received, uint256 minimum);
    error StaleOracle(uint256 updatedAt);
    error OnlyAutomation();
    error AutomationAlreadySet();
    error InsufficientBGW(uint256 have, uint256 need);
    error InvalidFeeBps(uint256 bps);
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyWhitelisted() {
        if (!whitelist[msg.sender]) revert NotWhitelisted(msg.sender);
        _;
    }

    modifier onlyAutomation() {
        if (msg.sender != automation) revert OnlyAutomation();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param _bgwToken          BGWToken contract address
    /// @param _govToken          BGWGovToken contract address
    /// @param _teamWallet        45 % of perf fee
    /// @param _holdbackWallet    20 % of perf fee (insurance)
    /// @param _lpSeedingWallet   10 % of perf fee
    /// @param _reserveFundWallet  5 % of perf fee
    /// @param _admin             Owner (founder wallet or multisig)
    constructor(
        address _bgwToken,
        address _govToken,
        address _teamWallet,
        address _holdbackWallet,
        address _lpSeedingWallet,
        address _reserveFundWallet,
        address _admin
    ) Ownable(_admin) {
        if (_bgwToken          == address(0)) revert ZeroAddress();
        if (_govToken          == address(0)) revert ZeroAddress();
        if (_teamWallet        == address(0)) revert ZeroAddress();
        if (_holdbackWallet    == address(0)) revert ZeroAddress();
        if (_lpSeedingWallet   == address(0)) revert ZeroAddress();
        if (_reserveFundWallet == address(0)) revert ZeroAddress();

        bgwToken          = BGWToken(_bgwToken);
        govToken          = BGWGovToken(_govToken);
        teamWallet        = _teamWallet;
        holdbackWallet    = _holdbackWallet;
        lpSeedingWallet   = _lpSeedingWallet;
        reserveFundWallet = _reserveFundWallet;

        // Bootstrap high-water mark at $1.00 per BGW (18 dec)
        highWaterMark = 1e18;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NAV & Pricing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total vault NAV: sum of all sleeve values (USDC, 6 dec).
    ///         In production, this should also query Aave aToken balances,
    ///         Morpho positions, etc. For MVP, we track sleeve values manually
    ///         updated by the automation contract each harvest.
    function totalNAV() public view returns (uint256) {
        return sleeveAValue + sleeveBValue + sleeveCValue;
    }

    /// @notice NAV per BGW token in USDC (6 dec).
    ///         Returns 1e6 ($1.00) if no BGW has been minted yet.
    function navPerBGW() public view returns (uint256) {
        uint256 supply = bgwToken.totalSupply();
        if (supply == 0) return 1e6; // bootstrap: $1.00 per BGW
        // totalNAV is in 6 dec; supply is in 18 dec
        // result in 6 dec: (nav6 * 1e18) / supply18 → 6 dec
        return (totalNAV() * 1e18) / supply;
    }

    /// @notice NAV per BGW expressed in 18 dec (for HWM comparison).
    function navPerBGW18() public view returns (uint256) {
        // navPerBGW is 6 dec; scale up to 18 dec
        return navPerBGW() * 1e12;
    }

    /// @notice Fetch ETH/USD price from Chainlink (8 dec).
    ///         Reverts if feed is stale (>1 hour).
    function getETHPrice() public view returns (uint256 price) {
        (, int256 answer, , uint256 updatedAt, ) =
            IChainlinkAggregator(ETH_USD_FEED).latestRoundData();
        if (block.timestamp - updatedAt > ORACLE_STALE_THRESHOLD)
            revert StaleOracle(updatedAt);
        require(answer > 0, "BGWVault: negative oracle price");
        price = uint256(answer); // 8 decimals
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit USDC into the vault. Must be whitelisted.
    ///         Mints BGW at current NAV. Distributes proportional BGW-GOV.
    /// @param  usdcAmount  Amount of USDC (6 dec) to deposit.
    function deposit(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyWhitelisted
    {
        if (usdcAmount == 0) revert ZeroAmount();

        // Pull USDC from user
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // Calculate BGW to mint: deposit / navPerBGW (both in 6 dec → result 18 dec)
        // bgwToMint = usdcAmount(6 dec) * 1e18 / navPerBGW(6 dec) → 18 dec
        uint256 nav6        = navPerBGW();
        uint256 bgwToMint   = (usdcAmount * 1e18) / nav6;

        // Distribute BGW-GOV from community pool before minting BGW
        // (so the formula uses post-mint supply denominator)
        uint256 govAmount = _calcGovDistribution(bgwToMint);

        // Mint BGW to depositor
        bgwToken.mint(msg.sender, bgwToMint);

        // Distribute BGW-GOV (vault holds community pool)
        if (govAmount > 0) {
            govToken.distributeToDepositor(msg.sender, govAmount);
        }

        // Deploy USDC into sleeves
        _deployToSleeves(usdcAmount);

        emit Deposited(msg.sender, usdcAmount, bgwToMint, govAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeem BGW for USDC. Applies exit fee + perf fee if above HWM.
    /// @param  bgwAmount  BGW to burn (18 dec).
    /// @param  minUSDC    Minimum USDC to accept (slippage guard, 6 dec).
    function redeem(uint256 bgwAmount, uint256 minUSDC)
        external
        nonReentrant
        whenNotPaused
        onlyWhitelisted
    {
        if (bgwAmount == 0) revert ZeroAmount();

        uint256 userBalance = bgwToken.balanceOf(msg.sender);
        if (userBalance < bgwAmount) revert InsufficientBGW(userBalance, bgwAmount);

        // Gross USDC value of this redemption
        uint256 grossUsdc = (bgwAmount * navPerBGW()) / 1e18;

        // ── Exit fee ───────────────────────────────────────────────────────
        uint256 feeBps      = stressModeActive ? stressExitFeeBps : exitFeeBps;
        uint256 exitFeeUsdc = FeeLib.calcExitFee(grossUsdc, feeBps);

        // ── Performance fee on accrued yield (if above HWM) ───────────────
        uint256 perfFeeUsdc;
        uint256 currentNav18 = navPerBGW18();
        if (currentNav18 > highWaterMark) {
            // Yield per BGW since HWM (in 18 dec)
            uint256 yieldPerBGW18 = currentNav18 - highWaterMark;
            // Total yield attributable to this redemption (6 dec)
            uint256 yieldUsdc = (bgwAmount * yieldPerBGW18) / 1e30; // 18+12=30 → 6 dec
            perfFeeUsdc = FeeLib.calcPerfFee(yieldUsdc);
        }

        // ── Net payout ────────────────────────────────────────────────────
        uint256 netUsdc = grossUsdc - exitFeeUsdc - perfFeeUsdc;
        if (netUsdc < minUSDC) revert SlippageTooHigh(netUsdc, minUSDC);

        // Burn BGW
        bgwToken.burnFrom(msg.sender, bgwAmount);

        // Update sleeve values (proportional reduction)
        _reduceSleevesProRata(grossUsdc);

        // Distribute performance fee
        if (perfFeeUsdc > 0) {
            _distributePerfFee(perfFeeUsdc);
            // Update HWM after crystallisation
            highWaterMark = navPerBGW18();
        }

        // Exit fee → holdback wallet (conservative; could be burned)
        if (exitFeeUsdc > 0) {
            IERC20(USDC).safeTransfer(holdbackWallet, exitFeeUsdc);
        }

        // Transfer net USDC to user
        // Note: in production, large redemptions trigger partial in-kind delivery.
        //       For MVP, all redemptions convert to USDC from the vault's balance.
        IERC20(USDC).safeTransfer(msg.sender, netUsdc);

        emit Redeemed(msg.sender, bgwAmount, netUsdc, exitFeeUsdc, perfFeeUsdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Harvest yield recording
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by BridgewayAutomation after claiming and converting all
    ///         protocol rewards to USDC. Records the net yield, takes perf fee,
    ///         and updates the HWM.
    /// @param  netYieldUsdc  Net yield in USDC (6 dec) after gas + slippage.
    /// @param  newSleeveA    Updated Sleeve A value post-harvest (6 dec).
    /// @param  newSleeveB    Updated Sleeve B value post-harvest (6 dec).
    /// @param  newSleeveC    Updated Sleeve C value post-harvest (6 dec).
    function recordHarvest(
        uint256 netYieldUsdc,
        uint256 newSleeveA,
        uint256 newSleeveB,
        uint256 newSleeveC
    ) external onlyAutomation {
        // Update sleeve values
        sleeveAValue = newSleeveA;
        sleeveBValue = newSleeveB;
        sleeveCValue = newSleeveC;
        lastHarvestTime = block.timestamp;

        emit SleeveValuesUpdated(newSleeveA, newSleeveB, newSleeveC);

        if (netYieldUsdc == 0) return;

        // Take performance fee only if current NAV > HWM
        uint256 currentNav18 = navPerBGW18();
        uint256 perfFeeUsdc;
        if (currentNav18 > highWaterMark) {
            perfFeeUsdc = FeeLib.calcPerfFee(netYieldUsdc);
            _distributePerfFee(perfFeeUsdc);
            highWaterMark = navPerBGW18();
        }

        emit HarvestRecorded(netYieldUsdc, perfFeeUsdc, highWaterMark);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Buyback & Burn
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Spend `usdcAmount` from the buyback accumulator:
    ///         swap USDC → BGW on Camelot, then burn the received BGW.
    /// @param  usdcAmount  USDC to spend (6 dec). Must be ≤ buybackAccumulator.
    function executeBuyback(uint256 usdcAmount) external onlyAutomation {
        if (usdcAmount == 0 || usdcAmount > buybackAccumulator) return;

        buybackAccumulator -= usdcAmount;

        // Approve Camelot to spend USDC
        IERC20(USDC).forceApprove(CAMELOT_ROUTER, usdcAmount);

        // Get expected BGW out
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        uint256[] memory amountsOut =
            ICamelotRouter(CAMELOT_ROUTER).getAmountsOut(usdcAmount, path);
        uint256 minBGW = (amountsOut[1] * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
            FeeLib.BPS_DENOM;

        uint256 bgwBefore = bgwToken.balanceOf(address(this));

        ICamelotRouter(CAMELOT_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                usdcAmount,
                minBGW,
                path,
                address(this),
                address(0), // no referrer
                block.timestamp + 5 minutes
            );

        uint256 bgwReceived = bgwToken.balanceOf(address(this)) - bgwBefore;

        // Burn the bought BGW
        bgwToken.burn(bgwReceived);

        emit BuybackExecuted(usdcAmount, bgwReceived);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Sleeve value update (manual rebalance report)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Automation reports updated sleeve values after rebalancing.
    function updateSleeveValues(
        uint256 newSleeveA,
        uint256 newSleeveB,
        uint256 newSleeveC
    ) external onlyAutomation {
        sleeveAValue = newSleeveA;
        sleeveBValue = newSleeveB;
        sleeveCValue = newSleeveC;
        emit SleeveValuesUpdated(newSleeveA, newSleeveB, newSleeveC);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the automation contract address. Can only be called once.
    function setAutomation(address _automation) external onlyOwner {
        if (automationSet) revert AutomationAlreadySet();
        if (_automation == address(0)) revert ZeroAddress();
        automation    = _automation;
        automationSet = true;
        emit AutomationSet(_automation);
    }

    /// @notice Add or remove an address from the vault whitelist.
    ///         Also updates the BGWToken whitelist.
    function setWhitelisted(address account, bool status) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        whitelist[account] = status;
        bgwToken.setWhitelisted(account, status);
        emit WhitelistUpdated(account, status);
    }

    /// @notice Batch whitelist update.
    function setWhitelistedBatch(address[] calldata accounts, bool status)
        external
        onlyOwner
    {
        for (uint256 i; i < accounts.length; ++i) {
            whitelist[accounts[i]] = status;
            bgwToken.setWhitelisted(accounts[i], status);
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    /// @notice Set normal exit fee (max 100 bps = 1 %).
    function setExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        exitFeeBps = feeBps;
    }

    /// @notice Set stress exit fee (max 200 bps = 2 %).
    function setStressExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 200) revert InvalidFeeBps(feeBps);
        stressExitFeeBps = feeBps;
    }

    /// @notice Activate or deactivate stress mode (higher exit fee).
    function setStressMode(bool active) external onlyOwner {
        stressModeActive = active;
        emit StressModeToggled(active);
    }

    /// @notice Update fee recipient wallets.
    function updateFeeWallets(
        address _team,
        address _holdback,
        address _lp,
        address _reserve
    ) external onlyOwner {
        if (_team    == address(0)) revert ZeroAddress();
        if (_holdback == address(0)) revert ZeroAddress();
        if (_lp      == address(0)) revert ZeroAddress();
        if (_reserve == address(0)) revert ZeroAddress();

        teamWallet        = _team;
        holdbackWallet    = _holdback;
        lpSeedingWallet   = _lp;
        reserveFundWallet = _reserve;
        emit FeeWalletsUpdated(_team, _holdback, _lp, _reserve);
    }

    /// @notice Emergency pause. Blocks deposit + redeem.
    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Emergency: recover tokens accidentally sent to the vault.
    ///         Cannot recover USDC (vault funds) — use carefully.
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyOwner
    {
        require(token != USDC, "BGWVault: cannot recover vault USDC");
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy new USDC deposit into sleeves at target weights (70/25/5).
    function _deployToSleeves(uint256 usdcAmount) internal {
        uint256 toA = (usdcAmount * FeeLib.SLEEVE_A_BPS) / FeeLib.BPS_DENOM;
        uint256 toB = (usdcAmount * FeeLib.SLEEVE_B_BPS) / FeeLib.BPS_DENOM;
        uint256 toC = usdcAmount - toA - toB; // remainder to avoid dust

        sleeveAValue += toA;
        sleeveBValue += toB;
        sleeveCValue += toC;

        // In production: USDC is deployed into Aave (Sleeve B), Lido/Aave (Sleeve A),
        // Pendle/GMX/Morpho (Sleeve C).
        // For MVP: USDC sits in the vault; automation deploys it externally
        // and reports back via recordHarvest() / updateSleeveValues().
    }

    /// @dev Reduce sleeve values proportionally when BGW is redeemed.
    function _reduceSleevesProRata(uint256 grossUsdc) internal {
        uint256 nav = totalNAV();
        if (nav == 0) return;

        sleeveAValue -= (sleeveAValue * grossUsdc) / nav;
        sleeveBValue -= (sleeveBValue * grossUsdc) / nav;
        sleeveCValue -= (sleeveCValue * grossUsdc) / nav;
    }

    /// @dev Distribute performance fee across 6 recipients.
    function _distributePerfFee(uint256 totalFee) internal {
        if (totalFee == 0) return;

        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(totalFee);

        IERC20(USDC).safeTransfer(teamWallet,        s.team);
        IERC20(USDC).safeTransfer(holdbackWallet,    s.holdback);
        IERC20(USDC).safeTransfer(lpSeedingWallet,   s.lpSeed);
        IERC20(USDC).safeTransfer(reserveFundWallet, s.reserve);

        // Buyback portion → accumulator
        buybackAccumulator += s.buyback;

        // Direct burn: convert to BGW and burn immediately
        if (s.directBurn > 0) {
            _burnViaSwap(s.directBurn);
        }
    }

    /// @dev Swap USDC → BGW on Camelot and burn (used for direct-burn fee split).
    function _burnViaSwap(uint256 usdcAmount) internal {
        IERC20(USDC).forceApprove(CAMELOT_ROUTER, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        uint256[] memory amountsOut =
            ICamelotRouter(CAMELOT_ROUTER).getAmountsOut(usdcAmount, path);
        uint256 minBGW = (amountsOut[1] * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
            FeeLib.BPS_DENOM;

        uint256 bgwBefore = bgwToken.balanceOf(address(this));

        ICamelotRouter(CAMELOT_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                usdcAmount,
                minBGW,
                path,
                address(this),
                address(0),
                block.timestamp + 5 minutes
            );

        uint256 received = bgwToken.balanceOf(address(this)) - bgwBefore;
        if (received > 0) bgwToken.burn(received);
    }

    /// @dev Calculate BGW-GOV to distribute to a new depositor.
    ///      Fixed-rate formula: govAmount = bgwMinted × (COMMUNITY_ALLOC / TOTAL_SUPPLY)
    ///                                    = bgwMinted × 30%
    ///      The fixed denominator (100 M, the GOV total supply) means every depositor
    ///      receives the same rate regardless of when they deposit or how large the
    ///      existing BGW supply is. Pool depletes gracefully once 100 M BGW is minted.
    function _calcGovDistribution(uint256 bgwMinted) internal view returns (uint256) {
        uint256 communityPool = govToken.balanceOf(address(this));
        if (communityPool == 0 || bgwMinted == 0) return 0;

        uint256 govAmount = (bgwMinted * GOV_COMMUNITY_ALLOC) / GOV_TOTAL_SUPPLY;
        return govAmount > communityPool ? communityPool : govAmount;
    }
}
