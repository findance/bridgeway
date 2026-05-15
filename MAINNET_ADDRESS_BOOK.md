# Bridgeway Mainnet Address Book

This file separates confirmed deployment inputs from values that still need
operator verification. Do not deploy from an address copied only from chat or a
markdown table. Every row must be verified against the official source and by an
on-chain probe before mainnet use.

## Confirmed Registry Seeds

These are the chain-local assets currently seeded by
`BridgewayChainConfig`.

| Chain | Chain ID | Asset | Token | Price feed | Token decimals | Feed decimals | Source |
| --- | ---: | --- | --- | --- | ---: | ---: | --- |
| Arbitrum One | 42161 | USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` | 6 | 8 | Circle / Chainlink |
| Arbitrum One | 42161 | WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | 18 | 8 | Arbitrum / Chainlink |
| Arbitrum One | 42161 | WBTC | `0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f` | `0x6ce185860a4963106506C203335A2910413708e9` | 8 | 8 | WBTC / Chainlink |
| Arbitrum One | 42161 | LINK | `0xf97f4df75117a78c1A5a0DBb814Af92458539FB4` | `0x86E53CF1B870786351Da77A57575e79CB55812CB` | 18 | 8 | Chainlink |
| Base | 8453 | USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x51597f405303C4377E36123cBc172b13269EA163` | 6 | 8 | Circle / Chainlink |
| Base | 8453 | WETH | `0x4200000000000000000000000000000000000006` | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | 18 | 8 | Base / Chainlink |
| Base | 8453 | cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` | 8 | 8 | Coinbase / Chainlink |
| Base | 8453 | LINK | `0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196` | `0x17CAb8FE31E32f08326e5E27412894e49B0f9D65` | 18 | 8 | Chainlink |

## Confirmed Chain IDs

| Chain | EVM chain ID |
| --- | ---: |
| Ethereum mainnet | 1 |
| Arbitrum One | 42161 |
| Base | 8453 |
| Avalanche C-Chain | 43114 |
| BNB Chain | 56 |

## Confirmed CCIP Inputs

| Chain | EVM chain ID | CCIP selector | Router | Source |
| --- | ---: | ---: | --- | --- |
| Arbitrum One | 42161 | `4949039107694359620` | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` | Chainlink CCIP Directory |

## Confirmed Testnet CCIP Inputs

These values are for testing only. Never use them in a mainnet deployment.

| Chain | EVM chain ID | CCIP selector | Router | Source |
| --- | ---: | ---: | --- | --- |
| Arbitrum Sepolia | 421614 | `3478487238524512106` | `0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165` | Chainlink CCIP Testnet Directory |

## Manual Confirmation Required

These inputs are intentionally not hardcoded as confirmed deployment values yet.

| Area | What remains |
| --- | --- |
| CCIP selectors | Arbitrum One mainnet and Arbitrum Sepolia testnet are confirmed. Re-copy each remaining selector directly from the current Chainlink CCIP directory immediately before deployment. Do not infer from old tables. |
| CCIP routers | Arbitrum One mainnet and Arbitrum Sepolia testnet are confirmed. Pick the router version that matches the imported CCIP interfaces and confirm each remaining router from the current Chainlink CCIP directory. |
| Source sender bytes | Fill only after each spoke reporter is deployed. The hub must pin exact encoded sender bytes per CCIP selector. |
| Owner and operator addresses | Replace all EOAs with approved multisigs for owner, automation, treasury, and pause roles. |
| Native staking wrappers | Confirm exact protocol contracts for wstETH, LBTC, sAVAX, BNB staking, stake.link/LINK, and any ERC4626-compatible wrappers. |
| BNB USDC | Decide whether to use Binance-peg USDC or avoid USDC on BNB. Circle's public supported-chain list does not currently make BNB native USDC a confirmed Bridgeway input. |
| cbBTC outside Base/Ethereum | Treat any Arbitrum cbBTC address as unapproved until Coinbase documentation and liquidity are verified. |

## Operator Verification Standard

1. Pull token and oracle addresses from the official protocol or Chainlink page.
2. Convert every address through an EIP-55 checksum validator.
3. Run `ProbeMainnetAddresses` on the target chain fork or RPC.
4. For tokens, verify `symbol()` and `decimals()`.
5. For feeds, verify `decimals()` and that `latestRoundData()` returns a positive, non-stale answer.
6. Save the source URL and explorer URL next to each approved address.
7. Have a second operator repeat the verification before deployment.
