# Bridgeway Protocol — Implementation Reference
*Spec v1.22 | Arbitrum One | Standalone Vault (no Enzyme)*

This file is the developer quick-reference. Read CLAUDE.md for project context.

---

## Contract Dependency Order (write in this order)

```
1. interfaces/  (no deps — pure ABI)
2. libraries/FeeLib.sol
3. tokens/BGWToken.sol
4. tokens/BGWGovToken.sol
5. tokens/FounderVesting.sol
6. core/BGWVault.sol          ← depends on 1-5
7. core/BridgewayAutomation.sol  ← depends on 6
8. scripts/deploy/
9. test/
```

---

## Interface Signatures

### IAaveV3.sol
```solidity
interface IAaveV3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}
```

### ILido.sol
```solidity
interface ILido {
    function submit(address referral) external payable returns (uint256 shares);
    function getPooledEthByShares(uint256 sharesAmount) external view returns (uint256);
}

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
}
```

### IMorphoBlue.sol
```solidity
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorphoBlue {
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares,
                    address onBehalf, bytes memory data) external returns (uint256, uint256);
    function withdraw(MarketParams memory marketParams, uint256 assets, uint256 shares,
                      address onBehalf, address receiver) external returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
}
```

### ICamelotRouter.sol
```solidity
interface ICamelotRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        address referrer,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts);
}
```

### IChainlinkAggregator.sol
```solidity
interface IChainlinkAggregator {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function decimals() external view returns (uint8);
}
```

### IPendle.sol
```solidity
interface IPendleRouter {
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
}
```

### IGMXRewardRouter.sol
```solidity
interface IGMXRewardRouter {
    function mintAndStakeGlp(address token, uint256 amount, uint256 minUsdg, uint256 minGlp)
        external returns (uint256);
    function unstakeAndRedeemGlp(address tokenOut, uint256 glpAmount, uint256 minOut, address receiver)
        external returns (uint256);
    function handleRewards(bool shouldClaimGmx, bool shouldStakeGmx, bool shouldClaimEsGmx,
        bool shouldStakeEsGmx, bool shouldStakeMplEth, bool shouldClaimWeth, bool shouldConvertWethToEth)
        external;
}
```

---

## BGWToken.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
// ERC-20 vault share token. Minted by BGWVault only.

contract BGWToken is ERC20, AccessControl, Pausable {

    bytes32 public constant MINTER_ROLE  = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE  = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLIST_ADMIN_ROLE = keccak256("BLACKLIST_ADMIN_ROLE");

    mapping(address => bool) public blacklisted;
    mapping(address => bool) public whitelist;

    // Events
    event Whitelisted(address indexed account, bool status);
    event Blacklisted(address indexed account, bool status);

    // Errors
    error NotWhitelisted(address account);
    error AccountBlacklisted(address account);

    constructor(address admin) ERC20("Bridgeway Index", "BGW") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(BLACKLIST_ADMIN_ROLE, admin);
    }

    // Only vault calls this
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused;

    // Holder or vault calls this (on redemption)
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE);

    // Public burn (buyback engine calls this)
    function burn(uint256 amount) external;

    // Admin whitelist management
    function setWhitelisted(address account, bool status) external onlyRole(DEFAULT_ADMIN_ROLE);
    function setBlacklisted(address account, bool status) external onlyRole(BLACKLIST_ADMIN_ROLE);

    // Override _beforeTokenTransfer to enforce whitelist + blacklist + pause
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override;
}
```

---

## BGWGovToken.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
// Fixed 100M supply governance token. Non-transferable from vesting contract.

contract BGWGovToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {

    uint256 public constant TOTAL_SUPPLY     = 100_000_000e18;
    uint256 public constant FOUNDER_ALLOC    = 70_000_000e18;
    uint256 public constant COMMUNITY_ALLOC  = 30_000_000e18;

    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    address public immutable founderVestingContract;
    address public immutable vault; // BGWVault — holds community pool

    // Events
    event CommunityDistributed(address indexed to, uint256 amount);

    constructor(address founderVesting, address vaultAddr, address admin)
        ERC20("Bridgeway Governance", "BGW-GOV") ERC20Permit("Bridgeway Governance") {
        // Mint 70M to vesting, 30M to vault
        _mint(founderVesting, FOUNDER_ALLOC);
        _mint(vaultAddr, COMMUNITY_ALLOC);
        founderVestingContract = founderVesting;
        vault = vaultAddr;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(DISTRIBUTOR_ROLE, vaultAddr);
    }

    // Called by BGWVault when user deposits
    // Sends proportional share of community pool to depositor
    function distributeToDepositor(address depositor, uint256 amount)
        external onlyRole(DISTRIBUTOR_ROLE);

    // ERC20Votes overrides
    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes);
    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes);
    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes);
}
```

