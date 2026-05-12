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
    // State — whitelist
    // ─────────────────────────────────────────────────────────────────────────

    mapping(address => bool) public whitelist;

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
    event DirectBurnDeferred(uint256 usdcAmount);
    event SleeveValuesUpdated(uint256 sleeveA, uint256 sleeveB, uint256 sleeveC);
    event ManagementFeeCharged(uint256 feeUsdc, uint256 elapsed);
    event ManagementFeeBpsUpdated(uint256 newBps);
    event ExitFeeBpsUpdated(uint256 newBps);
    event StressExitFeeBpsUpdated(uint256 newBps);
    event WhitelistUpdated(address indexed account, bool status);
    event StressModeToggled(bool active);
    event AutomationSet(address indexed automation);
    event AutomationRevoked(address indexed old);
    event FeeWalletsUpdated(address team, address holdback, address lp, address reserve);
    event ProtectedTokenUpdated(address indexed token, bool protected);

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

    /// @notice Total vault NAV: sum of all sleeve values + buyback accumulator (USDC, 6 dec).
    function totalNAV() public view returns (uint256) {
        return sleeveAValue + sleeveBValue + sleeveCValue + buybackAccumulator;
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

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

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

        bgwToken.adminBurn(msg.sender, bgwAmount);

        _reduceSleevesProRata(grossUsdc);

        if (perfFeeUsdc > 0) {
            _distributePerfFee(perfFeeUsdc);
            highWaterMark     = navPerBGW18();
            lastHWMUpdateTime = block.timestamp;
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
        // Sanity bounds (C-01 partial mitigation):
        //   1. Reported sleeve total must not exceed 2× pre-harvest NAV.
        //   2. Claimed yield must not exceed actual vault USDC balance —
        //      automation cannot claim more than what physically arrived.
        uint256 reportedTotal = newSleeveA + newSleeveB + newSleeveC;
        require(reportedTotal <= totalNAV() * 2, "BGWVault: sleeve report too high");
        require(
            netYieldUsdc <= IERC20(USDC).balanceOf(address(this)),
            "BGWVault: yield exceeds balance"
        );

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
            highWaterMark     = navPerBGW18();
            lastHWMUpdateTime = block.timestamp;
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

        IERC20(USDC).forceApprove(CAMELOT_ROUTER, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        // NAV-based floor: expectedBGW = usdcAmount / navPerBGW (both 6 dec → 18 dec result)
        uint256 expectedBGW = (usdcAmount * 1e18) / navPerBGW();
        uint256 minBGW      = (expectedBGW * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
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
    ) external whenNotPaused onlyAutomation {
        sleeveAValue = newSleeveA;
        sleeveBValue = newSleeveB;
        sleeveCValue = newSleeveC;
        emit SleeveValuesUpdated(newSleeveA, newSleeveB, newSleeveC);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin functions
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set or replace the automation contract address.
    ///         Replaceable so a compromised automation contract can be rotated.
    function setAutomation(address _automation) external onlyOwner {
        if (_automation == address(0)) revert ZeroAddress();
        automation = _automation;
        emit AutomationSet(_automation);
    }

    /// @notice Revoke the current automation contract (sets to address(0)).
    ///         Use in emergencies to stop all harvest/buyback until a new
    ///         automation address is set via setAutomation.
    function revokeAutomation() external onlyOwner {
        address old = automation;
        automation = address(0);
        emit AutomationRevoked(old);
    }

    /// @notice Fee recipients pull any USDC that failed to push automatically.
    function claimFees() external nonReentrant {
        uint256 amount = pendingFees[msg.sender];
        if (amount == 0) return;
        pendingFees[msg.sender] = 0;
        IERC20(USDC).safeTransfer(msg.sender, amount);
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
    function setExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        exitFeeBps = feeBps;
        emit ExitFeeBpsUpdated(feeBps);
    }

    /// @notice Set stress exit fee (max 200 bps = 2 %).
    function setStressExitFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 200) revert InvalidFeeBps(feeBps);
        stressExitFeeBps = feeBps;
        emit StressExitFeeBpsUpdated(feeBps);
    }

    /// @notice Activate or deactivate stress mode (higher exit fee).
    function setStressMode(bool active) external onlyOwner {
        stressModeActive = active;
        emit StressModeToggled(active);
    }

    /// @notice Set annual management fee (max 100 bps = 1.00 %).
    function setManagementFeeBps(uint256 feeBps) external onlyOwner {
        if (feeBps > 100) revert InvalidFeeBps(feeBps);
        managementFeeBps = feeBps;
        emit ManagementFeeBpsUpdated(feeBps);
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
            pendingFees[recipient] += amount;
        }
    }

    /// @dev Swap USDC → BGW on Camelot and burn (used for direct-burn fee split).
    ///      minBGW is derived from vault NAV to resist sandwich attacks (C-03).
    ///      On swap failure, emits DirectBurnDeferred and leaves USDC in vault
    ///      rather than reverting and blocking the entire harvest (H-04/H-07).
    function _burnViaSwap(uint256 usdcAmount) internal {
        IERC20(USDC).forceApprove(CAMELOT_ROUTER, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = address(bgwToken);

        // NAV-based floor prevents the pool spot price being used as the sandwich target
        uint256 expectedBGW = (usdcAmount * 1e18) / navPerBGW();
        uint256 minBGW      = (expectedBGW * (FeeLib.BPS_DENOM - MAX_SLIPPAGE_BPS)) /
            FeeLib.BPS_DENOM;

        uint256 bgwBefore = bgwToken.balanceOf(address(this));

        try ICamelotRouter(CAMELOT_ROUTER)
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
        } catch {
            IERC20(USDC).forceApprove(CAMELOT_ROUTER, 0);
            emit DirectBurnDeferred(usdcAmount);
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

        // Waive management fee when vault is underwater (H-06)
        if (navPerBGW18() <= _decayedHWM()) return;

        uint256 elapsed = block.timestamp - lastHarvestTime;
        if (elapsed == 0) return;

        // Cap at 90 days to prevent excessive fee accrual after automation downtime
        if (elapsed > 90 days) elapsed = 90 days;

        uint256 fee = (nav * managementFeeBps * elapsed) / (FeeLib.BPS_DENOM * 365 days);
        if (fee == 0) return;

        uint256 available = IERC20(USDC).balanceOf(address(this));
        if (fee > available) fee = available;
        if (fee == 0) return;

        _distributePerfFee(fee);
        _reduceSleevesProRata(fee);
        emit ManagementFeeCharged(fee, elapsed);
    }

    /// @dev Calculate BGW-GOV to distribute to a new depositor.
    function _calcGovDistribution(uint256 bgwMinted) internal view returns (uint256) {
        uint256 communityPool = govToken.balanceOf(address(this));
        if (communityPool == 0 || bgwMinted == 0) return 0;

        uint256 govAmount = (bgwMinted * GOV_COMMUNITY_ALLOC) / GOV_TOTAL_SUPPLY;
        return govAmount > communityPool ? communityPool : govAmount;
    }
}
