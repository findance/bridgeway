# Clearcrest Base Mainnet Redeployment Commands

This file is the operator runbook for redeploying the fixed Base vault/sleeve stack from commit `d74ceb0`.

Important: the token bytecode/salts now changed for Clearcrest CCR and Clearcrest-GOV CGOV. Start with `01_DeployTokens`; do not reuse the old pre-Clearcrest token addresses.

1. Clean up the old smoke-test config.
2. Deploy new Clearcrest CCR and Clearcrest-GOV CGOV tokens.
3. Deploy a new `BGWVault` with the new tokens.
4. Deploy and wire new Sleeve A/Sleeve B stack.
5. Use the Protocol Owner Safe to grant CCR token roles to the new vault.
6. Use the CGOV vault-reference timelock to point governance mint/whitelist checks at the new vault.
7. Smoke-test deposit and redeem.

## Phase 0 - Confirm Code And Branch

```bash
cd /Users/vipul/bridgeway-all
git status --short
git rev-parse --short HEAD
forge build
forge test
```

Expected head: `d74ceb0`.

## Phase 1 - Clean Old USDT Trusted-Asset Smoke State

USDT was intentionally added to Sleeves A/B/C to test trusted asset add/remove. Sleeve C was already removed. Remove Sleeve B and A before proceeding.

```bash
export USDT=0xfde4C96c8593536E31f229EA8f37b2ADa2699bb2
export OLD_VAULT=0x62f60d6C5bcdf76B0Dd086526B9e18f99d5a8B5a

NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)

cast send $OLD_VAULT \
  "setTrustedSleeveAsset(uint8,address,bool)" \
  1 \
  $USDT \
  false \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG

NONCE=$((NONCE + 1))

cast send $OLD_VAULT \
  "setTrustedSleeveAsset(uint8,address,bool)" \
  0 \
  $USDT \
  false \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG
```

Verify:

```bash
{
  echo "A_TRUSTED=$(cast call $OLD_VAULT 'trustedSleeveAssets(uint8,address)(bool)' 0 $USDT --rpc-url $BASE_RPC_URL)"
  echo "B_TRUSTED=$(cast call $OLD_VAULT 'trustedSleeveAssets(uint8,address)(bool)' 1 $USDT --rpc-url $BASE_RPC_URL)"
  echo "C_TRUSTED=$(cast call $OLD_VAULT 'trustedSleeveAssets(uint8,address)(bool)' 2 $USDT --rpc-url $BASE_RPC_URL)"
  echo "PROTECTED=$(cast call $OLD_VAULT 'protectedTokens(address)(bool)' $USDT --rpc-url $BASE_RPC_URL)"
  echo "USE_COUNT=$(cast call $OLD_VAULT 'trustedAssetUseCount(address)(uint256)' $USDT --rpc-url $BASE_RPC_URL)"
  echo "NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)"
} 2>&1 | tee -a $REDEPLOY_LOG
```

If `PROTECTED=true` while `USE_COUNT=0`, unprotect USDT:

```bash
NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)

cast send $OLD_VAULT \
  "setProtectedToken(address,bool)" \
  $USDT \
  false \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG
```

## Phase 2 - Reset Stale Deployment Outputs

Keep infrastructure constants, unset old deployed outputs.

```bash
unset VAULT AUTOMATION
unset SLEEVE_A_WRAPPER AERODROME_CBBTC_STRATEGY BASE_CBBTC_YIELD_ADAPTER SLEEVE_B_ADAPTER
unset A_ROUTE B_ROUTE A_ACTIVE_BPS B_ACTIVE_BPS
```

Keep these set:

