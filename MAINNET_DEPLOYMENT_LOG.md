# Bridgeway Mainnet Deployment Log

This file records the live deployment console trail for the Base mainnet launch
from `feature/hub-spoke`.

Do not store private keys, RPC URLs, API keys, Safe signatures, or secrets here.
Sensitive Foundry cache files are referenced only by path when useful.

## Session Metadata

| Field | Value |
| --- | --- |
| Branch | `feature/hub-spoke` |
| Commit | `d2d74eb9c05f906a8f1ad403e5fc4e79de102c36` |
| Hub chain | Base mainnet |
| Chain ID | `8453` |
| Deployer | `0x13c142E565d28b1558BecAA2Af4495CB133801f4` |
| Protocol Owner Safe | `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348` |
| Founder/Treasury placeholder | `0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625` |

## Source Verification

Local branch and remote branch matched before deployment.

```text
Branch: feature/hub-spoke
Local HEAD:  d2d74eb9c05f906a8f1ad403e5fc4e79de102c36
Remote HEAD: d2d74eb9c05f906a8f1ad403e5fc4e79de102c36
Tracked diff: none
Untracked local files:
  .slither_env/
  slither_report.json
```

## Test Run

Command:

```bash
forge test
```

Result:

```text
Ran 17 test suites in 3.05s (10.94s CPU time): 243 tests passed, 0 failed, 0 skipped (243 total tests)
```

Notable suites passed:

- `BridgewayRegistryTest`
- `BGWTokenTest`
- `FounderVestingTest`
- `NativeStakingPhase4Test`
- `BridgewayHubSpokeTest`
- `SleeveACbbtcWrapperTest`
- `AutomationTest`
- `SleeveCAlphaYieldAdapterTest`
- `SleeveBStableYieldAdapterTest`
- `BaseCBBTCYieldAdapterTest`
- `SleeveABasketAdapterTest`
- `NavRateFuzzTest`
- `BGWVaultTest`
- `BridgewayRateReporterTest`
- `BridgewayCCIPNAVReceiverTest`
- `BaseCBBTCYieldForkTest`
- `DeployTest`

## Phase 1 - Deterministic Token Preflight

Command:

```bash
forge script scripts/deploy/00_PredictDeterministicTokens.s.sol \
  --rpc-url $BASE_RPC_URL
```

Output:

```text
CREATE2 factory: 0x4e59b44847b379578588920cA78FbF26c0B4956C
CREATE2 factory code length: 69
TOKEN_TEMP_ADMIN: 0x13c142E565d28b1558BecAA2Af4495CB133801f4
FOUNDER_TREASURY: 0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625
BGW_TOKEN_PREDICTED= 0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
BGW_TOKEN_CODE_LENGTH= 0
GOV_TOKEN_PREDICTED= 0x297E63945B9B93Ab2573D35e6ce6652a46d87713
GOV_TOKEN_CODE_LENGTH= 0
BGW_TOKEN_SALT:
0x0164f0fc310f6448bebab43406441ed7866b37e8b826c8f660e3def430851eb8
GOV_TOKEN_SALT:
0x7cf2392eeaf80dd93c65115778e237cbcefb9db5986e52c9ba6ea026df2bebf6
```

Manual code checks:

```text
cast balance $DEPLOYER --rpc-url $BASE_RPC_URL
235663237729323

cast code $BGW_TOKEN --rpc-url $BASE_RPC_URL
0x

cast code $GOV_TOKEN --rpc-url $BASE_RPC_URL
0x
```

Decision: preflight passed. Both canonical token addresses were empty.

## Phase 2 - Canonical Token Deployment

### Dry Run

Command:

```bash
forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $BASE_RPC_URL \
  --sender $DEPLOYER \
  -vvvv
```

Summary:

```text
BGWToken predicted:    0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
BGWGovToken predicted: 0x297E63945B9B93Ab2573D35e6ce6652a46d87713
BGWToken salt:         0x0164f0fc310f6448bebab43406441ed7866b37e8b826c8f660e3def430851eb8
BGWGovToken salt:      0x7cf2392eeaf80dd93c65115778e237cbcefb9db5986e52c9ba6ea026df2bebf6

Transactions to broadcast:
  1. CREATE2 deploy BGWToken at 0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
  2. CREATE2 deploy BGWGovToken at 0x297E63945B9B93Ab2573D35e6ce6652a46d87713
  3. BGWToken.setGovernanceCompanion(0x297E63945B9B93Ab2573D35e6ce6652a46d87713)

Estimated total gas used: 5860786
Estimated amount required: 0.00006019027222 ETH
Dry-run file: /Users/vipul/bridgeway-all/broadcast/01_DeployTokens.s.sol/8453/dry-run/run-latest.json
```

Decision: dry run matched expected canonical addresses and gas was within
deployer balance.

### Broadcast

Command:

```bash
forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $BASE_RPC_URL \
  --sender $DEPLOYER \
  --broadcast
```

Output:

```text
BGWToken:       0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
BGWGovToken:    0x297E63945B9B93Ab2573D35e6ce6652a46d87713
Set BGW-GOV companion on BGWToken

BGW_TOKEN= 0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
GOV_TOKEN= 0x297E63945B9B93Ab2573D35e6ce6652a46d87713
Temporary token admin: 0x13c142E565d28b1558BecAA2Af4495CB133801f4
Founder treasury: 0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625

BGWGovToken deploy tx:
0x465ad38764b9ca7afbff7c2dc6c2f4d76211393b465dfd17dd11895ac3afa78f
Block: 46230029
Paid: 0.00001488926392 ETH

BGWToken deploy tx:
0x72051d3b65a43806cb54ce4827377f9ceeaa42fa6e017b438b9b119ff83df2a4
Block: 46230028
Paid: 0.00000836453478 ETH

setGovernanceCompanion tx:
0x674fe88b1ecfce6d57bebfc595d0794c2c7c565698d1766df8161617c38903ee
Block: 46230031
Paid: 0.00000027014048 ETH

Total paid: 0.00002352393918 ETH
Broadcast file: /Users/vipul/bridgeway-all/broadcast/01_DeployTokens.s.sol/8453/run-latest.json
Sensitive cache file: /Users/vipul/bridgeway-all/cache/01_DeployTokens.s.sol/8453/run-latest.json
```

### Post-Deploy Token Verification

Command:

```bash
cast code $BGW_TOKEN --rpc-url $BASE_RPC_URL | cut -c1-10
cast code $GOV_TOKEN --rpc-url $BASE_RPC_URL | cut -c1-10
cast call $BGW_TOKEN "governanceCompanion()(address)" --rpc-url $BASE_RPC_URL
cast call $GOV_TOKEN "founderTreasury()(address)" --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL
cast call $GOV_TOKEN "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL
```

Output:

```text
0x60806040
0x60806040
0x297E63945B9B93Ab2573D35e6ce6652a46d87713
0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625
0x0000000000000000000000000000000000000000000000000000000000000000
0x0000000000000000000000000000000000000000000000000000000000000000
```

Decision: token deployment passed verification.

## Phase 3 - Vault Deployment

### Dry Run

Command:

```bash
forge script scripts/deploy/02_DeployVault.s.sol \
  --rpc-url $BASE_RPC_URL \
  --sender $DEPLOYER \
  -vvvv
```

Summary:

```text
BGWVault predicted by simulation:
0xDbC67391e3DAf3E542B7D290f607FE0CBc91307f

Actions:
  - Deploy BGWVault
  - Grant BGW MINTER_ROLE to vault
  - Grant BGW BURNER_ROLE to vault
  - Grant BGW WHITELIST_ADMIN_ROLE to vault
  - Whitelist vault
  - Initialize BGW-GOV vault
  - Whitelist founder treasury
  - Grant BGW DEFAULT_ADMIN_ROLE to Protocol Owner Safe
  - Grant BGW PAUSER_ROLE to Protocol Owner Safe
  - Grant BGW BLACKLIST_ADMIN_ROLE to Protocol Owner Safe
  - Grant BGW WHITELIST_ADMIN_ROLE to Protocol Owner Safe
  - Grant BGW-GOV DEFAULT_ADMIN_ROLE to Protocol Owner Safe
  - Revoke deployer PAUSER_ROLE
  - Revoke deployer BLACKLIST_ADMIN_ROLE
  - Revoke deployer WHITELIST_ADMIN_ROLE
  - Revoke deployer BGW DEFAULT_ADMIN_ROLE
  - Revoke deployer BGW-GOV DEFAULT_ADMIN_ROLE
  - Transfer BGWVault ownership to Protocol Owner Safe as pending owner

Transactions to broadcast: 18
Nonces: 31 through 48
Estimated total gas used: 8610988
Estimated amount required: 0.0000869709788 ETH
Dry-run file: /Users/vipul/bridgeway-all/broadcast/02_DeployVault.s.sol/8453/dry-run/run-latest.json
```

Important sequencing note:

Script `02` transfers vault ownership to the Protocol Owner Safe as pending
owner. Do not accept ownership from the Safe until owner-only sleeve wiring is
complete, unless the later wiring is done from the Safe.

Decision: dry run passed and predicted vault address is saved for the next step.

### Broadcast Attempt 1

Command:

```bash
forge script scripts/deploy/02_DeployVault.s.sol \
  --rpc-url $BASE_RPC_URL \
  --sender $DEPLOYER \
  --broadcast 2>&1 | tee -a /Users/vipul/bridgeway-all/MAINNET_DEPLOYMENT_RAW.log
```

Result:

```text
BGWVault: 0xDbC67391e3DAf3E542B7D290f607FE0CBc91307f
Transactions saved to: /Users/vipul/bridgeway-all/broadcast/02_DeployVault.s.sol/8453/run-latest.json
Sensitive values saved to: /Users/vipul/bridgeway-all/cache/02_DeployVault.s.sol/8453/run-latest.json

Error: Failed to send transaction after 4 attempts Err(server returned an error response: error code -32000: in-flight transaction limit reached for delegated accounts)

Context:
- server returned an error response: error code -32000: gapped-nonce tx from delegated accounts
```

Foundry artifact status:

```text
Nonce 31 / 0x1f: hash 0x778a8304b8725bc1aae09d54d105716d8aa68f51ec3acf59161ab296666b59cb - BGWVault create
Nonce 32 / 0x20: hash 0x0a713c0828eac9a6c3d08c276d8a48457e231058d1ea83772d028490842d7089 - BGW MINTER_ROLE grant to vault
Nonce 33 / 0x21: hash 0x96a1a81eb8896e0e0f1a0cc87ad61cd5f27b8e5a82bfcb5303371a81b29660f9 - BGW BURNER_ROLE grant to vault
Nonce 34+ / 0x22+: hash null in Foundry artifact
```

Decision: treat Script 02 as partially submitted until on-chain verification
confirms exactly which transactions landed. Do not rerun the full script blindly.

On-chain receipt verification:

```text
0x778a8304b8725bc1aae09d54d105716d8aa68f51ec3acf59161ab296666b59cb
  Status: 1
  Block: 46230702
  Effect: BGWVault deployed at 0xDbC67391e3DAf3E542B7D290f607FE0CBc91307f

0x0a713c0828eac9a6c3d08c276d8a48457e231058d1ea83772d028490842d7089
  Status: 1
  Block: 46230703
  Effect: BGWToken MINTER_ROLE granted to vault

0x96a1a81eb8896e0e0f1a0cc87ad61cd5f27b8e5a82bfcb5303371a81b29660f9
  Status: 1
  Block: 46230705
  Effect: BGWToken BURNER_ROLE granted to vault
```

Resume point: continue Script 02 wiring from the BGWToken WHITELIST_ADMIN_ROLE
grant to the vault. Verify deployer nonce before sending any manual continuation
transactions.

Manual continuation:

