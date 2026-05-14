# Sleeve Adapter Design

Bridgeway sleeves are now adapter-ready. A sleeve can run in one of two modes:

- Manual accounting: no adapter configured; automation reports sleeve values.
- Adapter accounting: adapter configured; deposits and redemptions route through the adapter, and NAV is read from `totalAssetsUSDC()`.

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

Purpose: long-term crypto growth exposure.

Suggested trusted assets:

- WETH
- WBTC
- wstETH
- Aave aWETH / aWBTC / awstETH

Possible adapter:

- swap USDC into target blue-chip assets
- deposit into Aave or equivalent lending markets
- value assets through Chainlink or a vetted oracle path
- harvest any rewards into USDC

## Sleeve B: Stability

Purpose: lower-volatility stablecoin yield.

Suggested trusted assets:

- USDC
- USDT
- DAI, only if governance accepts the risk
- Aave aUSDC / aUSDT
- Morpho USDC vault shares

Possible adapter:

- keep exposure mostly in USDC-denominated lending vaults
- prefer audited, liquid, withdrawal-friendly markets
- value positions as USDC unless the stable asset depegs beyond configured oracle bounds

## Sleeve C: Alpha

Purpose: capped, higher-risk yield opportunities.

Suggested trusted assets:

- Pendle PT tokens approved by governance
- GMX / GLP-style positions if liquid and oracle-supported
- selected restaking or structured-yield positions
- Morpho Blue isolated markets with strict caps

Possible adapter:

- use explicit position caps
- expose conservative USDC valuation
- require unwind support before large redemptions
- avoid assets without reliable pricing and exit liquidity

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