```bash
export BASE_RPC_URL="https://base-mainnet.g.alchemy.com/v2/PRhoD3X6orZwD8NtGSvb5"
export PROTOCOL_OWNER_SAFE=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
export VAULT_OWNER=$PROTOCOL_OWNER_SAFE
export TOKEN_ADMIN=$PROTOCOL_OWNER_SAFE
export AUTOMATION_OWNER=$PROTOCOL_OWNER_SAFE
export FOUNDER_TREASURY=0x57cd13D05ef79092858bc64FfeC1d89EE07D9625
export TEAM_WALLET=$FOUNDER_TREASURY
export HOLDBACK_WALLET=$FOUNDER_TREASURY
export RESERVE_WALLET=$FOUNDER_TREASURY

export BGW_TOKEN=0x60529BA0958a35AD64FC31523B51D194b4D78A7f
export GOV_TOKEN=0x0262f068A9A69C88988061bE1689bdD02967676d

export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export USDC_ADDRESS=$USDC
export CBBTC=0xcbB7C0000aB88B473b1f5afd9ef808440eed33Bf
export AERO=0x940181a94A35A4569E4529A3CDfB74e38FD98631

export USDC_USD_FEED=0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
export BTC_USD_PRICE_FEED=0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F

export AAVE_POOL=0xA238Dd80C259a72e81d7e4664a9801593F98d1c5
export A_USDC=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
export A_CBBTC=0xbDb9300B7cDe636d9cD4Aff00f6f009ffBBc8EE6
export MORPHO_VAULT=0xeE8F4eC5672F09119b96ab6fB59c27E1B7e44B61

export AERODROME_SWAP_ROUTER=0xBE6D8f0d05cC4be24d5167a3Ef062215BE6D18a5
export AERODROME_ROUTER_V2=$AERODROME_SWAP_ROUTER
export AERODROME_POSITION_MANAGER=0x827922686190790b37229fd06084350E74485b72
export AERODROME_VOTER=0x16613524e02ad97eDfeF371bC883F2F5d6C480A5
export AERODROME_USDC_CBBTC_POOL=0x4e962BB3889Bf030368F56810A9c96B83CB3E778
export AERODROME_GAUGE=0x6399ed6725cC163D019aA64FF55b22149D7179A8

export AERODROME_TICK_SPACING=100
export AERODROME_TICK_LOWER=-887200
export AERODROME_TICK_UPPER=887200
export INITIAL_AERODROME_NET_APY_BPS=500
export AERO_TO_CBBTC_PATH=0x940181a94a35a4569e4529a3cdfb74e38fd986310007d0833589fcd6edb6e08f4c7c32d4f71b54bda02913000064cbb7c0000ab88b473b1f5afd9ef808440eed33bf
export RESCUE_RECEIVER=$PROTOCOL_OWNER_SAFE
export MAX_STALE_SECONDS=0
```

Check the Aerodrome gauge still resolves:

```bash
export AERODROME_GAUGE=$(cast call $AERODROME_VOTER \
  "gauges(address)(address)" \
  $AERODROME_USDC_CBBTC_POOL \
  --rpc-url $BASE_RPC_URL)

echo "AERODROME_GAUGE=$AERODROME_GAUGE"
echo "GAUGE_CODE=$(cast code $AERODROME_GAUGE --rpc-url $BASE_RPC_URL | cut -c1-10)"
```

## Phase 3 - Deploy New Vault With Existing Tokens

Do not run `02_DeployVault.s.sol` for this reuse-token path because it calls token admin functions that now belong to the Safe and calls `govToken.initVault()`, which can only run once.

Deploy the fixed vault directly with the deployer as temporary owner so script 14 can wire sleeves.

```bash
forge create contracts/core/BGWVault.sol:BGWVault \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --constructor-args \
    $BGW_TOKEN \
    $GOV_TOKEN \
    $TEAM_WALLET \
    $HOLDBACK_WALLET \
    $RESERVE_WALLET \
    $DEPLOYER \
    $USDC_ADDRESS \
    $USDC_USD_FEED \
  2>&1 | tee -a $REDEPLOY_LOG
```

Export the new vault from the `Deployed to:` line:

```bash
export VAULT=<new_vault_address>
```

Bootstrap owner-only vault settings while deployer is temporary owner:

```bash
NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)

cast send $VAULT \
  "setWhitelisted(address,bool)" \
  $VAULT \
  true \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG

NONCE=$((NONCE + 1))

cast send $VAULT \
  "setWhitelisted(address,bool)" \
  $FOUNDER_TREASURY \
  true \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG
```

Optional smoke depositor whitelist:

```bash
NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)

cast send $VAULT \
  "setWhitelisted(address,bool)" \
  $DEPLOYER \
  true \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $NONCE \
  2>&1 | tee -a $REDEPLOY_LOG
```

## Phase 4 - Deploy And Wire New Sleeves

Dry run:

```bash
forge script scripts/deploy/14_DeployAndWireSleeves.s.sol \
  --rpc-url $BASE_RPC_URL \
  2>&1 | tee -a $REDEPLOY_LOG
```

Broadcast:

```bash
forge script scripts/deploy/14_DeployAndWireSleeves.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --slow \
  2>&1 | tee -a $REDEPLOY_LOG
```

Export outputs from the logs:

```bash
export SLEEVE_A_WRAPPER=<SleeveACbbtcWrapper>
export AERODROME_CBBTC_STRATEGY=<AerodromeCbbtcStrategy>
export BASE_CBBTC_YIELD_ADAPTER=<BaseCBBTCYieldAdapter>
export SLEEVE_B_ADAPTER=<SleeveBStableYieldAdapter>
```

## Phase 5 - Protocol Owner Safe Actions

These are Safe transactions, not deployer `cast send` transactions, unless the Safe signer tooling is being used.

Generate calldata for the Safe UI.

```bash
export BGW_MINTER_ROLE=$(cast call $BGW_TOKEN "MINTER_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export BGW_BURNER_ROLE=$(cast call $BGW_TOKEN "BURNER_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export BGW_WHITELIST_ADMIN_ROLE=$(cast call $BGW_TOKEN "WHITELIST_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)
export BGW_DEFAULT_ADMIN_ROLE=$(cast call $BGW_TOKEN "DEFAULT_ADMIN_ROLE()(bytes32)" --rpc-url $BASE_RPC_URL)

echo "CCR grant MINTER new vault calldata:"
cast calldata "grantRole(bytes32,address)" $BGW_MINTER_ROLE $VAULT

echo "CCR grant BURNER new vault calldata:"
cast calldata "grantRole(bytes32,address)" $BGW_BURNER_ROLE $VAULT

echo "CCR grant WHITELIST_ADMIN new vault calldata:"
cast calldata "grantRole(bytes32,address)" $BGW_WHITELIST_ADMIN_ROLE $VAULT
```

Submit those three transactions from `PROTOCOL_OWNER_SAFE` to `BGW_TOKEN`.

Then propose the GOV vault reference update from the Safe to `GOV_TOKEN`:

```bash
echo "GOV proposeVaultReference new vault calldata:"
cast calldata "proposeVaultReference(address)" $VAULT
```

Submit that calldata from `PROTOCOL_OWNER_SAFE` to `GOV_TOKEN`.

Wait 48 hours, then execute:

```bash
echo "GOV executeVaultReference calldata:"
cast calldata "executeVaultReference()"
```

Submit that calldata from `PROTOCOL_OWNER_SAFE` to `GOV_TOKEN`.

After the new vault is proven, revoke old vault token roles from the Safe:

```bash
export OLD_VAULT=0x62f60d6C5bcdf76B0Dd086526B9e18f99d5a8B5a

echo "CCR revoke MINTER old vault calldata:"
cast calldata "revokeRole(bytes32,address)" $BGW_MINTER_ROLE $OLD_VAULT

echo "CCR revoke BURNER old vault calldata:"
cast calldata "revokeRole(bytes32,address)" $BGW_BURNER_ROLE $OLD_VAULT

echo "CCR revoke WHITELIST_ADMIN old vault calldata:"
cast calldata "revokeRole(bytes32,address)" $BGW_WHITELIST_ADMIN_ROLE $OLD_VAULT
```