```text
Nonce 34:
  Tx: 0x748d936710fcfe61ac43db251d78c7b74dcdb1fb8c03612f8aab25b2ad7a971f
  Status: 1
  Block: 46247726
  Effect: BGWToken WHITELIST_ADMIN_ROLE granted to vault

Nonce 35:
  Tx: 0xfb61789b40ff862e310f0d16f8200f76e62dbd1cc1dc1e74f434cf700e0719fc
  Status: 1
  Block: 46247747
  Effect: Vault whitelisted itself for protocol reserve mint-and-burn

Nonce 36:
  Tx: 0x5a6703b30c1b1caf564d064e6fb2ad15d14e960cbe994cdcff848887b1faed89
  Status: 1
  Block: 46247775
  Effect: BGWGovToken initialized with vault

Nonce 37:
  Tx: 0x6b6f040394152fb7bc9983c29017daf667288ff79d4b6b5038b39e9986602002
  Status: 1
  Block: 46247796
  Effect: Founder treasury whitelisted

Nonce 38:
  Tx: 0xff13b863abd08d1dd6ac5f36ccbfd694dc697fa98cc0fcf450e35d8f2064ff0c
  Status: 1
  Block: 46247811
  Effect: BGWToken DEFAULT_ADMIN_ROLE granted to Protocol Owner Safe

Nonce 39:
  Tx: 0x23c7b103319f8a92808b0835ea833de6454a71b2ee791f3a9e6ef6bfb6511049
  Status: 1
  Block: 46247834
  Effect: BGWToken PAUSER_ROLE granted to Protocol Owner Safe

Nonce 40:
  Tx: 0xe1cbc95b9073c9b30ebd3b12e598b62ff35c67bcb84556524466e8ed23df4e2f
  Status: 1
  Block: 46247926
  Effect: BGWToken BLACKLIST_ADMIN_ROLE granted to Protocol Owner Safe

Nonce 41:
  Tx: 0xad87c699a9818ab5eb2b6dd04f4e3997b237bdd7cdfd4922967cdf3de07659ad
  Status: 1
  Block: 46247949
  Effect: BGWToken WHITELIST_ADMIN_ROLE granted to Protocol Owner Safe

Nonce 42:
  Tx: 0xb50bf53d79d89b35cbfd8cc9edc48b871935442ca95d7252811391d75cfcce5a
  Status: 1
  Block: 46247968
  Effect: BGWGovToken DEFAULT_ADMIN_ROLE granted to Protocol Owner Safe

Nonce 43:
  Tx: 0xc4715fbea023d9e954f40bff3fa7da91bd5a24767ce0d968a109c5a489613fac
  Status: 1
  Block: 46248003
  Effect: BGWToken PAUSER_ROLE revoked from deployer

Nonce 44:
  Tx: 0x2acbd7f7b4a49c553e7b3c418caaa6bc7978a53b12521882073fd37e37675a0e
  Status: 1
  Block: 46248026
  Effect: BGWToken BLACKLIST_ADMIN_ROLE revoked from deployer

Nonce 45:
  Tx: 0xc59baf7e08c9d7d2617189197f58185a75c152d1e21623df0615856a36045845
  Status: 1
  Block: 46248050
  Effect: BGWToken WHITELIST_ADMIN_ROLE revoked from deployer

Nonce 46:
  Tx: 0xb23801cd38417a0bec0b23947b9d87ad331119040c1e5e767f05efb56839d1ef
  Status: 1
  Block: 46248072
  Effect: BGWToken DEFAULT_ADMIN_ROLE revoked from deployer

Nonce 47:
  Tx: 0x0116d578793d2e986c16fb750ade9170044ad288a2e5d78fffe5f02304c8d301
  Status: 1
  Block: 46248094
  Effect: BGWGovToken DEFAULT_ADMIN_ROLE revoked from deployer

Nonce 48:
  Tx: 0xc37607aa1c3754ddb32ffbe45baf71aa1f8bf57bc20aeb67114853a65593d43b
  Status: 1
  Block: 46248154
  Effect: BGWVault ownership transfer started; pending owner is Protocol Owner Safe
```

