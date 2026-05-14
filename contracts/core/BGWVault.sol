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

    /// @dev Chainlink price staleness threshold.
    uint256 public constant ORACLE_STALE_THRESHOLD = 1 hours;

    /// @dev Max slippage allowed on DEX swaps (default 1 %).
    uint256 public constant MAX_SLIPPAGE_BPS = 100;

    // ─────────────────────────────────────────────────────────────────────────
    // Immutables — set once at construction, never changed (M-06)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC token address (6 dec). Passed at deploy — no bytecode hardcoding.
    address public immutable USDC;

    /// @notice Chainlink ETH/USD price feed. Passed at deploy for testnet flexibility.
    address public immutable ETH_USD_FEED;

    // ── BGW-GOV distribution rate ─────────────────────────────────────────────
    // Fixed-rate formula: each depositor gets bgwMinted × (30M / 100M) BGW-GOV.
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
    // State — DEX router (M-06: settable so router upgrades don't force redeploy)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Camelot DEX router used for USDC → BGW buyback swaps.
    ///         Owner can propose a new address via proposeRouterUpdate() + 48h timelock.
    address public camelotRouter;

    // ─────────────────────────────────────────────────────────────────────────
    // State — automation
    // ─────────────────────────────────────────────────────────────────────────

    address public automation;              // BridgewayAutomation contract

    // ─────────────────────────────────────────────────────────────────────────
    // State — portfolio accounting
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total USDC value currently tracked in each sleeve (6 dec).
    uint256 public sleeveAValue;
    uint256 public sleeveBValue;
    uint256 public sleeveCValue;

    /// @notice High-water mark — NAV per BGW at last fee crystallisation (18 dec scale).
    uint256 public highWaterMark;
    uint256 public lastHWMUpdateTime;

    /// @notice Annual management fee in basis points (default 50 = 0.50 %).
    uint256 public managementFeeBps = FeeLib.MANAGEMENT_FEE_BPS;

    /// @notice USDC accumulated for next BGW buyback (6 dec).
    uint256 public buybackAccumulator;

    /// @notice Timestamp of last monthly harvest.
    uint256 public lastHarvestTime;

    // ─────────────────────────────────────────────────────────────────────────
    // State — exit fee
    // ─────────────────────────────────────────────────────────────────────────

    uint256 public exitFeeBps       = FeeLib.EXIT_FEE_BPS;
    uint256 public stressExitFeeBps = FeeLib.STRESS_EXIT_BPS;
    bool    public stressModeActive;

    // ─────────────────────────────────────────────────────────────────────────
    // State — principal tracking (C-01)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Running total of all USDC deposited minus proportional redemptions.
    uint256 public cumulativePrincipal;

    /// @notice Realised losses formally acknowledged by the owner via proposeRealisedLoss.
    uint256 public authorisedLosses;

    // ─────────────────────────────────────────────────────────────────────────
    // State — automation timelock (C-01)
    // ─────────────────────────────────────────────────────────────────────────

    address public pendingAutomation;
    uint256 public automationProposalEta;

    // ─────────────────────────────────────────────────────────────────────────
    // State — realised-loss timelock (C-01)
    // ─────────────────────────────────────────────────────────────────────────

    struct PendingLossMark {
        uint256 amount;
        uint256 executeAfter;
    }
    PendingLossMark public pendingLossMark;

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

    /// @notice Sum of all escrowed pendingFees — included in totalNAV() so deposits
    ///         during an escrow window price BGW correctly (C-03).
    uint256 public totalPendingFees;

    /// @notice Timestamp when fees last failed for each recipient (used by sweepStaleFees).
    mapping(address => uint256) public lastFeeAccrual;

    // ─────────────────────────────────────────────────────────────────────────
    // State — fee-change timelock (M-03)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum delay between proposing and executing a fee-level change.
    ///         Gives depositors time to exit before a higher fee takes effect.
    uint256 public constant FEE_CHANGE_DELAY = 48 hours;

    bytes32 public constant CHANGE_EXIT_FEE   = keccak256("EXIT_FEE");
    bytes32 public constant CHANGE_STRESS_FEE = keccak256("STRESS_EXIT_FEE");
    bytes32 public constant CHANGE_MGMT_FEE   = keccak256("MANAGEMENT_FEE");

    struct PendingFeeChange {
        uint256 value;
        uint256 executeAfter; // 0 = no pending change
    }
    mapping(bytes32 => PendingFeeChange) public pendingFeeChanges;

    struct PendingWalletsChange {
        address team;
        address holdback;
        address lp;
        address reserve;
        uint256 executeAfter; // 0 = no pending change
    }
    PendingWalletsChange public pendingWalletsChange;

    // Router / oracle address changes share the same timelock discipline.
    bytes32 public constant CHANGE_ROUTER = keccak256("CAMELOT_ROUTER");

    struct PendingAddressChange {
        address value;
        uint256 executeAfter; // 0 = no pending change
    }
    mapping(bytes32 => PendingAddressChange) public pendingAddressChanges;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event MaxDepositCapUpdated(uint256 newCap);
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
    event DirectBurnDeferred(uint256 indexed usdcAmount, bytes reason); // H-08
    event PairBootstrapped(address indexed pair);                       // H-07
    event StaleFeeSwept(address indexed staleWallet, address indexed recipient, uint256 amount); // H-13
    event SleeveValuesUpdated(uint256 sleeveA, uint256 sleeveB, uint256 sleeveC);
    event ManagementFeeCharged(uint256 feeUsdc, uint256 elapsed);
    event ManagementFeeBpsUpdated(uint256 newBps);
    event ExitFeeBpsUpdated(uint256 newBps);
    event StressExitFeeBpsUpdated(uint256 newBps);
    event WhitelistUpdated(address indexed account, bool status);
    event StressModeToggled(bool active);
    event AutomationSet(address indexed automation);
    event AutomationRevoked(address indexed old);
    // C-01 — automation timelock
    event AutomationProposed(address indexed candidate, uint256 executeAfter);
    event AutomationCancelled(address indexed candidate);
    // C-01 — realised loss governance
    event LossMarkProposed(uint256 amount, uint256 executeAfter);
    event LossMarkExecuted(uint256 amount);
    event LossMarkCancelled();
    event FeeWalletsUpdated(address team, address holdback, address lp, address reserve);
    event ProtectedTokenUpdated(address indexed token, bool protected);
    // Timelock events (M-03)
    event FeeChangeProposed(bytes32 indexed changeType, uint256 newValue, uint256 executeAfter);
    event FeeChangeExecuted(bytes32 indexed changeType, uint256 newValue);
    event FeeChangeCancelled(bytes32 indexed changeType);
    event FeeWalletsProposed(address team, address holdback, address lp, address reserve, uint256 executeAfter);
    event FeeWalletsCancelled();
    event AddressChangeProposed(bytes32 indexed changeType, address newValue, uint256 executeAfter);
    event AddressChangeExecuted(bytes32 indexed changeType, address newValue);
    event AddressChangeCancelled(bytes32 indexed changeType);

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
    error NoPendingChange(bytes32 changeType);
    error TimelockNotElapsed(uint256 executeAfter);
    error DepositExceedsCap(uint256 amount, uint256 cap);

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
        address _lpSeedingWallet,
        address _reserveFundWallet,
        address _admin,
        address _usdc,
        address _camelotRouter,
        address _ethUsdFeed
    ) Ownable(_admin) {
        if (_bgwToken          == address(0)) revert ZeroAddress();
        if (_govToken          == address(0)) revert ZeroAddress();
        if (_teamWallet        == address(0)) revert ZeroAddress();
        if (_holdbackWallet    == address(0)) revert ZeroAddress();
        if (_lpSeedingWallet   == address(0)) revert ZeroAddress();
        if (_reserveFundWallet == address(0)) revert ZeroAddress();
        if (_usdc              == address(0)) revert ZeroAddress();
        if (_camelotRouter     == address(0)) revert ZeroAddress();
        if (_ethUsdFeed        == address(0)) revert ZeroAddress();

        bgwToken          = BGWToken(_bgwToken);
        govToken          = BGWGovToken(_govToken);
        teamWallet        = _teamWallet;
        holdbackWallet    = _holdbackWallet;
        lpSeedingWallet   = _lpSeedingWallet;
        reserveFundWallet = _reserveFundWallet;
        USDC              = _usdc;
        camelotRouter     = _camelotRouter;
        ETH_USD_FEED      = _ethUsdFeed;

        highWaterMark     = 1e18;
        lastHWMUpdateTime = block.timestamp;

        // ── Seed protectedTokens with Aave V3 Arbitrum One aTokens + LST wrappers ──
        // These are the yield-bearing tokens the vault holds on behalf of depositors.
        // Owner must add new entries (Pendle PTs, GMX GLP, etc.) before each deploy
        // and remove them once the position is fully unwound.
        //
        // Aave V3 Arbitrum One — verify at https://aave.com/docs before mainnet deploy.
        protectedTokens[0x724dc807b04555b71ed48a6896b6F41593b8C637] = true; // aUSDCn
        protectedTokens[0x6ab707Aca953eDAeFBc4fD23bA73294241490620] = true; // aUSDT
        protectedTokens[0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8] = true; // aWETH
        protectedTokens[0x078f358208685046a11C85e8ad32895DED33A249] = true; // aWBTC
        protectedTokens[0x513c7E3a9c69cA3e22550eF58AC1C0088e918FFf] = true; // awstETH
        // Lido wstETH on Arbitrum (underlying of Aave sleeve A)
        protectedTokens[0x5979D7b546E38E414F7E9822514be443A4800529] = true; // wstETH
        // Pendle PT tokens, GMX GLP, Morpho shares, sUSDe → add via setProtectedToken
        // before each protocol deployment.
    }

    // ─────────────────────────────────────────────────────────────────────────
    // NAV & Pricing
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Total vault NAV: sum of all sleeve values + buyback accumulator + escrowed
    ///         pending fees (C-03: prevents NAV under-reporting when fee pushes fail).
    function totalNAV() public view returns (uint256) {
        return sleeveAValue + sleeveBValue + sleeveCValue + buybackAccumulator + totalPendingFees;
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

    /// @notice Fetch ETH/USD price from Chainlink (8 dec). Reverts if stale (>1 hour).
    function getETHPrice() public view returns (uint256 price) {
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(ETH_USD_FEED).latestRoundData();
        if (block.timestamp - updatedAt > ORACLE_STALE_THRESHOLD)
            revert StaleOracle(updatedAt);
        require(answeredInRound >= roundId, "BGWVault: stale round");
        require(answer > 0, "BGWVault: negative oracle price");
        price = uint256(answer);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposit
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit USDC into the vault. Must be whitelisted.
    ///         Mints BGW at current NAV. Distributes proportional BGW-GOV.
    /// @param  usdcAmount  Amount of USDC (6 dec) to deposit.
    /// @param  minBgwOut   Minimum BGW to receive (slippage guard, 18 dec). Pass 0 to skip.
    function deposit(uint256 usdcAmount, uint256 minBgwOut)
        external
        nonReentrant
        whenNotPaused
        onlyWhitelisted
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (maxDepositUsdc > 0 && usdcAmount > maxDepositUsdc)
            revert DepositExceedsCap(usdcAmount, maxDepositUsdc);

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);
        cumulativePrincipal += usdcAmount;

        uint256 nav6      = navPerBGW();
        uint256 bgwToMint = (usdcAmount * 1e18) / nav6;

        if (bgwToMint < minBgwOut) revert SlippageTooHigh(bgwToMint, minBgwOut);

        uint256 govAmount = _calcGovDistribution(bgwToMint);

        // Effects before interactions (CEI)
        _deployToSleeves(usdcAmount);

        bgwToken.mint(msg.sender, bgwToMint);
        if (govAmount > 0) {
            govToken.distributeToDepositor(msg.sender, govAmount);
        }

        emit Deposited(msg.sender, usdcAmount, bgwToMint, govAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Redeem
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Redeem BGW for USDC. Applies exit fee + perf fee if above HWM.
    ///         No whitelist check — holders must always be able to exit (H-02).
    /// @param  bgwAmount  BGW to burn (18 dec).
    /// @param  minUSDC    Minimum USDC to accept (slippage guard, 6 dec).
    function redeem(uint256 bgwAmount, uint256 minUSDC)
        external
        nonReentrant
        whenNotPaused
    {
        if (bgwAmount == 0) revert ZeroAmount();

        uint256 userBalance = bgwToken.balanceOf(msg.sender);
        if (userBalance < bgwAmount) revert InsufficientBGW(userBalance, bgwAmount);

        uint256 grossUsdc = (bgwAmount * navPerBGW()) / 1e18;

        uint256 feeBps      = stressModeActive ? stressExitFeeBps : exitFeeBps;
        uint256 exitFeeUsdc = FeeLib.calcExitFee(grossUsdc, feeBps);

        uint256 perfFeeUsdc;
        uint256 currentNav18 = navPerBGW18();
        uint256 effectiveHwm = _decayedHWM();
        if (currentNav18 > effectiveHwm) {
            uint256 yieldPerBGW18 = currentNav18 - effectiveHwm;
            uint256 yieldUsdc     = (bgwAmount * yieldPerBGW18) / 1e30;
            perfFeeUsdc           = FeeLib.calcPerfFee(yieldUsdc);
        }

        uint256 netUsdc = grossUsdc - exitFeeUsdc - perfFeeUsdc;
        if (netUsdc < minUSDC) revert SlippageTooHigh(netUsdc, minUSDC);

        // Proportionally reduce cumulative principal before burning (C-01).
        // Must be done before adminBurn because totalSupply changes after the burn.
        uint256 supply = bgwToken.totalSupply();
        if (supply > 0 && cumulativePrincipal > 0) {
            uint256 principalSlice = (bgwAmount * cumulativePrincipal) / supply;
            cumulativePrincipal -= principalSlice;
        }

        bgwToken.adminBurn(msg.sender, bgwAmount);

        _reduceSleevesProRata(grossUsdc);

        if (perfFeeUsdc > 0) {
            _distributePerfFee(perfFeeUsdc);
            // H-03/H-14: same 1% minimum delta required for HWM crystallisation.
            if (currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM) {
                highWaterMark     = navPerBGW18();
                lastHWMUpdateTime = block.timestamp;
            }
        }

        if (exitFeeUsdc > 0) {
            _tryTransferFee(holdbackWallet, exitFeeUsdc);
        }

        IERC20(USDC).safeTransfer(msg.sender, netUsdc);

        emit Redeemed(msg.sender, bgwAmount, netUsdc, exitFeeUsdc, perfFeeUsdc);
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
    function recordHarvest(
        uint256 netYieldUsdc,
        uint256 newSleeveA,
        uint256 newSleeveB,
        uint256 newSleeveC
    ) external nonReentrant whenNotPaused onlyAutomation {
        // Yield must not exceed actual USDC received — fundamental sanity check (C-01).
        require(
            netYieldUsdc <= IERC20(USDC).balanceOf(address(this)),
            "BGWVault: yield exceeds balance"
        );

        // Time-weighted anti-manipulation bounds (C-01).
        // Gated on lastHarvestTime > 0 so the very first harvest is unconstrained
        // (no baseline exists to measure rate against).
        if (lastHarvestTime > 0) {
            uint256 sinceLastHarvest = block.timestamp - lastHarvestTime;
            require(sinceLastHarvest >= FeeLib.MIN_HARVEST_GAP, "BGWVault: harvest gap too short");

            uint256 nav = totalNAV();
            if (nav > 0 && netYieldUsdc > 0) {
                uint256 maxYield = (nav * FeeLib.MAX_YIELD_APR_BPS * sinceLastHarvest) /
                    (FeeLib.BPS_DENOM * 365 days);
                require(netYieldUsdc <= maxYield, "BGWVault: yield rate too high");
            }

            _checkSleeveMove(sleeveAValue, newSleeveA, sinceLastHarvest);
            _checkSleeveMove(sleeveBValue, newSleeveB, sinceLastHarvest);
            _checkSleeveMove(sleeveCValue, newSleeveC, sinceLastHarvest);
        }

        sleeveAValue = newSleeveA;
        sleeveBValue = newSleeveB;
        sleeveCValue = newSleeveC;
        emit SleeveValuesUpdated(newSleeveA, newSleeveB, newSleeveC);

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
                highWaterMark     = navPerBGW18();
                lastHWMUpdateTime = block.timestamp;
            }
        }

        emit HarvestRecorded(netYieldUsdc, perfFeeUsdc, highWaterMark);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Automation-only: Buyback & Burn
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Spend `usdcAmount` from the buyback accumulator:
    ///         swap USDC → BGW on Camelot, then burn the received BGW.
    ///
    ///         minBGW is derived from the vault's own NAV rather than Camelot's
    ///         spot price, preventing sandwich attacks that inflate the pool price
    ///         just before the swap to reduce the floor (C-03).
    function executeBuyback(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyAutomation
    {
        if (usdcAmount == 0 || usdcAmount > buybackAccumulator) return;

        buybackAccumulator -= usdcAmount;

        IERC20(USDC).forceApprove(camelotRouter, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        // NAV-based floor: expectedBGW = usdcAmount / navPerBGW (both 6 dec → 18 dec result)
        uint256 expectedBGW = (usdcAmount * 1e18) / navPerBGW();
        uint256 minBGW      = (expectedBGW * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
            FeeLib.BPS_DENOM;

        uint256 bgwBefore = bgwToken.balanceOf(address(this));

        ICamelotRouter(camelotRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                usdcAmount,
                minBGW,
                path,
                address(this),
                address(0),
                block.timestamp + 5 minutes
            );

        uint256 bgwReceived = bgwToken.balanceOf(address(this)) - bgwBefore;

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
    ) external nonReentrant whenNotPaused onlyAutomation {
        // Time-weighted anti-manipulation bounds (C-01).
        // No MIN_HARVEST_GAP here — rebalancing may legitimately follow a harvest.
        // Gated on lastHarvestTime > 0 so pre-harvest setup calls are unconstrained.
        if (lastHarvestTime > 0) {
            uint256 elapsed = block.timestamp - lastHarvestTime;
            _checkSleeveMove(sleeveAValue, newSleeveA, elapsed);
            _checkSleeveMove(sleeveBValue, newSleeveB, elapsed);
            _checkSleeveMove(sleeveCValue, newSleeveC, elapsed);
        }
        sleeveAValue = newSleeveA;
        sleeveBValue = newSleeveB;
        sleeveCValue = newSleeveC;
        emit SleeveValuesUpdated(newSleeveA, newSleeveB, newSleeveC);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Propose replacing the automation contract (48-hour timelock, C-01).
    ///         Only contract addresses accepted — EOAs cannot call vault functions.
    function proposeAutomation(address _automation) external onlyOwner {
        if (_automation == address(0)) revert ZeroAddress();
        require(_automation.code.length > 0, "BGWVault: not a contract");
        uint256 eta = block.timestamp + FeeLib.AUTOMATION_TIMELOCK_DELAY;
        pendingAutomation     = _automation;
        automationProposalEta = eta;
        emit AutomationProposed(_automation, eta);
    }

    function executeAutomation() external onlyOwner {
        address candidate = pendingAutomation;
        require(candidate != address(0), "BGWVault: no pending automation");
        require(block.timestamp >= automationProposalEta, "BGWVault: timelock not elapsed");
        pendingAutomation     = address(0);
        automationProposalEta = 0;
        automation            = candidate;
        emit AutomationSet(candidate);
    }

    function cancelAutomation() external onlyOwner {
        address candidate = pendingAutomation;
        require(candidate != address(0), "BGWVault: no pending automation");
        pendingAutomation     = address(0);
        automationProposalEta = 0;
        emit AutomationCancelled(candidate);
    }

    /// @notice Instantly revoke the current automation contract.
    ///         Emergency circuit-breaker — stops all harvest/buyback immediately.
    function revokeAutomation() external onlyOwner {
        address old = automation;
        automation = address(0);
        emit AutomationRevoked(old);
    }

    /// @notice Whitelist a Camelot BGW/USDC pair address so buybacks can receive BGW (H-07).
    ///         Must be called after LP is seeded and before the first executeBuyback.
    function bootstrapPair(address pair) external onlyOwner {
        if (pair == address(0)) revert ZeroAddress();
        whitelist[pair] = true;
        bgwToken.setWhitelisted(pair, true);
        emit PairBootstrapped(pair);
    }

    // ── Realised-loss governance (C-01) ──────────────────────────────────────────
    // Large genuine losses (exploit, liquidation) that exceed the automation shrink
    // cap require owner acknowledgement with a 48-hour timelock so depositors can
    // observe and react before the loss is recorded as authorised.

    function proposeRealisedLoss(uint256 amount) external onlyOwner {
        require(amount > 0, "BGWVault: zero loss");
        uint256 eta = block.timestamp + FeeLib.AUTOMATION_TIMELOCK_DELAY;
        pendingLossMark = PendingLossMark(amount, eta);
        emit LossMarkProposed(amount, eta);
    }

    function executeRealisedLoss() external onlyOwner {
        PendingLossMark memory p = pendingLossMark;
        require(p.executeAfter > 0,                   "BGWVault: no pending loss");
        require(block.timestamp >= p.executeAfter,    "BGWVault: timelock not elapsed");
        delete pendingLossMark;
        authorisedLosses += p.amount;
        emit LossMarkExecuted(p.amount);
    }

    function cancelRealisedLoss() external onlyOwner {
        require(pendingLossMark.executeAfter > 0, "BGWVault: no pending loss");
        delete pendingLossMark;
        emit LossMarkCancelled();
    }

    /// @notice Fee recipients pull any USDC that failed to push automatically.
    function claimFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        if (amount == 0) return;
        pendingFees[msg.sender] = 0;
        totalPendingFees -= amount; // C-03: keep NAV consistent
        IERC20(USDC).safeTransfer(msg.sender, amount);
    }

    /// @notice Owner can redirect fees that have been unclaimed for STALE_FEE_DELAY (1 year).
    ///         Protects against permanently locked funds if a fee wallet is permanently inaccessible (H-13).
    function sweepStaleFees(address staleWallet, address newRecipient) external onlyOwner nonReentrant {
        require(newRecipient != address(0), "BGWVault: zero recipient");
        uint256 amount = pendingFees[staleWallet];
        require(amount > 0, "BGWVault: no pending fees");
        require(
            lastFeeAccrual[staleWallet] > 0 &&
            block.timestamp >= lastFeeAccrual[staleWallet] + FeeLib.STALE_FEE_DELAY,
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
    function setWhitelistedBatch(address[] calldata accounts, bool status)
        external
        onlyOwner
    {
        require(accounts.length <= 200, "BGWVault: batch too large");
        for (uint256 i; i < accounts.length; ++i) {
            whitelist[accounts[i]] = status;
            bgwToken.setWhitelisted(accounts[i], status);
            emit WhitelistUpdated(accounts[i], status);
        }
    }

    /// @notice Set normal exit fee (max 100 bps = 1 %).
    // ── Fee-change timelock (M-03) ────────────────────────────────────────────
    // Fee-level changes (BPS) and wallet updates follow a two-step pattern:
    //   1. propose*  — queues the new value; emits a propose event for off-chain monitoring
    //   2. execute*  — applies the change once FEE_CHANGE_DELAY (48 h) has elapsed
    //   3. cancel*   — discards the pending change before it executes
    // setStressMode remains instant — it is an emergency circuit-breaker, not a fee increase.

    function proposeExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        uint256 eta = block.timestamp + FEE_CHANGE_DELAY;
        pendingFeeChanges[CHANGE_EXIT_FEE] = PendingFeeChange(feeBps, eta);
        emit FeeChangeProposed(CHANGE_EXIT_FEE, feeBps, eta);
    }

    function executeExitFeeBps() external onlyOwner {
        PendingFeeChange memory p = pendingFeeChanges[CHANGE_EXIT_FEE];
        if (p.executeAfter == 0)                    revert NoPendingChange(CHANGE_EXIT_FEE);
        if (block.timestamp < p.executeAfter)        revert TimelockNotElapsed(p.executeAfter);
        delete pendingFeeChanges[CHANGE_EXIT_FEE];
        exitFeeBps = p.value;
        emit FeeChangeExecuted(CHANGE_EXIT_FEE, p.value);
        emit ExitFeeBpsUpdated(p.value);
    }

    function cancelExitFeeBps() external onlyOwner {
        if (pendingFeeChanges[CHANGE_EXIT_FEE].executeAfter == 0) revert NoPendingChange(CHANGE_EXIT_FEE);
        delete pendingFeeChanges[CHANGE_EXIT_FEE];
        emit FeeChangeCancelled(CHANGE_EXIT_FEE);
    }

    function proposeStressExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 200) revert InvalidFeeBps(feeBps);
        uint256 eta = block.timestamp + FEE_CHANGE_DELAY;
        pendingFeeChanges[CHANGE_STRESS_FEE] = PendingFeeChange(feeBps, eta);
        emit FeeChangeProposed(CHANGE_STRESS_FEE, feeBps, eta);
    }

    function executeStressExitFeeBps() external onlyOwner {
        PendingFeeChange memory p = pendingFeeChanges[CHANGE_STRESS_FEE];
        if (p.executeAfter == 0)             revert NoPendingChange(CHANGE_STRESS_FEE);
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter);
        delete pendingFeeChanges[CHANGE_STRESS_FEE];
        stressExitFeeBps = p.value;
        emit FeeChangeExecuted(CHANGE_STRESS_FEE, p.value);
        emit StressExitFeeBpsUpdated(p.value);
    }

    function cancelStressExitFeeBps() external onlyOwner {
        if (pendingFeeChanges[CHANGE_STRESS_FEE].executeAfter == 0) revert NoPendingChange(CHANGE_STRESS_FEE);
        delete pendingFeeChanges[CHANGE_STRESS_FEE];
        emit FeeChangeCancelled(CHANGE_STRESS_FEE);
    }

    /// @notice Activate or deactivate stress mode (higher exit fee). Instant — emergency use.
    function setStressMode(bool active) external onlyOwner {
        stressModeActive = active;
        emit StressModeToggled(active);
    }

    function proposeManagementFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        uint256 eta = block.timestamp + FEE_CHANGE_DELAY;
        pendingFeeChanges[CHANGE_MGMT_FEE] = PendingFeeChange(feeBps, eta);
        emit FeeChangeProposed(CHANGE_MGMT_FEE, feeBps, eta);
    }

    function executeManagementFeeBps() external onlyOwner {
        PendingFeeChange memory p = pendingFeeChanges[CHANGE_MGMT_FEE];
        if (p.executeAfter == 0)             revert NoPendingChange(CHANGE_MGMT_FEE);
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter);
        delete pendingFeeChanges[CHANGE_MGMT_FEE];
        managementFeeBps = p.value;
        emit FeeChangeExecuted(CHANGE_MGMT_FEE, p.value);
        emit ManagementFeeBpsUpdated(p.value);
    }

    function cancelManagementFeeBps() external onlyOwner {
        if (pendingFeeChanges[CHANGE_MGMT_FEE].executeAfter == 0) revert NoPendingChange(CHANGE_MGMT_FEE);
        delete pendingFeeChanges[CHANGE_MGMT_FEE];
        emit FeeChangeCancelled(CHANGE_MGMT_FEE);
    }

    function proposeFeeWallets(
        address _team,
        address _holdback,
        address _lp,
        address _reserve
    ) external onlyOwner {
        if (_team     == address(0)) revert ZeroAddress();
        if (_holdback == address(0)) revert ZeroAddress();
        if (_lp       == address(0)) revert ZeroAddress();
        if (_reserve  == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + FEE_CHANGE_DELAY;
        pendingWalletsChange = PendingWalletsChange(_team, _holdback, _lp, _reserve, eta);
        emit FeeWalletsProposed(_team, _holdback, _lp, _reserve, eta);
    }

    function executeFeeWallets() external onlyOwner {
        PendingWalletsChange memory p = pendingWalletsChange;
        if (p.executeAfter == 0)             revert NoPendingChange(bytes32("FEE_WALLETS"));
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter);
        delete pendingWalletsChange;
        teamWallet        = p.team;
        holdbackWallet    = p.holdback;
        lpSeedingWallet   = p.lp;
        reserveFundWallet = p.reserve;
        emit FeeWalletsUpdated(p.team, p.holdback, p.lp, p.reserve);
    }

    function cancelFeeWallets() external onlyOwner {
        if (pendingWalletsChange.executeAfter == 0) revert NoPendingChange(bytes32("FEE_WALLETS"));
        delete pendingWalletsChange;
        emit FeeWalletsCancelled();
    }

    /// @notice Propose replacing the Camelot DEX router (e.g., after a protocol upgrade).
    ///         48-hour timelock gives depositors time to react to an unexpected change.
    function proposeRouterUpdate(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        uint256 eta = block.timestamp + FEE_CHANGE_DELAY;
        pendingAddressChanges[CHANGE_ROUTER] = PendingAddressChange(newRouter, eta);
        emit AddressChangeProposed(CHANGE_ROUTER, newRouter, eta);
    }

    function executeRouterUpdate() external onlyOwner {
        PendingAddressChange memory p = pendingAddressChanges[CHANGE_ROUTER];
        if (p.executeAfter == 0)             revert NoPendingChange(CHANGE_ROUTER);
        if (block.timestamp < p.executeAfter) revert TimelockNotElapsed(p.executeAfter);
        delete pendingAddressChanges[CHANGE_ROUTER];
        camelotRouter = p.value;
        emit AddressChangeExecuted(CHANGE_ROUTER, p.value);
    }

    function cancelRouterUpdate() external onlyOwner {
        if (pendingAddressChanges[CHANGE_ROUTER].executeAfter == 0) revert NoPendingChange(CHANGE_ROUTER);
        delete pendingAddressChanges[CHANGE_ROUTER];
        emit AddressChangeCancelled(CHANGE_ROUTER);
    }

    /// @notice Set a per-deposit USDC cap. Set to 0 to remove the cap entirely.
    function setMaxDepositCap(uint256 cap) external onlyOwner {
        maxDepositUsdc = cap;
        emit MaxDepositCapUpdated(cap);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Mark a token as protected (true) or unprotected (false).
    ///         Call with true before deploying vault funds into a new protocol.
    ///         Call with false only after the position is fully unwound.
    function setProtectedToken(address token, bool _protected) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        protectedTokens[token] = _protected;
        emit ProtectedTokenUpdated(token, _protected);
    }

    /// @notice Batch version of setProtectedToken for initial setup.
    function setProtectedTokenBatch(address[] calldata tokens, bool _protected)
        external
        onlyOwner
    {
        require(tokens.length <= 50, "BGWVault: batch too large");
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            protectedTokens[tokens[i]] = _protected;
            emit ProtectedTokenUpdated(tokens[i], _protected);
        }
    }

    /// @notice Emergency: recover tokens accidentally sent to the vault.
    ///         Blocked for USDC (vault funds), BGW, BGW-GOV, and any token
    ///         registered as a vault position via setProtectedToken (C-02).
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyOwner
    {
        require(to != address(0),               "BGWVault: zero recipient");
        require(token != USDC,                  "BGWVault: cannot recover vault USDC");
        require(token != address(bgwToken),     "BGWVault: cannot recover BGW");
        require(token != address(govToken),     "BGWVault: cannot recover BGW-GOV");
        require(!protectedTokens[token],        "BGWVault: token is a vault position");
        IERC20(token).safeTransfer(to, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Deploy new USDC deposit into sleeves at target weights (70/25/5).
    function _deployToSleeves(uint256 usdcAmount) internal {
        uint256 toA = (usdcAmount * FeeLib.SLEEVE_A_BPS) / FeeLib.BPS_DENOM;
        uint256 toB = (usdcAmount * FeeLib.SLEEVE_B_BPS) / FeeLib.BPS_DENOM;
        uint256 toC = usdcAmount - toA - toB;

        sleeveAValue += toA;
        sleeveBValue += toB;
        sleeveCValue += toC;
    }

    /// @dev Reduce all NAV components proportionally when value leaves the vault.
    ///      Includes buybackAccumulator so totalNAV() tracks vault USDC correctly.
    function _reduceSleevesProRata(uint256 grossUsdc) internal {
        uint256 nav = totalNAV();
        if (nav == 0) return;

        sleeveAValue       -= (sleeveAValue       * grossUsdc) / nav;
        sleeveBValue       -= (sleeveBValue       * grossUsdc) / nav;
        sleeveCValue       -= (sleeveCValue       * grossUsdc) / nav;
        buybackAccumulator -= (buybackAccumulator * grossUsdc) / nav;
    }

    /// @dev Distribute performance fee across 6 recipients.
    ///      Uses try-transfer with pendingFees fallback so one bad wallet
    ///      cannot block the entire fee distribution (H-02).
    function _distributePerfFee(uint256 totalFee) internal {
        if (totalFee == 0) return;

        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(totalFee);

        _tryTransferFee(teamWallet,        s.team);
        _tryTransferFee(holdbackWallet,    s.holdback);
        _tryTransferFee(lpSeedingWallet,   s.lpSeed);
        _tryTransferFee(reserveFundWallet, s.reserve);

        buybackAccumulator += s.buyback;

        if (s.directBurn > 0) {
            _burnViaSwap(s.directBurn);
        }
    }

    /// @dev Attempt to push USDC fee to `recipient`. On failure, escrow in
    ///      pendingFees so the recipient can pull later via claimFees().
    function _tryTransferFee(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = USDC.call(
            abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount)
        );
        bool success = ok && (ret.length == 0 || abi.decode(ret, (bool)));
        if (!success) {
            pendingFees[recipient]   += amount;
            totalPendingFees         += amount; // C-03: track for totalNAV()
            lastFeeAccrual[recipient] = block.timestamp; // H-13: stale-fee clock
        }
    }

    /// @dev Swap USDC → BGW on Camelot and burn (used for direct-burn fee split).
    ///      minBGW is derived from vault NAV to resist sandwich attacks (C-03).
    ///      On swap failure, emits DirectBurnDeferred and leaves USDC in vault
    ///      rather than reverting and blocking the entire harvest (H-04/H-07).
    function _burnViaSwap(uint256 usdcAmount) internal {
        IERC20(USDC).forceApprove(camelotRouter, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        // NAV-based floor prevents the pool spot price being used as the sandwich target
        uint256 expectedBGW = (usdcAmount * 1e18) / navPerBGW();
        uint256 minBGW      = (expectedBGW * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
            FeeLib.BPS_DENOM;

        uint256 bgwBefore = bgwToken.balanceOf(address(this));

        try ICamelotRouter(camelotRouter)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                usdcAmount,
                minBGW,
                path,
                address(this),
                address(0),
                block.timestamp + 5 minutes
            )
        {
            uint256 received = bgwToken.balanceOf(address(this)) - bgwBefore;
            if (received > 0) bgwToken.burn(received);
        } catch (bytes memory reason) {
            // C-05: route deferred USDC to buyback accumulator so it isn't stranded.
            IERC20(USDC).forceApprove(camelotRouter, 0);
            buybackAccumulator += usdcAmount;
            emit DirectBurnDeferred(usdcAmount, reason); // H-08: include revert reason
        }
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
        uint256 gap     = highWaterMark - FeeLib.HWM_FLOOR;
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
        bool aboveHWM  = navPerBGW18() > _decayedHWM();
        uint256 feeBps = aboveHWM ? managementFeeBps : FeeLib.BASE_MGMT_FEE_BPS;

        uint256 fee = (nav * feeBps * elapsed) / (FeeLib.BPS_DENOM * 365 days);
        if (fee == 0) return;

        uint256 available = IERC20(USDC).balanceOf(address(this));
        if (fee > available) fee = available;
        if (fee == 0) return;

        _distributePerfFee(fee);
        _reduceSleevesProRata(fee);
        emit ManagementFeeCharged(fee, elapsed);
    }

    /// @dev Revert if a sleeve value move exceeds the time-weighted daily cap.
    ///      Growth cap: 10%/day × elapsed.  Shrink cap: 25%/day × elapsed.
    ///      Skipped when oldVal == 0 — first seeding of a sleeve is unconstrained.
    function _checkSleeveMove(uint256 oldVal, uint256 newVal, uint256 elapsed) internal pure {
        if (oldVal == 0) return;
        if (newVal >= oldVal) {
            uint256 maxGrow = (oldVal * FeeLib.MAX_SLEEVE_GROWTH_BPS_DAY * elapsed) /
                (FeeLib.BPS_DENOM * 1 days);
            require(newVal - oldVal <= maxGrow, "BGWVault: sleeve growth too fast");
        } else {
            uint256 maxShrink = (oldVal * FeeLib.MAX_SLEEVE_SHRINK_BPS_DAY * elapsed) /
                (FeeLib.BPS_DENOM * 1 days);
            require(oldVal - newVal <= maxShrink, "BGWVault: sleeve shrink too fast");
        }
    }

    /// @dev Calculate BGW-GOV to distribute to a new depositor.
    function _calcGovDistribution(uint256 bgwMinted) internal view returns (uint256) {
        uint256 communityPool = govToken.balanceOf(address(this));
        if (communityPool == 0 || bgwMinted == 0) return 0;

        uint256 govAmount = (bgwMinted * GOV_COMMUNITY_ALLOC) / GOV_TOTAL_SUPPLY;
        return govAmount > communityPool ? communityPool : govAmount;
    }
}