## Phase 6 - Verify Wiring

```bash
{
  echo "NONCE=$(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL)"
  echo "VAULT_OWNER=$(cast call $VAULT 'owner()(address)' --rpc-url $BASE_RPC_URL)"
  echo "VAULT_PENDING_OWNER=$(cast call $VAULT 'pendingOwner()(address)' --rpc-url $BASE_RPC_URL)"

  echo "BGW_MINTER_VAULT=$(cast call $BGW_TOKEN 'hasRole(bytes32,address)(bool)' $BGW_MINTER_ROLE $VAULT --rpc-url $BASE_RPC_URL)"
  echo "BGW_BURNER_VAULT=$(cast call $BGW_TOKEN 'hasRole(bytes32,address)(bool)' $BGW_BURNER_ROLE $VAULT --rpc-url $BASE_RPC_URL)"
  echo "BGW_WHITELIST_ADMIN_VAULT=$(cast call $BGW_TOKEN 'hasRole(bytes32,address)(bool)' $BGW_WHITELIST_ADMIN_ROLE $VAULT --rpc-url $BASE_RPC_URL)"
  echo "GOV_VAULT=$(cast call $GOV_TOKEN 'vault()(address)' --rpc-url $BASE_RPC_URL)"

  echo "A_ROUTE_COUNT=$(cast call $VAULT 'sleeveAdapterRouteCount(uint8)(uint256)' 0 --rpc-url $BASE_RPC_URL)"
  echo "B_ROUTE_COUNT=$(cast call $VAULT 'sleeveAdapterRouteCount(uint8)(uint256)' 1 --rpc-url $BASE_RPC_URL)"
  echo "A_ROUTE=$(cast call $VAULT 'sleeveAdapterRoutes(uint8,uint256)(address,uint16,bool)' 0 0 --rpc-url $BASE_RPC_URL)"
  echo "B_ROUTE=$(cast call $VAULT 'sleeveAdapterRoutes(uint8,uint256)(address,uint16,bool)' 1 0 --rpc-url $BASE_RPC_URL)"
  echo "WEIGHT_A=$(cast call $VAULT 'sleeveADepositBps()(uint16)' --rpc-url $BASE_RPC_URL)"
  echo "WEIGHT_B=$(cast call $VAULT 'sleeveBDepositBps()(uint16)' --rpc-url $BASE_RPC_URL)"
  echo "WEIGHT_C=$(cast call $VAULT 'sleeveCDepositBps()(uint16)' --rpc-url $BASE_RPC_URL)"

  echo "WRAPPER_YIELD_ADAPTER=$(cast call $SLEEVE_A_WRAPPER 'yieldAdapter()(address)' --rpc-url $BASE_RPC_URL)"
  echo "YIELD_CONTROLLER=$(cast call $BASE_CBBTC_YIELD_ADAPTER 'controller()(address)' --rpc-url $BASE_RPC_URL)"
  echo "AERO_CONTROLLER=$(cast call $AERODROME_CBBTC_STRATEGY 'controller()(address)' --rpc-url $BASE_RPC_URL)"
  echo "AERO_GAUGE=$(cast call $AERODROME_CBBTC_STRATEGY 'gauge()(address)' --rpc-url $BASE_RPC_URL)"
  echo "AERO_PATH=$(cast call $AERODROME_CBBTC_STRATEGY 'aeroToCbbtcPath()(bytes)' --rpc-url $BASE_RPC_URL)"
  echo "AERO_NET_APY_BPS=$(cast call $AERODROME_CBBTC_STRATEGY 'netApyBps()(uint256)' --rpc-url $BASE_RPC_URL)"
} 2>&1 | tee -a $REDEPLOY_LOG
```

