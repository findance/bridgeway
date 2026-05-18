# Bridgeway Deployment Notebook

This notebook is the repo-tracked deployment ledger for `feature/hub-spoke`.
It records deployed addresses, deprecated attempts, confirmed transactions, and
future placeholders so every local checkout uses the same references.

Do not store private keys, RPC URLs, API keys, Safe signatures, or secrets here.

## Current Branch

| Field | Value |
| --- | --- |
| Branch | `feature/hub-spoke` |
| Network posture | Mainnet deployment in progress |
| Hub chain | Base |
| wstLINK rate path status | Live and valid; excluded from launch allocation |
| Last updated | 2026-05-17 |

## Operator And Safe Addresses

| Role | Address | Notes |
| --- | --- | --- |
| Deployer EOA | `0x13c142E565d28b1558BecAA2Af4495CB133801f4` | Used for bootstrap deployments. Do not treat as long-term owner. |
| Bridgeway Protocol Owner Safe | `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348` | Active owner of current reporter and registry. |
| Bridgeway Treasury Safe | `0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625` | Treasury recipient placeholder for current one-team setup. |

## Confirmed CCIP And Asset Inputs

| Item | Value |
| --- | --- |
| Ethereum chain ID | `1` |
| Arbitrum One chain ID | `42161` |
| Ethereum CCIP selector | `5009297550715157269` |
| Arbitrum CCIP selector | `4949039107694359620` |
| Ethereum CCIP router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| Arbitrum CCIP router | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` |
| Ethereum wstLINK | `0x911D86C72155c33993d594B0Ec7E6206B4C803da` |
| Arbitrum wstLINK | `0x3106E2e148525b3DB36795b04691D444c24972fB` |

## Active Mainnet Deployments

No production Base hub contracts have been deployed yet.

### wstLINK Rate Reporter Path

| Component | Chain | Address | Status |
| --- | --- | --- | --- |
| `BridgewayL1RateReporter` | Ethereum | `0xCB8ad5f63084D7eaB4116E3dd27381BD0Ef849bE` | Active reporter; Safe-owned |
| `BridgewayRateRegistry` | Arbitrum One | `0x0067a2c413f34A32cA13Da2e013BCfa839DdBAc4` | Active registry; Safe-owned |

This Ethereum-to-Arbitrum wstLINK rate path is live infrastructure and a reference
deployment. It is not the production hub path and is not approved for launch
allocation under the current Base-hub policy.

Ownership state at deployment checkpoint:

| Contract | Active owner | Pending owner | Notes |
| --- | --- | --- | --- |
| `BridgewayL1RateReporter` `0xCB8a...49bE` | `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348` | none | Ownership accepted by Protocol Owner Safe on Ethereum. |
| `BridgewayRateRegistry` `0x0067...BAc4` | `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348` | none | Ownership accepted by Protocol Owner Safe on Arbitrum One. |

### First Successful wstLINK Rate Report

| Field | Value |
| --- | --- |
| Ethereum source transaction | `0x2f4386cb3c4d866997148558e1aad01a26d5639a7493bbe836ca3b4223076da7` |
| CCIP message ID | `0xfb98dce23993e85bbbf9530fe70fc38312cbf4322b79f531c92fd69a46df8d4d` |
| Arbitrum destination transaction | `0x8cce49b2538464473c472f4b135119dc2dab2eb47f7ce6d5abe0982d2f527d84` |
| Destination block | `463824647` |
| Registry event | `RateUpdated(address,uint256,uint256,uint256)` |
| Reported asset | `0x3106E2e148525b3DB36795b04691D444c24972fB` |
| Reported rate | `1223082197491030871` |
| L1 source block | `25115928` |
| L1 source timestamp | `1779033167` |
| Arbitrum `rateStatus` state after settle | `0` (`Valid`) |

Validation command used:

```bash
cast call $L2_RATE_REGISTRY \
  "rateStatus(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint8)" \
  $WSTLINK_L2 \
  --rpc-url $ARBITRUM_RPC
