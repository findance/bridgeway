# Bridgeway Sleeve Policy

This document is the source of truth for the intended asset policy inside the 70/25/5 sleeve allocation. At launch, the founder multisig approves the initial asset lists. After `activateSleeveGovernance()`, changes require BGW-GOV voting.

## Global Sleeve Targets

| Sleeve | Target |
| --- | ---: |
| Sleeve A — Growth | 70% |
| Sleeve B — Stability | 25% |
| Sleeve C — Alpha | 5% |

## Ingress Rule

External users may enter Bridgeway from any supported chain or asset through frontend routing, but the vault deposit asset remains Arbitrum USDC. Routing should convert or bridge the user's source asset into Arbitrum USDC before calling `deposit()`.

- Preferred routing stack: LI.FI or Socket for route discovery.
- Preferred USDC rail: Circle CCTP where available.
- Fallback bridge rails: Across or deBridge where suitable.
- Once Arbitrum USDC is deposited, BGWVault allocates across Sleeve A, Sleeve B, and Sleeve C according to the approved sleeve policies.
- The routing layer must not bypass sleeve asset approvals, oracle checks, or adapter controls.

## Rebalance Rule

Rebalancing is automatic once per month, targeted for the 15th day of each month.

- Monthly rebalance is calendar-based, not drift-triggered.
- Sleeve A and Sleeve B rebalance against the 70% / 25% targets.
- Sleeve A and Sleeve B may temporarily sit above their targets to avoid funding Sleeve C.
- Sleeve C is one-way: value may flow from Sleeve C into Sleeve B or Sleeve A, but fresh value must not flow from Sleeve A or Sleeve B back into Sleeve C during automatic rebalancing.
- Sleeve C should only shrink or remain unchanged during automatic monthly rebalancing.
- Sleeve C can receive new capital only through a separate explicit founder/governance-approved strategy allocation, not through the monthly rebalance path.

## Sleeve A — Growth

Sleeve A holds the top 10 crypto assets by market capitalization, excluding stablecoins.

Selection rules:

- Include the top 10 non-stable crypto assets by market cap.
- Exclude stablecoins, algorithmic stables, bridged duplicates, wrapped duplicates, and assets without a supported Arbitrum execution path.
- Use the most liquid, canonical Arbitrum-compatible representation for each approved asset.
- Founder approves the initial list; later changes require BGW-GOV proposal approval.

Weighting rules:

- Initial launch weights may be founder-approved fixed weights. Later weights should be updated by founder/governance proposal.
- Maximum 30% of Sleeve A per asset.
- Minimum 3% of Sleeve A per included asset.
- If an asset falls below the 3% floor after market-cap weighting, raise it to 3% and proportionally scale down the uncapped assets.
- If an asset exceeds the 30% cap, cap it at 30% and proportionally redistribute the excess to uncapped assets.

Initial proposed Sleeve A weights:

| Asset | Weight |
| --- | ---: |
| BTC | 25% |
| ETH | 25% |
| BNB | 8% |
| SOL | 8% |
| XRP | 7% |
| LINK | 7% |
| ADA | 6% |
| AVAX | 5% |
| TRX | 5% |
| DOGE | 4% |

This keeps BTC and ETH at 50% combined, places DOGE as the smallest approved exposure, and allocates the remaining 50% across the other eight assets.

Rebalancing:

- Scheduled rebalance: monthly on the 15th, together with the global sleeve rebalance.
- Emergency rebalance allowed only for depeg-like wrapped asset failure, oracle failure, protocol exploit, sanctions/compliance event, or loss of viable liquidity.
- Existing policy continues unchanged if no new proposal is approved.

Yield:

- Native staking or liquid staking yield where applicable.
- Lending yield through approved venues such as Aave, where the risk is acceptable.
- Rewards are harvested by the adapter, converted or compounded according to the approved adapter logic, and reflected in `totalAssetsUSDC()`.

BTC launch route:

- BTC exposure is approved through a Base cbBTC spoke adapter once deployed and verified.
- The default cbBTC deployment policy is 80% Aave V3 Base cbBTC supply and 20% Aerodrome USDC/cbBTC LP.
- The Aerodrome leg is a capped yield engine, not core BTC custody. Its net APY must be measured after pool fees, slippage, reward conversion, operating gas, and expected rebalance expense.
- If Aerodrome net APY falls below 2.5%, the keeper should withdraw the Aerodrome leg and move that allocation into Aave V3 Base cbBTC.
- Morpho cbBTC vaults are excluded at launch because curated vault performance fees and curator risk are not needed for the first BTC route.
- LBTC remains a future BTC yield candidate only after the standard 1:1 delayed redemption and instant market-exit flows are implemented.

## Sleeve B — Stability

Sleeve B holds trusted stablecoins or stablecoin exposures from trusted issuers, optimized for safe yield. Non-yielding stablecoins are excluded unless temporarily needed as a liquidity buffer.

