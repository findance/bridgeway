# Bridgeway (BGW) — Smart Contract Deployment

On-chain hybrid index fund automation wrapper built on Enzyme Finance.
Handles performance fees, 6-way fee splits, monthly buyback snapshots, and hourly/daily BGW burns.

---

## Architecture

```
User deposits USDC
        ↓
Enzyme Finance Vault  (asset custody, NAV, rebalancing)
        ↓  sweeps yield fees to ↓
BridgewayAutomationWrapper  (this contract)
        ↓  splits fees 6 ways ↓
45% Team | 20% Holdback | 15% Buyback accumulator
10% LP   |  5% Reserve  |  5% Burn (BGW bought + burned)
        ↓  monthly snapshot ↓
Daily / hourly BGW buyback + burn  (auto via Chainlink Automation)
```

---

## Fee Model

| Fee | Rate |
|-----|------|
| Annual management | 0.50% (via Enzyme) |
| Entry fee | 0.10% (via Enzyme) |
| Exit fee | 0.10% (via Enzyme) |
| Performance fee | 15% of staking yield (owner-reported) |
| Buyback ops cut | 0.1% per execution (self-funding Chainlink) |

---

## What Claude Can Run vs What You Run

| Task | Who |
|------|-----|
| Compile contracts | Claude or you |
| Run full test suite | Claude or you |
| Deploy to testnet | **You** (needs private key) |
| Fill in .env | **You** (your keys only) |
| Register Chainlink Automation | **You** (browser wallet) |
| Create Enzyme vault | **You** (browser wallet) |

---

## Quick Start

### 1 — Install dependencies
```bash
npm install
```

### 2 — Configure environment
```bash
cp .env.example .env
# Edit .env and fill in all values
```

### 3 — Compile
```bash
npm run compile
# Expected: Compiled X Solidity files successfully
```

### 4 — Run tests (no wallet needed)
```bash
npm test
# Expected: 25 passing
```

### 5 — Deploy to Arbitrum Sepolia
```bash
# Get free testnet ETH first: https://faucet.triangleplatform.com/arbitrum/sepolia
npm run deploy:testnet
# Saves proxy address to deployments.json
```

---

## Post-Deploy Steps

### Verify on Arbiscan
```bash
npm run verify:testnet
```

### Register Chainlink Automation
1. Go to [automation.chain.link](https://automation.chain.link)
2. Register New Upkeep → **Custom Logic**
3. Contract address: proxy address from `deployments.json`
4. Fund with ~5 LINK (testnet); the 0.1% ops cut tops it up over time

### Create Enzyme Vault
1. Go to [app.enzyme.finance](https://app.enzyme.finance) → Create Vault → Arbitrum
2. Add basket assets (top 20 cryptos + 5 stablecoins)
3. Set fee recipient = your proxy contract address

### Test fee distribution
```bash
npx hardhat console --network arbitrumSepolia
```
```js
const w = await ethers.getContractAt("BridgewayAutomationWrapper", "YOUR_PROXY")
await w.recordStakingYield(ethers.parseUnits("1000", 6))  // $1000 yield
```

---

## Upgrade Contract
```bash
npm run upgrade:testnet
```

---

## Security Properties

- UUPS upgradeable — owner only
- ReentrancyGuard on all state-changing functions
- Pausable emergency stop
- Blacklist mapping for AML compliance
- `forceApprove` (reset-to-0 before set) on router approvals
- Dynamic Chainlink slippage with stale oracle fallback (3%)
- Constructor zero-address validation on all five addresses
- `rescueTokens()` cannot touch USDC or BGW

---

## Project Structure

```
contracts/
  BridgewayAutomationWrapper.sol   ← main contract (UUPS proxy target)
  mocks/
    MockEnzymeVault.sol
    MockUSDC.sol
    MockBGWToken.sol
    MockCamelotRouter.sol
    MockPriceFeed.sol
scripts/
  deploy.js
  upgrade.js
  verify.js
test/
  BridgewayWrapper.test.js
.env.example
hardhat.config.js
```

---

## Known Risks (read before mainnet)

1. **Regulatory** — BGW is a security in most jurisdictions. Get legal advice before public launch.
2. **Ondo SPYon/QQQon** — KYC-gated; cannot be wrapped permissionlessly. Drop or replace the equity layer.
3. **Owner trust** — `recordStakingYield` is owner-reported. Add vault-introspection or multi-sig before mainnet.
4. **No timelock** — UUPS + single-key owner is fine for testnet only. Add multi-sig + 48h timelock for mainnet.
5. **Audit required** — chat-based iteration is not a security audit. Engage Trail of Bits / OpenZeppelin / Spearbit before mainnet.
