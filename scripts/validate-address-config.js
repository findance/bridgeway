#!/usr/bin/env node

const fs = require("fs");

const MAINNET_CHAIN_IDS = new Set([1, 56, 8453, 42161, 43114]);
const TESTNET_CHAIN_IDS = new Set([97, 84532, 421614, 43113, 11155111, 560048]);
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const UINT_RE = /^[0-9]+$/;

function usage() {
  console.error("Usage: node scripts/validate-address-config.js <config.json> [--broadcast]");
  process.exit(2);
}

const file = process.argv[2];
const broadcast = process.argv.includes("--broadcast");
if (!file) usage();

const config = JSON.parse(fs.readFileSync(file, "utf8"));
const errors = [];

function fail(message) {
  errors.push(message);
}

function requireString(value, path) {
  if (typeof value !== "string" || value.length === 0) fail(`${path} must be a non-empty string`);
}

function requireAddress(value, path) {
  requireString(value, path);
  if (typeof value === "string" && !ADDRESS_RE.test(value)) fail(`${path} must be a 20-byte hex address`);
}

function requireSelector(value, path) {
  requireString(value, path);
  if (typeof value === "string" && !UINT_RE.test(value)) fail(`${path} must be a decimal string`);
}

function validateStatus() {
  requireString(config.schemaVersion, "schemaVersion");
  if (config.schemaVersion !== "1.0") fail("schemaVersion must be 1.0");

  if (config.environment !== "mainnet" && config.environment !== "testnet") {
    fail("environment must be mainnet or testnet");
  }

  requireString(config.status, "status");
  requireString(config.requiredStatusForBroadcast, "requiredStatusForBroadcast");
  requireString(config.ccipInterfaceVersion, "ccipInterfaceVersion");

  if (config.settlementPolicy) {
    if (config.settlementPolicy.redemptionAsset !== "USDC") {
      fail("settlementPolicy.redemptionAsset must be USDC");
    }
    if (config.settlementPolicy.neverValueUSDCAboveUSD !== true) {
      fail("settlementPolicy.neverValueUSDCAboveUSD must be true");
    }
    if (config.settlementPolicy.allowUSDCBelowUSD !== true) {
      fail("settlementPolicy.allowUSDCBelowUSD must be true");
    }
    if (config.settlementPolicy.redemptionMaxUsdPrice !== "1.00000000") {
      fail("settlementPolicy.redemptionMaxUsdPrice must be 1.00000000");
    }
  }

  if (broadcast && config.status !== config.requiredStatusForBroadcast) {
    fail(`broadcast blocked: status ${config.status} does not equal ${config.requiredStatusForBroadcast}`);
  }
}

