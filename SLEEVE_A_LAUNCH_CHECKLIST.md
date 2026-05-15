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

## Practical Asset Notes

- BTC and ETH are the cleanest Sleeve A assets because WBTC/WETH-style assets usually have deep liquidity and reliable oracle support.
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

## Current Adapter Coverage

- Deploys USDC into the configured basket.
- Values positions using Chainlink-style USD feeds.
- Withdraws pro-rata to USDC.
- Rebalances back toward configured weights.
- Uses idle USDC before selling assets during withdrawals.
- Supports emergency unwind of one asset or all assets.
- Prevents changing asset configuration while the adapter still holds value.
