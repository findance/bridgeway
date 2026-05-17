#!/usr/bin/env node

const fs = require("fs");
const crypto = require("crypto");
const { spawnSync } = require("child_process");

const MAINNET_CHAIN_IDS = new Set([1, 56, 8453, 42161, 43114]);
const TESTNET_CHAIN_IDS = new Set([97, 84532, 421614, 43113, 11155111, 560048]);
const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const FUNCTION_SELECTOR_RE = /^0x[0-9a-fA-F]{8}$/;
const UINT_RE = /^[0-9]+$/;
const SAFE_TEXT_RE = /^[\x20-\x7E]*$/;
const ALLOWED_URL_HOSTS = new Set([
  "api.avax.network",
  "aerodrome.finance",
  "app.aave.com",
  "app.benqi.fi",
  "app.lista.org",
  "app.staderlabs.com",
  "arbiscan.io",
  "basescan.org",
  "bsc-rpc.publicnode.com",
  "bscscan.com",
  "curve.fi",
  "data.chain.link",
  "docs.benqi.fi",
  "docs.chain.link",
  "docs.lido.fi",
  "docs.lombard.finance",
  "docs.stake.link",
  "ethereum.publicnode.com",
  "etherscan.io",
  "github.com",
  "hoodi.etherscan.io",
  "lombard.finance",
  "pancakeswap.finance",
  "sepolia.arbiscan.io",
  "sepolia.basescan.org",
  "sepolia.etherscan.io",
  "snowscan.xyz",
  "snowtrace.io",
  "staking.chain.link",
  "testnet.bscscan.com",
  "testnet.snowtrace.io",
  "traderjoexyz.com",
  "www.ankr.com"
]);

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

function requireSafeText(value, path, maxLength = 500) {
  requireString(value, path);
  if (typeof value === "string") {
    if (value.length > maxLength) fail(`${path} exceeds ${maxLength} characters`);
    if (!SAFE_TEXT_RE.test(value)) fail(`${path} must be printable ASCII without newlines`);
  }
}

function requireAllowedUrl(value, path) {
  requireSafeText(value, path, 300);
  try {
    const url = new URL(value);
    if (url.protocol !== "https:") fail(`${path} must use https`);
    if (!ALLOWED_URL_HOSTS.has(url.hostname)) fail(`${path} host is not allowlisted: ${url.hostname}`);
  } catch {
    fail(`${path} must be a valid URL`);
  }
}

function checksumAddress(value) {
  const result = spawnSync("cast", ["to-checksum", value], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"]
  });
  if (result.status !== 0) {
    if (result.error && result.error.code === "ENOENT") {
      fail(`cast not found. Install Foundry before validating addresses: https://book.getfoundry.sh/getting-started/installation`);
      return null;
    }
    fail(`cast to-checksum failed for ${value}: ${result.stderr.trim() || "unknown error"}`);
    return null;
  }
  return result.stdout.trim();
}

function requireAddress(value, path) {
  requireString(value, path);
  if (typeof value === "string") {
    if (!ADDRESS_RE.test(value)) {
      fail(`${path} must be a 20-byte hex address`);
      return;
    }
    const checksummed = checksumAddress(value);
    if (checksummed && value !== checksummed) {
      fail(`${path} must use EIP-55 checksum case: ${checksummed}`);
    }
  }
}

function requireSelector(value, path) {
  requireString(value, path);
  if (typeof value === "string" && !UINT_RE.test(value)) fail(`${path} must be a decimal string`);
}

function requireFunctionSelector(value, path) {
  requireString(value, path);
  if (typeof value === "string" && !FUNCTION_SELECTOR_RE.test(value)) fail(`${path} must be a 4-byte selector`);
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

  validateFileIntegrity();
}

function deepSort(value) {
  if (Array.isArray(value)) return value.map(deepSort);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, deepSort(value[key])]));
  }
  return value;
}

function configDigest() {
  const clone = JSON.parse(JSON.stringify(config));
  if (clone.fileIntegrity) {
    clone.fileIntegrity.gitCommit = null;
    clone.fileIntegrity.sha256 = null;
  }
  return crypto.createHash("sha256").update(JSON.stringify(deepSort(clone))).digest("hex");
}

