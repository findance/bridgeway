# Sleeve C Arbitrum PT Spoke

Use this path for Pendle PT exposure when Ethereum mainnet gas or PT-sUSDe yields are unattractive. The Base vault does not need to be redeployed; this deploys a source-chain spoke for Sleeve C and reports NAV back to the Base hub through the existing hub/spoke plumbing.

## Current Preference

- Source chain: Arbitrum One (`42161`)
- Sleeve: C (`ClearcrestSleeveCPTSpokePortfolio`)
- Strategy: PT-only, no YT
- Entry rule: buy PT only sub-par and only when realized implied APY clears the configured minimum
- Suggested market class: USDai / sUSDai PT markets on Arbitrum, after risk review of the underlying

## Required Public Config

Set these before simulating. Do not put private keys or private RPC keys in committed files.

```bash
export DEPLOY_SLEEVE_C_PT_SPOKE=true
export PT_SPOKE_SOURCE_CHAIN_ID=42161
export PT_SPOKE_OWNER=$PROTOCOL_SAFE
export PT_SPOKE_OPERATOR=$DEPLOYER

# Arbitrum token/market config. Fill these from Pendle + oracle docs and validate code exists.
export CHAIN_USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
export PT_TOKEN=<arbitrum_pt_token>
export PENDLE_PT_MARKET=<arbitrum_pendle_market>
export PENDLE_PT_ORACLE=<arbitrum_pendle_pt_oracle>
export ASSET_USD_PRICE_FEED=<underlying_usd_chainlink_feed>
export PENDLE_ROUTER=<arbitrum_pendle_router>
export PENDLE_PT_TWAP_SECONDS=900
```

## Address Validation

Run this before any broadcast:

```bash
echo "ARB_CHAIN_ID=$(cast chain-id --rpc-url $ARBITRUM_RPC_URL)"
echo "CHAIN_USDC_CODE=$(cast code $CHAIN_USDC --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "PT_TOKEN_CODE=$(cast code $PT_TOKEN --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "PENDLE_MARKET_CODE=$(cast code $PENDLE_PT_MARKET --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "PENDLE_ORACLE_CODE=$(cast code $PENDLE_PT_ORACLE --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "ASSET_FEED_CODE=$(cast code $ASSET_USD_PRICE_FEED --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "PENDLE_ROUTER_CODE=$(cast code $PENDLE_ROUTER --rpc-url $ARBITRUM_RPC_URL | cut -c1-10)"
echo "PT_NAME=$(cast call $PT_TOKEN 'name()(string)' --rpc-url $ARBITRUM_RPC_URL)"
echo "USDC_SYMBOL=$(cast call $CHAIN_USDC 'symbol()(string)' --rpc-url $ARBITRUM_RPC_URL)"
echo "FEED_DESCRIPTION=$(cast call $ASSET_USD_PRICE_FEED 'description()(string)' --rpc-url $ARBITRUM_RPC_URL)"
echo "FEED_DECIMALS=$(cast call $ASSET_USD_PRICE_FEED 'decimals()(uint8)' --rpc-url $ARBITRUM_RPC_URL)"
```

Expected:

- `ARB_CHAIN_ID=42161`
- all `*_CODE` values start with `0x60806040` or otherwise are not `0x`
- USDC symbol is `USDC`
- PT name matches the intended Arbitrum PT market and maturity
- feed description matches the PT underlying, not an unrelated asset

## Simulate

```bash
forge script scripts/deploy/16_DeployPTSpokePortfolio.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --account clearcrest-deployer-v2
```

## Broadcast

Broadcast only after the simulation prints the intended Arbitrum PT, market, and source chain id.

```bash
forge script scripts/deploy/16_DeployPTSpokePortfolio.s.sol \
  --rpc-url $ARBITRUM_RPC_URL \
  --account clearcrest-deployer-v2 \
  --broadcast
```

## After Deploy

- Save `PT_SPOKE_PORTFOLIO`.
- Wire/report through the existing Base hub/spoke path.
- Keep Sleeve C deposit weight at `0` until the Arbitrum PT spoke reports a valid NAV and fork tests pass.
- For first capital, use a small guarded `buyPtWithUsdc` with explicit `maxPtPriceUsdc18` and `minImpliedApyBps`.
