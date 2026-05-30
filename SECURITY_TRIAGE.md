# Clearcrest / Bridgeway — Manual Scanner Triage

Branch: `feature/hub-spoke` · Commit baseline: `e5dbb8d`
Scope: triage the manual items left after the hardening pass. **No change to deployer/admin rights** — centralization items are documented as accepted-with-ops-controls, not re-architected.

Verdict legend: **ACCEPT** = false positive / intentional, document and move on · **DOC** = accept but add a code comment or runbook note · **ACTION** = code or process change recommended.

---

## 1. Aderyn H-1 — "State change after external call" (20 instances)

Every one of the 20 instances is a *read* external call (`.decimals()`, `.asset()`, or a trusted NAV read) followed by writing the value that was just read. None is followed by a value-moving call, and all sit behind either constructor context or an `onlyOwner`/`onlyAutomation` + `nonReentrant` boundary. The detector matches the syntactic pattern (external call → SSTORE) but cannot see that the "external call" is a pure metadata read from a trusted contract. Classchecks-effects-interactions exists to stop an attacker re-entering between effect and interaction; here there is no attacker-controlled interaction after the write.

Grouped classification:

| # | Location | Pattern | Verdict |
|---|----------|---------|---------|
| 1–3 | `BaseCBBTCYieldAdapter.sol` 79–81 | Constructor: validate `strategy.asset()==cbbtc`, read `decimals()`, then assign immutable-style config | ACCEPT |
| 4–6 | `ERC4626NativeStakingAdapter.sol` 65–67 | Constructor: validate `vault.asset()`, read `decimals()`, assign config | ACCEPT |
| 7 | `SleeveABasketAdapter.sol` 169 | `setAssets()` (`onlyOwner nonReentrant`): read token `decimals()` while rebuilding `_assets` | ACCEPT |
| 8–10 | `SleeveACbbtcWrapper.sol` 105–107 | Constructor: read cbBTC/USDC/feed `decimals()`, assign config | ACCEPT |
| 11–14 | `SleeveADualMorphoEthWrapper.sol` 116–121 | Constructor: validate both Morpho vaults' `asset()==weth`, read `decimals()`, assign config | ACCEPT |
| 15 | `SleeveADualMorphoEthWrapper.sol` 235 | `proposeMorphoVault()` (`onlyOwner`): validate candidate `asset()==weth`, then queue pending vault behind `MIGRATION_DELAY` | ACCEPT |
| 16 | `SleeveBStableYieldAdapter.sol` 62 | Constructor: validate `morphoVault.asset()==usdc`, assign config | ACCEPT |
| 17 | `SleeveCAlphaYieldAdapter.sol` 91 | `setStrategies()` (`onlyOwner nonReentrant`): validate each `vault.asset()==usdc`, rebuild `_strategies` | ACCEPT |
| 18–19 | `ClearcrestRegistry.sol` 45–46 | `setAsset()` (`onlyOwner`): if decimals unspecified, read `token.decimals()` / `feed.decimals()`, then store `AssetConfig` | ACCEPT |
| 20 | `ClearcrestRedemptionModule.sol` 120 | `acknowledgeQueuedRedemptionLiquidity()` (owner/automation): read `hubNAV.totalSpokeNAVUSDC()`, then store it as `spokeNavSnapshotUsdc` | DOC |

### Why constructor reads (instances 1–6, 8–14, 16) are not reentrancy
A constructor runs before the contract has code/state an attacker can re-enter, and the called contracts (the token, the Aave/ERC4626 vault, the Chainlink feed) are deployment-time trusted inputs. The flagged "state changes" are one-time config assignments. Accept as a known false-positive class.

### Why owner-gated config setters (7, 15, 17, 18–19) are not reentrancy
`setAssets`, `setStrategies`, `setAsset`, `proposeMorphoVault` are all `onlyOwner` (two also `nonReentrant`). The external call is a metadata/`asset()` validation read against the operator-supplied token/vault. Even if a malicious token re-entered, it could only re-enter another owner-only function as the owner — no privilege escalation, no fund movement tied to the half-written state. The validation read is in fact a *defensive* check (rejecting mismatched assets). Accept.

### Instance 20 — the only one worth a comment
`acknowledgeQueuedRedemptionLiquidity` reads the trusted hub NAV and writes `redemption.spokeNavSnapshotUsdc = currentSpokeNav` — it is recording the value it just read, used to gate liquidity release (`spokeDrop < reservedRelease` reverts). The function is restricted to `owner()`/`automation`, `hubNAV` is a trusted contract, and no transfer follows the write (the USDC `safeTransfer` lives in the separate `claim` path). Not exploitable.

**DOC action:** add a NatSpec line above L119 noting that `hubNAV` is trusted and the post-read write is an intentional snapshot, so future readers/scanners don't re-flag it. No logic change.

> Suggested wording for the accepted-patterns log:
> *"Aderyn H-1 (20): all instances are pre-assignment metadata reads (`decimals`/`asset`) in constructors or owner-gated config setters, plus one owner/automation snapshot of trusted hub NAV. No attacker-controlled call follows the state write. Accepted as checks-effects-interactions false positives; no fund-moving external call is involved."*