function validateFileIntegrity() {
  if (!config.fileIntegrity || typeof config.fileIntegrity !== "object") {
    fail("fileIntegrity is required");
    return;
  }

  const { gitCommit, sha256 } = config.fileIntegrity;
  if (gitCommit !== null && (typeof gitCommit !== "string" || !/^[0-9a-f]{40}$/.test(gitCommit))) {
    fail("fileIntegrity.gitCommit must be null or a full 40-character git commit hash");
  }
  if (sha256 !== null) {
    if (typeof sha256 !== "string" || !/^[0-9a-f]{64}$/.test(sha256)) {
      fail("fileIntegrity.sha256 must be null or a 64-character lowercase sha256 hex digest");
    } else {
      const digest = configDigest();
      if (sha256 !== digest) fail(`fileIntegrity.sha256 mismatch: expected ${digest}`);
    }
  }
  if (broadcast && (gitCommit === null || sha256 === null)) {
    fail("broadcast blocked: fileIntegrity.gitCommit and fileIntegrity.sha256 must be populated");
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
  requireSafeText(chain.name, `chains.${key}.name`, 80);

  if (!chain.ccip) {
    fail(`chains.${key}.ccip is required`);
  } else {
    if (chain.ccip.version !== config.ccipInterfaceVersion) {
      fail(`chains.${key}.ccip.version must equal top-level ccipInterfaceVersion`);
    }
    requireSelector(chain.ccip.selector, `chains.${key}.ccip.selector`);
    requireAddress(chain.ccip.router, `chains.${key}.ccip.router`);
    requireAllowedUrl(chain.ccip.source, `chains.${key}.ccip.source`);
    requireAllowedUrl(chain.ccip.explorer, `chains.${key}.ccip.explorer`);
    if (!chain.ccip.verification) fail(`chains.${key}.ccip.verification is required`);
    if (!chain.ccip.validation) fail(`chains.${key}.ccip.validation is required`);
  }

  for (const [symbol, asset] of Object.entries(chain.assets || {})) {
    requireAddress(asset.token, `chains.${key}.assets.${symbol}.token`);
    requireAddress(asset.priceFeed, `chains.${key}.assets.${symbol}.priceFeed`);
    requireSafeText(symbol, `chains.${key}.assets symbol`, 40);
    if (!Number.isInteger(asset.tokenDecimals)) fail(`chains.${key}.assets.${symbol}.tokenDecimals must be integer`);
    if (!Number.isInteger(asset.feedDecimals)) fail(`chains.${key}.assets.${symbol}.feedDecimals must be integer`);
  }

  if (chain.settlementAsset) {
    if (chain.settlementAsset.symbol !== "USDC") fail(`chains.${key}.settlementAsset.symbol must be USDC`);
    requireAddress(chain.settlementAsset.token, `chains.${key}.settlementAsset.token`);
    requireAddress(chain.settlementAsset.usdPriceFeed, `chains.${key}.settlementAsset.usdPriceFeed`);
    if (chain.settlementAsset.source) requireAllowedUrl(chain.settlementAsset.source, `chains.${key}.settlementAsset.source`);
    if (chain.settlementAsset.explorer) requireAllowedUrl(chain.settlementAsset.explorer, `chains.${key}.settlementAsset.explorer`);
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
    requireSafeText(wrapper.symbol, `chains.${key}.stakingWrappers.${symbol}.symbol`, 40);
    requireAddress(wrapper.token, `chains.${key}.stakingWrappers.${symbol}.token`);
    requireString(wrapper.type, `chains.${key}.stakingWrappers.${symbol}.type`);
    requireSafeText(wrapper.type, `chains.${key}.stakingWrappers.${symbol}.type`, 80);
    requireString(wrapper.status, `chains.${key}.stakingWrappers.${symbol}.status`);
    requireSafeText(wrapper.status, `chains.${key}.stakingWrappers.${symbol}.status`, 80);
    requireAllowedUrl(wrapper.explorer, `chains.${key}.stakingWrappers.${symbol}.explorer`);
    if (!Array.isArray(wrapper.sources) || wrapper.sources.length === 0) {
      fail(`chains.${key}.stakingWrappers.${symbol}.sources must be a non-empty array`);
    } else {
      wrapper.sources.forEach((source, i) => requireAllowedUrl(source, `chains.${key}.stakingWrappers.${symbol}.sources[${i}]`));
    }
    if (wrapper.notes) {
      requireSafeText(wrapper.notes, `chains.${key}.stakingWrappers.${symbol}.notes`, 500);
    }
    if (wrapper.rateModel) {
      requireString(wrapper.rateModel.method, `chains.${key}.stakingWrappers.${symbol}.rateModel.method`);
      requireString(wrapper.rateModel.underlyingSymbol, `chains.${key}.stakingWrappers.${symbol}.rateModel.underlyingSymbol`);
      if (!Number.isInteger(wrapper.rateModel.underlyingDecimals)) {
        fail(`chains.${key}.stakingWrappers.${symbol}.rateModel.underlyingDecimals must be integer`);
      }
      if (wrapper.rateModel.wrappedToUnderlyingSelector) {
        requireFunctionSelector(
          wrapper.rateModel.wrappedToUnderlyingSelector,
          `chains.${key}.stakingWrappers.${symbol}.rateModel.wrappedToUnderlyingSelector`
        );
      }
      if (wrapper.rateModel.underlyingToWrappedSelector) {
        requireFunctionSelector(
          wrapper.rateModel.underlyingToWrappedSelector,
          `chains.${key}.stakingWrappers.${symbol}.rateModel.underlyingToWrappedSelector`
        );
      }
    }
    if (chain.chainId === 42161 && symbol === "LBTC") {
      if (wrapper.status !== "blocked-redundant-pending-lombard-registry") {
        fail("chains.42161.stakingWrappers.LBTC must remain blocked until Lombard lists Arbitrum");
      }
    }
    if (chain.chainId === 42161 && symbol === "wstLINK") {
      if (wrapper.status !== "pending-rate-reporter-deployment" && wrapper.status !== "adapter-ready") {
        fail("chains.42161.stakingWrappers.wstLINK must remain pending until the rate reporter is deployed");
      }
      if (!wrapper.rateModel || wrapper.rateModel.method !== "bridgeway-ccip-rate-reporter") {
        fail("chains.42161.stakingWrappers.wstLINK must document bridgeway-ccip-rate-reporter pricing");
      }
      if (wrapper.status === "adapter-ready" && !wrapper.rateModel.deployment) {
        fail("chains.42161.stakingWrappers.wstLINK adapter-ready requires rateModel.deployment");
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
