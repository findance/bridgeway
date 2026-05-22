# Bridgeway Base Mainnet Redeployment Expected Outputs

Use this file as the checklist while running `MAINNET_REDEPLOYMENT_COMMANDS.md`.

## Bug-Fix Preservation Checklist

Latest commit:

```text
d74ceb0 Fix Aerodrome redemption and accounting edge cases
```

Preserved earlier fixes:

- AERO compounding path remains configured through `AERO_TO_CBBTC_PATH`.
- Sleeve A wrapper still bounds `maxStale` to 24 hours.
- Sleeve A wrapper still rejects unknown Aerodrome tick spacings.
- Sleeve A emergency unwind still exists: `emergencyWithdrawAll()`.
- Base cbBTC yield adapter still supports controller `withdrawAll(address)`.
- Vault redemption still uses idle redemption reserve, then Sleeve B, then Sleeve C, then Sleeve A.
- Small deposits still route to stable-only Sleeve B below `smallDepositStableOnlyThresholdUsdc`.
- Dashboard deep refresh support remains in `tools/bridgeway-dashboard.html`.

New fixes in `d74ceb0`:

- Aerodrome stale mark does not block `totalAssetsCbbtc()`.
- Aerodrome `maxMarkStale` capped at 72 hours.
- Aerodrome keeper mark movement capped at 10%.
- AERO reward swap no longer uses zero min-out; if `minAeroToCbbtcOut` is unset, AERO remains idle.
- Aerodrome liquidity decrease uses token minimums.
- cbBTC stack has `ReentrancyGuard`.
- Strategy harvest honors receiver and reports harvested cbBTC.
- Vault fee/buyback/reserve accounting is separated.
- Buybacks deploy without retaining redemption buffer.
- Excess sleeve returns are credited to idle redemption reserve.
- Sleeve C partial withdrawal decrements `remaining`.

## Phase 0 Expected Output

`git status --short`:

```text
<empty>
```

`git rev-parse --short HEAD`:

```text
d74ceb0
```

`forge build`:

```text
Compiler run successful
```

`forge test`:

```text
271 tests passed, 0 failed, 0 skipped
```

Foundry may warn that it cannot write `/Users/vipul/.foundry/cache/signatures`; this is sandbox/cache noise, not a Solidity failure.

## Phase 1 Expected Output

After USDT cleanup:

```text
A_TRUSTED=false
B_TRUSTED=false
C_TRUSTED=false
USE_COUNT=0
```

`PROTECTED` should become `false` after the optional `setProtectedToken(USDT,false)` cleanup.

## Phase 2 Expected Output

Gauge check:

```text
AERODROME_GAUGE=0x6399ed6725cC163D019aA64FF55b22149D7179A8
GAUGE_CODE=0x363d3d37
```

If `GAUGE_CODE=0x`, stop and re-resolve the Aerodrome gauge before deploying sleeves.

## Phase 3 Expected Output

`forge create contracts/core/BGWVault.sol:BGWVault ...` should include:

```text
Deployer: 0x13c142E565d28b1558BecAA2Af4495CB133801f4
Deployed to: 0x...
Transaction hash: 0x...
```

Export:

```text
VAULT=0x...
```

Vault bootstrap checks:

```text
owner() = 0x13c142E565d28b1558BecAA2Af4495CB133801f4
whitelist(VAULT) = true
whitelist(FOUNDER_TREASURY) = true
```

## Phase 4 Expected Output

Dry run should show:

```text
Script ran successfully.
SIMULATION COMPLETE.
SleeveACbbtcWrapper: 0x...
AerodromeCbbtcStrategy: 0x...
Aerodrome gauge: 0x6399ed6725cC163D019aA64FF55b22149D7179A8
AERO reward compounding path configured.
BaseCBBTCYieldAdapter: 0x...
SleeveBStableYieldAdapter: 0x...
Sleeves wired: A = 0x...  B = 0x...
Deposit weights: 6500 / 3500 / 0
Protected tokens registered.
Ownership transfers initiated to: 0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
```

Broadcast should show the same logs without `SIMULATION COMPLETE`, plus:

```text
Transactions saved to: /Users/vipul/bridgeway-all/broadcast/14_DeployAndWireSleeves.s.sol/8453/run-latest.json
```

