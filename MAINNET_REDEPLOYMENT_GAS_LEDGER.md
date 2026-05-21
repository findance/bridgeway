# Bridgeway Mainnet Redeployment Gas Ledger

Purpose: track gas for the next redeployment separately from the first smoke deployment.

Paste each successful transaction receipt under the matching section. For each tx, record:

- transaction hash
- operation
- gasUsed
- effectiveGasPrice
- l1Fee, if present
- total cost = gasUsed * effectiveGasPrice + l1Fee

## Summary

| Phase | Tx Count | Total ETH |
| --- | ---: | ---: |
| 01 Tokens | 3 | 0.000024936462 |
| 02 Vault | 3 partial | 0.000033330478875 |
| 14 Sleeves | 0 | TBD |
| Smoke Deposit/Redeem | 0 | TBD |
| Total | 6 partial | 0.000058266940875 |

## 01 Tokens

Broadcast: `broadcast/01_DeployTokens.s.sol/8453/run-latest.json`

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0xb777562d3f8279fe3211653596dcdfae763440234bc735e865899612f42d312b` | Deploy BGW token | 1,477,737 | 6,000,000 | 0.000008866422 |
| `0xd05478638499eb895995f65671f1114a9280b1af91b130fecf661623b97e0fa2` | Deploy BGW-GOV token | 2,630,612 | 6,000,000 | 0.000015783672 |
| `0xb74982a6e86d2b75e8e7da7f261b1df1818bf99559a9776cbe8a41ac1c172e15` | Set BGW-GOV companion | 47,728 | 6,000,000 | 0.000000286368 |

Subtotal: 4,156,077 gas, 0.000024936462 ETH.

## 02 Vault

Broadcast attempt: `broadcast/02_DeployVault.s.sol/8453/run-latest.json`

Partial success before RPC delegated-account in-flight limit:

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0x6a0eab869c5f4a53cea9602be17e1b6b6dec81c564d4c14fa816f48bb4938fe6` | Deploy BGWVault | 5,570,257 | 5,875,000 | 0.000032725259875 |
| `0x1ed0b0139986be7348216eda21467944f197436cf4e66e8268bb05e3d9daaccc` | Grant BGW MINTER_ROLE to vault | 51,514 | 5,875,000 | 0.000000302644750 |
| `0x0e845a44f43d275514570f19194d87d6f1219f5563d3a7d7b9684dfa328a81d7` | Grant BGW BURNER_ROLE to vault | 51,502 | 5,875,000 | 0.000000302574250 |

Partial subtotal: 5,673,273 gas, 0.000033330478875 ETH.

## 14 Sleeves

TBD

## Smoke Deposit/Redeem

TBD
