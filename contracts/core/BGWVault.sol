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

    /// @notice Net portfolio profit already considered for periodic performance fees.
    ///         This is adjusted pro-rata on redemptions so new deposits are not
    ///         charged for pre-entry gains.
    uint256 public performanceFeeProfitCheckpointUsdc;

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

    /// @notice Minimum accepted deposit amount in USDC. 0 = no minimum.
    uint256 public minDepositUsdc = 1e6;

    /// @notice Minimum per-route sleeve allocation to deploy externally. Smaller amounts stay idle in sleeve NAV.
    uint256 public minSleeveRouteDepositUsdc = 20e6;

    /// @notice Deposits below this size route entirely to stable Sleeve B. 0 = disabled.
    uint256 public smallDepositStableOnlyThresholdUsdc = 20e6;

    /// @notice Target idle USDC buffer, in bps of local NAV, kept for routine redemptions.
    uint16 public redemptionBufferBps = 200;

    /// @notice Minimum idle USDC buffer kept for routine redemptions.
    uint256 public minRedemptionBufferUsdc = 2e6;

    /// @notice Tracked idle USDC that belongs to BGW holders and is reserved for routine redemptions.
    uint256 public idleRedemptionReserveUsdc;

    /// @notice Max age for the USDC/USD redemption feed. 0 = no age-based block.
    uint256 public usdcRedemptionMaxStale;

    /// @notice Deployment bootstrap mode. While true, owner can recover idle
    ///         vault USDC immediately for launch mistakes. Finalize before public deposits.
    bool public bootstrapMode = true;

    struct PendingTreasuryVaultUSDCRecovery {
        address to;
        uint256 amount;
        uint256 executeAfter;
    }

    PendingTreasuryVaultUSDCRecovery public pendingTreasuryVaultUSDCRecovery;

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
    event SleeveHarvested(uint8 indexed sleeve, uint256 totalYieldUsdc, uint256 compoundedIntoSleeveB);
    event SleeveEmergencyUnwound(uint8 indexed sleeve, uint256 routesTriggered, uint256 usdcArrivedAtVault);
    event BuybackExecuted(uint256 usdcInjected, uint256 bgwMintedAndBurned);
    event StaleFeeSwept(address indexed staleWallet, address indexed recipient, uint256 amount); // H-13
    event SleeveValuesUpdated(uint256 sleeveA, uint256 sleeveB, uint256 sleeveC);
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
    event USDCRedemptionMaxStaleUpdated(uint256 maxStale);
    event MinDepositUpdated(uint256 minimum);
    event MinSleeveRouteDepositUpdated(uint256 minimum);
    event SmallDepositStableOnlyThresholdUpdated(uint256 threshold);
    event RedemptionBufferUpdated(uint16 bufferBps, uint256 minimumUsdc);
    event RedemptionReserveFunded(address indexed funder, uint256 amount);
    event SleeveRebalanced(uint8 indexed fromSleeve, uint8 indexed toSleeve, uint256 requestedUsdc, uint256 movedUsdc);
    event BootstrapFinalized();
    event TreasuryVaultUSDCRecoveryProposed(address indexed to, uint256 amount, uint256 executeAfter);
    event TreasuryVaultUSDCRecoveryCancelled(address indexed to, uint256 amount);
    event TreasuryVaultUSDCRecovered(address indexed to, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotWhitelisted(address account);
    error ZeroAmount();
    error SlippageTooHigh(uint256 received, uint256 minimum);
    error StaleOracle(uint256 updatedAt);
    error OnlyAutomation();
    error OnlyAutomationOrOwner();
    error InsufficientBGW(uint256 have, uint256 need);
    error InvalidFeeBps(uint256 bps);
    error ZeroAddress();
    error DepositExceedsCap(uint256 amount, uint256 cap);
    error DepositBelowMinimum(uint256 amount, uint256 minimum);
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
    error BootstrapAlreadyFinalized();
    error NoPendingTreasuryVaultUSDCRecovery();
    error TimelockNotReady(uint256 executeAfter);
    error YieldExceedsBalance();
    error HarvestGapTooShort();
    error YieldRateTooHigh();
    error NotContract(address account);
    error FeesNotStale();
    error InvalidSleeve(uint8 sleeve);
    error RouteLengthMismatch();
    error TooManyRoutes(uint256 count, uint256 max);
    error DuplicateRoute(address adapter);
    error RouteBpsTooHigh(uint256 totalBps);
    error SleeveMoveTooFast();
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

    modifier onlyAutomationOrOwner() {
        if (msg.sender != automation && msg.sender != owner()) revert OnlyAutomationOrOwner();
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
        return _sleeveValue(SLEEVE_A) + _sleeveValue(SLEEVE_B) + _sleeveValue(SLEEVE_C) + holderIdleUSDC();
    }

    /// @notice Idle vault USDC attributable to BGW holders, excluding fee/buyback reserves.
    function holderIdleUSDC() public view returns (uint256) {
        return idleRedemptionReserveUsdc;
    }

    /// @notice Current target idle USDC redemption buffer.
    function redemptionBufferTargetUSDC() public view returns (uint256 target) {
        target = _redemptionBufferTargetUSDC(totalLocalNAV());
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
    function depositFor(address recipient, uint256 usdcAmount, uint256 minBgwOut) public nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (!whitelist[recipient]) revert NotWhitelisted(recipient);
        if (usdcAmount == 0) revert ZeroAmount();
        if (minDepositUsdc > 0 && usdcAmount < minDepositUsdc) {
            revert DepositBelowMinimum(usdcAmount, minDepositUsdc);
        }
        if (maxDepositUsdc > 0 && usdcAmount > maxDepositUsdc) {
            revert DepositExceedsCap(usdcAmount, maxDepositUsdc);
        }

        uint256 nav6 = navPerBGW();
        uint256 bgwToMint = (usdcAmount * 1e18) / nav6;

        if (bgwToMint < minBgwOut) revert SlippageTooHigh(bgwToMint, minBgwOut);

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);
        cumulativePrincipal += usdcAmount;

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

        _fundRedemptionFromLiquidSleeves(grossUsdc);

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
        _consumeIdleRedemptionReserve(requiredUsdc);

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

    /// @notice Called by BridgewayAutomation after sleeve harvests and reward claims.
    /// @param  netYieldUsdc  Net realised yield in USDC terms (6 dec). This can
    ///         be redeployed sleeve yield rather than idle vault USDC.
    /// @param  newSleeveA    Updated Sleeve A value post-harvest (6 dec).
    /// @param  newSleeveB    Updated Sleeve B value post-harvest (6 dec).
    /// @param  newSleeveC    Updated Sleeve C value post-harvest (6 dec).
    function recordHarvest(uint256 netYieldUsdc, uint256 newSleeveA, uint256 newSleeveB, uint256 newSleeveC)
        external
        nonReentrant
        whenNotPaused
        onlyAutomation
    {
        // Time-weighted anti-manipulation bounds (C-01).
        // lastHarvestTime is initialised in the constructor so the first harvest
        // is constrained against the deployment timestamp instead of receiving
        // a one-time unrestricted reporting window.
        uint256 sinceLastHarvest = block.timestamp - lastHarvestTime;
        if (sinceLastHarvest < FeeLib.MIN_HARVEST_GAP) revert HarvestGapTooShort();

        uint256 nav = totalNAV();
        if (nav > 0 && netYieldUsdc > 0) {
            uint256 maxYield = (nav * FeeLib.MAX_YIELD_APR_BPS * sinceLastHarvest) / (FeeLib.BPS_DENOM * 365 days);
            if (netYieldUsdc > maxYield) revert YieldRateTooHigh();
        }

        uint256 oldA = _sleeveValue(SLEEVE_A);
        uint256 oldB = _sleeveValue(SLEEVE_B);
        uint256 oldC = _sleeveValue(SLEEVE_C);
        uint256 actualA = _reportedOrAdapterValue(SLEEVE_A, newSleeveA);
        uint256 actualB = _reportedOrAdapterValue(SLEEVE_B, newSleeveB);
        uint256 actualC = _reportedOrAdapterValue(SLEEVE_C, newSleeveC);

        _checkSleeveMove(oldA, actualA, sinceLastHarvest);
        _checkSleeveMove(oldB, actualB, sinceLastHarvest);
        _checkSleeveMove(oldC, actualC, sinceLastHarvest);

        _setReportedSleeveValue(SLEEVE_A, actualA);
        _setReportedSleeveValue(SLEEVE_B, actualB);
        _setReportedSleeveValue(SLEEVE_C, actualC);
        emit SleeveValuesUpdated(actualA, actualB, actualC);

        _chargeManagementFee();

        lastHarvestTime = block.timestamp;

        uint256 currentNav18 = navPerBGW18();
        uint256 effectiveHwm = _decayedHWM();
        uint256 perfFeeUsdc;
        if (currentNav18 > effectiveHwm) {
            uint256 feeableProfitUsdc = _feeablePerformanceProfitUsdc();
            if (nav > 0 && feeableProfitUsdc > 0) {
                uint256 maxYield = (nav * FeeLib.MAX_YIELD_APR_BPS * sinceLastHarvest) / (FeeLib.BPS_DENOM * 365 days);
                if (feeableProfitUsdc > maxYield) revert YieldRateTooHigh();
            }

            perfFeeUsdc = FeeLib.calcPerfFee(feeableProfitUsdc);
            if (perfFeeUsdc > 0) {
                _distributePerfFee(perfFeeUsdc);
                _reduceSleevesProRata(perfFeeUsdc);
                performanceFeeProfitCheckpointUsdc = _currentPerformanceProfitUsdc();
            }
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
        uint256 availableUsdc = _availableUSDCForBuyback();
        if (usdcAmount > availableUsdc) revert InsufficientLocalLiquidity(availableUsdc, usdcAmount);

        buybackAccumulator -= usdcAmount;

        uint256 bgwToMintAndBurn = (usdcAmount * 1e18) / navPerBGW();
        _deployToSleevesUnbuffered(usdcAmount);
        bgwToken.protocolMintAndBurn(address(this), bgwToMintAndBurn);

        emit BuybackExecuted(usdcAmount, bgwToMintAndBurn);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Sleeve adapter harvest fan-out
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trigger `ISleeveAdapter.harvest()` on every active route in a
    ///         sleeve. Sleeve A yield compounds back into Sleeve A, Sleeve B
    ///         yield compounds back into Sleeve B, and realised Sleeve C yield
    ///         is redirected into Sleeve B's stable adapter.
    ///
    ///         N-05: this is the only on-chain path that reaches the
    ///         sleeve-adapter `harvest()` functions; without it, AERO emissions
    ///         and other realisable rewards stay trapped in their gauges.
    function harvestSleeves(uint8 sleeve)
        external
        nonReentrant
        whenNotPaused
        onlyAutomationOrOwner
        returns (uint256 totalYieldUsdc, uint256 compoundedIntoSleeveB)
    {
        _validateSleeve(sleeve);
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount == 0) {
            emit SleeveHarvested(sleeve, 0, 0);
            return (0, 0);
        }

        for (uint256 i; i < routeCount; ++i) {
            SleeveAdapterRoute memory route = _sleeveAdapterRoutes[sleeve][i];
            if (!route.active) continue;
            totalYieldUsdc += ISleeveAdapter(route.adapter).harvest();
        }

        if (totalYieldUsdc > 0) {
            // forceExternalDeploy = true so the small-deposit / route-min
            // guards don't push the harvested yield back into idle.
            uint8 destination = sleeve == SLEEVE_C ? SLEEVE_B : sleeve;
            _deployToSleeve(destination, totalYieldUsdc, true);
            if (destination == SLEEVE_B) compoundedIntoSleeveB = totalYieldUsdc;
        }

        emit SleeveHarvested(sleeve, totalYieldUsdc, compoundedIntoSleeveB);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Owner-only: Emergency unwind orchestration (L-01)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Trigger `emergencyWithdrawAll()` on every active route in a
    ///         sleeve. Each adapter swaps its underlying position back to
    ///         USDC and ships the proceeds to the vault, so funds converge
    ///         here even when individual adapters are misbehaving.
    ///
    ///         L-01: emergency unwinds must terminate at the vault. The
    ///         adapter modifiers are widened to `onlyOwnerOrVault` so this
    ///         vault-orchestrated path works without giving the deployer a
    ///         new privilege — the existing owner key still works directly.
    function emergencyUnwindSleeves(uint8 sleeve) external nonReentrant onlyOwner returns (uint256 usdcArrivedAtVault) {
        _validateSleeve(sleeve);
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount == 0) {
            emit SleeveEmergencyUnwound(sleeve, 0, 0);
            return 0;
        }

        uint256 balanceBefore = IERC20(USDC).balanceOf(address(this));
        uint256 triggered;
        for (uint256 i; i < routeCount; ++i) {
            address adapter = _sleeveAdapterRoutes[sleeve][i].adapter;
            if (adapter == address(0)) continue;
            // Try the cbBTC-stack name first, then fall back to the basket
            // adapter's distinct selector. Either call routes USDC to vault.
            (bool ok,) = adapter.call(abi.encodeWithSignature("emergencyWithdrawAll()"));
            if (!ok) {
                (ok,) = adapter.call(abi.encodeWithSignature("emergencyUnwindAll()"));
            }
            if (ok) triggered += 1;
        }

        uint256 balanceAfter = IERC20(USDC).balanceOf(address(this));
        usdcArrivedAtVault = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

        // New USDC at the vault from the unwind is holder NAV — credit the
        // buffer so it survives the next deposit's `_retainRedemptionBuffer`
        // and `_fundRedemptionFromLiquidSleeves` paths.
        if (usdcArrivedAtVault > 0) {
            idleRedemptionReserveUsdc += usdcArrivedAtVault;
        }

        // Sleeve manual accounting is left in place — the funded-adapter
        // values it relied on have been zeroed externally, so subsequent
        // NAV reads of `_routeAssetsUSDC(sleeve)` return ~0.

        emit SleeveEmergencyUnwound(sleeve, triggered, usdcArrivedAtVault);
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

        _checkSleeveMove(_sleeveValue(SLEEVE_A), actualA, elapsed);
        _checkSleeveMove(_sleeveValue(SLEEVE_B), actualB, elapsed);
        _checkSleeveMove(_sleeveValue(SLEEVE_C), actualC, elapsed);
        _setReportedSleeveValue(SLEEVE_A, actualA);
        _setReportedSleeveValue(SLEEVE_B, actualB);
        _setReportedSleeveValue(SLEEVE_C, actualC);
        emit SleeveValuesUpdated(actualA, actualB, actualC);
    }

    /// @notice Move sleeve value toward configured weights using the approved
    ///         one-way policy: Sleeve C -> Sleeve B, then Sleeve B -> Sleeve A.
    ///         Automatic rebalancing never funds Sleeve C and never moves A down.
    /// @param maxMoveUsdc Maximum total USDC value to move in this call.
    /// @return movedCToB USDC value moved from Sleeve C into Sleeve B.
    /// @return movedBToA USDC value moved from Sleeve B into Sleeve A.
    function rebalanceSleevesOneWay(uint256 maxMoveUsdc)
        external
        nonReentrant
        whenNotPaused
        onlyAutomationOrOwner
        returns (uint256 movedCToB, uint256 movedBToA)
    {
        if (maxMoveUsdc == 0) return (0, 0);

        uint256 nav = totalLocalNAV();
        if (nav == 0) return (0, 0);

        uint256 targetA = (nav * sleeveADepositBps) / FeeLib.BPS_DENOM;
        uint256 targetB = (nav * sleeveBDepositBps) / FeeLib.BPS_DENOM;
        uint256 targetC = nav - targetA - targetB;

        uint256 moved;
        uint256 cValue = _sleeveValue(SLEEVE_C);
        if (cValue > targetC) {
            uint256 amount = cValue - targetC;
            uint256 remainingCap = maxMoveUsdc - moved;
            if (amount > remainingCap) amount = remainingCap;

            movedCToB = _moveSleeveValue(SLEEVE_C, SLEEVE_B, amount);
            moved += movedCToB;
        }

        if (moved < maxMoveUsdc) {
            uint256 bValue = _sleeveValue(SLEEVE_B);
            if (bValue > targetB) {
                uint256 amount = bValue - targetB;
                uint256 remainingCap = maxMoveUsdc - moved;
                if (amount > remainingCap) amount = remainingCap;

                movedBToA = _moveSleeveValue(SLEEVE_B, SLEEVE_A, amount);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the automation contract. Only contract addresses accepted.
    ///         In production the vault owner should be a timelock/controller.
    function setAutomation(address _automation) external onlyOwner {
        if (_automation == address(0)) revert ZeroAddress();
        if (_automation.code.length == 0) revert NotContract(_automation);
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
        if (amount == 0) revert ZeroAmount();
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
        if (newRecipient == address(0)) revert ZeroAddress();
        uint256 amount = pendingFees[staleWallet];
        if (amount == 0) revert NoPendingFees();
        if (lastFeeAccrual[staleWallet] == 0 || block.timestamp < lastFeeAccrual[staleWallet] + FeeLib.STALE_FEE_DELAY)
        {
            revert FeesNotStale();
        }
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

    /// @notice Add USDC to the holder redemption reserve.
    ///         Direct USDC transfers are not counted as holder NAV; use this
    ///         function when topping up cash for redemptions.
    function fundRedemptionReserve(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        idleRedemptionReserveUsdc += amount;
        emit RedemptionReserveFunded(msg.sender, amount);
    }

    /// @notice Wire the vault to a hub-chain confirmed spoke NAV cache.
    ///         Use address(0) to disconnect hub-spoke accounting.
    function setHubNAV(address newHubNAV) external onlyOwner {
        if (newHubNAV != address(0) && newHubNAV.code.length == 0) revert NotContract(newHubNAV);
        hubNAV = newHubNAV;
        emit HubNAVSet(newHubNAV);
    }

    /// @notice Finalize deployment bootstrap mode. After this, owner/Safe USDC
    ///         recovery requires a 48-hour propose/execute delay.
    function finalizeBootstrap() external onlyOwner {
        if (!bootstrapMode) revert BootstrapAlreadyFinalized();
        bootstrapMode = false;
        emit BootstrapFinalized();
    }

    /// @notice Recover idle USDC from the vault to the treasury/Safe.
    ///         During bootstrap this executes immediately; after bootstrap it
    ///         creates a 48-hour pending recovery.
    function recoverTreasuryVaultUSDC(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (bootstrapMode) {
            _recoverTreasuryVaultUSDC(to, amount);
            return;
        }

        uint256 executeAfter = block.timestamp + FeeLib.AUTOMATION_TIMELOCK_DELAY;
        pendingTreasuryVaultUSDCRecovery =
            PendingTreasuryVaultUSDCRecovery({to: to, amount: amount, executeAfter: executeAfter});
        emit TreasuryVaultUSDCRecoveryProposed(to, amount, executeAfter);
    }

    /// @notice Execute a pending post-bootstrap USDC recovery after the 48-hour delay.
    function executeTreasuryVaultUSDCRecovery() external onlyOwner nonReentrant {
        PendingTreasuryVaultUSDCRecovery memory pending = pendingTreasuryVaultUSDCRecovery;
        if (pending.to == address(0)) revert NoPendingTreasuryVaultUSDCRecovery();
        if (block.timestamp < pending.executeAfter) revert TimelockNotReady(pending.executeAfter);

        delete pendingTreasuryVaultUSDCRecovery;
        _recoverTreasuryVaultUSDC(pending.to, pending.amount);
    }

    /// @notice Cancel a pending post-bootstrap USDC recovery.
    function cancelTreasuryVaultUSDCRecovery() external onlyOwner {
        PendingTreasuryVaultUSDCRecovery memory pending = pendingTreasuryVaultUSDCRecovery;
        if (pending.to == address(0)) revert NoPendingTreasuryVaultUSDCRecovery();
        delete pendingTreasuryVaultUSDCRecovery;
        emit TreasuryVaultUSDCRecoveryCancelled(pending.to, pending.amount);
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

    /// @notice Set a minimum accepted deposit amount. Set to 0 to remove the minimum.
    function setMinDepositUsdc(uint256 minimum) external onlyOwner {
        minDepositUsdc = minimum;
        emit MinDepositUpdated(minimum);
    }

    /// @notice Set the minimum per-route amount deployed to external sleeve adapters.
    ///         Smaller allocations remain as idle vault USDC counted in that sleeve's NAV.
    function setMinSleeveRouteDepositUsdc(uint256 minimum) external onlyOwner {
        minSleeveRouteDepositUsdc = minimum;
        emit MinSleeveRouteDepositUpdated(minimum);
    }

    /// @notice Route deposits below this size entirely to Sleeve B's stable adapter.
    ///         Set to 0 to use normal sleeve weights for all deposit sizes.
    function setSmallDepositStableOnlyThresholdUsdc(uint256 threshold) external onlyOwner {
        smallDepositStableOnlyThresholdUsdc = threshold;
        emit SmallDepositStableOnlyThresholdUpdated(threshold);
    }

    /// @notice Configure the idle USDC buffer retained for routine redemptions.
    function setRedemptionBuffer(uint16 bufferBps, uint256 minimumUsdc) external onlyOwner {
        if (bufferBps > 2_000) revert InvalidFeeBps(bufferBps);
        redemptionBufferBps = bufferBps;
        minRedemptionBufferUsdc = minimumUsdc;
        emit RedemptionBufferUpdated(bufferBps, minimumUsdc);
    }

    /// @notice Set max USDC/USD feed age for redemptions. Set to 0 to disable age-based blocking.
    function setUSDCRedemptionMaxStale(uint256 maxStale) external onlyOwner {
        usdcRedemptionMaxStale = maxStale;
        emit USDCRedemptionMaxStaleUpdated(maxStale);
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
        if (to == address(0)) revert ZeroAddress();
        if (token == USDC) revert ProtectedTokenRecovery(token);
        if (token == address(bgwToken)) revert ProtectedTokenRecovery(token);
        if (token == address(govToken)) revert ProtectedTokenRecovery(token);
        if (protectedTokens[token]) revert ProtectedTokenRecovery(token);
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy new USDC deposit into sleeves at configured target weights.
    function _deployToSleeves(uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;
        usdcAmount = _retainRedemptionBuffer(usdcAmount);
        if (usdcAmount == 0) return;

        _deployToSleevesUnbuffered(usdcAmount);
    }

    function _deployToSleevesUnbuffered(uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;

        uint256 stableOnlyThreshold = smallDepositStableOnlyThresholdUsdc;
        if (stableOnlyThreshold != 0 && usdcAmount < stableOnlyThreshold) {
            _deployToSleeve(SLEEVE_B, usdcAmount, true);
            return;
        }

        uint256 postDepositNav = totalLocalNAV() + usdcAmount;
        uint256 targetA = (postDepositNav * sleeveADepositBps) / FeeLib.BPS_DENOM;
        uint256 targetB = (postDepositNav * sleeveBDepositBps) / FeeLib.BPS_DENOM;
        uint256 targetC = postDepositNav - targetA - targetB;

        uint256 remaining = usdcAmount;
        (uint256 toB, uint256 afterB) = _allocateDepositDeficit(targetB, _sleeveValue(SLEEVE_B), remaining);
        remaining = afterB;

        uint256 allocation;
        (allocation, remaining) = _allocateDepositDeficit(targetA, _sleeveValue(SLEEVE_A), remaining);
        uint256 toA = allocation;

        (allocation, remaining) = _allocateDepositDeficit(targetC, _sleeveValue(SLEEVE_C), remaining);
        uint256 toC = allocation;

        if (remaining > 0) {
            uint256 extraA = (remaining * sleeveADepositBps) / FeeLib.BPS_DENOM;
            uint256 extraB = (remaining * sleeveBDepositBps) / FeeLib.BPS_DENOM;
            uint256 extraC = remaining - extraA - extraB;
            toA += extraA;
            toB += extraB;
            toC += extraC;
        }

        _deployToSleeve(SLEEVE_A, toA, false);
        _deployToSleeve(SLEEVE_B, toB, false);
        _deployToSleeve(SLEEVE_C, toC, false);
    }

    function _allocateDepositDeficit(uint256 target, uint256 current, uint256 remaining)
        internal
        pure
        returns (uint256 allocation, uint256 newRemaining)
    {
        if (remaining == 0 || current >= target) return (0, remaining);
        uint256 deficit = target - current;
        allocation = deficit > remaining ? remaining : deficit;
        newRemaining = remaining - allocation;
    }

    function _retainRedemptionBuffer(uint256 availableToDeploy) internal returns (uint256 deployableUsdc) {
        uint256 target = _redemptionBufferTargetUSDC(totalLocalNAV() + availableToDeploy);
        uint256 reserve = idleRedemptionReserveUsdc;
        if (reserve >= target) return availableToDeploy;

        uint256 shortfall = target - reserve;
        uint256 retain = shortfall > availableToDeploy ? availableToDeploy : shortfall;
        idleRedemptionReserveUsdc = reserve + retain;
        return availableToDeploy - retain;
    }

    function _redemptionBufferTargetUSDC(uint256 localNav) internal view returns (uint256 target) {
        target = (localNav * redemptionBufferBps) / FeeLib.BPS_DENOM;
        if (target < minRedemptionBufferUsdc) target = minRedemptionBufferUsdc;
        if (target > localNav) target = localNav;
    }

    /// @dev Reduce portfolio sleeves proportionally when holder NAV leaves the vault.
    ///      The buyback accumulator is a separate reserve and is not redeemable NAV.
    function _reduceSleevesProRata(uint256 grossUsdc) internal {
        uint256 nav = totalLocalNAV();
        if (nav == 0) return;
        if (grossUsdc > nav) revert InsufficientLocalLiquidity(nav, grossUsdc);

        _withdrawFromSleeve(SLEEVE_A, (_sleeveValue(SLEEVE_A) * grossUsdc) / nav);
        _withdrawFromSleeve(SLEEVE_B, (_sleeveValue(SLEEVE_B) * grossUsdc) / nav);
        _withdrawFromSleeve(SLEEVE_C, (_sleeveValue(SLEEVE_C) * grossUsdc) / nav);
    }

    /// @dev Fund redemptions from the most liquid sleeve first. Stable Sleeve B
    ///      is the first line of defense for routine exits; Sleeve A is touched
    ///      only when the stable/cash layers are insufficient.
    function _fundRedemptionFromLiquidSleeves(uint256 grossUsdc) internal returns (uint256 usdcReturned) {
        uint256 nav = totalLocalNAV();
        if (nav == 0) return 0;
        if (grossUsdc > nav) revert InsufficientLocalLiquidity(nav, grossUsdc);

        uint256 idle = idleRedemptionReserveUsdc;
        uint256 availableUsdc = _availableUSDC();
        if (idle > availableUsdc) idle = availableUsdc;
        if (idle >= grossUsdc) {
            idleRedemptionReserveUsdc = idle - grossUsdc;
            return 0;
        }

        uint256 remaining = grossUsdc - idle;
        if (idle > 0) idleRedemptionReserveUsdc = 0;

        uint256 sleeveB = _sleeveValue(SLEEVE_B);
        uint256 request = sleeveB > remaining ? remaining : sleeveB;
        if (request > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_B, request);
            usdcReturned += returned;
            if (returned > request) idleRedemptionReserveUsdc += returned - request;
            remaining = returned >= remaining ? 0 : remaining - returned;
        }

        uint256 sleeveC = _sleeveValue(SLEEVE_C);
        request = sleeveC > remaining ? remaining : sleeveC;
        if (request > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_C, request);
            usdcReturned += returned;
            if (returned > request) idleRedemptionReserveUsdc += returned - request;
            remaining = returned >= remaining ? 0 : remaining - returned;
        }

        if (remaining > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_A, remaining);
            usdcReturned += returned;
            if (returned > remaining) idleRedemptionReserveUsdc += returned - remaining;
        }
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
        if (supply > 0 && performanceFeeProfitCheckpointUsdc > 0) {
            uint256 profitSlice = (bgwAmount * performanceFeeProfitCheckpointUsdc) / supply;
            performanceFeeProfitCheckpointUsdc -= profitSlice;
        }
    }

    function _availableUSDC() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 reserved = totalPendingFees + buybackAccumulator;
        return usdcBalance > reserved ? usdcBalance - reserved : 0;
    }

    function _availableUSDCForFees() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 reserved = totalPendingFees + buybackAccumulator + idleRedemptionReserveUsdc;
        return usdcBalance > reserved ? usdcBalance - reserved : 0;
    }

    function _availableUSDCForBuyback() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 reserved = totalPendingFees + idleRedemptionReserveUsdc;
        return usdcBalance > reserved ? usdcBalance - reserved : 0;
    }

    function _currentPerformanceProfitUsdc() internal view returns (uint256) {
        uint256 nav = totalNAV();
        return nav > cumulativePrincipal ? nav - cumulativePrincipal : 0;
    }

    function _feeablePerformanceProfitUsdc() internal view returns (uint256) {
        uint256 currentProfit = _currentPerformanceProfitUsdc();
        uint256 checkpoint = performanceFeeProfitCheckpointUsdc;
        return currentProfit > checkpoint ? currentProfit - checkpoint : 0;
    }

    function _consumeIdleRedemptionReserve(uint256 amount) internal {
        uint256 reserve = idleRedemptionReserveUsdc;
        if (reserve == 0 || amount == 0) return;
        idleRedemptionReserveUsdc = amount >= reserve ? 0 : reserve - amount;
    }

    function _recoverTreasuryVaultUSDC(address to, uint256 amount) internal {
        uint256 available = _availableUSDCForFees();
        if (amount > available) amount = available;
        if (amount == 0) revert ZeroAmount();

        emit TreasuryVaultUSDCRecovered(to, amount);
        IERC20(USDC).safeTransfer(to, amount);
    }

    function _deployToSleeve(uint8 sleeve, uint256 usdcAmount, bool forceExternalDeploy) internal {
        if (usdcAmount == 0) return;
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) {
            uint256 allocated;
            for (uint256 i; i < routeCount; ++i) {
                SleeveAdapterRoute memory route = _sleeveAdapterRoutes[sleeve][i];
                if (!route.active || route.depositBps == 0) continue;

                uint256 routeAmount = (usdcAmount * route.depositBps) / FeeLib.BPS_DENOM;
                if (routeAmount == 0) continue;
                if (!forceExternalDeploy && minSleeveRouteDepositUsdc > 0 && routeAmount < minSleeveRouteDepositUsdc) {
                    continue;
                }

                allocated += routeAmount;
                IERC20(USDC).safeTransfer(route.adapter, routeAmount);
                ISleeveAdapter(route.adapter).deploy(routeAmount);
            }

            uint256 remainder = usdcAmount - allocated;
            if (remainder > 0) {
                // N-03: hold the un-routed remainder as part of the redemption
                // buffer rather than crediting a phantom manual sleeve value.
                // Keeps the routed-sleeve accounting honest and the buffer
                // self-replenishes on small deposits below `minSleeveRouteDepositUsdc`.
                idleRedemptionReserveUsdc += remainder;
            }
            return;
        }

        _setSleeveValue(sleeve, _manualSleeveValue(sleeve) + usdcAmount);
    }

    function _withdrawFromSleeve(uint8 sleeve, uint256 usdcAmount) internal returns (uint256 usdcReturned) {
        if (usdcAmount == 0) return 0;
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) {
            uint256 remaining = usdcAmount;
            uint256 manual = _manualSleeveValue(sleeve);
            uint256 fromManual = manual > remaining ? remaining : manual;
            if (fromManual > 0) {
                _setSleeveValue(sleeve, manual - fromManual);
                remaining -= fromManual;
                usdcReturned += fromManual;
            }

            for (uint256 i; i < routeCount && remaining > 0; ++i) {
                address routeAdapter = _sleeveAdapterRoutes[sleeve][i].adapter;
                uint256 routeAssets = ISleeveAdapter(routeAdapter).totalAssetsUSDC();
                if (routeAssets == 0) continue;

                uint256 request = routeAssets > remaining ? remaining : routeAssets;
                uint256 returned = ISleeveAdapter(routeAdapter).withdraw(request);
                usdcReturned += returned;
                remaining = returned >= remaining ? 0 : remaining - returned;
            }
            return usdcReturned;
        }

        uint256 current = _manualSleeveValue(sleeve);
        usdcReturned = usdcAmount > current ? current : usdcAmount;
        _setSleeveValue(sleeve, current - usdcReturned);
        return usdcReturned;
    }

    function _moveSleeveValue(uint8 fromSleeve, uint8 toSleeve, uint256 usdcAmount)
        internal
        returns (uint256 movedUsdc)
    {
        movedUsdc = _withdrawFromSleeve(fromSleeve, usdcAmount);
        if (movedUsdc == 0) return 0;

        _deployToSleeve(toSleeve, movedUsdc, true);
        emit SleeveRebalanced(fromSleeve, toSleeve, usdcAmount, movedUsdc);
    }

    function _reportedOrAdapterValue(uint8 sleeve, uint256 reportedValue) internal view returns (uint256) {
        if (_sleeveAdapterRoutes[sleeve].length > 0) return _sleeveValue(sleeve);
        return reportedValue;
    }

    function _setReportedSleeveValue(uint8 sleeve, uint256 reportedValue) internal {
        if (_sleeveAdapterRoutes[sleeve].length == 0) {
            _setSleeveValue(sleeve, reportedValue);
        }
    }

    function _sleeveValue(uint8 sleeve) internal view returns (uint256) {
        uint256 routeCount = _sleeveAdapterRoutes[sleeve].length;
        if (routeCount > 0) return _manualSleeveValue(sleeve) + _routeAssetsUSDC(sleeve);
        return _manualSleeveValue(sleeve);
    }

    function _manualSleeveValue(uint8 sleeve) internal view returns (uint256) {
        if (sleeve == SLEEVE_A) return sleeveAValue;
        if (sleeve == SLEEVE_B) return sleeveBValue;
        if (sleeve == SLEEVE_C) return sleeveCValue;
        revert InvalidSleeve(sleeve);
    }

    function _setSleeveValue(uint8 sleeve, uint256 value) internal {
        if (sleeve == SLEEVE_A) {
            sleeveAValue = value;
        } else if (sleeve == SLEEVE_B) {
            sleeveBValue = value;
        } else if (sleeve == SLEEVE_C) {
            sleeveCValue = value;
        } else {
            revert InvalidSleeve(sleeve);
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
        if (adapters.length != depositBps.length || adapters.length != active.length) revert RouteLengthMismatch();
        if (adapters.length > 10) revert TooManyRoutes(adapters.length, 10);

        for (uint256 i; i < adapters.length; ++i) {
            address adapter = adapters[i];
            if (adapter == address(0)) revert ZeroAddress();
            if (adapter.code.length == 0) revert NotContract(adapter);

            for (uint256 j = i + 1; j < adapters.length; ++j) {
                if (adapter == adapters[j]) revert DuplicateRoute(adapter);
            }

            if (active[i]) activeBps += depositBps[i];
        }
        if (activeBps > FeeLib.BPS_DENOM) revert RouteBpsTooHigh(activeBps);

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
        if (sleeve > SLEEVE_C) revert InvalidSleeve(sleeve);
    }

    /// @dev Distribute performance fee across 6 recipients.
    ///      Uses try-transfer with pendingFees fallback so one bad wallet
    ///      cannot block the entire fee distribution (H-02).
    function _distributePerfFee(uint256 totalFee) internal {
        if (totalFee == 0) return;

        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(totalFee);

        _tryTransferAvailableFee(teamWallet, s.team);
        _tryTransferAvailableFee(holdbackWallet, s.holdback);
        _tryTransferAvailableFee(reserveFundWallet, s.reserve);

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

    function _tryTransferAvailableFee(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (amount > _availableUSDCForFees()) {
            pendingFees[recipient] += amount;
            totalPendingFees += amount;
            lastFeeAccrual[recipient] = block.timestamp;
            return;
        }
        _tryTransferFee(recipient, amount);
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
        if (updatedAt == 0 || updatedAt > block.timestamp) {
            revert StaleOracle(updatedAt);
        }
        uint256 maxStale = usdcRedemptionMaxStale;
        if (maxStale != 0 && block.timestamp - updatedAt > maxStale) {
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
            if (newVal - oldVal > maxGrow) revert SleeveMoveTooFast();
        } else {
            uint256 maxShrink = (oldVal * FeeLib.MAX_SLEEVE_SHRINK_BPS_DAY * elapsed) / (FeeLib.BPS_DENOM * 1 days);
            if (oldVal - newVal > maxShrink) revert SleeveMoveTooFast();
        }
    }
}
