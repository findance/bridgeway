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
| Ethereum Sepolia | 11155111 |
| Ethereum Hoodi | 560048 |
| Arbitrum Sepolia | 421614 |
| Base Sepolia | 84532 |
| Avalanche Fuji | 43113 |
| BNB Chain Testnet | 97 |

## Confirmed CCIP Inputs

| Chain | EVM chain ID | CCIP selector | Router | Source |
| --- | ---: | ---: | --- | --- |
| Ethereum | 1 | `5009297550715157269` | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` | Chainlink CCIP Directory |
| Arbitrum One | 42161 | `4949039107694359620` | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` | Chainlink CCIP Directory |
| Base | 8453 | `15971525489660198786` | `0x881e3A65B4d4a04dD529061dd0071cf975F58bCD` | Chainlink CCIP Directory |
| Avalanche C-Chain | 43114 | `6433500567565415381` | `0xF4c7E640EdA248ef95972845a62bdC74237805dB` | Chainlink CCIP Directory |
| BNB Chain | 56 | `11344663589394136015` | `0x34B03Cb9086d7D758AC55af71584F81A598759FE` | Chainlink CCIP Directory |

## Confirmed Testnet CCIP Inputs

These values are for testing only. Never use them in a mainnet deployment.

| Chain | EVM chain ID | CCIP selector | Router | Source |
| --- | ---: | ---: | --- | --- |
| Ethereum Sepolia | 11155111 | `16015286601757825753` | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` | Chainlink CCIP Testnet Directory |
| Ethereum Hoodi | 560048 | `10380998176179737091` | `0xc93Dac3422660A41500a24C94BF14616995e3CA6` | Chainlink CCIP Testnet Directory |
| Arbitrum Sepolia | 421614 | `3478487238524512106` | `0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165` | Chainlink CCIP Testnet Directory |
| Base Sepolia | 84532 | `10344971235874465080` | `0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93` | Chainlink CCIP Testnet Directory |
| Avalanche Fuji | 43113 | `14767482510784806043` | `0xF694E193200268f9a4868e4Aa017A0118C9a8177` | Chainlink CCIP Testnet Directory |
| BNB Chain Testnet | 97 | `13264668187771770619` | `0xE1053aE1857476f36A3C62580FF9b016E8EE8F6f` | Chainlink CCIP Testnet Directory |

Ethereum Sepolia is the default Bridgeway testnet because it pairs naturally
with Arbitrum Sepolia, Base Sepolia, Avalanche Fuji, and BNB Chain Testnet.
Ethereum Hoodi is a separate Ethereum testnet, useful for Ethereum
infrastructure, staking, or validator-style rehearsal. Keep Hoodi optional until
Bridgeway specifically needs that environment.

## Manual Confirmation Required

These inputs are intentionally not hardcoded as confirmed deployment values yet.

| Area | What remains |
| --- | --- |
| CCIP selectors | Confirmed for Ethereum, Arbitrum, Base, Avalanche, and BNB mainnet plus their listed testnets. Re-copy from the current Chainlink CCIP directory immediately before production deployment. |
| CCIP routers | Confirmed for Ethereum, Arbitrum, Base, Avalanche, and BNB mainnet plus their listed testnets. Verify the router version matches the imported CCIP interfaces before deployment. |
| Source sender bytes | Fill only after each spoke reporter is deployed. The hub must pin exact encoded sender bytes per CCIP selector. |
| Owner and operator addresses | Replace all EOAs with approved multisigs for owner, automation, treasury, and pause roles. |
| Native staking wrappers | Confirm exact protocol contracts for wstETH, LBTC, sAVAX, BNB staking, stake.link/LINK, and any ERC4626-compatible wrappers. |
| BNB USDC | Decide whether to use Binance-peg USDC or avoid USDC on BNB. Circle's public supported-chain list does not currently make BNB native USDC a confirmed Bridgeway input. |
| cbBTC outside Base/Ethereum | Treat any Arbitrum cbBTC address as unapproved until Coinbase documentation and liquidity are verified. |
| CCIP infrastructure metadata | Optional `ccip_infra` rows are documentation and monitoring only. Deploy scripts must not read RMN or registry-module addresses as deployment inputs. |

## Operator Verification Standard

1. Pull token and oracle addresses from the official protocol or Chainlink page.
2. Convert every address through an EIP-55 checksum validator.
3. Run `ProbeMainnetAddresses` on the target chain fork or RPC.
4. For tokens, verify `symbol()` and `decimals()`.
5. For feeds, verify `decimals()` and that `latestRoundData()` returns a positive, non-stale answer.
6. Save the source URL and explorer URL next to each approved address.
7. Have a second operator repeat the verification before deployment.
8. Fill each chain's `verification` and `validation` blocks in the JSON config.
9. Fill every mainnet `multisig` field with the approved Safe or operations wallet.
10. Flip `status` only after approval: `approved-for-mainnet` or `approved-for-testnet`.
11. Run `npm run validate:addresses`; deployment scripts must use the same broadcast guard.
12. If `ccip_infra` is filled, verify those addresses from Chainlink/explorer sources and keep `deployCritical` set to `false`.
