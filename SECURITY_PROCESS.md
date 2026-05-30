# Clearcrest / Bridgeway — Security Process & Accepted Findings Register

Branch: `feature/hub-spoke` · Baseline commit: `e5dbb8d`
Companion to `SECURITY_TRIAGE.md` (the reasoning). This file is the **process of record**: what we accepted, why, who signs off, and how to reproduce the scans. Keep it under version control and update it on every scanner run.

Guiding constraint: **deployer/admin rights are not modified.** Centralization is mitigated by operational controls (Safe + timelock + documented roles), not by removing owner powers.

---

## A. Scanner re-run procedure (reproducibility)

Run these from repo root and attach outputs to the PR before any tag/deploy.

```bash
# Compile + unit/invariant tests
forge build
forge test -vvv

# Static analysis
aderyn .                       # writes report.md (Aderyn)
slither . --json slither_report.json

# Symbolic (per-contract; runtime can be long)
myth analyze contracts/core/modules/ClearcrestRedemptionModule.sol --solc-json mythril.config.json
myth analyze contracts/core/modules/ClearcrestMaintenanceModule.sol --solc-json mythril.config.json
myth analyze contracts/core/ClearcrestVault.sol --solc-json mythril.config.json

# Hygiene gate
git diff --cached --check
```

Latest validation (commit `e5dbb8d`): `forge build` pass · `forge test` 302 passed · `git diff --cached --check` clean · Mythril: redemption & maintenance modules clean, vault reports symbolic-only warnings (see §C).

**Rule:** a new finding is either fixed in code, or added to the register below with a verdict and sign-off. Nothing is silently ignored.

---

## B. Accepted findings register — Aderyn H-1 (reentrancy: state change after external call)

**Disposition: ACCEPTED (false-positive class) for 19/20; 1 documented in code.**

All 20 instances are a *read* external call (`.decimals()`, `.asset()`, or a trusted NAV read) followed by writing the value just read. No value-moving call follows any of the writes. Every instance is either constructor context or behind `onlyOwner` / owner-or-automation with the vault's reentrancy boundary.

| Location(s) | Pattern | Disposition |
|---|---|---|
| `BaseCBBTCYieldAdapter.sol` 79–81 | Constructor metadata validation + config assign | Accepted FP |
| `ERC4626NativeStakingAdapter.sol` 65–67 | Constructor metadata validation + config assign | Accepted FP |
| `SleeveACbbtcWrapper.sol` 105–107 | Constructor metadata reads + config assign | Accepted FP |
| `SleeveADualMorphoEthWrapper.sol` 116–121 | Constructor `asset()` validation + config assign | Accepted FP |
| `SleeveBStableYieldAdapter.sol` 62 | Constructor `asset()` validation + config assign | Accepted FP |
| `SleeveABasketAdapter.sol` 169 | `setAssets()` `onlyOwner nonReentrant`, reads token decimals | Accepted FP |
| `SleeveCAlphaYieldAdapter.sol` 91 | `setStrategies()` `onlyOwner nonReentrant`, validates `asset()` | Accepted FP |
| `SleeveADualMorphoEthWrapper.sol` 235 | `proposeMorphoVault()` `onlyOwner`, validates then queues behind `MIGRATION_DELAY` | Accepted FP |
| `ClearcrestRegistry.sol` 45–46 | `setAsset()` `onlyOwner`, reads decimals if unspecified | Accepted FP |
| `ClearcrestRedemptionModule.sol` 120 | owner/automation snapshot of trusted hub NAV | Accepted — documented in code (§E) |

**Rationale of record:** checks-effects-interactions exists to prevent an attacker re-entering between an effect and a fund-moving interaction. In every instance the only "interaction" is a pure metadata/NAV read from a deployment-time-trusted contract, and the "effect" is recording config or the value just read. Constructors are not re-enterable. Owner-gated setters could at worst be re-entered *as the owner*, which grants no escalation and touches no half-written fund state. Accepted.

Sign-off: ______________________  Date: __________

---

## C. Accepted findings register — Mythril vault arithmetic

**Disposition: ACCEPTED (symbolic-only); backed by invariant tests (§D).**

Mythril models every storage integer as unconstrained and reports possible over/underflow on `totalNAV`, `claimFees`/`pendingFees` and related accounting. Two facts neutralise this: Solidity 0.8 reverts on over/underflow (worst case is a revert, not corruption), and the subtractions it flags are already guarded — e.g. `ClearcrestVault.totalNAV()` returns `grossNav > queued ? grossNav - queued : 0`.

