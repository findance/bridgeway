# Contracts

This folder will hold the Solidity sources. The authoritative spec is `../bridgeway_spec_v1.3.md`.

## Why the v10 contract from the previous chat is not the starting point

The v10 `BridgewayAutomationWrapper.sol` from the earlier iteration was built against an older design:

- Top 10 non-stable cryptos, market-cap weighted with 30% max / 3% min per asset
- Annual management fee + entry fee (now removed — performance fee only)
- Single token, no separate BGWToken (now requires immutable BGWToken with MINTER_ROLE)
- No sleeve allocation (now configurable strategy sleeves; launch 65/35/0, final target 65/30/5)
- No harvest-and-compound flow (now monthly, automated)

The v1.3 spec is a substantial redesign. The v10 file is a useful reference for patterns (UUPS, Chainlink Automation wiring, Camelot integration, fee splitter logic) but the actual implementation must be written fresh.

## What needs to be built

| File | Purpose |
|---|---|
| `BGWToken.sol` | Immutable ERC-20, 18 decimals, MINTER_ROLE (granted to wrapper only), public `burn()`, pausable, blacklist |
| `BridgewayAutomationWrapper.sol` | UUPS upgradeable wrapper — deposit/redeem entry points, configurable sleeve allocation, monthly harvest+compound, 6-way fee split, buyback engine, Chainlink Automation hooks |
| `adapters/PendlePTAdapter.sol` | Pendle PT-stETH deposit/withdraw/value-read |
| `adapters/GMXGLPAdapter.sol` | GLP mint/burn + reward claim |
| `adapters/MorphoBlueAdapter.sol` | Morpho Blue isolated market deposit/withdraw |
| `adapters/SymbioticAdapter.sol` | Unlevered restaking position management (custom dev, 2–3 weeks) |
| `mocks/` | Mock Enzyme vault, USDC, CCR token, Camelot router, Chainlink price feed for local testing |

## Suggested prompt for VSCode (Claude Code extension)

Open VSCode in this folder and start with:

> Read `../bridgeway_spec_v1.3.md`. Scaffold a Hardhat project here with:
> - `BGWToken.sol` per §4 of the spec (immutable ERC-20 + MINTER_ROLE + pausable + blacklist)
> - `BridgewayAutomationWrapper.sol` skeleton per §6 (UUPS upgradeable, OpenZeppelin upgradeable libraries, Chainlink AutomationCompatibleInterface, Camelot router)
> - Mock contracts under `mocks/`
> - `scripts/deploy.js` that deploys BGWToken first, then the wrapper proxy, then grants MINTER_ROLE
> - `test/` skeleton with one passing test per major function
>
> Don't implement the strategy adapters yet — leave interfaces for them. Target Arbitrum Sepolia for deployment. Build the genesis-bootstrap path (first deposit = $1.00 per CCR) into the wrapper's deposit logic.

## Things to remember when implementing

- **Genesis bootstrap rule** (§4): first deposit mints CCR 1:1 with USDC value (NAV per CCR starts at $1.00). All later deposits use the pro-rata formula. Handle the `totalSupply == 0` case in deposit logic.
- **`recordStakingYield`**: for testnet, owner-trusted is acceptable. Spec §8.1 requires on-chain derivation before mainnet — design the interface so the verification path can be added later without breaking ABI compatibility.
- **UUPS upgrade**: spec §8.1 requires a 48h timelock on `upgradeTo()` for mainnet. For testnet a single owner is fine, but write the contract so the owner address can be swapped to a `TimelockController` later without storage layout changes.
- **Monthly rebalance**: run automatically on the 15th. Sleeve A/B rebalance around configured targets; Sleeve C is one-way during automatic rebalancing and must not be topped up from A/B until its routes are enabled.
- **In-kind redemption**: Sleeve C tokens must be transferable to redeemer. Symbiotic/Karak unbonding periods may complicate this — document the behavior in the redeem function.
