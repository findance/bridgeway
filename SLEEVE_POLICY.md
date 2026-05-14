# Bridgeway Sleeve Policy

This document is the source of truth for the intended asset policy inside the 70/25/5 sleeve allocation. At launch, the founder multisig approves the initial asset lists. After `activateSleeveGovernance()`, changes require BGW-GOV voting.

## Global Sleeve Targets

| Sleeve | Target |
| --- | ---: |
| Sleeve A — Growth | 70% |
| Sleeve B — Stability | 25% |
| Sleeve C — Alpha | 5% |

## Sleeve A — Growth

Sleeve A holds the top 10 crypto assets by market capitalization, excluding stablecoins.

Selection rules:

- Include the top 10 non-stable crypto assets by market cap.
- Exclude stablecoins, algorithmic stables, bridged duplicates, wrapped duplicates, and assets without a supported Arbitrum execution path.
- Use the most liquid, canonical Arbitrum-compatible representation for each approved asset.
- Founder approves the initial list; later changes require BGW-GOV proposal approval.

Weighting rules:

- Market-cap weighted.
- Maximum 30% of Sleeve A per asset.
- Minimum 3% of Sleeve A per included asset.
- If an asset falls below the 3% floor after market-cap weighting, raise it to 3% and proportionally scale down the uncapped assets.
- If an asset exceeds the 30% cap, cap it at 30% and proportionally redistribute the excess to uncapped assets.

Rebalancing:

- Scheduled rebalance: quarterly.
- Emergency rebalance allowed only for depeg-like wrapped asset failure, oracle failure, protocol exploit, sanctions/compliance event, or loss of viable liquidity.
- Existing policy continues unchanged if no new proposal is approved.

Yield:

- Native staking or liquid staking yield where applicable.
- Lending yield through approved venues such as Aave, where the risk is acceptable.
- Rewards are harvested by the adapter, converted or compounded according to the approved adapter logic, and reflected in `totalAssetsUSDC()`.

## Sleeve B — Stability

Sleeve B holds the top 5 trusted stablecoins or stablecoin exposures from trusted issuers, optimized for safe yield.

Sleeve B priority order:

1. Safety
2. Liquidity
3. Yield

Selection rules:

- Include only stablecoins with trusted issuers, transparent backing, deep liquidity, and reliable redemption/market structure.
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
- Suggested max per issuer: 40% of Sleeve B.
- Suggested minimum per approved stablecoin exposure: 5% of Sleeve B.
- Keep a liquid USDC reserve when adapter liquidity or redemption timing requires it.

Yield:

- Aave, Morpho, or other approved lending venues.
- Adapter should prefer withdrawal reliability and conservative valuation over headline APY.
- Compounding should happen inside the Sleeve B adapter by harvesting rewards, converting them into approved stable exposure, redeploying into approved venues, and reporting updated `totalAssetsUSDC()`.

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

Risk rules:

- Every strategy must have a hard cap.
- Every strategy must have a reliable valuation method.
- Every strategy must have a documented unwind path.
- Illiquid or delayed-withdrawal strategies must be sized conservatively.

Rebalancing:

- Sleeve C drift should be monitored more tightly than Sleeves A/B.
- Emergency exit can be proposed if a strategy’s oracle, liquidity, or protocol risk changes materially.

## Governance Rule

No asset or adapter change is automatic. If no new proposal is approved, the current sleeve asset list, weights, and adapter configuration continue.
