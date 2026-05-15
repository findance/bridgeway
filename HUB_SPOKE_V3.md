# Bridgeway V3 Hub-Spoke Foundation

Bridgeway V3 keeps the user-facing vault and BGW accounting on a hub chain,
while native-chain spokes hold and stake assets where liquidity is strongest.

## V3 Boundary

- Hub chain: BGW mint/redeem, global NAV cache, fee logic, governance.
- Spoke chains: native asset custody, staking/lending adapters, local NAV.
- CCIP/SmartData layer: confirmed NAV reports from spokes to hub.

The current implementation wires confirmed spoke NAV into `BGWVault` pricing
when the owner connects a deployed `BridgewayHubNAV` through the vault timelock.
Native staking adapters and queued redemption routing are still future phases.

## Contracts

- `BridgewayRegistry`: per-chain asset registry for token addresses, price
  feeds, decimals, and trust flags.
- `BridgewaySpokeReporter`: chain-local NAV reporter scaffold. Future native
  adapters update local NAV, and CCIP relays the report payload to the hub.
- `BridgewayHubNAV`: hub-side confirmed NAV cache. It accepts reports only from
  configured reporters, enforces nonces, rejects stale reports, and bounds
  reported NAV movement.
- `BridgewayCCIPNAVReceiver`: hub-chain CCIP entry point. It accepts messages
  only from the configured Chainlink router, verifies the source chain selector
  and exact source sender bytes, then forwards the decoded NAV report to
  `BridgewayHubNAV`.
- `BridgewayNativeSpokePortfolio`: chain-local native asset portfolio. It
  aggregates approved native staking adapters and prepares monotonic NAV
  reports for CCIP relay.
- `ERC4626NativeStakingAdapter`: generic EVM-chain adapter for approved
  native staking/lending wrappers that expose ERC4626-style accounting.
- `BGWVault`: optional `hubNAV` integration. `totalNAV()` is local sleeve NAV
  plus confirmed spoke NAV; `totalLocalNAV()` and `totalSpokeNAV()` expose the
  split for monitoring. Large redemptions that cannot be covered by local NAV
  are burned immediately and queued as claimant liabilities.

## Safety Rules

- No optimistic NAV is used for redemptions.
- A spoke report is usable only after confirmed delivery to the hub.
- Material spokes block aggregate NAV if their report is stale.
- Reporters are allowlisted per source chain.
- CCIP source selectors are not EVM chain IDs. The receiver maps each CCIP
  selector to the expected Bridgeway spoke chain ID.
- Source sender bytes are hashed and pinned per CCIP selector.
- Report nonces must increase monotonically.
- Queued redemptions remain NAV liabilities until the hub acknowledges that the
  matching local/spoke NAV has been removed from active accounting.
- Values are normalized to 18-decimal USD internally and can be exposed as
  6-decimal USDC for vault integration.

## Deployment Path

1. Deploy one `BridgewayRegistry` per chain.
2. Configure chain-local token and oracle addresses in that chain's registry.
3. Deploy spoke reporters next to native-chain adapters.
4. Deploy hub NAV cache on the hub chain with `05_DeployHubNAV.s.sol`.
5. Deploy hub-chain CCIP receiver with `06_DeployCCIPNAVReceiver.s.sol`.
6. Configure each CCIP source with `configureSource(ccipSelector, spokeChainId,
   sourceSenderBytes, true)`.
7. Configure `BridgewayHubNAV` so each spoke reporter is the CCIP receiver.
8. Wire the deployed hub NAV into `BGWVault` with `proposeHubNAVUpdate()`, wait
   the vault timelock, then call `executeHubNAVUpdate()`.
9. Keep enough Arbitrum USDC/local sleeve liquidity for normal redemptions until
   Phase 5 queued redemption routing is implemented.
10. For queued redemptions, unwind spoke liquidity, update/confirm the spoke NAV
    drop, call `acknowledgeQueuedRedemptionLiquidity()`, then let the claimant
    call `claimQueuedRedemption()`.

## Pinned Roadmap

### Phase 1: Registry + Chain Configs - Complete

- Add `BridgewayRegistry`.
- Make adapters chain-aware.
- Prepare Arbitrum, Base, and other chain configs.

Phase 1 completion notes:

- `SleeveABasketAdapter` can now resolve token, oracle, decimals, and trust
  status from `BridgewayRegistry`.
- Arbitrum seed config includes USDC, WETH, WBTC, and LINK.
- Base seed config includes USDC, WETH, cbBTC, and Chainlink-documented LINK.
- `04_DeployAndConfigureRegistry.s.sol` deploys and seeds a chain-local
  registry based on `block.chainid`.

### Phase 2: Hub-and-Spoke Accounting - Complete

- Arbitrum Hub remains the BGW mint, redeem, and accounting chain.
- Spokes hold assets on native chains.
- Spokes expose `totalAssets()`.
- Hub stores confirmed NAV reports from each spoke.

Phase 2 completion notes:

- `BridgewaySpokeReporter` now exposes both `totalAssets()` and
  `totalAssetsUSDC()` for dashboard and vault-style integrations.
