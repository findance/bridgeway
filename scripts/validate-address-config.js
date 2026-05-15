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

  if (config.environment === "mainnet" && !chain.multisig) {
    fail(`chains.${key}.multisig is required for mainnet`);
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
