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

1. The canonical Base-hub token address or approved spoke custody/reporting path.
2. The Chainlink-style USD price feed address.
3. The maximum oracle staleness window.
4. The buy path from USDC to the asset.
5. The sell path from the asset back to USDC.
6. The maximum slippage setting for the adapter.
7. Liquidity evidence showing the route can support expected deposit, redemption, and rebalance size.
8. Whether the asset is native, bridged, wrapped, or synthetic.

## Step 2 Token Address Review

| Asset | Target | Proposed Base/spoke representation | Source / bridge | Status |
| --- | ---: | --- | --- | --- |
| BTC | 25% | Base cbBTC adapter | Coinbase cbBTC on Base | Approved policy, pending deploy |
| ETH | 25% | Base WETH or Ethereum spoke | Base WETH / future native ETH spoke | Pending final route |
| BNB | 8% | BNB Chain native spoke | Native BNB validator staking later | Deferred |
| SOL | 8% | Solana native spoke | JitoSOL or native SOL custody later | Deferred |
| XRP | 7% | TBD | Manual verification required | Not approved |
| LINK | 7% | Base LINK or Ethereum spoke | Base LINK / future Ethereum source spoke | Pending final route |
| ADA | 6% | TBD | Manual verification required | Not approved |
| AVAX | 5% | Avalanche native spoke | Native AVAX later | Deferred |
| TRX | 5% | TBD | Manual verification required | Not approved |
| DOGE | 4% | TBD | Manual verification required | Not approved |

Do not move a pending candidate into adapter configuration until its explorer page, implementation/proxy or native custody path, bridge source if any, holders, liquidity, oracle, and route are all reviewed.

## Practical Asset Notes

- BTC and Base USDC are the cleanest Base-local launch path because cbBTC, Aave V3 Base, and Aerodrome are all on the chosen hub chain.
- ETH and LINK can be Base-local spot exposures if route depth and oracle checks pass, or future Ethereum spoke exposures if Base custody is not approved.
- BTC exposure should use a Base cbBTC spoke rather than Arbitrum WBTC. The approved policy is 80% Aave V3 Base cbBTC supply and 20% Aerodrome USDC/cbBTC LP, with the Aerodrome leg moved back to Aave if net APY after fees and operating expense drops below 4.5%.
- BNB, XRP, SOL, TRX, DOGE, ADA, and AVAX require extra caution because hub-chain representations may be bridged, wrapped, synthetic, route-limited, or impossible to verify on-chain from Base. Do not activate any of them until the approved spoke and reporting path are verified.
- If an asset lacks a reliable oracle or safe route, it should remain disabled even if it is in the target list.

## Activation Steps

1. Deploy the Base hub vault/token/NAV stack.
2. Deploy `SleeveABasketAdapter` or Base-native successor adapter only after final Base token/feed/routes are approved.
3. Configure only approved local assets and active spokes with tokens, feeds, weights, routes, and staleness rules.
4. Mark each token or spoke as trusted in `BGWVault`.
5. Confirm adapter `totalAssetsUSDC()` equals the current manual Sleeve A value if replacing manual accounting.
6. Set the adapter as `SLEEVE_A` in `BGWVault`.
7. Run a small test deposit, withdrawal, rebalance, and emergency unwind before increasing caps.

## Base cbBTC Yield Route

The Base BTC route is the first Base-hub Sleeve A activation path and should remain separate from any future Arbitrum alpha or spoke adapter.

| Venue | Target | Role | Exit rule |
| --- | ---: | --- | --- |
| Aave V3 Base cbBTC | 80% | Conservative cbBTC lending / parking | Primary fallback venue |
| Aerodrome USDC/cbBTC LP | 20% max | Capped yield engine | Exit to Aave when net APY < 4.5% |

Before activation, verify:

1. Coinbase cbBTC address and Chainlink BTC/USD feed for Base.
2. Aave V3 Base cbBTC reserve status, supply cap, pause/freeze flags, and withdrawal liquidity.
3. Aerodrome pool address, pool fee, liquidity depth, reward APR, executable exit slippage, and reward-to-cbBTC conversion route.
4. Keeper logic that calculates net Aerodrome APY after fees, slippage, reward conversion, gas, and rebalance expense.
5. Emergency unwind path back to cbBTC, then to Base USDC only if the user chooses instant market exit.

Production contracts:

- `AerodromeCbbtcStrategy` wraps one Aerodrome Slipstream concentrated-liquidity NFT, optionally stakes it in the matching CL gauge, and exposes a conservative cbBTC-denominated interface to `BaseCBBTCYieldAdapter`.
- `BaseCBBTCYieldAdapter` enforces the 80% Aave / 20% Aerodrome policy and exits the Aerodrome leg to Aave when `netApyBps < 450`.
- `AerodromeCbbtcStrategy.totalAssetsCbbtc()` uses a keeper mark-to-market value instead of pretending the LP NFT is always worth principal. The keeper mark must be refreshed before `maxMarkStale` expires.
- The Aerodrome AERO reward conversion path is configured separately with `setAeroToCbbtcPath(bytes)`. If unset, AERO rewards stay idle in the strategy and are not counted in cbBTC NAV until converted and marked.

Deploy with `scripts/deploy/13_DeployBaseCBBTCYieldSpoke.s.sol` after filling:

- `CBBTC`, `USDC`, `AERO`
- `AAVE_POOL`, `A_CBBTC`
- `AERODROME_POSITION_MANAGER`, `AERODROME_SWAP_ROUTER`, optional `AERODROME_GAUGE`
- `BTC_USD_PRICE_FEED`
- `AERODROME_TICK_SPACING`, `AERODROME_TICK_LOWER`, `AERODROME_TICK_UPPER`
- `STRATEGY_KEEPER`

## Current Adapter Coverage

- Deploys USDC into the configured basket.
- Values positions using Chainlink-style USD feeds.
- Withdraws pro-rata to USDC.
- Rebalances back toward configured weights.
- Uses idle USDC before selling assets during withdrawals.
- Supports emergency unwind of one asset or all assets.
- Prevents changing asset configuration while the adapter still holds value.