function validateChain(key, chain) {
  const keyChainId = Number(key);
  if (!Number.isSafeInteger(keyChainId)) fail(`chains.${key} key must be a safe integer chain id`);
  if (chain.chainId !== keyChainId) fail(`chains.${key}.chainId must equal JSON key ${key}`);

  if (config.environment === "mainnet" && !MAINNET_CHAIN_IDS.has(chain.chainId)) {
    fail(`mainnet config contains non-mainnet chain id ${chain.chainId}`);
  }
  if (config.environment === "testnet" && !TESTNET_CHAIN_IDS.has(chain.chainId)) {
    fail(`testnet config contains non-testnet chain id ${chain.chainId}`);
  }

  requireString(chain.name, `chains.${key}.name`);

  if (!chain.ccip) {
    fail(`chains.${key}.ccip is required`);
  } else {
    if (chain.ccip.version !== config.ccipInterfaceVersion) {
      fail(`chains.${key}.ccip.version must equal top-level ccipInterfaceVersion`);
    }
    requireSelector(chain.ccip.selector, `chains.${key}.ccip.selector`);
    requireAddress(chain.ccip.router, `chains.${key}.ccip.router`);
    requireString(chain.ccip.source, `chains.${key}.ccip.source`);
    requireString(chain.ccip.explorer, `chains.${key}.ccip.explorer`);
    if (!chain.ccip.verification) fail(`chains.${key}.ccip.verification is required`);
    if (!chain.ccip.validation) fail(`chains.${key}.ccip.validation is required`);
  }

  for (const [symbol, asset] of Object.entries(chain.assets || {})) {
    requireAddress(asset.token, `chains.${key}.assets.${symbol}.token`);
    requireAddress(asset.priceFeed, `chains.${key}.assets.${symbol}.priceFeed`);
    if (!Number.isInteger(asset.tokenDecimals)) fail(`chains.${key}.assets.${symbol}.tokenDecimals must be integer`);
    if (!Number.isInteger(asset.feedDecimals)) fail(`chains.${key}.assets.${symbol}.feedDecimals must be integer`);
  }

  if (chain.settlementAsset) {
    if (chain.settlementAsset.symbol !== "USDC") fail(`chains.${key}.settlementAsset.symbol must be USDC`);
    requireAddress(chain.settlementAsset.token, `chains.${key}.settlementAsset.token`);
    requireAddress(chain.settlementAsset.usdPriceFeed, `chains.${key}.settlementAsset.usdPriceFeed`);
    if (!Number.isInteger(chain.settlementAsset.tokenDecimals)) {
      fail(`chains.${key}.settlementAsset.tokenDecimals must be integer`);
    }
    if (!Number.isInteger(chain.settlementAsset.feedDecimals)) {
      fail(`chains.${key}.settlementAsset.feedDecimals must be integer`);
    }
    const pricing = chain.settlementAsset.redemptionPricing;
    if (!pricing) {
      fail(`chains.${key}.settlementAsset.redemptionPricing is required`);
    } else {
      if (pricing.maxUsdPrice !== "1.00000000") {
        fail(`chains.${key}.settlementAsset.redemptionPricing.maxUsdPrice must be 1.00000000`);
      }
      if (pricing.allowBelowPeg !== true) {
        fail(`chains.${key}.settlementAsset.redemptionPricing.allowBelowPeg must be true`);
      }
      if (pricing.neverValueAboveUsd !== true) {
        fail(`chains.${key}.settlementAsset.redemptionPricing.neverValueAboveUsd must be true`);
      }
    }
  }

  for (const [symbol, wrapper] of Object.entries(chain.stakingWrappers || {})) {
    requireString(wrapper.symbol, `chains.${key}.stakingWrappers.${symbol}.symbol`);
    requireAddress(wrapper.token, `chains.${key}.stakingWrappers.${symbol}.token`);
    requireString(wrapper.type, `chains.${key}.stakingWrappers.${symbol}.type`);
    requireString(wrapper.status, `chains.${key}.stakingWrappers.${symbol}.status`);
    requireString(wrapper.explorer, `chains.${key}.stakingWrappers.${symbol}.explorer`);
    if (!Array.isArray(wrapper.sources) || wrapper.sources.length === 0) {
      fail(`chains.${key}.stakingWrappers.${symbol}.sources must be a non-empty array`);
    }
    if (chain.chainId === 42161 && symbol === "LBTC") {
      if (wrapper.status !== "blocked-redundant-pending-lombard-registry") {
        fail("chains.42161.stakingWrappers.LBTC must remain blocked until Lombard lists Arbitrum");
      }
    }
  }

  if (config.environment === "mainnet" && chain.chainId === 56) {
    if (chain.settlementAsset) {
      fail("chains.56.settlementAsset must remain unset: BNB Chain USDC is not approved for redemption settlement");
    }
    const policy = chain.settlementPolicy;
    if (!policy) {
      fail("chains.56.settlementPolicy is required");
    } else {
      if (policy.status !== "rejected-for-redemption-settlement") {
        fail("chains.56.settlementPolicy.status must reject redemption settlement");
      }
      if (policy.asset !== "USDC") {
        fail("chains.56.settlementPolicy.asset must be USDC");
      }
      if (!Array.isArray(policy.forbiddenUses) || !policy.forbiddenUses.includes("redemption-settlement")) {
        fail("chains.56.settlementPolicy.forbiddenUses must include redemption-settlement");
      }
      requireString(policy.redemptionRoute, "chains.56.settlementPolicy.redemptionRoute");
    }
  }

  if (config.environment === "mainnet" && !chain.multisig) {
    fail(`chains.${key}.multisig is required for mainnet`);
  }

  if (chain.ccip_infra) {
    if (chain.ccip_infra.deployCritical !== false) {
      fail(`chains.${key}.ccip_infra.deployCritical must be false`);
    }
    for (const field of ["rmn", "token_admin_registry", "registry_module_owner"]) {
      const value = chain.ccip_infra[field];
      if (value !== null && value !== undefined) requireAddress(value, `chains.${key}.ccip_infra.${field}`);
    }
  }
}

validateStatus();
if (!config.chains || typeof config.chains !== "object") fail("chains object is required");
for (const [key, chain] of Object.entries(config.chains || {})) validateChain(key, chain);

if (errors.length > 0) {
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}

console.log(`${file}: ok${broadcast ? " (broadcast allowed)" : ""}`);
