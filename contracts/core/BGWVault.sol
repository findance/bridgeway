// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../tokens/BGWToken.sol";
import "../tokens/BGWGovToken.sol";
import "../interfaces/IChainlinkAggregator.sol";
import "../interfaces/IAaveV3.sol";
import "../interfaces/IMorphoBlue.sol";
import "../interfaces/IBridgewayHubNAV.sol";
import "../interfaces/ISleeveAdapter.sol";
import "../libraries/FeeLib.sol";

/// @title  BGWVault
/// @notice Bridgeway Protocol — standalone vault (no Enzyme).
///
///         Holds all assets across three sleeves:
///           A  65 %  Growth     — top non-stable cryptos through approved routes
///           B  30 %  Stability  — trusted stablecoin exposures
///           C   5 %  Alpha      — capped higher-yield strategies
///
///         Launch weights are 65/35/0 while Sleeve C is intentionally deferred.
///         The owner can move to 65/30/5 through the config timelock once Sleeve C
///         routes are ready.
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
    using FeeLib for uint256;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Chainlink price staleness threshold.
    uint256 public constant ORACLE_STALE_THRESHOLD = 20 minutes;

    /// @dev Chainlink USD feeds are normalized to 8 decimals for pricing guards.
    uint256 public constant USD_PRICE_SCALE = 1e8;

    uint8 public constant SLEEVE_A = 0;
    uint8 public constant SLEEVE_B = 1;
    uint8 public constant SLEEVE_C = 2;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables — set once at construction, never changed (M-06)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC token address (6 dec). Passed at deploy — no bytecode hardcoding.
    address public immutable USDC;

    /// @notice Chainlink USDC/USD price feed used to cap redemption settlement value.
    address public immutable USDC_USD_FEED;

    // ─────────────────────────────────────────────────────────────────────────
    // State — tokens
    // ─────────────────────────────────────────────────────────────────────────

    BGWToken public immutable bgwToken;
    BGWGovToken public immutable govToken;

    // ─────────────────────────────────────────────────────────────────────────
    // State — fee wallets
    // ─────────────────────────────────────────────────────────────────────────

    address public teamWallet;
    address public holdbackWallet;
    address public reserveFundWallet;

    // ─────────────────────────────────────────────────────────────────────────
    // State — automation
    // ─────────────────────────────────────────────────────────────────────────

    address public automation; // BridgewayAutomation contract

    // ─────────────────────────────────────────────────────────────────────────
    // State — portfolio accounting
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total USDC value currently tracked in each sleeve (6 dec).
    uint256 public sleeveAValue;
    uint256 public sleeveBValue;
    uint256 public sleeveCValue;

    /// @notice Optional strategy adapters for sleeves A/B/C.
    ///         If unset, the sleeve uses manual vault accounting.
    address[3] public sleeveAdapters;

    struct SleeveAdapterRoute {
        address adapter;
        uint16 depositBps;
        bool active;
    }

    /// @notice Optional multi-adapter routes per sleeve. Once configured for a
    ///         sleeve, these routes supersede the legacy single adapter slot.
    ///         Registered adapters are always counted in NAV until removed empty.
    mapping(uint8 => SleeveAdapterRoute[]) private _sleeveAdapterRoutes;

    /// @notice Vault-level deposit weights. Launch config sends Sleeve C's 5%
    ///         allocation to Sleeve B until the alpha sleeve is deliberately enabled.
    uint16 public sleeveADepositBps = 6_500;
    uint16 public sleeveBDepositBps = 3_500;
    uint16 public sleeveCDepositBps = 0;

    /// @notice Optional hub-chain global NAV cache for confirmed spoke reports.
    ///         When set, totalNAV() includes confirmed spoke NAV in addition to local sleeves.
    address public hubNAV;

    /// @notice Governance-approved assets for each sleeve.
    mapping(uint8 => mapping(address => bool)) public trustedSleeveAssets;

    /// @dev Number of sleeves that currently trust a token.
    mapping(address => uint256) public trustedAssetUseCount;

    /// @notice High-water mark — NAV per BGW at last fee crystallisation (18 dec scale).
    uint256 public highWaterMark;
    uint256 public lastHWMUpdateTime;

    /// @notice Annual management fee in basis points (default 50 = 0.50 %).
    uint256 public managementFeeBps = FeeLib.MANAGEMENT_FEE_BPS;

    /// @notice USDC accumulated for next BGW reserve injection and burn (6 dec).
    uint256 public buybackAccumulator;

    /// @notice Timestamp of last monthly harvest.
    uint256 public lastHarvestTime;

    // ─────────────────────────────────────────────────────────────────────────
    // State — exit fee
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public exitFeeBps = FeeLib.EXIT_FEE_BPS;
    uint256 public stressExitFeeBps = FeeLib.STRESS_EXIT_BPS;
    bool public stressModeActive;

    // ─────────────────────────────────────────────────────────────────────────
    // State — principal tracking (C-01)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Running total of all USDC deposited minus proportional redemptions.
    uint256 public cumulativePrincipal;

    /// @notice Realised losses formally acknowledged by governance.
    uint256 public authorisedLosses;

    // ─────────────────────────────────────────────────────────────────────────
    // State — whitelist
    // ─────────────────────────────────────────────────────────────────────────

    mapping(address => bool) public whitelist;

    /// @notice Maximum USDC per single deposit. 0 = uncapped.
    uint256 public maxDepositUsdc;

    // ─────────────────────────────────────────────────────────────────────────
    // State — protected tokens (C-02)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tokens that cannot be swept via recoverToken().
    ///         Populated at construction with known Aave aTokens + LST wrappers.
    ///         Owner registers new entries whenever the vault deploys into a new
    ///         protocol (Pendle PTs, GMX GLP, Morpho shares, etc.) and removes
    ///         them once the position is fully unwound.
    mapping(address => bool) public protectedTokens;

    // ─────────────────────────────────────────────────────────────────────────
    // State — pending fees (pull-escrow for failed fee-wallet transfers)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC owed to fee recipients that could not be pushed directly.
    ///         Fee recipients call claimFees() to withdraw their balance.
    mapping(address => uint256) public pendingFees;

    /// @notice Sum of all escrowed pendingFees. This is deliberately excluded
    ///         from totalNAV() because it belongs to fee recipients, not BGW holders.
    uint256 public totalPendingFees;

    // ─────────────────────────────────────────────────────────────────────────
    // State — queued cross-chain redemptions
    // ─────────────────────────────────────────────────────────────────────────

    struct QueuedRedemption {
        address claimant;
        uint256 netUsdc;
        uint256 exitFeeUsdc;
        uint256 perfFeeUsdc;
        uint256 navLiabilityUsdc;
        uint256 spokeNavSnapshotUsdc;
        uint256 spokeNavReservedUsdc;
        bool claimed;
    }

    uint256 public queuedRedemptionCount;
    uint256 public totalQueuedRedemptionGross;
    uint256 public totalQueuedRedemptionNAVLiability;
    mapping(uint256 => QueuedRedemption) private _queuedRedemptions;

    /// @notice Timestamp when fees last failed for each recipient (used by sweepStaleFees).
    mapping(address => uint256) public lastFeeAccrual;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event MaxDepositCapUpdated(uint256 newCap);
    event Deposited(address indexed user, uint256 usdcAmount, uint256 bgwMinted, uint256 govDistributed);
    event Redeemed(address indexed user, uint256 bgwBurned, uint256 usdcPaid, uint256 exitFeeUsdc, uint256 perfFeeUsdc);
    event RedemptionQueued(
        uint256 indexed redemptionId,
        address indexed user,
        uint256 bgwBurned,
        uint256 grossUsdc,
        uint256 netUsdc,
        uint256 exitFeeUsdc,
        uint256 perfFeeUsdc
    );
    event QueuedRedemptionClaimed(
        uint256 indexed redemptionId, address indexed user, uint256 netUsdc, uint256 exitFeeUsdc, uint256 perfFeeUsdc
    );
    event QueuedRedemptionLiquidityAcknowledged(
        uint256 indexed redemptionId, uint256 amount, uint256 remainingNAVLiability
    );
    event HarvestRecorded(uint256 netYieldUsdc, uint256 perfFeeUsdc, uint256 newHighWaterMark);
    event BuybackExecuted(uint256 usdcInjected, uint256 bgwMintedAndBurned);
    event StaleFeeSwept(address indexed staleWallet, address indexed recipient, uint256 amount); // H-13
    event SleeveValuesUpdated(uint256 sleeveA, uint256 sleeveB, uint256 sleeveC);
    event SleeveAdapterSet(uint8 indexed sleeve, address indexed adapter);
    event SleeveAdapterRoutesConfigured(uint8 indexed sleeve, uint256 routeCount, uint256 activeDepositBps);
    event SleeveDepositWeightsUpdated(uint16 sleeveA, uint16 sleeveB, uint16 sleeveC);
    event TrustedSleeveAssetUpdated(uint8 indexed sleeve, address indexed asset, bool trusted);
    event ManagementFeeCharged(uint256 feeUsdc, uint256 elapsed);
    event ManagementFeeBpsUpdated(uint256 newBps);
    event ExitFeeBpsUpdated(uint256 newBps);
    event StressExitFeeBpsUpdated(uint256 newBps);
    event WhitelistUpdated(address indexed account, bool status);
    event StressModeToggled(bool active);
    event AutomationSet(address indexed automation);
    event AutomationRevoked(address indexed old);
    event LossMarkExecuted(uint256 amount);
    event FeeWalletsUpdated(address team, address holdback, address reserve);
    event ProtectedTokenUpdated(address indexed token, bool protected);
    event HubNAVSet(address indexed hubNAV);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotWhitelisted(address account);
    error ZeroAmount();
    error SlippageTooHigh(uint256 received, uint256 minimum);
    error StaleOracle(uint256 updatedAt);
    error OnlyAutomation();
    error InsufficientBGW(uint256 have, uint256 need);
    error InvalidFeeBps(uint256 bps);
    error ZeroAddress();
    error DepositExceedsCap(uint256 amount, uint256 cap);
    error UnknownQueuedRedemption(uint256 redemptionId);
    error NotQueuedRedemptionClaimant(uint256 redemptionId, address caller);
    error QueuedRedemptionAlreadyClaimed(uint256 redemptionId);
    error QueuedRedemptionNotReady(uint256 redemptionId, uint256 navLiabilityRemaining);
    error InsufficientLocalLiquidity(uint256 available, uint256 required);
    error FundedAdapterRemovalBlocked(uint8 sleeve, address adapter, uint256 assetsUsdc);
    error InvalidSleeveDepositWeights(uint256 totalBps);
    error NoPendingFees();
    error ProtectedTokenRecovery(address token);
    error AdapterChangeAfterDeposits();
    error InvalidOracleRound(uint80 roundId, uint80 answeredInRound);
    error InvalidOraclePrice(int256 answer);
    error BatchTooLarge(uint256 count, uint256 max);
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

    constructor(
        address _bgwToken,
        address _govToken,
        address _teamWallet,
        address _holdbackWallet,
        address _reserveFundWallet,
        address _admin,
        address _usdc,
        address _usdcUsdFeed
    ) Ownable(_admin) {
        if (_bgwToken == address(0)) revert ZeroAddress();
        if (_govToken == address(0)) revert ZeroAddress();
        if (_teamWallet == address(0)) revert ZeroAddress();
        if (_holdbackWallet == address(0)) revert ZeroAddress();
        if (_reserveFundWallet == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_usdcUsdFeed == address(0)) revert ZeroAddress();

        bgwToken = BGWToken(_bgwToken);
        govToken = BGWGovToken(_govToken);
        teamWallet = _teamWallet;
        holdbackWallet = _holdbackWallet;
        reserveFundWallet = _reserveFundWallet;
        USDC = _usdc;
        USDC_USD_FEED = _usdcUsdFeed;

        highWaterMark = 1e18;
        lastHWMUpdateTime = block.timestamp;
        lastHarvestTime = block.timestamp;

        // ── Seed protectedTokens with legacy launch-approved Aave V3 aTokens ──
        // These are the yield-bearing tokens the vault holds on behalf of depositors.
        // Owner must add new entries (Pendle PTs, GMX GLP, etc.) before each deploy
        // and remove them once the position is fully unwound.
        //
        // Legacy Aave V3 Arbitrum One entries. Base deployments must add Base
        // aTokens through setProtectedToken before moving funds.
        protectedTokens[0x724dc807b04555b71ed48a6896b6F41593b8C637] = true; // aUSDCn
        protectedTokens[0x6ab707Aca953eDAeFBc4fD23bA73294241490620] = true; // aUSDT
        protectedTokens[0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8] = true; // aWETH
        // Pendle PT tokens, GMX GLP, Morpho shares, sUSDe -> add via setProtectedToken
        // before each protocol deployment.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NAV & Pricing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Portfolio NAV attributable to BGW holders.
    ///         Pending fees are excluded because they are liabilities owed to fee
    ///         recipients, even when their USDC is still held by the vault.
    ///         The buyback accumulator is also excluded because it is reserved
    ///         for future BGW buyback-and-burn actions, not ordinary redeemable NAV.
    function totalNAV() public view returns (uint256) {
        uint256 grossNav = totalLocalNAV() + totalSpokeNAV();
        uint256 queued = totalQueuedRedemptionNAVLiability;
        return grossNav > queued ? grossNav - queued : 0;
    }

    /// @notice NAV held on the hub chain in local sleeves.
    function totalLocalNAV() public view returns (uint256) {
        return _sleeveValue(SLEEVE_A) + _sleeveValue(SLEEVE_B) + _sleeveValue(SLEEVE_C);
    }

    /// @notice Confirmed spoke NAV cached by the hub NAV contract. Queued
    ///         redemptions are deducted once via totalQueuedRedemptionNAVLiability.
    function totalSpokeNAV() public view returns (uint256) {
        address nav = hubNAV;
        if (nav == address(0)) return 0;
        return IBridgewayHubNAV(nav).totalSpokeNAVUSDC();
    }

    /// @notice Current USDC-denominated value for one sleeve.
    function sleeveValue(uint8 sleeve) public view returns (uint256) {
        return _sleeveValue(sleeve);
    }

    /// @notice NAV per BGW token in USDC (6 dec). Returns 1e6 ($1.00) if no BGW minted.
    function navPerBGW() public view returns (uint256) {
        uint256 supply = bgwToken.totalSupply();
        if (supply == 0) return 1e6;
        return (totalNAV() * 1e18) / supply;
    }

    /// @notice NAV per BGW expressed in 18 dec (for HWM comparison).
    function navPerBGW18() public view returns (uint256) {
        return navPerBGW() * 1e12;
    }

    /// @notice Effective HWM after time-based decay.
    function effectiveHighWaterMark() public view returns (uint256) {
        return _decayedHWM();
    }

    /// @notice USDC/USD redemption value, capped at $1.00 and allowed to mark down below peg.
    function getUSDCPriceForRedemption() public view returns (uint256 price) {
        price = _usdPrice8(USDC_USD_FEED);
        if (price > USD_PRICE_SCALE) return USD_PRICE_SCALE;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit USDC into the vault for the caller. Must be whitelisted.
    ///         Mints BGW at current NAV. Distributes proportional BGW-GOV.
    /// @param  usdcAmount  Amount of USDC (6 dec) to deposit.
    /// @param  minBgwOut   Minimum BGW to receive (slippage guard, 18 dec). Pass 0 to skip.
    function deposit(uint256 usdcAmount, uint256 minBgwOut) external {
        depositFor(msg.sender, usdcAmount, minBgwOut);
    }

    /// @notice Deposit USDC into the vault and mint BGW/BGW-GOV to `recipient`.
    ///         This supports external zaps/aggregators that deliver hub-chain USDC.
    /// @param  recipient   Address receiving BGW and BGW-GOV on the hub chain.
    /// @param  usdcAmount  Amount of USDC (6 dec) to deposit.
    /// @param  minBgwOut   Minimum BGW to receive (slippage guard, 18 dec). Pass 0 to skip.
    function depositFor(address recipient, uint256 usdcAmount, uint256 minBgwOut)
        public
        nonReentrant
        whenNotPaused
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (!whitelist[recipient]) revert NotWhitelisted(recipient);
        if (usdcAmount == 0) revert ZeroAmount();
        if (maxDepositUsdc > 0 && usdcAmount > maxDepositUsdc) {
            revert DepositExceedsCap(usdcAmount, maxDepositUsdc);
        }

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);
        cumulativePrincipal += usdcAmount;

        uint256 nav6 = navPerBGW();
        uint256 bgwToMint = (usdcAmount * 1e18) / nav6;

        if (bgwToMint < minBgwOut) revert SlippageTooHigh(bgwToMint, minBgwOut);

        // Effects before interactions (CEI)
        _deployToSleeves(usdcAmount);

        bgwToken.mint(recipient, bgwToMint);
        (uint256 depositorGov,) = govToken.mintForDeposit(recipient, bgwToMint);

        emit Deposited(recipient, usdcAmount, bgwToMint, depositorGov);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeem BGW for USDC. Applies exit fee + perf fee if above HWM.
    ///         No whitelist check — holders must always be able to exit (H-02).
    /// @param  bgwAmount  BGW to burn (18 dec).
    /// @param  minUSDC    Minimum USDC to accept (slippage guard, 6 dec).
    function redeem(uint256 bgwAmount, uint256 minUSDC) external nonReentrant whenNotPaused {
        if (bgwAmount == 0) revert ZeroAmount();

        uint256 userBalance = bgwToken.balanceOf(msg.sender);
        if (userBalance < bgwAmount) revert InsufficientBGW(userBalance, bgwAmount);

        uint256 grossUsdc = _redemptionUSDCAmount((bgwAmount * navPerBGW()) / 1e18);

        uint256 feeBps = stressModeActive ? stressExitFeeBps : exitFeeBps;
        uint256 exitFeeUsdc = FeeLib.calcExitFee(grossUsdc, feeBps);

        uint256 perfFeeUsdc;
        uint256 currentNav18 = navPerBGW18();
        uint256 effectiveHwm = _decayedHWM();
        if (currentNav18 > effectiveHwm) {
            uint256 yieldPerBGW18 = currentNav18 - effectiveHwm;
            uint256 yieldUsdc = (bgwAmount * yieldPerBGW18) / 1e30;
            perfFeeUsdc = FeeLib.calcPerfFee(yieldUsdc);
        }

        uint256 netUsdc = grossUsdc - exitFeeUsdc - perfFeeUsdc;
        if (netUsdc < minUSDC) revert SlippageTooHigh(netUsdc, minUSDC);

        uint256 currentNav18ForHwm = currentNav18;

        // Proportionally reduce cumulative principal before burning (C-01).
        // Must be done before adminBurn because totalSupply changes after the burn.
        _reducePrincipalForBurn(bgwAmount);

        bgwToken.adminBurn(msg.sender, bgwAmount);

        if (grossUsdc > totalLocalNAV()) {
            _queueRedemption(
                msg.sender, bgwAmount, grossUsdc, netUsdc, exitFeeUsdc, perfFeeUsdc, currentNav18ForHwm, effectiveHwm
            );
            return;
        }

        _reduceSleevesProRata(grossUsdc);

        if (perfFeeUsdc > 0) {
            _distributePerfFee(perfFeeUsdc);
            // H-03/H-14: same 1% minimum delta required for HWM crystallisation.
            if (currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM) {
                highWaterMark = navPerBGW18();
                lastHWMUpdateTime = block.timestamp;
            }
        }

        if (exitFeeUsdc > 0) {
            _tryTransferFee(holdbackWallet, exitFeeUsdc);
        }

        IERC20(USDC).safeTransfer(msg.sender, netUsdc);

        emit Redeemed(msg.sender, bgwAmount, netUsdc, exitFeeUsdc, perfFeeUsdc);
    }

    /// @notice Claim a queued redemption once hub-chain liquidity has arrived
    ///         from spoke unwinds or treasury buffering.
    function claimQueuedRedemption(uint256 redemptionId) external nonReentrant whenNotPaused {
        QueuedRedemption storage redemption = _queuedRedemptions[redemptionId];
        if (redemption.claimant == address(0)) revert UnknownQueuedRedemption(redemptionId);
        if (redemption.claimant != msg.sender) revert NotQueuedRedemptionClaimant(redemptionId, msg.sender);
        if (redemption.claimed) revert QueuedRedemptionAlreadyClaimed(redemptionId);
        if (redemption.navLiabilityUsdc > 0) {
            revert QueuedRedemptionNotReady(redemptionId, redemption.navLiabilityUsdc);
        }

        uint256 requiredUsdc = redemption.netUsdc + redemption.exitFeeUsdc + redemption.perfFeeUsdc;
        uint256 availableUsdc = _availableUSDC();
        if (availableUsdc < requiredUsdc) revert InsufficientLocalLiquidity(availableUsdc, requiredUsdc);

        redemption.claimed = true;
        totalQueuedRedemptionGross -= requiredUsdc;

        if (redemption.perfFeeUsdc > 0) {
            _distributePerfFee(redemption.perfFeeUsdc);
        }
        if (redemption.exitFeeUsdc > 0) {
            _tryTransferFee(holdbackWallet, redemption.exitFeeUsdc);
        }

        IERC20(USDC).safeTransfer(msg.sender, redemption.netUsdc);

        emit QueuedRedemptionClaimed(
            redemptionId, msg.sender, redemption.netUsdc, redemption.exitFeeUsdc, redemption.perfFeeUsdc
        );
    }

    /// @notice Mark queued redemption NAV as no longer counted in spoke/local
    ///         reports after unwind liquidity has arrived or a source NAV report
    ///         has dropped. This prepares the queue item for claimant withdrawal.
    function acknowledgeQueuedRedemptionLiquidity(uint256 redemptionId, uint256 amount) external {
        if (msg.sender != owner() && msg.sender != automation) revert OnlyAutomation();
        QueuedRedemption storage redemption = _queuedRedemptions[redemptionId];
        if (redemption.claimant == address(0)) revert UnknownQueuedRedemption(redemptionId);
        if (redemption.claimed) revert QueuedRedemptionAlreadyClaimed(redemptionId);
        if (amount > redemption.navLiabilityUsdc) amount = redemption.navLiabilityUsdc;

        uint256 reservedRelease = amount > redemption.spokeNavReservedUsdc ? redemption.spokeNavReservedUsdc : amount;
        if (reservedRelease > 0 && hubNAV != address(0) && redemption.spokeNavSnapshotUsdc > 0) {
            uint256 currentSpokeNav = IBridgewayHubNAV(hubNAV).totalSpokeNAVUSDC();
            uint256 spokeDrop = redemption.spokeNavSnapshotUsdc > currentSpokeNav
                ? redemption.spokeNavSnapshotUsdc - currentSpokeNav
                : 0;
            if (spokeDrop < reservedRelease) {
                revert QueuedRedemptionNotReady(redemptionId, reservedRelease);
            }
            redemption.spokeNavSnapshotUsdc = currentSpokeNav;
        }

        redemption.navLiabilityUsdc -= amount;
        totalQueuedRedemptionNAVLiability -= amount;

        if (reservedRelease > 0) {
            redemption.spokeNavReservedUsdc -= reservedRelease;
        }

        emit QueuedRedemptionLiquidityAcknowledged(redemptionId, amount, redemption.navLiabilityUsdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Harvest yield recording
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called by BridgewayAutomation after claiming and converting all
    ///         protocol rewards to USDC.
    /// @param  netYieldUsdc  Net yield in USDC (6 dec) after gas + slippage.
    /// @param  newSleeveA    Updated Sleeve A value post-harvest (6 dec).
    /// @param  newSleeveB    Updated Sleeve B value post-harvest (6 dec).
    /// @param  newSleeveC    Updated Sleeve C value post-harvest (6 dec).
    function recordHarvest(uint256 netYieldUsdc, uint256 newSleeveA, uint256 newSleeveB, uint256 newSleeveC)
        external
        nonReentrant
        whenNotPaused
        onlyAutomation
    {
        // Yield must not exceed actual USDC received — fundamental sanity check (C-01).
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 availableUsdc = usdcBalance > totalPendingFees ? usdcBalance - totalPendingFees : 0;
        require(netYieldUsdc <= availableUsdc, "BGWVault: yield exceeds balance");

        // Time-weighted anti-manipulation bounds (C-01).
        // lastHarvestTime is initialised in the constructor so the first harvest
        // is constrained against the deployment timestamp instead of receiving
        // a one-time unrestricted reporting window.
        uint256 sinceLastHarvest = block.timestamp - lastHarvestTime;
        require(sinceLastHarvest >= FeeLib.MIN_HARVEST_GAP, "BGWVault: harvest gap too short");

        uint256 nav = totalNAV();
        if (nav > 0 && netYieldUsdc > 0) {
            uint256 maxYield = (nav * FeeLib.MAX_YIELD_APR_BPS * sinceLastHarvest) / (FeeLib.BPS_DENOM * 365 days);
            require(netYieldUsdc <= maxYield, "BGWVault: yield rate too high");
        }

        uint256 actualA = _reportedOrAdapterValue(SLEEVE_A, newSleeveA);
        uint256 actualB = _reportedOrAdapterValue(SLEEVE_B, newSleeveB);
        uint256 actualC = _reportedOrAdapterValue(SLEEVE_C, newSleeveC);

        _checkSleeveMove(sleeveAValue, actualA, sinceLastHarvest);
        _checkSleeveMove(sleeveBValue, actualB, sinceLastHarvest);
        _checkSleeveMove(sleeveCValue, actualC, sinceLastHarvest);

        sleeveAValue = actualA;
        sleeveBValue = actualB;
        sleeveCValue = actualC;
        emit SleeveValuesUpdated(actualA, actualB, actualC);

        _chargeManagementFee();

        lastHarvestTime = block.timestamp;

        if (netYieldUsdc == 0) return;

        uint256 currentNav18 = navPerBGW18();
        uint256 effectiveHwm = _decayedHWM();
        uint256 perfFeeUsdc;
        if (currentNav18 > effectiveHwm) {
            perfFeeUsdc = FeeLib.calcPerfFee(netYieldUsdc);
            _distributePerfFee(perfFeeUsdc);
            _reduceSleevesProRata(perfFeeUsdc);
            // H-03/H-14: only crystallise when NAV is at least 1% above effective HWM,
            // preventing choppy markets from resetting the 1-year decay clock on every tick.
            if (currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM) {
                highWaterMark = navPerBGW18();
                lastHWMUpdateTime = block.timestamp;
            }
        }

        emit HarvestRecorded(netYieldUsdc, perfFeeUsdc, highWaterMark);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Buyback & Burn
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Spend `usdcAmount` from the buyback accumulator by injecting it
    ///         into portfolio sleeves, then minting and immediately burning the
    ///         corresponding BGW. No BGW-GOV is minted for this protocol-only
    ///         cycle, and no LP liquidity is touched.
    function executeBuyback(uint256 usdcAmount) external nonReentrant whenNotPaused onlyAutomation {
        if (usdcAmount == 0 || usdcAmount > buybackAccumulator) return;
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 availableUsdc = usdcBalance > totalPendingFees ? usdcBalance - totalPendingFees : 0;
        require(usdcAmount <= availableUsdc, "BGWVault: insufficient reserve USDC");

        buybackAccumulator -= usdcAmount;

        uint256 bgwToMintAndBurn = (usdcAmount * 1e18) / navPerBGW();
        _deployToSleeves(usdcAmount);
        bgwToken.protocolMintAndBurn(address(this), bgwToMintAndBurn);

        emit BuybackExecuted(usdcAmount, bgwToMintAndBurn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Sleeve value update (manual rebalance report)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Automation reports updated sleeve values after rebalancing.
    function updateSleeveValues(uint256 newSleeveA, uint256 newSleeveB, uint256 newSleeveC)
        external
        nonReentrant
        whenNotPaused
        onlyAutomation
    {
        // Time-weighted anti-manipulation bounds (C-01).
        // No MIN_HARVEST_GAP here — rebalancing may legitimately follow a harvest.
        uint256 elapsed = block.timestamp - lastHarvestTime;
        uint256 actualA = _reportedOrAdapterValue(SLEEVE_A, newSleeveA);
        uint256 actualB = _reportedOrAdapterValue(SLEEVE_B, newSleeveB);
        uint256 actualC = _reportedOrAdapterValue(SLEEVE_C, newSleeveC);

        _checkSleeveMove(sleeveAValue, actualA, elapsed);
        _checkSleeveMove(sleeveBValue, actualB, elapsed);
        _checkSleeveMove(sleeveCValue, actualC, elapsed);
        sleeveAValue = actualA;
        sleeveBValue = actualB;
        sleeveCValue = actualC;
        emit SleeveValuesUpdated(actualA, actualB, actualC);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the automation contract. Only contract addresses accepted.
    ///         In production the vault owner should be a timelock/controller.
    function setAutomation(address _automation) external onlyOwner {
        if (_automation == address(0)) revert ZeroAddress();
        require(_automation.code.length > 0, "BGWVault: not a contract");
        automation = _automation;
        emit AutomationSet(_automation);
    }

    /// @notice Instantly revoke the current automation contract.
    ///         Emergency circuit-breaker — stops all harvest/buyback immediately.
    function revokeAutomation() external onlyOwner {
        address old = automation;
        automation = address(0);
        emit AutomationRevoked(old);
    }

    /// @notice Record a genuine realised loss acknowledged by governance.
    ///         In production the vault owner should be a timelock/controller.
    function markRealisedLoss(uint256 amount) external onlyOwner {
        require(amount > 0, "BGWVault: zero loss");
        authorisedLosses += amount;
        emit LossMarkExecuted(amount);
    }

    /// @notice Fee recipients pull any USDC that failed to push automatically.
    function claimFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        if (amount == 0) return;
        pendingFees[msg.sender] = 0;
        totalPendingFees -= amount;
        IERC20(USDC).safeTransfer(msg.sender, amount);
    }

    /// @notice Owner can redirect fees that have been unclaimed for STALE_FEE_DELAY (1 year).
    ///         Protects against permanently locked funds if a fee wallet is permanently inaccessible (H-13).
    function sweepStaleFees(address staleWallet, address newRecipient) external onlyOwner nonReentrant {
        require(newRecipient != address(0), "BGWVault: zero recipient");
        uint256 amount = pendingFees[staleWallet];
        if (amount == 0) revert NoPendingFees();
        require(
            lastFeeAccrual[staleWallet] > 0 && block.timestamp >= lastFeeAccrual[staleWallet] + FeeLib.STALE_FEE_DELAY,
            "BGWVault: fees not stale"
        );
        pendingFees[staleWallet] = 0;
        totalPendingFees -= amount;
        emit StaleFeeSwept(staleWallet, newRecipient, amount);
        IERC20(USDC).safeTransfer(newRecipient, amount);
    }

    /// @notice Add or remove an address from the vault whitelist.
    function setWhitelisted(address account, bool status) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        whitelist[account] = status;
        bgwToken.setWhitelisted(account, status);
        emit WhitelistUpdated(account, status);
    }

    /// @notice Batch whitelist update (max 200 accounts per call).
    function setWhitelistedBatch(address[] calldata accounts, bool status) external onlyOwner {
        if (accounts.length > 200) revert BatchTooLarge(accounts.length, 200);
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
        emit ExitFeeBpsUpdated(feeBps);
    }

    function setStressExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 200) revert InvalidFeeBps(feeBps);
        stressExitFeeBps = feeBps;
        emit StressExitFeeBpsUpdated(feeBps);
    }

    /// @notice Activate or deactivate stress mode (higher exit fee). Instant — emergency use.
    function setStressMode(bool active) external onlyOwner {
        stressModeActive = active;
        emit StressModeToggled(active);
    }

    function setManagementFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        managementFeeBps = feeBps;
        emit ManagementFeeBpsUpdated(feeBps);
    }

    function setFeeWallets(address _team, address _holdback, address _reserve) external onlyOwner {
        if (_team == address(0)) revert ZeroAddress();
        if (_holdback == address(0)) revert ZeroAddress();
        if (_reserve == address(0)) revert ZeroAddress();
        teamWallet = _team;
        holdbackWallet = _holdback;
        reserveFundWallet = _reserve;
        emit FeeWalletsUpdated(_team, _holdback, _reserve);
    }

    /// @notice Wire the vault to a hub-chain confirmed spoke NAV cache.
    ///         Use address(0) to disconnect hub-spoke accounting.
    function setHubNAV(address newHubNAV) external onlyOwner {
        if (newHubNAV != address(0)) require(newHubNAV.code.length > 0, "BGWVault: hub NAV not contract");
        hubNAV = newHubNAV;
        emit HubNAVSet(newHubNAV);
    }

    /// @notice Set or clear the strategy adapter for one sleeve.
    ///         Use address(0) to return a sleeve to manual accounting. Direct
    ///         single-adapter changes are only allowed before live deposits.
    function setSleeveAdapter(uint8 sleeve, address adapter) external onlyOwner {
        if (bgwToken.totalSupply() != 0) revert AdapterChangeAfterDeposits();
        _setSleeveAdapter(sleeve, adapter);
    }

    /// @notice Configure multiple strategy routes for one sleeve without moving
    ///         existing funds. Any funded adapter that is currently counted must
    ///         remain present in the new route set.
    function configureSleeveAdapterRoutes(
        uint8 sleeve,
        address[] calldata adapters,
        uint16[] calldata depositBps,
        bool[] calldata active
    ) external onlyOwner {
        _configureSleeveAdapterRoutes(sleeve, adapters, depositBps, active);
    }

    function sleeveAdapterRouteCount(uint8 sleeve) external view returns (uint256) {
        _validateSleeve(sleeve);
        return _sleeveAdapterRoutes[sleeve].length;
    }

    function sleeveAdapterRouteAt(uint8 sleeve, uint256 index)
        external
        view
        returns (address adapter, uint16 depositBps, bool active)
    {
        _validateSleeve(sleeve);
        SleeveAdapterRoute memory route = _sleeveAdapterRoutes[sleeve][index];
        return (route.adapter, route.depositBps, route.active);
    }

    function sleeveAdapterActiveDepositBps(uint8 sleeve) external view returns (uint256) {
        _validateSleeve(sleeve);
        return _activeRouteDepositBps(sleeve);
    }

    /// @notice Set vault-level sleeve deposit weights for future deposits.
    function setSleeveDepositWeights(uint16 sleeveA, uint16 sleeveB, uint16 sleeveC) external onlyOwner {
        _setSleeveDepositWeights(sleeveA, sleeveB, sleeveC);
    }

    /// @notice Mark an asset as approved for a sleeve strategy.
    ///         Trusted assets are automatically protected from recoverToken().
    function setTrustedSleeveAsset(uint8 sleeve, address asset, bool trusted) external onlyOwner {
        _setTrustedSleeveAsset(sleeve, asset, trusted);
    }

    /// @notice Batch version of setTrustedSleeveAsset.
    function setTrustedSleeveAssetBatch(uint8 sleeve, address[] calldata assets, bool trusted) external onlyOwner {
        if (assets.length > 50) revert BatchTooLarge(assets.length, 50);
        for (uint256 i; i < assets.length; ++i) {
            _setTrustedSleeveAsset(sleeve, assets[i], trusted);
        }
    }

    /// @notice Set a per-deposit USDC cap. Set to 0 to remove the cap entirely.
    function setMaxDepositCap(uint256 cap) external onlyOwner {
        maxDepositUsdc = cap;
        emit MaxDepositCapUpdated(cap);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Mark a token as protected (true) or unprotected (false).
    ///         Call with true before deploying vault funds into a new protocol.
    ///         Call with false only after the position is fully unwound.
    function setProtectedToken(address token, bool _protected) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        protectedTokens[token] = _protected;
        emit ProtectedTokenUpdated(token, _protected);
    }

    /// @notice Batch version of setProtectedToken for initial setup.
    function setProtectedTokenBatch(address[] calldata tokens, bool _protected) external onlyOwner {
        if (tokens.length > 50) revert BatchTooLarge(tokens.length, 50);
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            protectedTokens[tokens[i]] = _protected;
            emit ProtectedTokenUpdated(tokens[i], _protected);
        }
    }

    /// @notice Emergency: recover tokens accidentally sent to the vault.
    ///         Blocked for USDC (vault funds), BGW, BGW-GOV, and any token
    ///         registered as a vault position via setProtectedToken (C-02).
    function recoverToken(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "BGWVault: zero recipient");
        require(token != USDC, "BGWVault: cannot recover vault USDC");
        require(token != address(bgwToken), "BGWVault: cannot recover BGW");
        require(token != address(govToken), "BGWVault: cannot recover BGW-GOV");
        if (protectedTokens[token]) revert ProtectedTokenRecovery(token);
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy new USDC deposit into sleeves at configured target weights.
    function _deployToSleeves(uint256 usdcAmount) internal {
        uint256 toA = (usdcAmount * sleeveADepositBps) / FeeLib.BPS_DENOM;
        uint256 toB = (usdcAmount * sleeveBDepositBps) / FeeLib.BPS_DENOM;
        uint256 toC = usdcAmount - toA - toB;

        _deployToSleeve(SLEEVE_A, toA);
        _deployToSleeve(SLEEVE_B, toB);
        _deployToSleeve(SLEEVE_C, toC);
    }

    /// @dev Reduce portfolio sleeves proportionally when holder NAV leaves the vault.
    ///      The buyback accumulator is a separate reserve and is not redeemable NAV.
    function _reduceSleevesProRata(uint256 grossUsdc) internal {
        uint256 nav = totalLocalNAV();
        if (nav == 0) return;
        require(grossUsdc <= nav, "BGWVault: insufficient local NAV");

        _withdrawFromSleeve(SLEEVE_A, (_sleeveValue(SLEEVE_A) * grossUsdc) / nav);
        _withdrawFromSleeve(SLEEVE_B, (_sleeveValue(SLEEVE_B) * grossUsdc) / nav);
        _withdrawFromSleeve(SLEEVE_C, (_sleeveValue(SLEEVE_C) * grossUsdc) / nav);
    }

    function _setSleeveDepositWeights(uint16 sleeveA, uint16 sleeveB, uint16 sleeveC) internal {
        _validateSleeveDepositWeights(sleeveA, sleeveB, sleeveC);
        sleeveADepositBps = sleeveA;
        sleeveBDepositBps = sleeveB;
        sleeveCDepositBps = sleeveC;
        emit SleeveDepositWeightsUpdated(sleeveA, sleeveB, sleeveC);
    }

    function _validateSleeveDepositWeights(uint16 sleeveA, uint16 sleeveB, uint16 sleeveC) internal pure {
        uint256 totalBps = uint256(sleeveA) + uint256(sleeveB) + uint256(sleeveC);
        if (totalBps != FeeLib.BPS_DENOM) revert InvalidSleeveDepositWeights(totalBps);
    }

    function _queueRedemption(
        address claimant,
        uint256 bgwBurned,
        uint256 grossUsdc,
        uint256 netUsdc,
        uint256 exitFeeUsdc,
        uint256 perfFeeUsdc,
        uint256 currentNav18,
        uint256 effectiveHwm
    ) internal {
        uint256 localNav = totalLocalNAV();
        uint256 spokeReserved = grossUsdc > localNav ? grossUsdc - localNav : 0;
        address nav = hubNAV;
        uint256 spokeSnapshot = nav == address(0) ? 0 : IBridgewayHubNAV(nav).totalSpokeNAVUSDC();

        uint256 redemptionId = ++queuedRedemptionCount;
        _queuedRedemptions[redemptionId] = QueuedRedemption({
            claimant: claimant,
            netUsdc: netUsdc,
            exitFeeUsdc: exitFeeUsdc,
            perfFeeUsdc: perfFeeUsdc,
            navLiabilityUsdc: grossUsdc,
            spokeNavSnapshotUsdc: spokeSnapshot,
            spokeNavReservedUsdc: spokeReserved,
            claimed: false
        });
        totalQueuedRedemptionGross += grossUsdc;
        totalQueuedRedemptionNAVLiability += grossUsdc;

        if (perfFeeUsdc > 0 && currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM) {
            highWaterMark = currentNav18;
            lastHWMUpdateTime = block.timestamp;
        }

        emit RedemptionQueued(redemptionId, claimant, bgwBurned, grossUsdc, netUsdc, exitFeeUsdc, perfFeeUsdc);
    }

    function _reducePrincipalForBurn(uint256 bgwAmount) internal {
        uint256 supply = bgwToken.totalSupply();
        if (supply > 0 && cumulativePrincipal > 0) {
            uint256 principalSlice = (bgwAmount * cumulativePrincipal) / supply;
            cumulativePrincipal -= principalSlice;
        }
    }

    function _availableUSDC() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        return usdcBalance > totalPendingFees ? usdcBalance - totalPendingFees : 0;
    }

    function _deployToSleeve(uint8 sleeve, uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) {
            uint256 allocated;
            for (uint256 i; i < routeCount; ++i) {
                SleeveAdapterRoute memory route = _sleeveAdapterRoutes[sleeve][i];
                if (!route.active || route.depositBps == 0) continue;

                uint256 routeAmount = (usdcAmount * route.depositBps) / FeeLib.BPS_DENOM;
                if (routeAmount == 0) continue;

                allocated += routeAmount;
                IERC20(USDC).safeTransfer(route.adapter, routeAmount);
                ISleeveAdapter(route.adapter).deploy(routeAmount);
            }

            uint256 remainder = usdcAmount - allocated;
            if (remainder > 0) _setSleeveValue(sleeve, _manualSleeveValue(sleeve) + remainder);
            return;
        }

        address adapter = sleeveAdapters[sleeve];
        if (adapter == address(0)) {
            _setSleeveValue(sleeve, _manualSleeveValue(sleeve) + usdcAmount);
            return;
        }

        IERC20(USDC).safeTransfer(adapter, usdcAmount);
        ISleeveAdapter(adapter).deploy(usdcAmount);
        _syncSleeveFromAdapter(sleeve);
    }

    function _withdrawFromSleeve(uint8 sleeve, uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) {
            uint256 remaining = usdcAmount;
            uint256 manual = _manualSleeveValue(sleeve);
            uint256 fromManual = manual > remaining ? remaining : manual;
            if (fromManual > 0) {
                _setSleeveValue(sleeve, manual - fromManual);
                remaining -= fromManual;
            }

            for (uint256 i; i < routeCount && remaining > 0; ++i) {
                address routeAdapter = _sleeveAdapterRoutes[sleeve][i].adapter;
                uint256 routeAssets = ISleeveAdapter(routeAdapter).totalAssetsUSDC();
                if (routeAssets == 0) continue;

                uint256 request = routeAssets > remaining ? remaining : routeAssets;
                uint256 returned = ISleeveAdapter(routeAdapter).withdraw(request);
                remaining = returned >= remaining ? 0 : remaining - returned;
            }
            return;
        }

        address adapter = sleeveAdapters[sleeve];
        if (adapter == address(0)) {
            uint256 current = _manualSleeveValue(sleeve);
            _setSleeveValue(sleeve, usdcAmount >= current ? 0 : current - usdcAmount);
            return;
        }

        ISleeveAdapter(adapter).withdraw(usdcAmount);
        _syncSleeveFromAdapter(sleeve);
    }

    function _syncSleeveFromAdapter(uint8 sleeve) internal {
        if (_sleeveAdapterRoutes[sleeve].length > 0) return;
        address adapter = sleeveAdapters[sleeve];
        if (adapter != address(0)) {
            _setSleeveValue(sleeve, ISleeveAdapter(adapter).totalAssetsUSDC());
        }
    }

    function _reportedOrAdapterValue(uint8 sleeve, uint256 reportedValue) internal view returns (uint256) {
        if (_sleeveAdapterRoutes[sleeve].length > 0) return _sleeveValue(sleeve);
        address adapter = sleeveAdapters[sleeve];
        if (adapter == address(0)) return reportedValue;
        return ISleeveAdapter(adapter).totalAssetsUSDC();
    }

    function _sleeveValue(uint8 sleeve) internal view returns (uint256) {
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) return _manualSleeveValue(sleeve) + _routeAssetsUSDC(sleeve);

        address adapter = sleeveAdapters[sleeve];
        if (adapter != address(0)) return ISleeveAdapter(adapter).totalAssetsUSDC();
        return _manualSleeveValue(sleeve);
    }

    function _manualSleeveValue(uint8 sleeve) internal view returns (uint256) {
        if (sleeve == SLEEVE_A) return sleeveAValue;
        if (sleeve == SLEEVE_B) return sleeveBValue;
        if (sleeve == SLEEVE_C) return sleeveCValue;
        revert("BGWVault: invalid sleeve");
    }

    function _setSleeveValue(uint8 sleeve, uint256 value) internal {
        if (sleeve == SLEEVE_A) {
            sleeveAValue = value;
        } else if (sleeve == SLEEVE_B) {
            sleeveBValue = value;
        } else if (sleeve == SLEEVE_C) {
            sleeveCValue = value;
        } else {
            revert("BGWVault: invalid sleeve");
        }
    }

    function _configureSleeveAdapterRoutes(
        uint8 sleeve,
        address[] memory adapters,
        uint16[] memory depositBps,
        bool[] memory active
    ) internal {
        uint256 activeBps = _validateSleeveAdapterRouteConfig(sleeve, adapters, depositBps, active);

        delete _sleeveAdapterRoutes[sleeve];
        for (uint256 i; i < adapters.length; ++i) {
            _sleeveAdapterRoutes[sleeve].push(
                SleeveAdapterRoute({adapter: adapters[i], depositBps: depositBps[i], active: active[i]})
            );
        }

        emit SleeveAdapterRoutesConfigured(sleeve, adapters.length, activeBps);
    }

    function _validateSleeveAdapterRouteConfig(
        uint8 sleeve,
        address[] memory adapters,
        uint16[] memory depositBps,
        bool[] memory active
    ) internal view returns (uint256 activeBps) {
        _validateSleeve(sleeve);
        require(
            adapters.length == depositBps.length && adapters.length == active.length,
            "BGWVault: route length mismatch"
        );
        require(adapters.length <= 10, "BGWVault: too many routes");

        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            if (adapter == address(0)) revert ZeroAddress();
            require(adapter.code.length > 0, "BGWVault: adapter not contract");

            for (uint256 j = i + 1; j < adapters.length; ++j) {
                require(adapter != adapters[j], "BGWVault: duplicate route");
            }

            if (active[i]) activeBps += depositBps[i];
        }
        require(activeBps <= FeeLib.BPS_DENOM, "BGWVault: route bps too high");

        address legacyAdapter = sleeveAdapters[sleeve];
        if (legacyAdapter != address(0) && !_containsAdapter(adapters, legacyAdapter)) {
            uint256 legacyAssets = ISleeveAdapter(legacyAdapter).totalAssetsUSDC();
            if (legacyAssets > 0) revert FundedAdapterRemovalBlocked(sleeve, legacyAdapter, legacyAssets);
        }

        SleeveAdapterRoute[] storage existingRoutes = _sleeveAdapterRoutes[sleeve];
        uint256 existingCount = existingRoutes.length;
        for (uint256 i; i < existingCount; ++i) {
            address existing = existingRoutes[i].adapter;
            if (_containsAdapter(adapters, existing)) continue;

            uint256 existingAssets = ISleeveAdapter(existing).totalAssetsUSDC();
            if (existingAssets > 0) revert FundedAdapterRemovalBlocked(sleeve, existing, existingAssets);
        }
    }

    function _containsAdapter(address[] memory adapters, address adapter) internal pure returns (bool) {
        uint256 count = adapters.length;
        for (uint256 i; i < count; ++i) {
            if (adapters[i] == adapter) return true;
        }
        return false;
    }

    function _activeRouteDepositBps(uint8 sleeve) internal view returns (uint256 totalBps) {
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        for (uint256 i; i < routeCount; ++i) {
            SleeveAdapterRoute memory route = _sleeveAdapterRoutes[sleeve][i];
            if (route.active) totalBps += route.depositBps;
        }
    }

    function _routeAssetsUSDC(uint8 sleeve) internal view returns (uint256 totalUsdc) {
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        for (uint256 i; i < routeCount; ++i) {
            totalUsdc += ISleeveAdapter(_sleeveAdapterRoutes[sleeve][i].adapter).totalAssetsUSDC();
        }
    }

    function _setSleeveAdapter(uint8 sleeve, address adapter) internal {
        _validateSleeve(sleeve);
        require(_sleeveAdapterRoutes[sleeve].length == 0, "BGWVault: routes configured");
        if (adapter != address(0)) require(adapter.code.length > 0, "BGWVault: adapter not contract");

        address currentAdapter = sleeveAdapters[sleeve];
        if (currentAdapter != address(0) && currentAdapter != adapter) {
            uint256 currentAssets = ISleeveAdapter(currentAdapter).totalAssetsUSDC();
            if (currentAssets > 0) revert FundedAdapterRemovalBlocked(sleeve, currentAdapter, currentAssets);
        }

        if (adapter != address(0)) {
            require(
                ISleeveAdapter(adapter).totalAssetsUSDC() == _manualSleeveValue(sleeve),
                "BGWVault: adapter value mismatch"
            );
        }
        sleeveAdapters[sleeve] = adapter;
        _syncSleeveFromAdapter(sleeve);
        emit SleeveAdapterSet(sleeve, adapter);
    }

    function _setTrustedSleeveAsset(uint8 sleeve, address asset, bool trusted) internal {
        _validateSleeve(sleeve);
        if (asset == address(0)) revert ZeroAddress();
        bool current = trustedSleeveAssets[sleeve][asset];
        if (current == trusted) return;

        trustedSleeveAssets[sleeve][asset] = trusted;
        if (trusted) {
            trustedAssetUseCount[asset] += 1;
            protectedTokens[asset] = true;
        } else {
            uint256 count = trustedAssetUseCount[asset];
            if (count > 0) trustedAssetUseCount[asset] = count - 1;
        }

        emit TrustedSleeveAssetUpdated(sleeve, asset, trusted);
        emit ProtectedTokenUpdated(asset, protectedTokens[asset]);
    }

    function _validateSleeve(uint8 sleeve) internal pure {
        require(sleeve <= SLEEVE_C, "BGWVault: invalid sleeve");
    }

    /// @dev Distribute performance fee across 6 recipients.
    ///      Uses try-transfer with pendingFees fallback so one bad wallet
    ///      cannot block the entire fee distribution (H-02).
    function _distributePerfFee(uint256 totalFee) internal {
        if (totalFee == 0) return;

        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(totalFee);

        _tryTransferFee(teamWallet, s.team);
        _tryTransferFee(holdbackWallet, s.holdback);
        _tryTransferFee(reserveFundWallet, s.reserve);

        buybackAccumulator += s.buyback;
    }

    /// @dev Attempt to push USDC fee to `recipient`. On failure, escrow in
    ///      pendingFees so the recipient can pull later via claimFees().
    function _tryTransferFee(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = USDC.call(abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount));
        bool success = ok && (ret.length == 0 || abi.decode(ret, (bool)));
        if (!success) {
            pendingFees[recipient] += amount;
            totalPendingFees += amount;
            lastFeeAccrual[recipient] = block.timestamp; // H-13: stale-fee clock
        }
    }

    /// @dev Apply the conservative USDC settlement mark for redemptions.
    ///      USDC above peg is capped at $1; USDC below peg reduces payout value.
    function _redemptionUSDCAmount(uint256 usdValue6) internal view returns (uint256) {
        return (usdValue6 * getUSDCPriceForRedemption()) / USD_PRICE_SCALE;
    }

    /// @dev Read and normalize a Chainlink USD feed to 8 decimals.
    function _usdPrice8(address feed) internal view returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > ORACLE_STALE_THRESHOLD) {
            revert StaleOracle(updatedAt);
        }
        if (answeredInRound < roundId) revert InvalidOracleRound(roundId, answeredInRound);
        if (answer <= 0) revert InvalidOraclePrice(answer);

        uint8 decimals = IChainlinkAggregator(feed).decimals();
        if (decimals == 8) return uint256(answer);
        if (decimals < 8) return uint256(answer) * (10 ** (8 - decimals));
        return uint256(answer) / (10 ** (decimals - 8));
    }

    /// @dev Returns the effective HWM after time-based linear decay.
    ///
    ///      Timeline (t = time since last HWM crystallisation):
    ///        0 – 1yr   : no decay, returns highWaterMark
    ///        1yr – 3yr : HWM slides linearly from highWaterMark → HWM_FLOOR ($1.00)
    ///        > 3yr     : returns HWM_FLOOR
    function _decayedHWM() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastHWMUpdateTime;
        if (elapsed <= FeeLib.HWM_DECAY_START) return highWaterMark;

        uint256 decayElapsed = elapsed - FeeLib.HWM_DECAY_START;
        if (decayElapsed >= FeeLib.HWM_DECAY_PERIOD) return FeeLib.HWM_FLOOR;

        if (highWaterMark <= FeeLib.HWM_FLOOR) return highWaterMark;
        uint256 gap = highWaterMark - FeeLib.HWM_FLOOR;
        uint256 decayed = (gap * decayElapsed) / FeeLib.HWM_DECAY_PERIOD;
        return highWaterMark - decayed;
    }

    /// @dev Charge the annual management fee proportional to time since last harvest.
    ///      Elapsed time is capped at 90 days to prevent fee shock after long gaps (M-04).
    ///
    ///      H-06: Fee is waived when vault NAV is at or below the effective HWM.
    ///      Depositors who are already underwater should not be charged an additional
    ///      annual fee on top of their unrealised losses.  The fee resumes automatically
    ///      once the vault recovers above the (decayed) HWM.
    function _chargeManagementFee() internal {
        if (managementFeeBps == 0 || lastHarvestTime == 0) return;
        uint256 nav = totalNAV();
        if (nav == 0) return;

        uint256 elapsed = block.timestamp - lastHarvestTime;
        if (elapsed == 0) return;

        // Cap at 90 days to prevent excessive fee accrual after automation downtime
        if (elapsed > 90 days) elapsed = 90 days;

        // H-06: charge base rate (0.1%/year) always; full rate (0.5%/year) only above HWM
        bool aboveHWM = navPerBGW18() > _decayedHWM();
        uint256 feeBps = aboveHWM ? managementFeeBps : FeeLib.BASE_MGMT_FEE_BPS;

        uint256 fee = (nav * feeBps * elapsed) / (FeeLib.BPS_DENOM * 365 days);
        if (fee == 0) return;

        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 available = usdcBalance > totalPendingFees ? usdcBalance - totalPendingFees : 0;
        if (fee > available) fee = available;
        if (fee == 0) return;

        _distributePerfFee(fee);
        _reduceSleevesProRata(fee);
        emit ManagementFeeCharged(fee, elapsed);
    }

    /// @dev Revert if a sleeve value move exceeds the time-weighted daily cap.
    ///      Growth cap: 10%/day × elapsed.  Shrink cap: 25%/day × elapsed.
    ///      Skipped when oldVal == 0 because no prior sleeve baseline exists.
    function _checkSleeveMove(uint256 oldVal, uint256 newVal, uint256 elapsed) internal pure {
        if (oldVal == 0) return;
        if (newVal >= oldVal) {
            uint256 maxGrow = (oldVal * FeeLib.MAX_SLEEVE_GROWTH_BPS_DAY * elapsed) / (FeeLib.BPS_DENOM * 1 days);
            require(newVal - oldVal <= maxGrow, "BGWVault: sleeve growth too fast");
        } else {
            uint256 maxShrink = (oldVal * FeeLib.MAX_SLEEVE_SHRINK_BPS_DAY * elapsed) / (FeeLib.BPS_DENOM * 1 days);
            require(oldVal - newVal <= maxShrink, "BGWVault: sleeve shrink too fast");
        }
    }
}