- `BridgewayHubNAV` remains the confirmed spoke NAV cache with reporter,
  staleness, nonce, and NAV-movement checks.
- `BGWVault` can now be timelock-wired to a `BridgewayHubNAV` contract.
- `totalNAV()` prices BGW from local sleeve NAV plus confirmed spoke NAV.
- `totalLocalNAV()` and `totalSpokeNAV()` separate hub-chain liquidity from
  remote spoke accounting.
- Local sleeve reductions for redemptions and fees are calculated against
  local NAV only. Remote spoke NAV is not silently reduced until Phase 5
  redemption routing exists.
- `05_DeployHubNAV.s.sol` deploys the hub NAV cache for the accounting chain.

### Phase 3: CCIP Reporting - Complete

- Spokes send confirmed NAV updates to Hub.
- Hub rejects stale or unauthorized reports.
- Pause mint/redeem if critical spoke data is stale.

Phase 3 completion notes:

- `BridgewayCCIPNAVReceiver` is the only contract that should be allowlisted as
  the reporter in `BridgewayHubNAV` for CCIP-driven spokes.
- The receiver rejects messages from any caller other than the configured CCIP
  router.
- The receiver rejects unconfigured CCIP source selectors and mismatched source
  sender bytes.
- The receiver verifies that the report payload's spoke chain ID matches the
  configured spoke chain ID for that CCIP selector.
- The repo targets Chainlink CCIP v1.6 contracts for the v3 design. This keeps
  the EVM receiver path compatible with current routers while aligning future
  Solana/native-spoke work with Chainlink's non-EVM CCIP architecture.
- `BridgewayHubNAV` still enforces stale-report, nonce, unauthorized reporter,
  disabled spoke, and NAV-movement checks after CCIP validation.
- `BGWVault` mint/redeem pricing already calls `totalNAV()`, so material stale
  spoke data blocks mint/redeem through the hub NAV stale-report revert.
- `06_DeployCCIPNAVReceiver.s.sol` deploys the hub-chain CCIP receiver.

### Phase 4: Native Staking Adapter Foundation - Complete

- SOL on Solana/Jito.
- AVAX on Avalanche/Benqi.
- BNB on BNB Chain.
- LINK via Ethereum/stake.link.
- BTC via Lombard/Babylon route.

Phase 4 completion notes:

- `ERC4626NativeStakingAdapter` supports EVM-compatible native-chain staking
  wrappers where the approved provider exposes ERC4626-style share accounting.
- The adapter stakes asset already transferred to it, withdraws asset back to
  the spoke/controller, values positions through Chainlink-style USD feeds, and
  rejects stale or invalid oracle prices.
- `BridgewayNativeSpokePortfolio` aggregates one or more native staking
  adapters into a single spoke NAV and prepares nonce-incrementing reports for
  CCIP relay.
- Phase 4 is protocol-address agnostic: Jito, Benqi, stake.link, Lombard, and
  Babylon route addresses must be approved per chain before deployment.
- EVM-native legs such as AVAX, BNB-chain assets, LINK wrappers, and BTC
  wrapper/restaking vaults can use this adapter when their approved wrapper is
  ERC4626-compatible.
- Solana/Jito cannot be deployed from this Solidity repo. It needs a Solana
  program or trusted Solana-side reporter that emits the same report payload
  format for the Phase 3 CCIP receiver.
- `07_DeployNativeERC4626Spoke.s.sol` deploys a spoke portfolio plus one
  ERC4626 native staking adapter.

### Phase 5: Redemption Routing - Complete

- Normal redemptions paid from the Arbitrum USDC buffer.
- Large redemptions become queued.
- Spokes unwind and route liquidity back to Arbitrum.
- BNB Chain is not an approved USDC settlement chain. BNB exposure must be held
  as native BNB in a spoke, reported to the hub as USD NAV, then unstaked and
  routed back to Arbitrum USDC before any queued redemption is claimable.

Phase 5 completion notes:

- `redeem()` still pays normal redemptions immediately when local hub-chain NAV
  can cover the gross redemption amount.
- If the gross redemption is larger than local NAV, the vault burns BGW
  immediately, computes exit/performance fees at the current confirmed NAV, and
  stores a queued redemption for the claimant.
- Queued redemption gross value is subtracted from holder NAV through
  `totalQueuedRedemptionNAVLiability`, so remaining holders do not receive an
  artificial NAV increase while remote assets are unwinding.
- A queued redemption cannot be claimed until owner/automation calls
  `acknowledgeQueuedRedemptionLiquidity()` for that redemption. This should only
  happen after the corresponding spoke NAV has dropped or matching liquidity is
  otherwise no longer counted in active NAV.
- `claimQueuedRedemption()` pays the claimant from Arbitrum USDC liquidity and
  routes exit/performance fees through the existing fee logic.
- Tests cover automatic queuing, NAV liability accounting, not-ready claim
  rejection, spoke NAV drop relay, acknowledgement, and final claimant payout.
