# Bridgeway Mainnet Deployment Notes

The running source-of-truth ledger for live, deprecated, and future deployment
addresses is `DEPLOYMENT_NOTEBOOK.md`.

## Deprecated Smoke-Test Deployments

Any wstLINK rate reporter or rate registry deployed from a local checkout before
the latest `feature/hub-spoke` hardening commits is deprecated and must not be
used for production configuration.

Do not wire production contracts to smoke-test addresses. Deploy a fresh
BridgewayL1RateReporter on Ethereum and a fresh BridgewayRateRegistry on
Arbitrum from the current branch before continuing deployment.

The old smoke-test pair is safe to abandon as long as:

- it is not funded,
- no new registry trusts it as a source sender,
- no production adapter or deployment config references it,
- operators use only the latest deployment output addresses.

## Fresh wstLINK Rate Reporter Flow

Run these from a clean, current `feature/hub-spoke` checkout.

```bash
git fetch origin
git checkout feature/hub-spoke
git pull --rebase origin feature/hub-spoke
forge test
```

Deploy the latest Ethereum reporter:

```bash
forge script scripts/deploy/08_DeployWstLINKL1RateReporter.s.sol \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

Deploy the latest Arbitrum registry using the new reporter address:

```bash
export L1_RATE_REPORTER=<new_ethereum_reporter>

forge script scripts/deploy/09_DeployWstLINKRateRegistry.s.sol \
  --rpc-url $ARBITRUM_RPC \
  --broadcast
```

Set the reporter receiver and send the first rate update:

```bash
export L1_RATE_REPORTER=<new_ethereum_reporter>
export L2_RATE_REGISTRY=<new_arbitrum_registry>
export RATE_REPORT_VALUE_WEI=3000000000000000

forge script ./scripts/deploy/12_SetReceiverAndReportWstLINKRate.s.sol \
  --tc SetReceiverAndReportWstLINKRate \
  --rpc-url $ETH_RPC_URL \
  --broadcast
```

Verify on Arbitrum:

```bash
cast call $L2_RATE_REGISTRY \
  "rateStatus(address)(uint256,uint256,uint256,uint256,uint256,uint256,uint8)" \
  $WSTLINK_L2 \
  --rpc-url $ARBITRUM_RPC
```

State `0` is valid. State `1` is settling and should become valid after the
configured settle window.