Script 02 status: completed by manual continuation after the delegated-account
nonce queue interrupted the original broadcast.

Post-completion verification:

```text
VAULT_CODE=0x60806040
VAULT_OWNER=0x13c142E565d28b1558BecAA2Af4495CB133801f4
VAULT_PENDING_OWNER=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
GOV_VAULT=0xDbC67391e3DAf3E542B7D290f607FE0CBc91307f
BGW_MINTER_VAULT=true
BGW_BURNER_VAULT=true
BGW_WADMIN_VAULT=true
BGW_DADMIN_SAFE=true
BGW_PAUSER_SAFE=true
BGW_BADMIN_SAFE=true
BGW_WADMIN_SAFE=true
BGW_DADMIN_DEPLOYER=false
GOV_DADMIN_SAFE=true
GOV_DADMIN_DEPLOYER=false
NONCE=49
```

Decision: Phase 3 passed. Deployer remains active vault owner for owner-only
sleeve wiring. Protocol Owner Safe is pending owner and holds token admin roles.

## Phase 5 - Sleeve Env Preflight

Operator env check before sleeve deployment showed missing required values:

```text
CBBTC=
BTC_USD_PRICE_FEED=
A_USDC=
A_CBBTC=
MORPHO_VAULT=
AERODROME_ROUTER_V2=
AERODROME_POSITION_MANAGER=
AERODROME_TICK_SPACING=
AERODROME_TICK_LOWER=
AERODROME_TICK_UPPER=
AERODROME_GAUGE=unset
RESCUE_RECEIVER=
```

Decision: stop before `14_DeployAndWireSleeves.s.sol` until all required
addresses and parameters are exported and verified on-chain.

Exported and verified sleeve env:

```text
CBBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
BTC_USD_PRICE_FEED=0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
A_USDC=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
A_CBBTC=0xbdb9300b7cde636d9cd4aff00f6f009ffbbc8ee6
MORPHO_VAULT=0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61
AERO=0x940181a94A35A4569E4529A3CDfB74e38FD98631
AERODROME_SWAP_ROUTER=0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5
AERODROME_POSITION_MANAGER=0x827922686190790b37229fd06084350E74485b72
AERODROME_TICK_SPACING=100
AERODROME_TICK_LOWER=-887200
AERODROME_TICK_UPPER=887200
AERODROME_GAUGE=0x0000000000000000000000000000000000000000
RESCUE_RECEIVER=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
MAX_STALE_SECONDS=1200
INITIAL_AERODROME_NET_APY_BPS=500
```

On-chain verification:

```text
CBBTC_SYMBOL="cbBTC"
CBBTC_DECIMALS=8
AERO_SYMBOL="AERO"
A_USDC_UNDERLYING=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
A_CBBTC_UNDERLYING=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
MORPHO_ASSET=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
BTC_FEED_DESC="BTC / USD"
ROUTER_CODE=0x60806040
NPM_CODE=0x60806040
```

Decision: sleeve env verification passed. Proceed to script 14 dry run only.

Script 14 dry run:

```text
Script ran successfully.
SleeveACbbtcWrapper: 0xd89014930C45282D2306Ea6C0050740303207701
AerodromeCbbtcStrategy: 0x3CC2848457e00D6114a2C546166e1f1596d8fCCd
BaseCBBTCYieldAdapter: 0x4B887acc298f68298E4C70Bc74AE0834f4F2028B
SleeveBStableYieldAdapter: 0xb95cF3E4009bB466E46909a4aF88aAaF29E7e7e4
Sleeves wired: A = 0xd89014930C45282D2306Ea6C0050740303207701 B = 0xb95cF3E4009bB466E46909a4aF88aAaF29E7e7e4
Deposit weights: 6500 / 3500 / 0
Protected tokens registered.
Estimated total gas used: 12663340
Estimated amount required: 0.00013929674 ETH
Dry-run file: /Users/vipul/bridgeway-all/broadcast/14_DeployAndWireSleeves.s.sol/8453/dry-run/run-latest.json
```