```

Confirmed output:

```text
1223082197491030871
1779034251
1779034311
1779120651
25115928
1779033167
0
```

Meaning:

| Output | Meaning |
| --- | --- |
| `1223082197491030871` | Valid wstLINK to stLINK/LINK rate, 1e18 scaled |
| `1779034251` | Arbitrum registry `lastUpdated` |
| `1779034311` | `settlesAt` |
| `1779120651` | `staleAt` |
| `25115928` | L1 source block |
| `1779033167` | L1 source timestamp |
| `0` | `RateState.Valid` |

## Deprecated Mainnet Deployments

These addresses are intentionally retained as historical references. Do not
wire new contracts, adapters, registries, or configs to them.

| Component | Chain | Address | Reason |
| --- | --- | --- | --- |
| Old smoke-test `BridgewayL1RateReporter` | Ethereum | `0x9ecEdCFd6C2c36A06f01B9a278DE53A6f355deDc` | Pre-final hardening / deprecated. |
| Old smoke-test `BridgewayRateRegistry` | Arbitrum One | `0x9ecEdCFd6C2c36A06f01B9a278DE53A6f355deDc` | Pre-final hardening / deprecated. |
| Pre-ERC165 `BridgewayL1RateReporter` | Ethereum | `0xa9De353B134c2242C2B543894fdB2d24AC040788` | Reporter itself was usable, but paired registry lacked ERC-165 receiver support. Deprecated to avoid 48h receiver-update timer during testing. |
| Pre-ERC165 `BridgewayRateRegistry` | Arbitrum One | `0x6cbD4adF810dE55d2f75D0886Fe6C403a81EF477` | Destination tx succeeded but registry remained `NoData`; missing CCIP receiver interface advertisement. |

Deprecated message/transaction references:

| Field | Value | Notes |
| --- | --- | --- |
| Pre-ERC165 source tx | `0xbe7ce7faf14d08cab5f625a278d60b4a691fb7c25f5a4d167c0e2792a91bb922` | Sent to deprecated registry. |
| Pre-ERC165 destination tx | `0xffe960e4cc5fdcb5a1527abd58ab2b0c31541d1b48a28642845367ad68a13abd` | Destination succeeded at off-ramp, but no registry `RateUpdated`. |
| Pre-ERC165 message ID | `0x13b68eef6c6f6402a34d4c1b177138ee6b5003e1cc68db3e01050e59def1c560` | Historical reference only. |

## Future Deployment Placeholders

Fill these rows only after each component is deployed, verified, and has passed
the post-deploy read checks. Leave `TBD` until then.

| Component | Chain | Address | Status | Notes |
| --- | --- | --- | --- | --- |
| `BGWToken` | Base | `TBD` | Not deployed in current notebook | Canonical BGW receipt token deployment. |
| `BGW-GOV` / governance token | Base | `TBD` | Not deployed in current notebook | Canonical governance token deployment. |
| `BridgewayVault` / `BGWVault` | Base | `TBD` | Not deployed in current notebook | Hub mint/redeem/accounting vault. |
| `BridgewayRegistry` | Base | `TBD` | Not deployed in current notebook | Chain-local address registry. |
| `BridgewayHubNAV` | Base | `TBD` | Not deployed in current notebook | Global NAV aggregation. |
| `BridgewayCCIPNAVReceiver` | Base | `TBD` | Not deployed in current notebook | Spoke NAV CCIP receiver. Must support `supportsInterface(0x85572ffb)`. |
| `BridgewayAutomation` | Base | `TBD` | Not deployed in current notebook | Harvest/buyback automation coordinator. |
| Sleeve A Base core adapter | Base | `TBD` | Future | Launch-approved core: Base USDC, cbBTC, WETH, LINK where safe and liquid. |
| Base cbBTC yield spoke / adapter | Base | `TBD` | Future | Approved BTC route: 80% Aave V3 Base cbBTC, 20% Aerodrome USDC/cbBTC LP, exit Aerodrome to Aave if net APY < 4.5%. |
| Sleeve B stable yield adapter | Base | `TBD` | Future | Aave V3 Base first; Morpho only after approval. |
| Sleeve C alpha adapter | Base or approved spoke | `TBD` | Future | ERC-4626 / alpha strategies capped at 5%; Arbitrum can be a spoke venue. |
| Native BTC NAV spoke | Bitcoin / custody layer | `TBD` | Future | Deferred; native BTC can be added later if custody/NAV operations are approved. |
| Sleeve A LST/LRT adapter | Arbitrum One + spokes | `TBD` | Excluded from launch | wstETH/LBTC/wstLINK/sAVAX/ankrBNB are not approved for launch allocation. |
| Sleeve A perp synthetic adapter | Arbitrum One | `TBD` | Future | GMX V2 only at first. |
| Avalanche native staking spoke | Avalanche C-Chain | `TBD` | Excluded from launch | Native AVAX can be revisited; sAVAX is not approved for launch allocation. |
| BNB native staking spoke | BNB Chain | `TBD` | Excluded from launch | Native BNB can be revisited; ankrBNB is not approved for launch allocation. |
| Base LINK spoke | Base | `TBD` | Future | LINK/USDC/WETH only until native BTC policy is implemented. |
| Ethereum source spoke | Ethereum | `TBD` | Future | Spot WETH/LINK only unless a later governance decision approves wrappers. |

## Required Post-Deploy Checks

### CCIP Receiver Interface

Every CCIP receiver must pass:

```bash
cast call <receiver> "supportsInterface(bytes4)(bool)" 0x85572ffb --rpc-url <rpc>
cast call <receiver> "supportsInterface(bytes4)(bool)" 0x01ffc9a7 --rpc-url <rpc>
```

Expected:

```text
true
true
```

### wstLINK Rate Registry

```bash
cast call $L2_RATE_REGISTRY "expectedSourceSender()(address)" --rpc-url $ARBITRUM_RPC
cast call $L2_RATE_REGISTRY "sourceChainSelector()(uint64)" --rpc-url $ARBITRUM_RPC
cast call $L2_RATE_REGISTRY "rateAssetCount()(uint256)" --rpc-url $ARBITRUM_RPC
cast call $L2_RATE_REGISTRY "rateAssetAt(uint256)(address)" 0 --rpc-url $ARBITRUM_RPC
cast call $L2_RATE_REGISTRY "rateStatus(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint8)" $WSTLINK_L2 --rpc-url $ARBITRUM_RPC
```

Expected source/asset values:

```text
0xCB8ad5f63084D7eaB4116E3dd27381BD0Ef849bE
5009297550715157269
1
0x3106E2e148525b3DB36795b04691D444c24972fB
```

`rateStatus` state meanings:

| State | Meaning |
| --- | --- |
| `0` | Valid |
| `1` | Settling |
| `2` | Stale |
| `3` | Paused |
| `4` | Unapproved |
| `5` | NoData |
| `6` | Misconfigured |

## Ownership Activation Checklist

Do not call `acceptOwnership()` from the Protocol Owner Safe until bootstrap and
smoke testing for that contract are complete.

Before Safe ownership acceptance:

- Confirm the contract address is the active address in this notebook.
- Confirm no deprecated address is referenced by deployment scripts or env vars.
- Confirm the relevant post-deploy checks pass.
- Confirm pending owner is `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348`.
- Confirm the owner Safe signer set and threshold outside this notebook.

After Safe ownership acceptance:

- Future receiver/source/router/rate-bound changes use contract timelocks.
- Do not start a timelock proposal unless the deployment step is intentionally
  moving from bootstrap/testing into controlled operations.

## Open Deployment Notes

- `config/mainnet-addresses.json` still has `status: draft-mainnet-confirmed-inputs`.
- File integrity fields are intentionally unset until the address book is final.
- BNB Chain USDC remains rejected for redemption settlement.
- WBTC and exchange-rate/yield wrapper tokens are excluded from launch
  allocation: WBTC, wstETH, wstLINK, LBTC, sAVAX, and ankrBNB.
- BTC exposure is approved through a future Base cbBTC yield spoke, not through
  Arbitrum WBTC. The Base cbBTC adapter must enforce 80% Aave / 20% Aerodrome and
  move Aerodrome funds back to Aave if net APY falls below 4.5%.
- Production BGW/BGW-GOV, settlement, Sleeve B, and global hub accounting should
  be deployed on Base. Existing Arbitrum deployments remain reference/spoke
  infrastructure unless explicitly re-approved.
- Native BTC custody exposure remains deferred.
- The wstLINK Arbitrum rate-provider path is live infrastructure only; it is not
  approved for allocation under the current launch policy.
