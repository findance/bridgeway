# Sleeve C Arbitrum PT Spoke

Use this path for Pendle PT exposure when Ethereum mainnet gas or PT-sUSDe yields are unattractive. The Base vault does not need to be redeployed; this deploys a source-chain spoke for Sleeve C and reports NAV back to the Base hub through the existing hub/spoke plumbing.

## Current Preference

- Source chain: Arbitrum One (`42161`)
- Sleeve: C (`ClearcrestSleeveCPTSpokePortfolio`)
- Strategy: PT-only, no YT
- Entry rule: buy PT only sub-par and only when realized implied APY clears the configured minimum
- Suggested market class: USDai / sUSDai / thBILL PT markets on Arbitrum, after risk review of the underlying

## Proposed Allocation

Keep the Base vault at `A=6500 / B=3500 / C=0` until the Arbitrum spoke is deployed, has a dust PT balance, and reports NAV back to the Base hub correctly.

After validation, move the vault sleeve deposit weights to:

- Sleeve A: `6000`
- Sleeve B: `3000`
- Sleeve C: `1000`

Within Sleeve C, target a conservative ladder:

- sUSDai PT: `5000`
- USDai PT: `3000`
- thBILL PT: `2000`

thBILL has the highest quoted APY but the thinnest liquidity and KYC/redemption dependency, so it should stay capped unless the issuer and redemption path are fully approved.

Enforce this with per-position caps on the spoke, not only operator convention. Use `setPositionCapUsdc(positionId, capUsdc)` after each position exists. A cap of `0` means uncapped and should not be used for live Sleeve C positions.

## Validated Arbitrum Config

These were validated on Arbitrum One against public RPC before deployment prep.

```bash
export CHAIN_USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
export PENDLE_PT_ORACLE=0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2
export PENDLE_ROUTER=0x888888888889758F76e7103c6CbF23ABbF58F946
export PENDLE_PT_TWAP_SECONDS=900

export ARB_USDC_USD_FEED=0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3
export ARB_USDAI_USD_FEED=0xF3d6b05E69918d71807Ab005791daCcEC5de8C78
```

### sUSDai PT

Use the USDAI/USD feed because this Pendle market's accounting asset is USDai.

```bash
export PT_TOKEN=0x07bc5bD6cE9A17f0e7aa91E0Adbc9070dcB1d1dE
export PENDLE_PT_MARKET=0x299674f6dA858f903D77486fBA50Bc9f2e0DB24D
export ASSET_USD_PRICE_FEED=$ARB_USDAI_USD_FEED
```

Validated:

- PT name: `PT Staked USDai 18JUN2026`
- SY: `0x30Ccf4Bbee313fCD19F3e295b3ba2920A24e2f62`
- YT: `0x7032cEe758fBA530C1c71Ab52de1727E555B8Ed4`
- Maturity: `1781740800`
- PT oracle sample rate: `996631417965046844`

### USDai PT

Use the USDAI/USD feed because this market's accounting asset is USDai.

```bash
export PT_USDAI_TOKEN=0x1cdDE40e29dA213f42A7fA109CcADCA372d9Ee1B
export PENDLE_USDAI_MARKET=0x8A8a557B90ec79496A18A1F9c9da8bbD7dB86Fd3
export USDAI_ASSET_USD_PRICE_FEED=$ARB_USDAI_USD_FEED
```

Validated:

- PT name: `PT USDai 18JUN2026`
- SY: `0x5edCBC20Cac67AdC2e724d4348Ff85132B085b82`
- YT: `0x5De2065F3C709b24f31c736Ef28c1CbB27cEedfc`
- Maturity: `1781740800`
- PT oracle sample rate: `997315850616532980`

### thBILL PT

Use USDC/USD as the feed because this Pendle market's accounting asset is Arbitrum USDC.

```bash
export PT_THBILL_TOKEN=0xE46271ecb1d5c7c5134868760F10c18B03021eF1
export PENDLE_THBILL_MARKET=0x22d95CeC2B962C142Fff9bE88Cfc7EF15043419f
export THBILL_ASSET_USD_PRICE_FEED=$ARB_USDC_USD_FEED
```

Validated:

- PT name: `PT thBILL 18JUN2026`
- SY: `0xc32e96B4C7EB7959B6A92f3f7eD5d2321e6ed3D4`
- YT: `0x58C40BF59d1714D7B84060dE9f7197AcCC0b3954`
- Maturity: `1781740800`
- PT oracle sample rate: `995923519411213753`

## Multi-Position Claim Safety

The spoke supports multiple PT positions and every claim should use `recordClaimForPosition(claimId, recipient, positionId, ptAmount)` once more than one PT token is live. The legacy `recordClaim(...)` remains available for the default position `0`, but Sleeve C operators should treat the position-specific function as mandatory.

Capital limits are also per-position. Guarded buys call the cap check after settlement, so a fill that would push a PT position over its configured cap reverts.

## Prototype Ownership And Emergency Receiver

For prototype testing, deploy the spoke with the deployer as `PT_SPOKE_OWNER` and `PT_SPOKE_OPERATOR`. This keeps caps, added positions, pause/unpause, and dust emergency recovery fast. The contract initializes `emergencyReceiver` to the owner, so before finalize it points at the deployer.

Before real allocation or moving Sleeve C above `0`, run the production handoff:

1. `setEmergencyReceiver(PROTOCOL_SAFE)`
2. `setOperator(<production_operator_or_ccip_handler>)`
3. `setClaimRecorder(<production_ccip_claim_recorder>)`
4. `transferOwnership(PROTOCOL_SAFE)`
5. Safe accepts ownership

After this handoff, emergency withdraw/redeem proceeds always go to the configured Safe receiver instead of an arbitrary call-time address.

## Required Public Config

Set these before simulating. Do not put private keys or private RPC keys in committed files.

```bash
export DEPLOY_SLEEVE_C_PT_SPOKE=true
export PT_SPOKE_SOURCE_CHAIN_ID=42161
export PT_SPOKE_OWNER=$DEPLOYER
export PT_SPOKE_OPERATOR=$DEPLOYER

# Arbitrum token/market config. Start with one validated market, then add more
# positions through owner governance after deploy.
export CHAIN_USDC=0xaf88d065e77c8cC2239327C5EDb3A432268e5831
export PT_TOKEN=0x07bc5bD6cE9A17f0e7aa91E0Adbc9070dcB1d1dE
export PENDLE_PT_MARKET=0x299674f6dA858f903D77486fBA50Bc9f2e0DB24D
export PENDLE_PT_ORACLE=0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2
export ASSET_USD_PRICE_FEED=0xF3d6b05E69918d71807Ab005791daCcEC5de8C78
export PENDLE_ROUTER=0x888888888889758F76e7103c6CbF23ABbF58F946
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
- After the dust test, add the remaining USDai/thBILL PT positions through owner governance with `addPositionWithFeed(...)`.
- Set per-position caps with `setPositionCapUsdc(...)` before any non-dust buy.
- Only then move Base vault weights to `6000 / 3000 / 1000`.
