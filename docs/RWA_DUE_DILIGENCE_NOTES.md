# RWA Due Diligence Notes

This note is a pre-allocation checklist for the Arbitrum Sleeve C PT candidates. It is not an approval to allocate capital.

## thBILL

- Protocol/issuer surface: Theo.
- Product: basket of institutional-grade tokenized U.S. Treasury bills.
- Current stated initial composition: tULTRA, a wrapped representation of Standard Chartered Libeara's tokenized Treasury bill, operated with Wellington Management and FundBridge.
- Redemption: only KYC-approved users can mint/redeem directly; Theo docs state redemption returns equivalent value in USDC and underlying collateral settlement can take up to 4 business days.
- Key risk: token holders do not directly claim underlying assets; direct mint/redeem is gated by KYC, so Clearcrest must assume secondary-market liquidity or verified institutional redemption access.
- Pendle PT candidate on Arbitrum: PT thBILL 18JUN2026.

Source: https://docs.theo.xyz/thbill

## USDai

- Protocol/issuer surface: USD.AI.
- Product: fully-backed synthetic dollar.
- Stated backing: stablecoin deposits finance AI infrastructure credit; USD.AI describes USDai as fully-backed and instantly redeemable.
- Yield: USDai itself does not pass yield to holders.
- Key risk: it is not a fiat stablecoin; stability depends on protocol collateral, redemption mechanics, and credit/liquidity design.
- Pendle PT candidate on Arbitrum: PT USDai 18JUN2026.

Sources:
- https://docs.usd.ai/usdai/overview
- https://usd.ai/usdai

## sUSDai

- Protocol/issuer surface: USD.AI.
- Product: yield-bearing counterpart to USDai.
- Stated yield source: loans collateralized by AI infrastructure assets, including GPUs; idle capital can be held in Treasury Bills.
- Redemption: USD.AI docs describe sUSDai as less liquid than stablecoins and subject to redemption periods/structured redemption mechanics.
- Risk profile: materially higher credit/liquidity risk than plain USDC lending or T-bills; should be sized as Sleeve C alpha, not Sleeve B stability.
- Pendle PT candidate on Arbitrum: PT Staked USDai 18JUN2026.

Sources:
- https://docs.usd.ai/usdai/overview
- https://docs.usd.ai/how-usd.ai-works
- https://docs.usd.ai/technical-protocol-overview
- https://usd.ai/insights/usdai-underwriting-and-risk-management

## On-Chain Pendle Validation

Validated on Arbitrum One (`chainId=42161`) through Pendle API and `readTokens()`:

| Asset | Market | PT | SY | YT | Expiry |
|---|---|---|---|---|---|
| thBILL | `0x22d95CeC2B962C142Fff9bE88Cfc7EF15043419f` | `0xE46271ecb1d5c7c5134868760F10c18B03021eF1` | `0xc32e96B4C7EB7959B6A92f3f7eD5d2321e6ed3D4` | `0x58C40BF59d1714D7B84060dE9f7197AcCC0b3954` | `1781740800` |
| sUSDai | `0x299674f6dA858f903D77486fBA50Bc9f2e0DB24D` | `0x07bc5bD6cE9A17f0e7aa91E0Adbc9070dcB1d1dE` | `0x30Ccf4Bbee313fCD19F3e295b3ba2920A24e2f62` | `0x7032cEe758fBA530C1c71Ab52de1727E555B8Ed4` | `1781740800` |
| USDai | `0x8A8a557B90ec79496A18A1F9c9da8bbD7dB86Fd3` | `0x1cdDE40e29dA213f42A7fA109CcADCA372d9Ee1B` | `0x5edCBC20Cac67AdC2e724d4348Ff85132B085b82` | `0x5De2065F3C709b24f31c736Ef28c1CbB27cEedfc` | `1781740800` |

## Allocation Gate

Before any real allocation:

- Confirm direct redemption path or acceptable exit liquidity for each asset.
- Confirm oracle/feed source for each underlying and set per-position feed in the PT spoke.
- Set explicit per-market capital caps.
- Start with dust capital and verify buy, NAV report, redeem/sell, in-kind fallback, and emergency rescue.
- Keep Sleeve C weight at `0` until the spoke is deployed, reporting, and fork-tested.
