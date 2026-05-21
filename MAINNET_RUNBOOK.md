# Bridgeway Mainnet Runbook

This is the step-by-step operator runbook for the Base hub launch from
`feature/hub-spoke`.

Do not store private keys, RPC URLs, API keys, Safe signatures, or secrets in
this file. Use local shell env vars only.

## Launch Policy

- Hub chain: Base.
- Canonical BGW and BGW-GOV deploy through CREATE2 only.
- Deprecated nonce-based Base token/vault addresses must not be reused.
- Sleeve weights at launch: Sleeve A 65%, Sleeve B 35%, Sleeve C 0%.
- Automation stays unwired until manual deployment and smoke testing are done.
- `SleeveACbbtcWrapper.enableConfigTimelock()` is called only after small-fund
  testing succeeds. Before that call, launch wiring is not blocked by 48 hours.
- After `enableConfigTimelock()`, yield adapter changes require the 48 hour
  propose/execute flow.

## Phase 0 - Clean Checkout And Global Env

```bash
cd /Users/vipul/bridgeway-all
git fetch origin
git checkout feature/hub-spoke
git pull --rebase origin feature/hub-spoke
forge test
```

Set local env. Replace placeholder RPC values locally; do not commit them.

```bash
export PATH="$HOME/.foundry/bin:$PATH"

export BASE_RPC_URL="<base-mainnet-rpc>"
export ETH_RPC_URL="<ethereum-mainnet-rpc>"
export ARBITRUM_RPC="<arbitrum-mainnet-rpc>"

export DEPLOYER_PRIVATE_KEY="<deployer-private-key>"
export DEPLOYER=$(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY)

export PROTOCOL_OWNER_SAFE=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
export FOUNDER_TREASURY=0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625
export TEAM_WALLET=0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625
export HOLDBACK_WALLET=0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625
export RESERVE_WALLET=0x57Cd13D05Ef79092858bc64FFEc1d89ee07d9625

export TOKEN_TEMP_ADMIN=$DEPLOYER
export TOKEN_ADMIN=$PROTOCOL_OWNER_SAFE
export VAULT_OWNER=$PROTOCOL_OWNER_SAFE
export AUTOMATION_OWNER=$PROTOCOL_OWNER_SAFE
export REGISTRY_OWNER=$PROTOCOL_OWNER_SAFE
export HUB_NAV_OWNER=$PROTOCOL_OWNER_SAFE
export CCIP_RECEIVER_OWNER=$PROTOCOL_OWNER_SAFE
```

Base asset inputs:

```bash
export USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export USDC_USD_FEED=0x7e860098F58bBFC8648a4311b374B1D669a2bc6B

export CBBTC=0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
export BTC_USD_PRICE_FEED=0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F

export AAVE_POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
export A_USDC=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
export A_CBBTC="<base-aave-cbbtc-atoken>"

export MORPHO_VAULT=0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61

export AERO="<base-aero-token>"
export AERODROME_SWAP_ROUTER="<aerodrome-swap-router>"
export AERODROME_ROUTER_V2="$AERODROME_SWAP_ROUTER"
export AERODROME_POSITION_MANAGER="<aerodrome-slipstream-position-manager>"
export AERODROME_TICK_SPACING="<tick-spacing>"
export AERODROME_TICK_LOWER="<tick-lower>"
export AERODROME_TICK_UPPER="<tick-upper>"

export STRATEGY_KEEPER=$DEPLOYER
export RESCUE_RECEIVER=$PROTOCOL_OWNER_SAFE
export MAX_STALE_SECONDS=1200
export INITIAL_AERODROME_NET_APY_BPS=500
```

If there is no launch gauge, leave `AERODROME_GAUGE` unset. To force the env
var explicitly, use the zero address:

```bash
export AERODROME_GAUGE=0x0000000000000000000000000000000000000000
```

Before broadcast, verify all non-placeholder env vars:

```bash
cast balance $DEPLOYER --rpc-url $BASE_RPC_URL
cast code $PROTOCOL_OWNER_SAFE --rpc-url $BASE_RPC_URL
cast call $USDC "symbol()(string)" --rpc-url $BASE_RPC_URL
cast call $USDC "decimals()(uint8)" --rpc-url $BASE_RPC_URL
cast call $USDC_USD_FEED "description()(string)" --rpc-url $BASE_RPC_URL
cast call $USDC_USD_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $BASE_RPC_URL
cast call $BTC_USD_PRICE_FEED "description()(string)" --rpc-url $BASE_RPC_URL
cast call $BTC_USD_PRICE_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $BASE_RPC_URL
```

Stop if any address has no code, an unexpected symbol/decimals, or stale oracle
data.

## Phase 1 - Deterministic Token Preflight

Predict canonical token addresses on Base:

```bash
forge script scripts/deploy/00_PredictDeterministicTokens.s.sol \
  --rpc-url $BASE_RPC_URL
```

Expected canonical addresses from the current notebook:

```bash
export BGW_TOKEN=0x9285e5bc1177Ee8E734513599035d382e32aA5Ee
export GOV_TOKEN=0x297E63945B9B93Ab2573D35e6ce6652a46d87713
```

Confirm both are empty before deployment:

```bash
cast code $BGW_TOKEN --rpc-url $BASE_RPC_URL
cast code $GOV_TOKEN --rpc-url $BASE_RPC_URL
```

Expected output for both: `0x`.

Repeat the same empty-code check on any future chain before deploying canonical
BGW tokens there.

## Phase 2 - Deploy Canonical Tokens

Dry run:

```bash
forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $BASE_RPC_URL
```

Broadcast:

```bash
forge script scripts/deploy/01_DeployTokens.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Post-check:

```bash
cast code $BGW_TOKEN --rpc-url $BASE_RPC_URL
cast code $GOV_TOKEN --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "governanceCompanion()(address)" --rpc-url $BASE_RPC_URL
cast call $GOV_TOKEN "founderTreasury()(address)" --rpc-url $BASE_RPC_URL
```

Expected:

- BGW and GOV code are non-empty.
- `governanceCompanion()` equals `$GOV_TOKEN`.
- `founderTreasury()` equals `$FOUNDER_TREASURY`.

## Phase 3 - Deploy Vault And Wire Token Roles

Dry run:

```bash
forge script scripts/deploy/02_DeployVault.s.sol \
  --rpc-url $BASE_RPC_URL
```

Broadcast:

```bash
forge script scripts/deploy/02_DeployVault.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Save the printed vault:

```bash
export VAULT="<printed-BGWVault-address>"
```

Post-check:

```bash
export DEFAULT_ADMIN_ROLE=$(cast call $BGW_TOKEN "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export MINTER_ROLE=$(cast call $BGW_TOKEN "MINTER_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export BURNER_ROLE=$(cast call $BGW_TOKEN "BURNER_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export WHITELIST_ADMIN_ROLE=$(cast call $BGW_TOKEN "WHITELIST_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)

cast call $VAULT "owner()(address)" --rpc-url $BASE_RPC_URL
cast call $VAULT "pendingOwner()(address)" --rpc-url $BASE_RPC_URL
cast call $GOV_TOKEN "vault()(address)" --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "hasRole(bytes32,address)(bool)" $MINTER_ROLE $VAULT --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "hasRole(bytes32,address)(bool)" $BURNER_ROLE $VAULT --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "hasRole(bytes32,address)(bool)" $WHITELIST_ADMIN_ROLE $VAULT --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $PROTOCOL_OWNER_SAFE --rpc-url $BASE_RPC_URL
cast call $BGW_TOKEN "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $DEPLOYER --rpc-url $BASE_RPC_URL
```

Expected:

- `owner()` is still `$DEPLOYER`.
- `pendingOwner()` is `$PROTOCOL_OWNER_SAFE`.
- `GOV_TOKEN.vault()` is `$VAULT`.
- Vault has minter, burner, and whitelist admin roles.
- Safe has token admin.
- Deployer no longer has BGW default admin.

Do not accept vault ownership yet. Script `14` must wire owner-only sleeve config
while deployer is still the active vault owner.

## Phase 4 - Deploy Optional Registry, Hub NAV, And CCIP Receiver

These can be deployed before or after sleeves. Wire only after their values are
reviewed.

```bash
forge script scripts/deploy/04_DeployAndConfigureRegistry.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast

forge script scripts/deploy/05_DeployHubNAV.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Save:

```bash
export REGISTRY="<printed-BridgewayRegistry-address>"
export HUB_NAV="<printed-BridgewayHubNAV-address>"
```

Deploy the Base CCIP NAV receiver if inbound spoke NAV is needed:

```bash
export CCIP_ROUTER=0x881e3A65B4d4a04dD529061dd0071cf975F58bCD

forge script scripts/deploy/06_DeployCCIPNAVReceiver.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Save:

```bash
export CCIP_NAV_RECEIVER="<printed-BridgewayCCIPNAVReceiver-address>"
```

Post-check receiver interface:

```bash
cast call $CCIP_NAV_RECEIVER "supportsInterface(bytes4)(bool)" 0x85572ffb --rpc-url $BASE_RPC_URL
cast call $CCIP_NAV_RECEIVER "supportsInterface(bytes4)(bool)" 0x01ffc9a7 --rpc-url $BASE_RPC_URL
```

Expected:

```text
true
true
```

Do not configure external spokes until sender bytes, source chain selectors,
nonce policy, and materiality/staleness limits are reviewed.

## Phase 5 - Deploy And Wire Sleeves

This is the first production sleeve activation pass:

- Sleeve A: Base cbBTC wrapper with 80% Aave cbBTC / 20% Aerodrome when marked
  APY is fresh and at least 4.5%.
- Sleeve B: Base USDC Aave/Morpho stable yield adapter.
- Sleeve C: 0% at launch.
- Vault deposit weights: 65/35/0.

Dry run:

```bash
forge script scripts/deploy/14_DeployAndWireSleeves.s.sol \
  --rpc-url $BASE_RPC_URL
```

Broadcast:

```bash
forge script scripts/deploy/14_DeployAndWireSleeves.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Save printed addresses:

```bash
export SLEEVE_A_WRAPPER="<printed-SleeveACbbtcWrapper-address>"
export AERODROME_CBBTC_STRATEGY="<printed-AerodromeCbbtcStrategy-address>"
export BASE_CBBTC_YIELD_ADAPTER="<printed-BaseCBBTCYieldAdapter-address>"
export SLEEVE_B_ADAPTER="<printed-SleeveBStableYieldAdapter-address>"
```

Post-check:

```bash
cast call $VAULT "sleeveAdapterRouteAt(uint8,uint256)(address,uint16,bool)" 0 0 --rpc-url $BASE_RPC_URL
cast call $VAULT "sleeveAdapterRouteAt(uint8,uint256)(address,uint16,bool)" 1 0 --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "yieldAdapter()(address)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "controller()(address)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "rescueReceiver()(address)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "aerodromeEnabled()(bool)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "configTimelockEnabled()(bool)" --rpc-url $BASE_RPC_URL
```

Expected:

- Vault sleeve adapter `0` is `$SLEEVE_A_WRAPPER`.
- Vault sleeve adapter `1` is `$SLEEVE_B_ADAPTER`.
- Each route has `depositBps=10000` and `active=true`.
- Wrapper yield adapter is `$BASE_CBBTC_YIELD_ADAPTER`.
- Yield adapter controller is `$SLEEVE_A_WRAPPER`.
- Rescue receiver is `$RESCUE_RECEIVER`.
- `configTimelockEnabled()` is `false` before smoke testing.

Do not call `enableConfigTimelock()` yet.

## Phase 6 - Small-Fund Smoke Test

Before accepting final ownership and enabling timelock, use tiny amounts only.
Keep the deployer as active vault owner for this phase so it can whitelist the
test depositor and adjust the temporary cap. The Safe is already pending owner
from Phase 3 but has not accepted ownership yet.

Set the smoke-test wallet and amount:

```bash
export TEST_DEPOSITOR="<test-wallet-address>"
export TEST_DEPOSIT_USDC=1000000
```

`TEST_DEPOSIT_USDC` is USDC 6-decimal units. `1000000` means 1 USDC.

Whitelist the test depositor and optionally set a very small deposit cap:

```bash
cast send $VAULT \
  "setWhitelisted(address,bool)" $TEST_DEPOSITOR true \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