## Phase 7 - Deploy Automation

Keep automation unwired until smoke tests pass.

```bash
export WIRE_AUTOMATION=false

forge script scripts/deploy/03_SetupAutomation.s.sol \
  --rpc-url $BASE_RPC_URL \
  --broadcast \
  --slow \
  2>&1 | tee -a $REDEPLOY_LOG
```

Export:

```bash
export AUTOMATION=<BridgewayAutomation>
```

## Phase 8 - Smoke Deposit

Only run after CCR roles are granted and CGOV vault reference has executed.

```bash
cast call $USDC \
  "balanceOf(address)(uint256)" \
  $DEPLOYER \
  --rpc-url $BASE_RPC_URL

cast send $USDC \
  "approve(address,uint256)" \
  $VAULT \
  60000000 \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL) \
  2>&1 | tee -a $REDEPLOY_LOG

cast call $VAULT \
  "deposit(uint256,uint256)" \
  60000000 \
  0 \
  --from $DEPLOYER \
  --rpc-url $BASE_RPC_URL \
  2>&1 | tee -a $REDEPLOY_LOG

cast send $VAULT \
  "deposit(uint256,uint256)" \
  60000000 \
  0 \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL) \
  --gas-limit 3000000 \
  2>&1 | tee -a $REDEPLOY_LOG
```

## Phase 9 - Smoke Redeem

Test 1 CCR redeem. If idle vault USDC is below the buffer, seed 2 USDC first.

```bash
{
  echo "VAULT_USDC=$(cast call $USDC 'balanceOf(address)(uint256)' $VAULT --rpc-url $BASE_RPC_URL)"
  echo "TOTAL_PENDING_FEES=$(cast call $VAULT 'totalPendingFees()(uint256)' --rpc-url $BASE_RPC_URL)"
  echo "NAV_PER_CCR=$(cast call $VAULT 'navPerBGW()(uint256)' --rpc-url $BASE_RPC_URL)"
  echo "EXIT_FEE_BPS=$(cast call $VAULT 'exitFeeBps()(uint16)' --rpc-url $BASE_RPC_URL)"
} 2>&1 | tee -a $REDEPLOY_LOG

cast call $VAULT \
  "redeem(uint256,uint256)" \
  1000000000000000000 \
  0 \
  --from $DEPLOYER \
  --rpc-url $BASE_RPC_URL \
  2>&1 | tee -a $REDEPLOY_LOG

cast send $VAULT \
  "redeem(uint256,uint256)" \
  1000000000000000000 \
  0 \
  --rpc-url $BASE_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --nonce $(cast nonce $DEPLOYER --rpc-url $BASE_RPC_URL) \
  --gas-limit 3000000 \
  2>&1 | tee -a $REDEPLOY_LOG
```

## Phase 10 - Dashboard Refresh

Open:

```text
file:///Users/vipul/bridgeway-all/tools/bridgeway-dashboard.html
```

Update the dashboard constants if the page does not auto-detect the new outputs:

- `vault = $VAULT`
- `sleeveAWrapper = $SLEEVE_A_WRAPPER`
- `baseCbbtcYieldAdapter = $BASE_CBBTC_YIELD_ADAPTER`
- `aerodromeCbbtcStrategy = $AERODROME_CBBTC_STRATEGY`
- `sleeveBAdapter = $SLEEVE_B_ADAPTER`

## Phase 11 - Final Safe Ownership Acceptance

Only after smoke deposit/redeem and dashboard checks pass, accept ownership from the Protocol Owner Safe for:

- `VAULT`
- `SLEEVE_A_WRAPPER`
- `AERODROME_CBBTC_STRATEGY`
- `BASE_CBBTC_YIELD_ADAPTER`
- `SLEEVE_B_ADAPTER`
- `AUTOMATION`

Safe calldata for each ownable contract:

```bash
cast calldata "acceptOwnership()"
```
