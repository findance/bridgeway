# Bridgeway Protocol — Claude Code Project Context

> This file is read automatically by Claude Code (in VSCode or terminal).
> It gives full project context so you can continue implementation without re-explaining anything.

---

## What This Project Is

Bridgeway is a **personal, closed-group crypto index vault** on Arbitrum One.
- Whitelist-only: only founder + personally invited contacts can deposit
- Standalone vault: no Enzyme Finance, no third-party vault infrastructure
- Fully automated: Chainlink Automation handles monthly harvest and daily buybacks
- Source code is **private** — on-chain data is publicly readable

Full specification: `bridgeway_spec_v1.22.md`

---

## Current Status

- [x] Protocol specification complete (v1.22)
- [ ] Smart contracts — NOT YET WRITTEN
- [ ] Tests — NOT YET WRITTEN
- [ ] Deployment scripts — NOT YET WRITTEN
- [ ] Frontend dashboard — NOT YET WRITTEN

**Start here:** Write contracts in order listed in the architecture section below.

---

## Contract Architecture

### Contracts to Build (in this order)

```
contracts/
├── tokens/
│   ├── BGWToken.sol              ← ERC-20 vault share token
│   ├── BGWGovToken.sol           ← Governance token (fixed 100M supply)
│   └── FounderVesting.sol        ← 4-year vesting for founder's 70M BGW-GOV
├── core/
│   ├── BGWVault.sol              ← Main vault (deposit, redeem, asset tracking)
│   └── BridgewayAutomation.sol  ← Chainlink Automation (harvest, buyback)
├── interfaces/
│   ├── IAaveV3.sol
│   ├── ILido.sol
│   ├── IMorphoBlue.sol
│   ├── ICamelotRouter.sol
│   └── IChainlinkAggregator.sol
└── libraries/
    └── FeeLib.sol                ← Fee calculation helpers

scripts/
├── deploy/
│   ├── 01_DeployTokens.s.sol
│   ├── 02_DeployVault.s.sol
│   └── 03_SetupAutomation.s.sol
└── test/
    ├── BGWToken.t.sol
    ├── BGWVault.t.sol
    └── Automation.t.sol
```

---

## Key Design Decisions

### BGWToken.sol
- Standard ERC-20, 18 decimals, Arbitrum One
- `MINTER_ROLE` held exclusively by BGWVault contract
- Transfers restricted: `require(whitelist[to], "Recipient not whitelisted")`
- Pausable, blacklistable (emergency use only)
- Immutable contract — no upgradeability on the token itself
- First deposit bootstraps at 1:1 ($1.00 NAV per BGW)

### BGWGovToken.sol
- Fixed supply: exactly 100,000,000 BGW-GOV minted at deploy, never again
- 70,000,000 → sent to `FounderVesting.sol` at deploy
- 30,000,000 → held by `BGWVault.sol` for proportional distribution to depositors
- No transfer restrictions (governance token, freely tradeable between whitelisted users)
- Distribution formula: `bgwGovToSend = (bgwMinted / totalBGWSupply) * 30_000_000e18`

### FounderVesting.sol
- Holds 70M BGW-GOV on behalf of founder
- Cliff: 12 months (nothing claimable before this)
- Linear vesting: months 13–48
- `claim()` callable only by founder address
- Vesting schedule:
  - End of year 1: 0% (cliff)
  - End of year 2: 25% = 17,500,000
  - End of year 3: 50% = 35,000,000
  - End of year 4: 100% = 70,000,000

### BGWVault.sol (most complex — write last among core contracts)
- Holds all vault assets directly (no external vault)
- Whitelist mapping: `mapping(address => bool) public whitelist`
- `onlyWhitelisted` modifier on `deposit()` and `redeem()`
- Only founder multisig can call `addToWhitelist()` / `removeFromWhitelist()`
- Tracks per-asset: `purchasedAmount` and `compoundedAmount` separately
- High-water mark: `uint256 public highWaterMarkPerBGW` (starts at 1e18 = $1.00)
- Performance fee: 15% on yield above HWM only
- Exit fee: 10 bps (0.10%) on all redemptions; 75 bps during crash
- `getAssetBreakdown(address asset)` — public, readable by anyone

### BridgewayAutomation.sol
- Implements Chainlink `AutomationCompatibleInterface`
- `checkUpkeep()` returns true for:
  - Monthly harvest (1st of month)
  - Reserve-injection buyback (when accumulator clears threshold and cooldown)
- `performUpkeep()` dispatches to `harvestAndCompound()` or `executeBuyback()`
- Buyback: reserve USDC is injected into sleeves, then temporary BGW is minted and burned without BGW-GOV minting

---

## Fee Distribution (Hardcoded in BGWVault)

Performance fee = 15% of yield above high-water mark.

