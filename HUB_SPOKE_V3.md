# Bridgeway V3 Hub-Spoke Foundation

Bridgeway V3 keeps the user-facing vault and BGW accounting on a hub chain,
while native-chain spokes hold and stake assets where liquidity is strongest.

## V3 Boundary

- Hub chain: BGW mint/redeem, global NAV cache, fee logic, governance.
- Spoke chains: native asset custody, staking/lending adapters, local NAV.
- CCIP/SmartData layer: confirmed NAV reports from spokes to hub.

The current implementation is an infrastructure scaffold only. It does not
change `BGWVault` mint/redeem behavior yet.

## Contracts

- `BridgewayRegistry`: per-chain asset registry for token addresses, price
  feeds, decimals, and trust flags.
- `BridgewaySpokeReporter`: chain-local NAV reporter scaffold. Future native
  adapters update local NAV, and CCIP relays the report payload to the hub.
- `BridgewayHubNAV`: hub-side confirmed NAV cache. It accepts reports only from
  configured reporters, enforces nonces, rejects stale reports, and bounds
  reported NAV movement.

## Safety Rules

- No optimistic NAV is used for redemptions.
- A spoke report is usable only after confirmed delivery to the hub.
- Material spokes block aggregate NAV if their report is stale.
- Reporters are allowlisted per source chain.
- Report nonces must increase monotonically.
- Values are normalized to 18-decimal USD internally and can be exposed as
  6-decimal USDC for vault integration.

## Deployment Path

1. Deploy one `BridgewayRegistry` per chain.
2. Configure chain-local token and oracle addresses in that chain's registry.
3. Deploy spoke reporters next to native-chain adapters.
4. Deploy hub NAV cache on the hub chain.
5. Wire CCIP receivers to call `reportSpokeNAV()` after validating source
   chain and source sender.
6. Integrate confirmed hub NAV into `BGWVault` only after spoke reporting,
   stale-report handling, and redemption queues are audited.