If the RPC returns delegated-account in-flight/gapped-nonce errors, resume one transaction at a time with the next nonce. Do not skip nonces.

## Phase 5 Expected Output

After BGW Safe role grants:

```text
BGW_MINTER_VAULT=true
BGW_BURNER_VAULT=true
BGW_WHITELIST_ADMIN_VAULT=true
```

After `proposeVaultReference(newVault)`:

```text
pendingVaultRef.value = VAULT
pendingVaultRef.executeAfter = now + 48 hours
```

After 48h and `executeVaultReference()`:

```text
GOV_VAULT=<new VAULT>
```

## Phase 6 Expected Output

Wiring check should be:

```text
A_ROUTE_COUNT=1
B_ROUTE_COUNT=1
A_ROUTE=<SLEEVE_A_WRAPPER>
10000 [1e4]
true
B_ROUTE=<SLEEVE_B_ADAPTER>
10000 [1e4]
true
WEIGHT_A=6500
WEIGHT_B=3500
WEIGHT_C=0
WRAPPER_YIELD_ADAPTER=<BASE_CBBTC_YIELD_ADAPTER>
YIELD_CONTROLLER=<SLEEVE_A_WRAPPER>
AERO_CONTROLLER=<BASE_CBBTC_YIELD_ADAPTER>
AERO_GAUGE=0x6399ed6725cC163D019aA64FF55b22149D7179A8
AERO_PATH=0x940181a94a35a4569e4529a3cdfb74e38fd986310007d0833589fcd6edb6e08f4c7c32d4f71b54bda02913000064cbb7c0000ab88b473b1f5afd9ef808440eed33bf
AERO_NET_APY_BPS=500
```

Ownership before Safe accept:

```text
VAULT_OWNER=0x13c142E565d28b1558BecAA2Af4495CB133801f4
VAULT_PENDING_OWNER=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
```

For sleeve contracts:

```text
pendingOwner() = 0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
```

## Phase 7 Expected Output

Automation deploy:

```text
BridgewayAutomation: 0x...
Automation not wired. Set WIRE_AUTOMATION=true when ready.
```

Export:

```text
AUTOMATION=0x...
```

## Phase 8 Expected Output

USDC approval:

```text
status 1 (success)
to 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

Deposit static call:

```text
0x
```

Deposit send:

```text
status 1 (success)
to <new VAULT>
```

Post-deposit state should be approximately:

```text
BGW_BALANCE_DEPLOYER=60000000000000000000 [6e19]
GOV_BALANCE_DEPLOYER=18000000000000000000 [1.8e19]
GOV_BALANCE_FOUNDER=42000000000000000000 [4.2e19]
TOTAL_SUPPLY_BGW=60000000000000000000 [6e19]
TOTAL_NAV≈60000000
SLEEVE_A_VALUE≈39000000
SLEEVE_B_VALUE≈21000000
holderIdleUSDC≈1200000
```

Small differences are normal from Aerodrome swap price/slippage and redemption buffer retention.

## Phase 9 Expected Output

Redeem static call:

```text
0x
```

Redeem send:

```text
status 1 (success)
to <new VAULT>
```

Post-redeem state should show:

```text
BGW_BALANCE_DEPLOYER=59000000000000000000 [5.9e19]
TOTAL_SUPPLY_BGW=59000000000000000000 [5.9e19]
```

USDC returned should be roughly `0.999` USDC after exit fee and redemption pricing, with dust depending on current NAV and USDC redemption price.

## Phase 10 Expected Output

Dashboard:

- `NAV Per BGW` displays a value near 1 USDC.
- `Total NAV` displays the post-smoke NAV.
- `Sleeve Summary` shows Sleeve A and Sleeve B values.
- Deep Refresh populates:
  - Sleeve A wrapper total
  - Base cbBTC yield adapter total
  - Aerodrome token id/gauge/path/APY
  - Sleeve B aUSDC and Morpho positions

## Phase 11 Expected Output

After Safe `acceptOwnership()` calls:

```text
owner() = 0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
pendingOwner() = 0x0000000000000000000000000000000000000000
```

Do not accept ownership until:

- BGW roles are granted to the new vault.
- GOV vault reference points to the new vault.
- Deposit static call returns `0x`.
- Redeem static call returns `0x`.
- Dashboard deep refresh populates.

