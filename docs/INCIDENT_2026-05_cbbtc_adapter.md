# Incident Post-Mortem: 2026-05 cbBTC Adapter

## Summary
The `BaseCBBTCYieldAdapter` was deployed with an incorrect `aCbbtc` immutable address configuration (`aBasUSDbC` instead of `aCbBTC`). Because the adapter did not validate the configured aToken address against the Aave V3 pool at deployment, the configuration silently succeeded. 

When the adapter attempted to process withdrawals, the `_aaveAssets()` function returned a balance of `0` (since the adapter held no `aBasUSDbC`), which caused the `available == 0` guard in `_withdrawAave()` to immediately exit without initiating an Aave withdrawal. This silently bricked withdrawals and stranded a live Aave position with no alternative rescue path.

Furthermore, an audit of other adapters revealed that `SleeveADualMorphoEthWrapper`'s emergency withdrawal path (`emergencyWithdrawAll`) was returning raw WETH to the `owner()` instead of converging to the vault as expected.

## Root Causes
1. **Unvalidated Immutable Address:** The Aave-aToken adapters read balances through an unvalidated immutable, so one wrong address silently bricks withdrawals.
2. **Missing Rescue Backstop:** No adapter had a generic `rescueToken` backstop to rescue stuck or misdirected tokens.
3. **Emergency Exit Deviation:** The ETH wrapper's emergency path did not attempt to swap back to the base settlement token (USDC) and forward to the vault, breaking the structural invariant that all yield converges at the vault.

## Remediation & Fixes
The following patches were applied to the system:
- **Adapter Validation (BaseCBBTCYieldAdapter & SleeveBStableYieldAdapter):** Added a constructor check that validates the provided aToken matches the canonical aToken reported by `pool.getReserveData()`. Mismatched configurations now revert immediately upon deployment.
- **Rescue Backstop:** Introduced an `onlyOwner` protected `rescueToken()` function to allow sweeping arbitrary stuck tokens to a designated receiver.
- **Sleeve A Convergence:** Modified `SleeveADualMorphoEthWrapper.emergencyWithdrawAll()` to mirror the cbBTC wrapper. It now attempts to swap the redeemed WETH to USDC and forwards any successfully converted USDC to the vault. Only the unconverted remainder is sent to the `owner()` as a fallback.

## Lessons Learned
- **Trust but Verify Injections:** Immutable configuration injected at deployment must be cross-verified against on-chain truth where possible (e.g., verifying an aToken maps to the correct underlying asset in the protocol pool).
- **Graceful Degradation:** Smart contracts interfacing with multiple layers should always have a generic emergency rescue function (like `rescueToken`) to recover funds in the event of unanticipated edge cases or bricked execution paths.
- **Symmetrical Exits:** Emergency paths should aim to preserve normal invariants as closely as possible (such as converging to the vault) and only break those invariants for the specific portion of funds that cannot be processed.