cast send $VAULT \
  "setDepositCap(uint256)" 10000000 \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

Recommended checks:

```bash
cast call $VAULT "totalNAV()(uint256)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "totalAssetsUSDC()(uint256)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_B_ADAPTER "totalAssetsUSDC()(uint256)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "totalAssetsUSDC()(uint256)" --rpc-url $BASE_RPC_URL
```

Then run a small controlled deposit from a whitelisted test wallet. Confirm:

```bash
cast send $USDC \
  "approve(address,uint256)" $VAULT $TEST_DEPOSIT_USDC \
  --rpc-url $BASE_RPC_URL \
  --private-key <test-depositor-private-key>

cast send $VAULT \
  "deposit(uint256,uint256)" $TEST_DEPOSIT_USDC 0 \
  --rpc-url $BASE_RPC_URL \
  --private-key <test-depositor-private-key>
```

- BGW minted to depositor.
- BGW-GOV minted according to policy.
- Vault NAV remains sensible.
- Sleeve A receives only its 65% share.
- Sleeve B receives only its 35% share.
- Sleeve C receives 0.
- cbBTC wrapper reports value using BTC/USD feed.
- Aerodrome only receives funds if `aerodromeEnabled()` is true.

Then run a tiny redemption. Confirm:

```bash
export TEST_BGW_BALANCE=$(cast call $BGW_TOKEN "balanceOf(address)(uint256)" $TEST_DEPOSITOR --rpc-url $BASE_RPC_URL)

cast send $BGW_TOKEN \
  "approve(address,uint256)" $VAULT $TEST_BGW_BALANCE \
  --rpc-url $BASE_RPC_URL \
  --private-key <test-depositor-private-key>

cast send $VAULT \
  "redeem(uint256,uint256)" $TEST_BGW_BALANCE 0 \
  --rpc-url $BASE_RPC_URL \
  --private-key <test-depositor-private-key>
```

- USDC returns to the redeemer.
- No unexpected protected token can be recovered.
- `totalNAV()` and sleeve values remain consistent.

If Aerodrome cbBTC to USDC swap is stressed or failing, wrapper withdrawal may
return 0 and keep cbBTC accounted in wrapper NAV. That is expected after the
hardening patch; do not force larger deposits until the route is healthy.

## Phase 7 - Safe Ownership Acceptance

After smoke tests pass, use the Protocol Owner Safe on Base to call
`acceptOwnership()` on each contract with pending Safe ownership:

- `$VAULT`
- `$SLEEVE_A_WRAPPER`
- `$AERODROME_CBBTC_STRATEGY`
- `$BASE_CBBTC_YIELD_ADAPTER`
- `$SLEEVE_B_ADAPTER`
- `$REGISTRY`, if deployed and pending
- `$HUB_NAV`, if deployed and pending
- `$CCIP_NAV_RECEIVER`, if deployed and pending

Safe Transaction Builder:

- To address: target contract.
- ABI method: `acceptOwnership()`.
- ETH value: `0`.
- Parameters: none.

