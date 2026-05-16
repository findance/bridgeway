# wstLINK Rate Reporter Deployment

This sequence makes Arbitrum `wstLINK` usable for Bridgeway NAV accounting without relying on a local DEX-implied exchange rate.

## Confirmed Inputs

| Input | Value |
| --- | --- |
| Ethereum CCIP selector | `5009297550715157269` |
| Arbitrum CCIP selector | `4949039107694359620` |
| Ethereum CCIP router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| Arbitrum CCIP router | `0x141fa059441E0ca23ce184B6A78bafD2A517DdE8` |
| Ethereum wstLINK | `0x911D86C72155c33993d594B0Ec7E6206B4C803da` |
| Arbitrum wstLINK | `0x3106E2e148525b3DB36795b04691D444c24972fB` |
| Owner Safe | `0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348` |

## Step 1: Deploy Ethereum Reporter

Run on Ethereum mainnet.

```bash
export RATE_REPORTER_OWNER=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
export ETH_CCIP_ROUTER=0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D
export WSTLINK_L1=0x911D86C72155c33993d594B0Ec7E6206B4C803da
export WSTLINK_L2=0x3106E2e148525b3DB36795b04691D444c24972fB
export ARBITRUM_CCIP_SELECTOR=4949039107694359620

forge script scripts/deploy/08_DeployWstLINKL1RateReporter.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

Save the printed `BridgewayL1RateReporter` address.

## Step 2: Deploy Arbitrum Rate Registry

Run on Arbitrum One.

```bash
export RATE_REGISTRY_OWNER=0x3f276b5355d34DA9D72Bba6D0ea0c103D3f15348
export ARBITRUM_CCIP_ROUTER=0x141fa059441E0ca23ce184B6A78bafD2A517DdE8
export L1_RATE_REPORTER=<printed reporter address from Step 1>
export ETHEREUM_CCIP_SELECTOR=5009297550715157269
export WSTLINK_L2=0x3106E2e148525b3DB36795b04691D444c24972fB
export WSTLINK_MAX_STALENESS_SECONDS=86400

forge script scripts/deploy/09_DeployWstLINKRateRegistry.s.sol \
  --rpc-url $ARBITRUM_RPC \
  --broadcast
```

Save the printed `BridgewayRateRegistry` address.

## Step 3: Set Reporter Receiver

Run on Ethereum mainnet from the reporter owner or via the owner Safe.

```bash
export L1_RATE_REPORTER=<printed reporter address from Step 1>
export L2_RATE_REGISTRY=<printed registry address from Step 2>

forge script scripts/deploy/10_SetWstLINKRateReporterReceiver.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

## Step 4: Fund Reporter and Send First Rate

Run on Ethereum mainnet. `RATE_REPORT_VALUE_WEI` is sent into `reportRate()` as a CCIP fee cushion.

```bash
export L1_RATE_REPORTER=<printed reporter address from Step 1>
export RATE_REPORT_VALUE_WEI=50000000000000000

forge script scripts/deploy/11_ReportWstLINKRate.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

Save the printed CCIP message ID.

## Step 5: Confirm Arbitrum Registry State

After CCIP delivery, confirm:

```bash
cast call $L2_RATE_REGISTRY \
  "getValidatedRate(address)(uint256)" \
  0x3106E2e148525b3DB36795b04691D444c24972fB \
  --rpc-url $ARBITRUM_RPC
```

The call should return a rate between `1e18` and `2e18`.

## Step 6: Record Deployment

After Step 5 succeeds, update `config/mainnet-addresses.json`:

- `chains.42161.stakingWrappers.wstLINK.status` -> `adapter-ready`
- Add `rateModel.deployment.l1RateReporter`
- Add `rateModel.deployment.l2RateRegistry`
- Add `rateModel.deployment.firstMessageId`
- Add `rateModel.deployment.firstConfirmedAt`
- Add `rateModel.deployment.senderBytes = abi.encode(l1RateReporter)`

Only then should the `deployed spoke source sender bytes` blocker be removed for this path.