---

## FounderVesting.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
// Vests 70M BGW-GOV to founder over 4 years with 1-year cliff.

contract FounderVesting is Ownable {

    address public immutable govToken;
    address public founder;
    uint256 public immutable vestingStart;
    uint256 public totalVested;       // total claimed so far

    // Schedule (cumulative):
    // Year 1 end: 0%
    // Year 2 end: 25% (17,500,000)
    // Year 3 end: 50% (35,000,000)
    // Year 4 end: 100% (70,000,000)

    uint256 public constant TOTAL   = 70_000_000e18;
    uint256 public constant Y2_CUM  = 17_500_000e18;
    uint256 public constant Y3_CUM  = 35_000_000e18;
    uint256 public constant Y4_CUM  = 70_000_000e18;

    // Events
    event Claimed(uint256 amount, uint256 totalClaimed);
    event FounderTransferred(address oldFounder, address newFounder);

    constructor(address _govToken, address _founder) Ownable(_founder) {
        govToken = _govToken;
        founder = _founder;
        vestingStart = block.timestamp;
    }

    // Returns tokens available to claim right now
    function vestedAmount() public view returns (uint256 vested);

    // Founder claims available tokens
    function claim() external;

    // Transfer founder role to successor (transfers 100% stake)
    function transferFounder(address newFounder) external onlyOwner;
}
```

---

## BGWVault.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
// Core vault. Holds all assets. Mints/burns BGW. Distributes BGW-GOV.

contract BGWVault is ReentrancyGuard, Pausable, Ownable2Step {

    // ── Tokens ──────────────────────────────────────────────────────────────
    BGWToken     public immutable bgwToken;
    BGWGovToken  public immutable govToken;

    // ── Fee Wallets ──────────────────────────────────────────────────────────
    address public teamWallet;
    address public holdbackWallet;
    address public lpSeedingWallet;
    address public reserveFundWallet;
    uint256 public buybackAccumulator;  // USDC pending buyback

    // ── Portfolio State ──────────────────────────────────────────────────────
    uint256 public totalDeposited;      // cumulative USDC deposited
    uint256 public highWaterMarkNAV;    // per-BGW, 18 decimals
    uint256 public lastSnapshotTime;
    uint256 public lastNAV;             // last computed total vault NAV in USD (6 dec)

    // Sleeve tracking (USD value)
    uint256 public sleeveAValue;
    uint256 public sleeveBValue;
    uint256 public sleeveCValue;

    // ── Whitelist ─────────────────────────────────────────────────────────────
    mapping(address => bool) public whitelist;

    // ── Events ────────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 usdcAmount, uint256 bgwMinted);
    event Redeemed(address indexed user, uint256 bgwBurned, uint256 usdcPaid);
    event HarvestCompleted(uint256 yieldUSD, uint256 perfFee);
    event BuybackExecuted(uint256 usdcSpent, uint256 bgwBurned);
    event WhitelistUpdated(address indexed account, bool status);
    event NAVUpdated(uint256 newNAV, uint256 bgwSupply);
    event ExitFeeChanged(uint256 newFeeBps);

    // ── Errors ─────────────────────────────────────────────────────────────────
    error NotWhitelisted();
    error ZeroAmount();
    error SlippageTooHigh();
    error StaleOracle();
    error SleeveCCapExceeded();
    error InsufficientBGW();
    error ExitFeeTooHigh();

    // ── Constructor ─────────────────────────────────────────────────────────────
    constructor(
        address _bgwToken,
        address _govToken,
        address _teamWallet,
        address _holdbackWallet,
        address _lpSeedingWallet,
        address _reserveFundWallet,
        address _admin
    ) Ownable(_admin);

    // ── Core User Functions ──────────────────────────────────────────────────────

    /// @notice Deposit USDC. Must be whitelisted. Mints BGW at current NAV.
    /// @param usdcAmount Amount of USDC (6 decimals) to deposit
    function deposit(uint256 usdcAmount) external nonReentrant whenNotPaused;

    /// @notice Redeem BGW for USDC. Burns BGW. Applies exit fee.
    /// @param bgwAmount Amount of BGW to redeem
    /// @param minUSDC   Minimum USDC to receive (slippage protection)
    function redeem(uint256 bgwAmount, uint256 minUSDC) external nonReentrant whenNotPaused;

    // ── NAV & Pricing ────────────────────────────────────────────────────────────

    /// @notice Returns current NAV per BGW token in USDC (6 decimals)
    function navPerBGW() public view returns (uint256);

    /// @notice Returns total vault NAV in USDC (6 decimals)
    function totalNAV() public view returns (uint256);

    /// @notice Fetches ETH/USD price from Chainlink; reverts if stale (>1hr)
    function getETHPrice() public view returns (uint256 price8dec);

    // ── Automation-only Functions (called by BridgewayAutomation) ────────────────

    /// @notice Record yield from staking/lending after harvest
    /// @param netYieldUSD Net yield in USDC (6 dec) after slippage/gas
    function recordHarvestYield(uint256 netYieldUSD) external onlyAutomation;

    /// @notice Trigger USDC→BGW buyback via Camelot, burn result
    /// @param usdcAmount USDC to spend from buybackAccumulator
    function executeBuyback(uint256 usdcAmount) external onlyAutomation;

    /// @notice Rebalance sleeves if drift exceeds thresholds
    function rebalance() external onlyAutomation;

    /// @notice Set the automation contract address (once)
    function setAutomation(address automation) external onlyOwner;

    // ── Admin Functions ───────────────────────────────────────────────────────────

    function setWhitelisted(address account, bool status) external onlyOwner;
    function setExitFeeBps(uint256 feeBps) external onlyOwner;    // 0–100 bps
    function setStressExitFeeBps(uint256 feeBps) external onlyOwner;
    function pause() external onlyOwner;
    function unpause() external onlyOwner;
    function updateFeeWallets(address team, address holdback, address lp, address reserve) external onlyOwner;

    // ── Internal Helpers ──────────────────────────────────────────────────────────

    function _deployToSleeves(uint256 usdcAmount) internal;
    function _computePerfFee(uint256 yieldUSD) internal returns (uint256 fee);
    function _distributePerfFee(uint256 fee) internal;
    function _govTokenDistribution(address depositor, uint256 bgwMinted) internal;
    function _currentExitFeeBps() internal view returns (uint256);
}
```

