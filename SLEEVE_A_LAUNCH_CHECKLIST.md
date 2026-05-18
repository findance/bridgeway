# Sleeve A Launch Checklist

Sleeve A uses `SleeveABasketAdapter` for the approved top-10 non-stable crypto basket.

## Initial Target Weights

| Rank | Asset | Target |
| ---: | --- | ---: |
| 1 | BTC | 25% |
| 2 | ETH | 25% |
| 3 | BNB | 8% |
| 4 | SOL | 8% |
| 5 | XRP | 7% |
| 6 | LINK | 7% |
| 7 | ADA | 6% |
| 8 | AVAX | 5% |
| 9 | TRX | 5% |
| 10 | DOGE | 4% |

## Manual Inputs Required Before Deployment

For each asset, the founder/governance process must approve:

1. The canonical Arbitrum-compatible token address.
2. The Chainlink-style USD price feed address.
3. The maximum oracle staleness window.
4. The buy path from USDC to the asset.
5. The sell path from the asset back to USDC.
6. The maximum slippage setting for the adapter.
7. Liquidity evidence showing the route can support expected deposit, redemption, and rebalance size.
8. Whether the asset is native, bridged, wrapped, or synthetic.

## Step 2 Token Address Review

| Asset | Target | Proposed Arbitrum token | Source / bridge | Status |
| --- | ---: | --- | --- | --- |
| BTC | 25% | Base cbBTC spoke, adapter TBD | Coinbase cbBTC on Base | Approved policy, pending adapter |
| ETH | 25% | `0x82af49447d8a07e3bd95bd0d56f35241523fbab1` | Arbitrum WETH | Approved candidate |
| BNB | 8% | `0x20359aF6B124F6f0219c21B0D8b769D43509930D` | LayerZero candidate | Pending verification |
| SOL | 8% | `0x2bcC6D6Cc72634C66bb62615467375176735439a` | Wormhole candidate | Pending verification |
| XRP | 7% | TBD | Manual verification required | Not approved |
| LINK | 7% | `0xf97f4df75117a78c1a5a0dbb814af92458539fb4` | Chainlink bridged LINK | Approved candidate |
| ADA | 6% | TBD | Manual verification required | Not approved |
| AVAX | 5% | `0x511dccd53265814138e698889966699666000000` | LayerZero candidate | Pending verification |
| TRX | 5% | TBD | Manual verification required | Not approved |
| DOGE | 4% | TBD | Manual verification required | Not approved |

Do not move a pending candidate into adapter configuration until its Arbiscan token page, implementation/proxy, bridge source, holders, liquidity, oracle, and route are all reviewed.

## Practical Asset Notes

- ETH and LINK are the cleanest Arbitrum-local Sleeve A assets for launch because their token, oracle, and route support are straightforward.
- BTC exposure should use a Base cbBTC spoke rather than Arbitrum WBTC. The approved policy is 80% Aave V3 Base cbBTC supply and 20% Aerodrome USDC/cbBTC LP, with the Aerodrome leg moved back to Aave if net APY after fees and operating expense drops below 4.5%.
- LINK and AVAX may be practical if the selected Arbitrum token, oracle, and route have enough liquidity.
- BNB, XRP, SOL, TRX, DOGE, and ADA require extra caution because Arbitrum representations may be bridged, wrapped, synthetic, or route-limited. Do not activate any of them until the approved token and route are verified.
- If an asset lacks a reliable oracle or safe route, it should remain disabled even if it is in the target list.

## Activation Steps

1. Deploy `SleeveABasketAdapter`.
2. Configure the 10 asset inputs with approved tokens, feeds, weights, and routes.
3. Mark each token as a trusted Sleeve A asset in `BGWVault`.
4. Confirm adapter `totalAssetsUSDC()` equals the current manual Sleeve A value if replacing manual accounting.
5. Set the adapter as `SLEEVE_A` in `BGWVault`.
6. Run a small test deposit, withdrawal, rebalance, and emergency unwind on testnet before mainnet.

## Base cbBTC Yield Route

The Base BTC spoke is a separate activation path from the Arbitrum `SleeveABasketAdapter`.

| Venue | Target | Role | Exit rule |
| --- | ---: | --- | --- |
| Aave V3 Base cbBTC | 80% | Conservative cbBTC lending / parking | Primary fallback venue |
| Aerodrome USDC/cbBTC LP | 20% max | Capped yield engine | Exit to Aave when net APY < 4.5% |

Before activation, verify:

1. Coinbase cbBTC address and Chainlink BTC/USD feed for Base.
2. Aave V3 Base cbBTC reserve status, supply cap, pause/freeze flags, and withdrawal liquidity.
3. Aerodrome pool address, pool fee, liquidity depth, reward APR, executable exit slippage, and reward-to-cbBTC conversion route.
4. Keeper logic that calculates net Aerodrome APY after fees, slippage, reward conversion, gas, and rebalance expense.
5. Emergency unwind path back to cbBTC, then to Arbitrum USDC only if the user chooses instant market exit.

## Current Adapter Coverage

- Deploys USDC into the configured basket.
- Values positions using Chainlink-style USD feeds.
- Withdraws pro-rata to USDC.
- Rebalances back toward configured weights.
- Uses idle USDC before selling assets during withdrawals.
- Supports emergency unwind of one asset or all assets.
- Prevents changing asset configuration while the adapter still holds value.