Variable → bounding invariant (what Mythril can't see):

| Variable | Invariant | Enforced by |
|---|---|---|
| `totalQueuedRedemptionNAVLiability` | ≤ accrued NAV; decremented in lockstep | `acknowledge`/`claim` decrements; `totalNAV` saturating sub |
| `pendingFees` / `claimableFees` | ≤ harvested yield | set in harvest path; `claimFees()` zeroes balance before transfer, `nonReentrant` |
| `highWaterMark` | ≥ `HWM_FLOOR` (1e18) | `_decayedHWM()` floor clamp |
| `navPerCCR` denominator | `supply == 0` handled | `navPerCCR()` returns `1e6` when supply is 0 |

Sign-off: ______________________  Date: __________

---

## D. Action register — invariant test assertions (converts §C from comment to proof)

These are tests, not contract changes. Add/confirm in `test/` and require green before deploy:

1. `totalNAV` never underflows: fuzz `totalQueuedRedemptionNAVLiability > grossNav` → expect `0`, no revert.
2. `claimFees` zeroes the recipient balance before transfer and is reentrancy-safe (reentrant claim attempt reverts / nets nothing).
3. `pendingFees ≤ Σ harvested yield` across a harvest sequence (accounting invariant).
4. `navPerCCR()` returns `1e6` at `totalSupply == 0`; monotonic vs NAV otherwise.
5. `highWaterMark` never decays below `HWM_FLOOR`; `_decayedHWM()` bounds hold across the full decay window.

Status: [ ] written  [ ] passing in CI    Sign-off: ______________  Date: ______

---

## E. Code fix of record — `ClearcrestRedemptionModule.sol:119`

Single documentation change (no logic change). See §"Suggested fix" in the chat / diff below. After applying, this instance is "accepted with in-code rationale" rather than an open finding.

Status: [ ] applied    Sign-off: ______________  Date: ______

---

## F. Accepted findings register — timestamp usage (Aderyn L-1 and timestamp warnings)

**Disposition: ACCEPTED — time gates, not entropy.**

Legitimate `block.timestamp` uses in scope, none of which are randomness or attacker-movable in a useful way (delays are hours/days; staleness windows are minutes; validator timestamp drift is seconds):

- Timelock ETAs / `MIGRATION_DELAY` (e.g. `proposeMorphoVault` → `morphoVaultAEta`).
- Redemption cooldowns.
- Oracle staleness checks (`maxStale`).
- HWM linear decay window (`HWM_DECAY_START` → `HWM_FLOOR`).
- Automation interval spacing.

Open check: confirm router swap deadlines are passed through and a deadline of `block.timestamp` is acceptable for our routes (Aderyn L-1 is a liveness/MEV nuance, not reentrancy).

Status: [ ] swap-deadline confirmed    Sign-off: ______________  Date: ______

---

## G. Centralization findings (Aderyn L-2) — operational mitigation (rights unchanged)

**Disposition: ACCEPTED AS DESIGNED.** A hub-spoke vault needs owner steering (rebalance, sleeve migration, emergency unwind). We mitigate by process, not by removing powers. Verify each on-chain before mainnet and record tx hashes:

- [ ] **Safe ownership.** `owner()` on vault, registry, all modules and all adapters transferred to the Gnosis Safe; no EOA retains owner. Cross-check `MAINNET_ADDRESS_BOOK.md`.
- [ ] **Timelock discipline.** Owner config changes route through existing delays (`MIGRATION_DELAY`, propose/finalize paths) so they are observable before taking effect.
- [ ] **Bootstrap finalization.** One-time setup flags (initial config, automation wiring) finalized/renounced so they can't be reused.
- [ ] **Emergency roles documented.** Holder of `automation`; who may call `emergencyUnwind*` and under what conditions; note `emergencyUnwindAll` is `onlyOwnerOrVault`.

Sign-off: ______________________  Date: __________

---

## H. Sign-off summary

| Section | Disposition | Owner | Date |
|---|---|---|---|
| B — Aderyn H-1 (20) | Accepted (19 FP + 1 documented) | | |
| C — Mythril vault arithmetic | Accepted (symbolic) | | |
| D — Invariant tests | Action (tests) | | |
| E — Redemption module L119 comment | Code (doc-only) | | |
| F — Timestamp usage | Accepted | | |
| G — Centralization | Accepted (ops mitigated) | | |

This register must be re-reviewed on every scanner run and before every tag/deploy.
