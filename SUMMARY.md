# Bridgeway (BGW) — Project Summary

## What it is

An on-chain index fund token that gives holders a single ERC-20 (BGW) representing a basket of:

- **Crypto layer** — top 10 non-stable cryptocurrencies by market cap, market-cap weighted with 30% max / 3% min per asset
- **Stable layer** — trusted yield-capable stablecoin exposures deployed for conservative yield
- **Alpha layer** — capped higher-yield strategies limited to 5% of NAV

NAV is accumulating — staking and lending rewards land in the vault and raise the per-token value rather than being distributed.

## Architecture

```
User deposits USDC
        ↓
BGWVault  (standalone, non-Enzyme)
   - 70/25/5 sleeve allocation with adapters
   - 4-way fee split
   - Reserve-injection buyback
        ↓
BridgewayAutomation
   - Harvest check
   - Auto buyback execution with threshold and cooldown
        ↓
Underlying basket  (top 10 non-stable crypto + top 5 trusted stables + capped alpha strategies)
```

## Final fee model

| Fee | Rate |
|-----|------|
| Annual management | 0.50% above HWM, 0.10% base below HWM |
| Exit | 0.10% normal, 0.75% stress mode |
| Performance | 15% of yield above HWM |

## Fee split (every fee taken)

| Wallet | Share | Type | Purpose |
|--------|-------|------|---------|
| Team | 45% | USDC | Salaries, dev, legal |
| Holdback | 30% | USDC | Ops, gas, oracles |
| Buyback | 15% | USDC | Reserve injection + temporary BGW mint/burn |
| Reserve | 10% | USDC | User protection |

## Buyback engine

- Automation executes reserve injection when the buyback accumulator clears threshold and cooldown
- Buyback execution does not trade against BGW/USDC liquidity
- Automation triggers the execution path

## Stack

- **Chain**: Arbitrum (mainnet target; Arbitrum Sepolia for testnet)
- **Vault**: Standalone BGWVault
- **DEX**: Camelot
- **Oracle**: Chainlink price feeds
- **Automation**: Chainlink Automation
- **Contract**: Solidity / Foundry / OpenZeppelin

## Status

- Smart contract iterated through v1 → v10
- v10 reportedly passes a clean audit by the previous Claude session (zero compile errors, zero logic bugs claimed)
- Not yet deployed to any testnet
- Enzyme vault not yet created
- No professional third-party audit

---

# Honest Design Review

The previous chat is well-structured and the contract iteration shows real progress. But there are several issues that the chat either understated or skipped over. Worth weighing these before committing more time:

## 1. Regulatory exposure is the single biggest unaddressed risk

This product may still create securities or fund-regulation risk in many jurisdictions because it pools funds, holds a managed basket of assets, charges a management fee, and takes a performance cut. The current policy excludes RWA, tokenized equity, S&P 500, Nasdaq 100, ETF, and equity-index exposure to avoid adding a direct tokenized-securities layer.

The previous chat mentioned "structure as a DAO" and "avoid promising returns" as mitigations. That's not enough. SEC, OSC (Canada), ESMA, and FCA have all gone after on-chain index/fund products in the last two years. Pendle, Index Coop, and several others have had to geofence US users or restructure.

If you intend to ship this publicly, you need an actual securities lawyer in your target jurisdictions before you write more code. Budget $5–20k for the conversation, not "if needed."

## 2. RWA and equity-index exposure are excluded

RWA, tokenized equity, S&P 500, Nasdaq 100, ETF, and equity-index exposure are not part of the sleeve policy. Adding them later should require a separate compliant product design rather than a normal sleeve proposal.

## 3. "Zero expenditure" was the original goal — that's no longer true

You started the chat asking for zero-cost. The design now realistically requires:

- Enzyme vault setup gas (~$100–500 on Arbitrum)
- Initial LP seed (the LP allocation is recursive — you need real USDC to seed BGW/USDC before the fee allocation can flow into LP)
- Chainlink price feed reads (priced per call on some networks)
- Chainlink Automation LINK funding (you're self-funding via ops, but bootstrap LINK is needed)
- Security audit (the chat mentioned $20–80k — this is real, and unaudited UUPS vault code that handles user funds is genuinely dangerous)
- Legal review (above)
- Domain, frontend, infra

A realistic floor to launch responsibly is $30–100k, not zero. If that doesn't fit, the path is to launch as a testnet-only educational project and be explicit about that.

## 4. Specific contract concerns the previous review didn't flag

I'm reviewing the design rather than the actual v10 source (which wasn't fully pasted into the chat — only descriptions of it were). But based on what's described:

- **`recordStakingYield(uint256) onlyOwner`** — the owner manually reports the yield amount that the performance fee is calculated against. This is a significant trust assumption. A malicious or compromised owner can over-report yield to mint more fee tokens. Mainnet should derive yield from the vault state (`vault.balance(t1) - vault.balance(t0) - net flows`), not owner input.
- **UUPS with single-key owner** — the previous chat agreed to skip the 48h timelock "since the owner is just you." For testnet that's fine. For mainnet with real user funds this is unacceptable — the owner can upgrade to a malicious implementation and drain the vault in one transaction. Multi-sig + timelock is non-negotiable for mainnet.
- **BGW/USDC liquidity bootstrapping** — buybacks no longer route through Camelot, so thin LP depth does not affect buyback execution. LP depth still matters for secondary-market transfers.
- **Buyback at low AUM** — at $100k AUM, reserve growth may be small. Gas on Arbitrum is cheap but not free, so the threshold and cooldown should still be reviewed at realistic early-stage volumes.
- **Performance fee scope** — the chat's final answer was "stake yield only, owner-reported." There's no on-chain way for a holder to verify the owner isn't double-charging or under-reporting. Consider an oracle-based or vault-introspection approach for mainnet.

## 5. The contract iteration approach has a meta-risk

Going from v1 → v10 in chat with the model auditing its own (and prior model's) output is a useful rapid prototyping loop, but it is **not** equivalent to a security audit. Each pass found issues, which is good — but the same model passing v10 as "perfect" doesn't mean a real auditor (Trail of Bits, OpenZeppelin, Spearbit, Cantina) wouldn't find another 5–15 issues, including ones with funds-loss severity.

For testnet: v10 is fine to deploy and learn from.
For mainnet with user funds: do not skip a real audit.

---

# Recommended next steps (in order)

1. **Get the v10 source into the repo cleanly.** The chat included pasted code that was truncated in places. Confirm you have the full file, drop it in `contracts/BridgewayAutomationWrapper.sol`, and verify it compiles standalone with the OpenZeppelin upgradeable imports.
2. **Hardhat scaffolding** — config, deploy script, mock contracts, tests. This is the first thing the previous Claude offered to build. It's the right next step.
3. **Local test pass** — full Foundry test suite covering happy paths and edge cases.
4. **Arbitrum Sepolia deploy** — proxy via OpenZeppelin Upgrades plugin, register on Chainlink Automation testnet, verify on Arbiscan.
5. **Stop and assess** — at this point you'll have a working testnet deployment. Before going further, get a securities lawyer call and decide whether to scope down (drop equity layer, geofence) or commit to a proper compliance and audit budget.

# How to continue this in VSCode

See `VSCODE_SETUP.md` in this folder.