Raw calldata, if needed:

```text
0x79ba5097
```

Post-check each contract:

```bash
cast call <contract> "owner()(address)" --rpc-url $BASE_RPC_URL
cast call <contract> "pendingOwner()(address)" --rpc-url $BASE_RPC_URL
```

Expected owner is `$PROTOCOL_OWNER_SAFE`; pending owner is zero.

## Phase 8 - Enable Post-Bootstrap Timelock

Only after Phase 6 and Phase 7 pass, use the Protocol Owner Safe to call:

```solidity
enableConfigTimelock()
```

on:

```text
$SLEEVE_A_WRAPPER
```

Post-check:

```bash
cast call $SLEEVE_A_WRAPPER "configTimelockEnabled()(bool)" --rpc-url $BASE_RPC_URL
```

Expected:

```text
true
```

From this point onward, yield adapter changes require:

```solidity
proposeYieldAdapter(address newAdapter)
```

wait 48 hours, then:

```solidity
executeYieldAdapterProposal()
```

## Phase 9 - Optional Automation Deployment

Deploy automation, but keep it unwired until operator approval:

```bash
export WIRE_AUTOMATION=false

forge script scripts/deploy/03_SetupAutomation.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast
```

Save:

```bash
export AUTOMATION="<printed-BridgewayAutomation-address>"
```

After production approval, wire automation from the vault owner Safe:

```solidity
setAutomation(address automation)
```

Then register on Chainlink Automation:

- Network: Base.
- Trigger: Custom logic.
- Target: `$AUTOMATION`.
- Gas limit: `500000`.
- Fund only after manual operations are stable.

## Phase 10 - Final Launch Checks

Run these checks before raising deposit caps:

```bash
forge test

cast call $VAULT "owner()(address)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "owner()(address)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "owner()(address)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "configTimelockEnabled()(bool)" --rpc-url $BASE_RPC_URL

cast call $VAULT "totalNAV()(uint256)" --rpc-url $BASE_RPC_URL
cast call $SLEEVE_A_WRAPPER "totalAssetsUSDC()(uint256)" --rpc-url $BASE_RPC_URL
cast call $BASE_CBBTC_YIELD_ADAPTER "aerodromeEnabled()(bool)" --rpc-url $BASE_RPC_URL
```

Expected:

- Owners are the Protocol Owner Safe.
- Wrapper config timelock is enabled.
- NAV views do not revert.
- Automation is either intentionally unset or explicitly approved.
- No placeholder env values were used in any broadcast.
- `DEPLOYMENT_NOTEBOOK.md` is updated with every deployed address and tx hash.

## Phase 11 - Update Repo Records

After each successful phase, update:

- `DEPLOYMENT_NOTEBOOK.md`
- `MAINNET_ADDRESS_BOOK.md`, only for confirmed inputs
- `config/mainnet-addresses.json`, if it is used by the deploy flow

Then commit:

```bash
git status --short
git add DEPLOYMENT_NOTEBOOK.md MAINNET_ADDRESS_BOOK.md config/mainnet-addresses.json MAINNET_RUNBOOK.md
git commit -m "Update mainnet deployment records"
git push origin feature/hub-spoke
```

## Stop Conditions

Stop deployment immediately if any of these occur:

- Predicted CREATE2 token address has existing code before Phase 2.
- A deployed address differs from the script prediction/output.
- Any oracle returns non-positive, incomplete, or stale data.
- Any Safe owner/pending owner differs from the expected address.
- `configTimelockEnabled()` is true before smoke testing.
- Aave or Morpho asset addresses do not match USDC/cbBTC expectations.
- Aerodrome route depth cannot support the smoke-test amount.
- Any post-check reverts unexpectedly.
- Alchemy or RPC reports gapped nonce, in-flight transaction limit, or null
  receipts after broadcast. Pause and inspect nonce/receipt state before
  resubmitting.