---

## BridgewayAutomation.sol — Full Interface

```solidity
// SPDX-License-Identifier: MIT
// Chainlink Automation compatible. Monthly harvest + daily buyback.

contract BridgewayAutomation is AutomationCompatibleInterface, Ownable {

    BGWVault public immutable vault;

    uint256 public lastHarvestTime;
    uint256 public constant HARVEST_INTERVAL = 30 days;
    uint256 public constant BUYBACK_THRESHOLD = 50e6;   // 50 USDC minimum

    // ── AutomationCompatible ──────────────────────────────────────────────────

    function checkUpkeep(bytes calldata)
        external view override returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external override;

    // ── Internal ──────────────────────────────────────────────────────────────

    function _harvestAll() internal;       // claim all rewards, convert to USDC
    function _rebalanceIfNeeded() internal;
    function _tryBuyback() internal;       // only if accumulator >= threshold
}
```

---

## FeeLib.sol — Interface

```solidity
library FeeLib {
    uint256 constant PERF_FEE_BPS       = 1500;  // 15%
    uint256 constant EXIT_FEE_BPS       = 10;    // 0.10%
    uint256 constant STRESS_EXIT_FEE    = 75;    // 0.75%
    uint256 constant BPS_DENOM          = 10_000;

    // 15% perf fee split
    uint256 constant TEAM_BPS           = 4500;  // 45%
    uint256 constant HOLDBACK_BPS       = 2000;  // 20%
    uint256 constant BUYBACK_BPS        = 1500;  // 15%
    uint256 constant LP_SEED_BPS        = 1000;  // 10%
    uint256 constant RESERVE_BPS        = 500;   // 5%
    uint256 constant DIRECT_BURN_BPS    = 500;   // 5%

    struct FeeSplit {
        uint256 team;
        uint256 holdback;
        uint256 buyback;
        uint256 lpSeed;
        uint256 reserve;
        uint256 directBurn;
    }

    function splitPerfFee(uint256 totalFee) internal pure returns (FeeSplit memory);
    function calcExitFee(uint256 grossUSDC, uint256 feeBps) internal pure returns (uint256);
    function calcPerfFee(uint256 yieldUSD) internal pure returns (uint256);
}
```