---

## 2. Mythril vault warnings — unconstrained-storage arithmetic

Mythril treats every `public`/storage integer as a free symbolic variable and reports possible over/underflow on `totalNAV`, `claimFees`/`pendingFees`, and related accounting. Two reasons these are noise here:

1. **Solidity 0.8 reverts on over/underflow.** A symbolic "underflow" is, at worst, a revert (DoS on that specific input), not silent corruption.
2. **The code already saturates the subtractions Mythril worries about.** Example, `ClearcrestVault.totalNAV()`:

   ```solidity
   uint256 grossNav = totalLocalNAV() + totalSpokeNAV();
   uint256 queued = totalQueuedRedemptionNAVLiability;
   return grossNav > queued ? grossNav - queued : 0;   // guarded, cannot underflow
   ```

   Mythril sees `totalQueuedRedemptionNAVLiability` as unconstrained and flags `grossNav - queued`; the ternary already prevents it.

Mythril does not know the invariants that actually bound these variables:
- `totalQueuedRedemptionNAVLiability` ≤ accrued NAV (decremented in lockstep with `acknowledge`/`claim`).
- `pendingFees` / `claimableFees` ≤ harvested yield; `claimFees()` is `nonReentrant` and zeroes the balance before transfer.
- `highWaterMark` is bounded below by `HWM_FLOOR` (1e18) in the decay path.
- Share price `totalNAV / totalSupply` is undefined only at `supply == 0`, which `navPerCCR()` special-cases (returns `1e6`).

**Verdict: ACCEPT**, with two **DOC** follow-ups:
- Record each warned variable next to the invariant that bounds it (table above) in the accepted-findings log, so an auditor can confirm rather than re-derive.
- Where the invariant lives only in your head, encode it as a test assertion (see verification note below). Tests are stronger evidence than a comment that Mythril is wrong.

No code change required for the arithmetic itself.

---

## 3. Timestamp warnings — `block.timestamp` use

All flagged uses are time *gates*, not randomness or money-deciding entropy:
- timelocks / `MIGRATION_DELAY` ETAs (e.g. `proposeMorphoVault` → `morphoVaultAEta`)
- redemption cooldowns
- oracle staleness (`maxStale`) checks
- HWM linear decay window (`HWM_DECAY_START` → floor)
- automation interval spacing

Miner/validator timestamp influence is bounded to a few seconds and cannot move any of these gates in an attacker-useful way (delays are hours/days; staleness windows are minutes). Aderyn L-1 ("`block.timestamp` swap deadline offers no protection") is the one to read carefully: confirm swap deadlines are still passed through and that you're comfortable a deadline equal to `block.timestamp` is acceptable for your router calls — that's a liveness/MEV nuance, not a reentrancy bug.

**Verdict: ACCEPT** as time-gate usage. **DOC** one line in the runbook listing the legitimate timestamp uses so reviewers don't re-litigate.

---

## 4. Centralization findings (Aderyn L-2) — accept WITHOUT changing rights

You asked not to change deployer/admin rights, and that's the right call for a hub-spoke vault that needs operational steering (rebalances, sleeve migrations, emergency unwind). The mitigation is process, not removing powers:

- **Safe (multisig) ownership.** Transfer `owner()` on the vault, registry, modules and all adapters to a Gnosis Safe; verify on-chain that no EOA retains owner after bootstrap. (Confirm against `MAINNET_ADDRESS_BOOK.md`.)
- **Timelock discipline.** Route owner config changes through the existing delay mechanisms (`MIGRATION_DELAY`, vault proposal/finalize paths) so changes are observable before they take effect.
- **Bootstrap finalization.** Ensure any one-time setup flags (initial config, automation wiring) are finalized/renounced so they can't be reused.
- **Documented emergency roles.** Write down who holds `automation`, who can call `emergencyUnwind*`, and under what conditions — and that `emergencyUnwindAll` is `onlyOwnerOrVault`.

**Verdict: ACCEPT as designed.** These are operational controls, not contract changes; nothing here narrows the owner's authority. Treat the finding as "mitigated by ops" and link to the runbook section that proves the Safe + timelock are live.

---

## Recommended actions summary

The only thing approaching a code change is the single NatSpec comment on `ClearcrestRedemptionModule.sol:119`. Everything else is documentation/process:

1. **DOC** — accepted-findings log entry for H-1 (wording above), with the per-variable invariant table for the Mythril section.
2. **DOC** — one NatSpec line on redemption-module L119 (trusted hub NAV snapshot).
3. **ACTION (tests, not contracts)** — add/confirm invariant test assertions for: `totalNAV` saturating sub, `claimFees` zero-before-transfer, `pendingFees ≤ harvested`, `navPerCCR` at `supply==0`, HWM floor. These convert "Mythril is wrong" into proof.
4. **DOC** — runbook list of legitimate `block.timestamp` gates; re-confirm swap-deadline handling (L-1).
5. **PROCESS** — confirm on-chain that owner = Safe, timelocks are wired, bootstrap finalized, emergency roles documented. No rights changed.