Sleeve B priority order:

1. Safety
2. Liquidity
3. Yield

Selection rules:

- Include only stablecoins with trusted issuers, transparent backing, deep liquidity, reliable redemption/market structure, and an approved yield venue.
- Do not include a stablecoin only to fill a target count; use fewer assets if fewer assets qualify.
- Reject algorithmic stablecoins by default.
- Exclude unbacked or weakly backed stablecoins unless explicitly approved by governance.
- Consider issuer concentration and chain-specific liquidity before approval.
- A stablecoin's headline APY must not override issuer, redemption, liquidity, or oracle risk.

Issuer scoring:

| Category | Weight |
| --- | ---: |
| Reserve quality | 25 |
| Transparency / attestations | 15 |
| Redemption reliability | 15 |
| Regulatory posture | 10 |
| Liquidity depth | 10 |
| Depeg history | 10 |
| Smart-contract / bridge risk | 10 |
| Yield venue availability | 5 |
| Total | 100 |

Approval thresholds:

- Score >= 80: qualifies for Sleeve B, subject to governance/founder approval.
- Score 70-79: requires explicit risk exception in the proposal.
- Score < 70: rejected.
- Algorithmic stablecoins are rejected by default regardless of score unless governance explicitly overrides the policy.

Scoring guidance:

- Reserve quality favors cash, short-duration T-bills, repo, regulated custodians, and low credit risk.
- Transparency favors frequent third-party attestations, clear reserve composition, and clear redemption terms.
- Redemption reliability favors issuers with proven direct redemption paths and minimal historical delays.
- Regulatory posture favors clear licensing, credible jurisdiction, and low enforcement uncertainty.
- Liquidity depth must consider Arbitrum liquidity, CEX liquidity, lending market depth, and expected slippage to USDC.
- Depeg history must consider frequency, severity, duration, and recovery cause.
- Smart-contract / bridge risk penalizes bridged-only assets, complex upgradeability, weak admin controls, and unaudited wrappers.
- Yield venue availability favors Aave, Morpho, or similarly vetted venues with reliable oracle and withdrawal paths.

Weighting rules:

- Yield-optimized within risk limits rather than pure market-cap weighted.
- No single issuer should dominate the sleeve unless governance explicitly approves.
- Venue caps should be set per adapter before deployment.
- Suggested max per issuer: 50% of Sleeve B.
- Suggested minimum per approved stablecoin exposure: 5% of Sleeve B.
- Keep a liquid USDC reserve when adapter liquidity or redemption timing requires it.

Yield:

- Aave, Morpho, or other approved lending venues.
- Adapter should prefer withdrawal reliability and conservative valuation over headline APY.
- Compounding should happen inside the Sleeve B adapter by harvesting rewards, converting them into approved stable exposure, redeploying into approved venues, and reporting updated `totalAssetsUSDC()`.
- Realized Sleeve C yield must be converted to USDC, transferred into Sleeve B, and compounded through the approved Sleeve B adapter.

Review cadence:

- Re-score approved stablecoins at least monthly.
- Re-score immediately after any depeg, reserve disclosure change, regulatory event, bridge incident, oracle issue, or major liquidity change.

## Sleeve C — Alpha

Sleeve C is capped at 5% of total vault NAV and is reserved for higher-yield strategies.

Allowed strategy types:

- Pendle PT / fixed-yield positions.
- GMX/GLP-style yield positions.
- Morpho isolated markets.
- Restaking or LRT positions only after explicit governance approval.

Excluded strategy types:

- RWA, tokenized equities, S&P 500, Nasdaq 100, ETF, or equity-index exposure.
- Any tokenized security, security-based swap, or off-chain fund exposure unless the protocol is redesigned as a compliant permissioned product.

Yield handling:

- Sleeve C principal remains capped inside Sleeve C.
- Sleeve C yield must be harvested, converted to USDC, moved into Sleeve B, and compounded through approved stablecoin yield venues.
- Sleeve C adapters must not auto-compound realized yield back into Sleeve C positions.

Risk rules:

- Every strategy must have a hard cap.
- Every strategy must have a reliable valuation method.
- Every strategy must have a documented unwind path.
- Illiquid or delayed-withdrawal strategies must be sized conservatively.

Rebalancing:

- Sleeve C is not topped up by automatic monthly rebalancing.
- If Sleeve C is above the intended cap, excess value may be harvested or unwound into Sleeve B or Sleeve A.
- If Sleeve C is below 5%, the shortfall remains in Sleeve A/B unless a separate founder/governance-approved proposal allocates capital to Sleeve C.
- Emergency exit can be proposed if a strategy’s oracle, liquidity, or protocol risk changes materially.

## Governance Rule

No asset or adapter change is automatic. If no new proposal is approved, the current sleeve asset list, weights, and adapter configuration continue.