---

## Key Constants (Arbitrum One Mainnet)

```solidity
// Oracles
address constant CHAINLINK_ETH_USD  = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
address constant CHAINLINK_BTC_USD  = 0x6ce185539ad4fdaBde7b3f4ab9e4cDD9B8F7B26;

// Core tokens
address constant USDC   = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant WETH   = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant WBTC   = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
address constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;

// Yield protocols
address constant AAVE_POOL  = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
address constant MORPHO     = 0x33333aea097c193e912c8f56c8a3e5d77e4b69f0;  // verify

// DEX
address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

// Staking
address constant LIDO_STETH = 0x5979D7b546E38E414F7E9822514be443A4800529;  // wstETH on Arb

// Chainlink Automation Registry (Arb)
address constant AUTOMATION_REGISTRY = 0x75c0530885F385721fddA23C539AF3701d6183D4;
```

---

## Deployment Checklist

### Before deployment:
- [ ] Replace all placeholder wallet addresses with real multisig addresses
- [ ] Set `FOUNDER_ADDRESS` to Vip's wallet
- [ ] Confirm LINK balance for Chainlink Automation (~10–20 LINK)
- [ ] Run `forge test --fork-url $ARBITRUM_RPC` — all tests pass
- [ ] Verify all Chainlink feed addresses still active on Arbitrum

### Deployment order:
```bash
# 1. Deploy tokens (no vault address needed yet)
forge script scripts/deploy/01_DeployTokens.s.sol --rpc-url $ARBITRUM_RPC --broadcast

# 2. Deploy vault (needs token addresses from step 1)
forge script scripts/deploy/02_DeployVault.s.sol --rpc-url $ARBITRUM_RPC --broadcast

# 3. Wire automation + whitelist founder
forge script scripts/deploy/03_SetupAutomation.s.sol --rpc-url $ARBITRUM_RPC --broadcast
```

### After deployment:
- [ ] Call `bgwToken.grantRole(MINTER_ROLE, vaultAddress)`
- [ ] Call `govToken.grantRole(DISTRIBUTOR_ROLE, vaultAddress)`
- [ ] Call `vault.setWhitelisted(founderAddress, true)`
- [ ] Call `vault.setAutomation(automationAddress)`
- [ ] Verify contracts on Arbiscan
- [ ] Register automation upkeep with Chainlink
- [ ] Make first deposit to bootstrap NAV at 1:1

---

## Test Scenarios

### BGWToken
- [ ] Only MINTER_ROLE can mint
- [ ] Non-whitelisted address cannot receive transfer
- [ ] Blacklisted address reverts on all transfers
- [ ] Paused state blocks mint + transfer
- [ ] Public burn works

### BGWVault — deposit
- [ ] Non-whitelisted reverts
- [ ] First deposit: NAV=1.00, mints exact USDC amount of BGW
- [ ] Second deposit uses updated NAV
- [ ] BGW-GOV distributed proportionally on deposit
- [ ] Sleeves receive correct proportions (70/25/5)

### BGWVault — redeem
- [ ] Redeem burns correct BGW
- [ ] Exit fee 0.10% applied
- [ ] Performance fee only applied if above high-water mark
- [ ] Small redemption (<$10k) fully in USDC
- [ ] High-water mark not updated on loss

### FeeLib
- [ ] Split sums to exactly 100%
- [ ] Exit fee calculation correct at 0.10% and 0.75%
- [ ] Perf fee is 15% of yield

### Automation
- [ ] checkUpkeep returns false before 30 days
- [ ] performUpkeep reverts if not 30 days elapsed
- [ ] Buyback only fires when accumulator >= threshold

---

## Solidity Version & Dependencies

```toml
# foundry.toml
[profile.default]
src      = "contracts"
out      = "out"
libs     = ["lib"]
solc     = "0.8.24"
optimizer = true
optimizer_runs = 200

[rpc_endpoints]
arbitrum = "${ARBITRUM_RPC}"
```

```bash
# Install deps
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2
forge install smartcontractkit/chainlink-brownie-contracts
```

### Imports used across contracts:
```solidity
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
```