| Recipient           | % of Fee | Purpose                          |
|---------------------|----------|----------------------------------|
| teamWallet          | 45%      | Operations                       |
| holdbackWallet      | 20%      | Protocol reserve                 |
| buybackAccumulator  | 15%      | USDC saved for reserve injection |
| lpSeedingWallet     | 10%      | DEX liquidity                    |
| reserveFundWallet   | 5%       | Insurance buffer                 |
| directBurnAmount    | 5%       | Added to reserve injection queue |

**Wallet addresses** — set in constructor, changeable only by founder multisig.
These are PLACEHOLDER values — replace before deployment:
```solidity
address public teamWallet        = 0x0000000000000000000000000000000000000001;
address public holdbackWallet    = 0x0000000000000000000000000000000000000002;
address public lpSeedingWallet   = 0x0000000000000000000000000000000000000003;
address public reserveFundWallet = 0x0000000000000000000000000000000000000004;
// buybackAccumulator is held in-contract as USDC balance.
// executeBuyback injects it into sleeves, then mints and burns temporary BGW.
```

---

## Portfolio Sleeve Allocations

| Sleeve | Target % | Assets | Yield Protocol |
|--------|----------|--------|----------------|
| A — Growth | 70% | Top 15 cryptos (BTC, ETH, SOL, BNB, XRP, DOGE, TON, ADA, TRX, AVAX, SHIB, SUI, LINK, BCH, OP) | Lido (stETH), Rocket Pool (rETH), Aave V3 |
| B — Stability | 25% | USDC, USDT, DAI, FRAX | Aave V3, Morpho Blue |
| C — Alpha | 5% | Pendle PT-stETH (1.5%), GMX GLP (1.5%), Morpho Blue (1.0%), Restaking (0.5%), USDe/sUSDe (0.5–1.0%) | Protocol-native |

**Rebalancing triggers:**
- Sleeve-level drift > 5% from target → rebalance
- Sleeve C drift > 2% → rebalance (tighter)
- Sleeve A: only `purchasedAmount` rebalances — `compoundedAmount` never sold

---

## Arbitrum One Contract Addresses (Production)

```solidity
// Chainlink Price Feeds (Arbitrum One)
address constant CHAINLINK_ETH_USD  = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
address constant CHAINLINK_BTC_USD  = 0x6ce185560a4963c78a5c59Ef30e3A93Ccc2E00B;
address constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD;

// Tokens (Arbitrum One)
address constant USDC    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant WETH    = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant WBTC    = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;
address constant stETH   = 0x5979D7b546E38E414F7E9822514be443A4800529; // wstETH on Arb
address constant USDT    = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

// DEX (Arbitrum One)
address constant CAMELOT_ROUTER = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

// Aave V3 (Arbitrum One)
address constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

// Chainlink Automation Registry (Arbitrum One)
address constant AUTOMATION_REGISTRY = 0x75c0530885F385721fddA23C539AF3701d6183D4;
```

---

## Governance & Control

- Founder multisig: 3-of-5 Gnosis Safe (set up before mainnet)
- BGW-GOV voting floor: founder keeps minimum 50.5%
- Veto power: founder on all critical decisions
- If founder does NOT vote: simple majority (>50%) of BGW-GOV decides
- Critical decisions: upgrades, fee changes, whitelist policy, Reserve Fund large disbursements

---

## Development Environment

```bash
# Recommended stack
forge init bridgeway           # Foundry
forge install OpenZeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink

# Build
forge build

# Test
forge test -vvv

# Deploy to Arbitrum Sepolia (testnet first!)
forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC \
  --private-key $PRIVATE_KEY \
  --broadcast

# Arbitrum Sepolia RPC
# https://sepolia-rollup.arbitrum.io/rpc
# Chain ID: 421614
```

---

## Important Rules for Claude Code

1. **Write tests for every contract function** — this handles real money
2. **Testnet first, always** — never deploy directly to mainnet
3. **No upgradeability on BGWToken** — immutable by design
4. **The `onlyWhitelisted` modifier must appear on `deposit()`, `redeem()`, and BGWToken transfers**
5. **ReentrancyGuard on all state-changing vault functions**
6. **All fee math uses basis points (bps)** — 10000 = 100%, 15 bps = 0.15%
7. **High-water mark updates AFTER fee distribution, not before**
8. **`compoundedAmount` is never included in rebalancing calculations for Sleeve A**
9. **BGW-GOV distribution happens inside `deposit()` atomically with BGW minting**
10. **The 5% direct-burn share is queued into the buyback accumulator for reserve injection**

---

## Continuing This Work

If opening this project fresh in Claude Code:
1. Read this file (`CLAUDE.md`) — you are reading it now
2. Read `bridgeway_spec_v1.22.md` for the full protocol spec
3. Read `IMPLEMENTATION_REFERENCE.md` for contract interfaces and function signatures
4. Check which contracts already exist in `contracts/` and continue from where work left off
5. Always run `forge test` before considering any contract complete

---

*Bridgeway v1.22 — Personal project. Whitelist-only. Experimental. Not investment advice.*
