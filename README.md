# Bridgeway Protocol (BGW) — v1.22

A whitelist-only, founder-operated crypto index vault on Arbitrum One.  
Standalone smart contracts — no Enzyme Finance, no third-party vault infrastructure.

---

## Architecture

```
Whitelisted depositor
        │  USDC
        ▼
    BGWVault  ──────────────────────────────────────────────────┐
    │  Mints BGW (share token) 1:1 at first deposit            │
    │  Distributes BGW-GOV governance tokens to depositors      │
    │  Tracks three portfolio sleeves:                          │
    │    A — 70%  Growth     (BTC, ETH, SOL … via Aave/LSTs)   │
    │    B — 25%  Stability  (USDC, USDT, DAI … via Aave/Morpho│
    │    C —  5%  Alpha      (Pendle, GMX, Morpho, restaking)   │
    │                                                           │
    │  Monthly harvest  ◄── BridgewayAutomation (Chainlink)    │
    │  Buyback & burn   ◄── BridgewayAutomation (Chainlink)    │
    └───────────────────────────────────────────────────────────┘

BGWToken      — ERC-20 vault share (18 dec), whitelist-transfer-only
BGWGovToken   — Fixed 100 M governance token; 70 M vested to founder,
                30 M distributed to depositors at fixed rate
FounderVesting — 1-year cliff, linear vesting months 13–48
```

---

## Contract Layout

```
contracts/
├── core/
│   ├── BGWVault.sol              ← main vault (deposit, redeem, harvest, buyback)
│   └── BridgewayAutomation.sol  ← Chainlink Automation upkeep
├── tokens/
│   ├── BGWToken.sol              ← ERC-20 share token (whitelist + blacklist + pause)
│   ├── BGWGovToken.sol           ← governance token (whitelist-transfer, ERC20Votes)
│   └── FounderVesting.sol        ← cliff/linear vesting for founder's 70 M BGW-GOV
├── interfaces/
│   ├── IAaveV3.sol
│   ├── ICamelotRouter.sol
│   ├── IChainlinkAggregator.sol
│   ├── ILido.sol
│   └── IMorphoBlue.sol
├── libraries/
│   └── FeeLib.sol                ← fee math helpers (bps constants, split logic)
└── mocks/
    └── MockCamelotRouter.sol     ← test-only swap simulator

test/
├── BGWToken.t.sol
├── BGWVault.t.sol
└── Automation.t.sol
```

---

## Fee Model

### Performance fee — 15% of yield above high-water mark

| Recipient          | Share |
|--------------------|-------|
| Team wallet        | 45 %  |
| Holdback wallet    | 20 %  |
| Buyback accumulator| 15 %  |
| LP seeding wallet  | 10 %  |
| Reserve fund       |  5 %  |
| Direct BGW burn    |  5 %  |

### Management fee — accrued each harvest

| Condition          | Rate       |
|--------------------|------------|
| NAV > HWM          | 0.50 %/yr  |
| NAV ≤ HWM          | 0.10 %/yr (floor — team always has operational income) |

### Exit fee

| Mode     | Rate    |
|----------|---------|
| Normal   | 0.10 %  |
| Stress   | 0.75 %  |

Fee-level changes (BPS) and wallet address changes take effect only after a **48-hour timelock** (propose → execute pattern).

---

## Automation (Chainlink)

`BridgewayAutomation` implements `AutomationCompatibleInterface`.

| Trigger   | Condition |
|-----------|-----------|
| Harvest   | Every 30 days |
| Buyback   | accumulator ≥ 500 USDC **AND** ≥ 30 days since last buyback |

Both conditions must be satisfied simultaneously for a buyback — whichever is last wins.

---

## Security Properties

All findings from an independent security audit (v1.22) have been resolved:

| Finding | Fix |
|---------|-----|
| C-01 | `recordHarvest` sanity bounds — yield cannot exceed vault USDC balance |
| C-02 | Protected-token registry blocks aToken / LST drain via `recoverToken` |
| C-03 | NAV-based `minBGW` floor on buyback swaps — sandwich-attack resistant |
| C-04 | `whenNotPaused` on all automation-facing state-changing functions |
| C-05 | `minBgwOut` slippage guard on `deposit()` |
| H-02 | Fee-wallet transfers use pull-escrow (`pendingFees`) on failure |
| H-03 | Burns bypass pause; transfers and mints still check `whenNotPaused` |
| H-04 | Single try/catch on Camelot swap; deferred burn on failure |
| H-05 | `_reduceSleevesProRata` includes `buybackAccumulator` — NAV invariant preserved |
| H-06 | Management fee gated: base 0.10%/yr always; full 0.50%/yr only above HWM |
| H-07 | Buyback is non-reverting — vault state never blocked by DEX failure |
| H-08 | `setWhitelistedBatch` capped at 200 entries |
| H-09 | Redeem uses `adminBurn` (MINTER_ROLE) not allowance-based `burnFrom` |
| H-10 | `lastHarvestTime` initialised to `block.timestamp` at deploy |
| H-11 | BGW-GOV transfers restricted to vault-whitelisted addresses |
| H-12 | `FounderVesting.claim()` blocked during Ownable2Step pending transfer |
| M-01 | `ReentrancyGuard` on `executeBuyback` |
| M-03 | 48-hour timelock on all fee-level and wallet-address setters |
| M-04 | Management fee accrual capped at 90 days elapsed |
| M-06 | Infrastructure addresses (USDC, router, oracle) injected via constructor — no bytecode hardcoding; Camelot router owner-upgradeable with 48-hour timelock |
| M-07 | Buyback threshold raised to 500 USDC with mandatory 30-day interval |
| L-07 | `recoverToken` zero-address recipient check |

Additional hardening: `Ownable2Step` throughout, `SafeERC20.forceApprove` on router approvals, `nonReentrant` on all vault state-changers.

---

## Development

### Prerequisites

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
# Expected: 86 tests passing
```

### Deploy (testnet first)

```bash
# Set env vars
export ARBITRUM_SEPOLIA_RPC=https://sepolia-rollup.arbitrum.io/rpc
export PRIVATE_KEY=0x...

forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast

forge script scripts/deploy/02_DeployVault.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast

forge script scripts/deploy/03_SetupAutomation.s.sol \
  --rpc-url $ARBITRUM_SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast
```

---

## Governance

- Founder multisig: 3-of-5 Gnosis Safe
- BGW-GOV voting: founder retains ≥ 50.5 % floor
- Critical decisions (upgrades, fee changes, whitelist policy): founder veto

---

## Known Risks (read before mainnet)

1. **Regulatory** — BGW may be classified as a security. Get legal advice before any public launch.
2. **Owner trust** — harvest yield is reported by the automation contract. Wire vault-introspection or use a multi-sig before mainnet.
3. **Audit scope** — one independent audit completed on v1.22. Additional review recommended before mainnet.
4. **Testnet first** — never deploy directly to mainnet. Deploy to Arbitrum Sepolia and run full integration tests.