Dry-run artifact transaction plan:

```text
15 transactions, nonces 49 through 63.
```

Decision: dry run passed. Check deployer balance and nonce before broadcast.

Script 14 broadcast attempt 1:

```text
SleeveACbbtcWrapper: 0xd89014930C45282D2306Ea6C0050740303207701
AerodromeCbbtcStrategy: 0x3CC2848457e00D6114a2C546166e1f1596d8fCCd
BaseCBBTCYieldAdapter: 0x4B887acc298f68298E4C70Bc74AE0834f4F2028B
SleeveBStableYieldAdapter: 0xb95cF3E4009bB466E46909a4aF88aAaF29E7e7e4

Error: Failed to send transaction after 4 attempts Err(server returned an error response: error code -32000: in-flight transaction limit reached for delegated accounts)
Context:
- server returned an error response: error code -32000: gapped-nonce tx from delegated accounts
```

Foundry artifact status:

```text
Nonce 49 / 0x31: hash 0xb162799af8a95dd7a36adb795c7a0fc701d6244207fa3e696fbc00830812a64a - SleeveACbbtcWrapper create
Nonce 50 / 0x32: hash 0x93a8756842e48d513a89470da1a9ec25c27995dec87688322bbd87360d23527b - AerodromeCbbtcStrategy create
Nonce 51 / 0x33: hash 0xdf8229d77651235372f73ddbe196774a4fd242e7e6af5d00be7af12fe70c1713 - strategy markToMarket
Nonce 52 / 0x34: hash 0x14c04a01be0336ab8533f5a5a79d65cec3733f1a00a628e82c1855879b847d1e - BaseCBBTCYieldAdapter create
Nonce 53+ / 0x35+: hash null in Foundry artifact
```

Decision: treat script 14 as partially submitted. Verify receipts before
manual continuation from nonce 53.

On-chain receipt verification:

```text
0xb162799af8a95dd7a36adb795c7a0fc701d6244207fa3e696fbc00830812a64a
  Status: 1
  Block: 46250674
  Effect: SleeveACbbtcWrapper deployed at 0xd89014930C45282D2306Ea6C0050740303207701

0x93a8756842e48d513a89470da1a9ec25c27995dec87688322bbd87360d23527b
  Status: 1
  Block: 46250675
  Effect: AerodromeCbbtcStrategy deployed at 0x3CC2848457e00D6114a2C546166e1f1596d8fCCd

0xdf8229d77651235372f73ddbe196774a4fd242e7e6af5d00be7af12fe70c1713
  Status: 1
  Block: 46250676
  Effect: AerodromeCbbtcStrategy markToMarket(0, 500)

0x14c04a01be0336ab8533f5a5a79d65cec3733f1a00a628e82c1855879b847d1e
  Status: 1
  Block: 46250678
  Effect: BaseCBBTCYieldAdapter deployed at 0x4B887acc298f68298E4C70Bc74AE0834f4F2028B
```

Resume point: continue script 14 from nonce 53 with strategy
`setController(BaseCBBTCYieldAdapter)`.

Manual continuation:

```text
Nonce 53:
  Tx: 0x478f20042f672db336834888c9954095120b5bdbb84542f40672c31302744671
  Status: 1
  Block: 46252698
  Effect: AerodromeCbbtcStrategy controller set to BaseCBBTCYieldAdapter

Nonce 54:
  Tx: 0x6990e5972ab391937547e305cff2c21d667f99fb2e73efabb1d667c4042497cf
  Status: 1
  Block: 46252728
  Effect: SleeveACbbtcWrapper yield adapter set to BaseCBBTCYieldAdapter

Nonce 55:
  Tx: 0x261c80a90f1c513d91148e5878825e72f6916de3ece3c4c22d6360bab7537868
  Status: 1
  Block: 46252766
  Effect: SleeveBStableYieldAdapter deployed at 0xb95cF3E4009bB466E46909a4aF88aAaF29E7e7e4

Nonce 56:
  Tx: 0xb5b492e4b421805aec075acd862cce3a56b96b71aecd8dbc6a5261bd257ec78f
  Status: 1
  Block: 46252786
  Effect: Vault sleeve adapter 0 set to SleeveACbbtcWrapper

Nonce 57:
  Initial gas estimation failed with an arithmetic panic from RPC simulation, but
  direct `cast call` returned `0x`. Retried with explicit gas limit.
  Tx: 0xcbaf14d862913877a367ae01db4041c83ce07013bb571636c955a665942a047d
  Status: 1
  Block: 46253069
  Effect: Vault sleeve adapter 1 set to SleeveBStableYieldAdapter

Nonce 58:
  Tx: 0x6613972b10fd001136538e9f894fbae3697fa2848890f989555153fc53617caa
  Status: 1
  Block: 46253104
  Effect: Vault sleeve deposit weights set to 6500 / 3500 / 0

Nonce 59:
  Tx: 0x105afb9f1d456eabcf5dcb55ec25954a5a60c9ec34872ff58c9536c26886de04
  Status: 1
  Block: 46253142
  Effect: Protected tokens registered: aUSDC, Morpho USDC vault, cbBTC, aBasCbBTC

Nonce 60:
  Tx: 0xca7951745542cb2831da86ee868a6b1ae10dc810b582685f02ae9d7411e8f619
  Status: 1
  Block: 46253236
  Effect: SleeveACbbtcWrapper ownership transfer started to Protocol Owner Safe

Nonce 61:
  Tx: 0x40b390aa191d09c8723ca8a6f415967fb4e17e77fa0f0e8ee46cdcba2b699140
  Status: 1
  Block: 46253254
  Effect: AerodromeCbbtcStrategy ownership transfer started to Protocol Owner Safe

Nonce 62:
  Tx: 0x706b6e4db862512a4d4da67ed14375d9a3d95176adaf4366b571655da40f0383
  Status: 1
  Block: 46253274
  Effect: BaseCBBTCYieldAdapter ownership transfer started to Protocol Owner Safe

Nonce 63:
  Tx: 0xc5adcc0dfda5c4e8ffd3995b7e2fea99433522fa5e19be4ab483c2a26f71237f
  Status: 1
  Block: 46253295
  Effect: SleeveBStableYieldAdapter ownership transfer started to Protocol Owner Safe
```

Post-script-14 verification:

```text
VAULT_A=0xd89014930C45282D2306Ea6C0050740303207701
VAULT_B=0xb95cF3E4009bB466E46909a4aF88aAaF29E7e7e4
A_YIELD_ADAPTER=0x4B887acc298f68298E4C70Bc74AE0834f4F2028B
YIELD_CONTROLLER=0xd89014930C45282D2306Ea6C0050740303207701
WEIGHT_A=6500
WEIGHT_B=3500
WEIGHT_C=0
WRAPPER_OWNER=0x13c142E565d28b1558BecAA2Af4495CB133801f4
WRAPPER_PENDING=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
STRATEGY_PENDING=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
YIELD_PENDING=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
SLEEVE_B_PENDING=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
NONCE=64
```

Small-fund smoke precheck:

```text
NONCE=64
USDC_BALANCE=3636099
VAULT_WHITELISTED=false
USDC_ALLOWANCE=0
MAX_DEPOSIT=0
```

Small-fund smoke setup:

```text
Nonce 64:
  Tx: 0x2e9094dcbde15c0cf866acc3ba123cc621b55fe319381d0373cb9ce1fa13c526
  Status: 1
  Block: 46253650
  Effect: Deployer/test depositor whitelisted in vault and BGW token

Nonce 65:
  Tx: 0x8a07eeb7f93b58f1e0ee4597a22dfbec71503be6b2a3e994ad334b11038ef5b2
  Status: 1
  Block: 46253672
  Effect: Deployer approved vault to spend 1 USDC

Deposit attempt:

```text
Nonce: 66 was not consumed
Command: deposit(1000000, 0)
Result: gas estimation reverted before broadcast with "Too little received"
Assessment: 1 USDC smoke deposit is too small/tight for the Sleeve A USDC -> cbBTC Aerodrome swap minimum.
Next action: temporarily route smoke deposit 100% to Sleeve B, then restore launch weights after smoke.
```

Second deposit attempt setup:

```text
Nonce 66:
  Tx: 0x0340aa960cc58fd8a396834f45b1fc13beb84eefd3b9006ea332e810b36a36c3
  Status: 1
  Block: 46253832
  Effect: Deployer approved vault to spend 4 USDC

Nonce: 67 was not consumed
Command: deposit(3000000, 0)
Result: gas estimation reverted before broadcast with panic 0x11
Assessment: tiny full-flow deposit still fails during adapter execution, likely in the small Aerodrome LP leg reached through Sleeve A.
```

Full-flow smoke deposit setup:

```text
Nonce 68:
  Tx: 0x002d28134932dd34adbfa1e5f00726e95619362806d57c761d6ea4b84fda806a
  Status: 1
  Block: 46254306
  Effect: Deployer approved vault to spend 60 USDC

Simulation:
  Command: deposit(60000000, 0)
  Result: 0x
  Assessment: 60 USDC full-flow deposit simulation passed

Full-flow smoke deposit:

```text
Nonce 69:
  Tx: 0x1a8acc429c9519879cfcf91a8b148f87a750ddef61ba56ab79c6d8b3d661a8f2
  Status: 1
  Block: 46255642
  Gas used: 2058178
  Effect: Deployer deposited 60 USDC; vault minted BGW and BGW-GOV.
  Path observed: Sleeve A USDC -> cbBTC -> BaseCBBTCYieldAdapter -> Aave cbBTC + Aerodrome LP; Sleeve B -> Aave USDC + Morpho USDC.
```

Post-deposit verification:

```text
NONCE=70
USDC_BALANCE_DEPLOYER=23168268
BGW_BALANCE_DEPLOYER=60000000000000000000
GOV_BALANCE_DEPLOYER=18000000000000000000
TOTAL_SUPPLY_BGW=60000000000000000000
TOTAL_NAV=59990304
LOCAL_NAV=59990304
SLEEVE_A_VALUE=38990304
SLEEVE_B_VALUE=21000000
A_WRAPPER_TOTAL=38990304
B_ADAPTER_TOTAL=21000000
```

BGW-GOV distribution verification:

```text
Founder treasury BGW-GOV balance=42000000000000000000
Interpretation: 60 BGW deposit minted 60 BGW-GOV total: 18 to depositor and 42 to founder treasury.
```

Performance baseline:

```text
NAV_PER_BGW=1000653
TOTAL_NAV=60039183
TOTAL_SUPPLY_BGW=60000000000000000000
SLEEVE_A_VALUE=39039168
SLEEVE_B_VALUE=21000015
```

Underlying position look-through:

```text
Sleeve A wrapper:
  A_WRAPPER_TOTAL_USDC=38954335
  A_WRAPPER_IDLE_USDC=0
  A_WRAPPER_IDLE_CBBTC=0

Sleeve A cbBTC yield adapter:
  YIELD_TOTAL_USDC=38954335
  YIELD_TOTAL_CBBTC=50345
  YIELD_IDLE_CBBTC=0
  YIELD_A_CBBTC=40276
  AERODROME_ENABLED=true

Aerodrome cbBTC strategy:
  AERO_TOTAL_CBBTC=10069
  AERO_NET_APY_BPS=500
  AERO_TOKEN_ID=71079622
  AERO_LIQUIDITY=140077
  AERO_IDLE_USDC=5
  AERO_IDLE_CBBTC=2

Sleeve B stable adapter:
  B_TOTAL_USDC=21000020
  B_IDLE_USDC=0
  B_AUSDC=14700012
  B_MORPHO_SHARES=5747789447953798281
  B_MORPHO_ASSETS=6300008
```
```
```
