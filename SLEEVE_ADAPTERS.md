# Sleeve Adapter Design

Bridgeway sleeves are now adapter-ready. A sleeve can run in one of two modes:

- Manual accounting: no adapter configured; automation reports sleeve values.
- Adapter accounting: adapter configured; deposits and redemptions route through the adapter, and NAV is read from `totalAssetsUSDC()`.

The canonical asset-selection and weighting rules live in `SLEEVE_POLICY.md`.

## Adapter Interface

Every production adapter must implement `ISleeveAdapter`:

```solidity
function deploy(uint256 usdcAmount) external;
function withdraw(uint256 usdcAmount) external returns (uint256 usdcReturned);
function harvest() external returns (uint256 yieldUsdc);
function totalAssetsUSDC() external view returns (uint256);
```

The vault transfers USDC to the adapter before calling `deploy()`. During redemption, the vault calls `withdraw()` and expects USDC back. For NAV, the vault trusts only `totalAssetsUSDC()`.

## Sleeve A: Growth

Purpose: top-10 non-stable crypto exposure, market-cap weighted with caps.

Policy:

- Top 10 crypto assets by market cap, excluding stablecoins.
- Market-cap weighted inside Sleeve A.
- Maximum 30% of Sleeve A per asset.
- Minimum 3% of Sleeve A per asset.
- Monthly rebalance on the 15th, using the approved policy weights.

Possible adapter:

- swap USDC into approved top-10 assets according to policy weights
- deposit into Aave or equivalent lending markets
- value assets through Chainlink or a vetted oracle path
- harvest any rewards into USDC

Implemented base adapter:

- `SleeveABasketAdapter` deploys USDC into a configurable basket of up to 10 approved assets.
- Each configured asset must respect the Sleeve A 3% minimum and 30% maximum weight.
- Weights must sum to 100%.
- NAV is calculated from Chainlink-style token/USD feeds and token balances.
- Withdrawals sell basket positions pro-rata back to USDC.
- Buy and sell paths are configured per asset so routes can use liquid connector assets instead of requiring direct pairs.
- Asset configuration can be changed only while the adapter is empty; an active basket must be unwound before replacing the approved asset list.
- `rebalance()` sells overweight assets and buys underweight assets back toward the configured weights.
- `emergencyUnwindAsset()` and `emergencyUnwindAll()` can exit positions into USDC without relying on fresh oracle prices.
- The adapter is intentionally generic; governance/founder approval still controls which real assets, feeds, and routes are safe to use.

## Sleeve B: Stability

Purpose: lower-volatility stablecoin yield.

Policy:

- Trusted stablecoins or stablecoin exposures with approved yield venues.
- Issuers must be trusted, liquid, and redemption-reliable.
- Yield is optimized within approved risk and venue caps.
- Non-yielding stablecoins are excluded unless temporarily needed as a liquidity buffer.
- Weakly backed or algorithmic stables require explicit governance approval.
- A single issuer may be capped up to 50% of Sleeve B if governance/founder approval accepts the concentration.

Possible adapter:

- keep exposure mostly in USDC-denominated lending vaults
- prefer audited, liquid, withdrawal-friendly markets
- value positions as USDC unless the stable asset depegs beyond configured oracle bounds

Implemented base adapter:

- `SleeveBStableYieldAdapter` deploys USDC 70% to Aave V3 USDC and 30% to an approved Morpho-style ERC4626 USDC vault.
- The Morpho vault must report USDC as its ERC4626 `asset()`.
- NAV is the adapter's idle USDC, aUSDC balance, and Morpho shares converted back to USDC assets.
- Withdrawals use idle USDC first, then Aave liquidity, then Morpho. The owner can call `rebalance()` after withdrawals or yield movement to restore the 70/30 policy.
- Sleeve B yield remains inside the sleeve for compounding; `harvest()` only returns idle USDC accidentally left in the adapter.

## Sleeve C: Alpha

Purpose: capped, higher-risk yield opportunities.

Policy:

- Pendle PT tokens approved by governance
- GMX / GLP-style positions if liquid and oracle-supported
- selected restaking or structured-yield positions
- Morpho Blue isolated markets with strict caps
- no RWA, tokenized equity, S&P 500, Nasdaq 100, ETF, or equity-index exposure

Possible adapter:

- use explicit position caps
- expose conservative USDC valuation
- require unwind support before large redemptions
- avoid assets without reliable pricing and exit liquidity
- harvest realized yield into USDC and return or route it for Sleeve B compounding
- never auto-compound realized Sleeve C yield back into Sleeve C positions
- support one-way monthly rebalance flows out of Sleeve C only; automatic rebalancing must not push Sleeve A or Sleeve B value into Sleeve C

Implemented base adapter:

- `SleeveCAlphaYieldAdapter` accepts up to six approved ERC4626 strategies whose underlying asset is USDC.
- Each strategy is capped at 50% of Sleeve C, so no single alpha venue can dominate the sleeve.
- Weights must sum to 100%, and strategy configuration can be changed only when the adapter is empty.
- The adapter tracks accounting principal separately from NAV.
- `harvest()` realises only growth above accounting principal, returns that yield as USDC to the vault, and leaves principal in Sleeve C.
- This adapter is meant for USDC-denominated wrappers around approved higher-yield venues. Direct non-USDC positions still need a separate audited adapter with oracle and swap-risk controls.

## Trusted Asset Confirmation

At launch, trusted sleeve assets and sleeve adapters are managed by the founder multisig. Once the system is ready, the founder calls:

```solidity
activateSleeveGovernance()
```

After activation, direct founder changes are disabled. Sleeve asset and adapter changes must go through BGW-GOV voting.

Before any adapter is used, governance should call:

```solidity
setTrustedSleeveAsset(sleeveId, asset, true)
```

or batch:

```solidity
setTrustedSleeveAssetBatch(sleeveId, assets, true)
```

Trusted assets are automatically protected from `recoverToken()`, so strategy positions cannot be accidentally swept. Removing an asset from a sleeve should happen only after the adapter fully exits that position. The token should remain protected until governance also confirms it is safe to remove from `protectedTokens`.

Recommended process:

1. Define target assets for a sleeve in a governance proposal.
2. Confirm oracle source, liquidity, smart-contract risk, and unwind path for each asset.
3. Founder proposes the sleeve asset or adapter update.
4. BGW-GOV holders vote for or against the proposal.
5. If votes for exceed votes against after the voting period, anyone may execute it.
6. If no proposal is created or approved, the existing sleeve policy continues unchanged.
7. Run a small deposit, harvest, and redemption test before scaling allocation.

Voting rules:

- Founder proposes.
- Community and founder BGW-GOV holders vote.
- Voting weight uses ERC20Votes snapshot voting power.
- A proposal passes when `forVotes > againstVotes`.
- No approved proposal means no change.

## Mainnet Rule

Do not deploy real capital into an adapter unless all assets it can hold are listed as trusted sleeve assets and protected in the vault.
