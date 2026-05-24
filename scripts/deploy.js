// Usage: npx hardhat run scripts/deploy.js --network arbitrumSepolia
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  if (process.env.ALLOW_LEGACY_WRAPPER_DEPLOY !== "true") {
    throw new Error(
      "Legacy BridgewayAutomationWrapper deploy is disabled. Use scripts/deploy/01_DeployTokens.s.sol, 02_DeployVault.s.sol, and 03_SetupAutomation.s.sol for the audited core contracts. Set ALLOW_LEGACY_WRAPPER_DEPLOY=true only for an intentional legacy testnet deployment."
    );
  }

  const [deployer] = await ethers.getSigners();
  const network    = await ethers.provider.getNetwork();

  console.log("================================================================");
  console.log("CLEARCREST (CCR) — Deploying BridgewayAutomationWrapper");
  console.log("================================================================");
  console.log("Deployer: ", deployer.address);
  console.log("Network:  ", network.name);
  console.log("Balance:  ", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("----------------------------------------------------------------");

  const required = [
    "ENZYME_VAULT_ADDRESS",
    "BGW_TOKEN_ADDRESS",
    "USDC_TOKEN_ADDRESS",
    "CAMELOT_ROUTER_ADDRESS",
    "CHAINLINK_PRICE_FEED",
    "TEAM_WALLET",
    "HOLDBACK_WALLET",
    "LP_SEED_WALLET",
    "RESERVE_WALLET",
  ];

  const missing = required.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    console.error("Missing env vars:", missing.join(", "));
    console.error("Copy .env.example to .env and fill in all values.");
    process.exit(1);
  }

  const cfg = {
    enzymeVault:    process.env.ENZYME_VAULT_ADDRESS,
    bgwToken:       process.env.BGW_TOKEN_ADDRESS,
    usdcToken:      process.env.USDC_TOKEN_ADDRESS,
    camelotRouter:  process.env.CAMELOT_ROUTER_ADDRESS,
    priceFeed:      process.env.CHAINLINK_PRICE_FEED,
    teamWallet:     process.env.TEAM_WALLET,
    holdbackWallet: process.env.HOLDBACK_WALLET,
    lpSeedWallet:   process.env.LP_SEED_WALLET,
    reserveWallet:  process.env.RESERVE_WALLET,
  };

  console.log("Config:");
  Object.entries(cfg).forEach(([k, v]) => console.log(`  ${k.padEnd(16)}: ${v}`));
  console.log("----------------------------------------------------------------");

  console.log("\n⏳ Deploying implementation + proxy...");
  const Factory = await ethers.getContractFactory("BridgewayAutomationWrapper");

  const proxy = await upgrades.deployProxy(
    Factory,
    [cfg.teamWallet, cfg.holdbackWallet, cfg.lpSeedWallet, cfg.reserveWallet],
    {
      kind: "uups",
      constructorArgs: [
        cfg.enzymeVault,
        cfg.bgwToken,
        cfg.usdcToken,
        cfg.camelotRouter,
        cfg.priceFeed,
      ],
      initializer: "initialize",
    }
  );

  await proxy.waitForDeployment();
  const proxyAddress = await proxy.getAddress();
  const implAddress  = await upgrades.erc1967.getImplementationAddress(proxyAddress);

  console.log("\n✅ DEPLOYMENT SUCCESSFUL");
  console.log("================================================================");
  console.log("Proxy (use this): ", proxyAddress);
  console.log("Implementation:   ", implAddress);
  console.log("================================================================");

  // Verify initial on-chain state
  const wrapper = await ethers.getContractAt("BridgewayAutomationWrapper", proxyAddress);
  const [teamW, holdbackW, lpW, reserveW, hwm, gasCost] = await Promise.all([
    wrapper.teamWallet(),
    wrapper.holdbackWallet(),
    wrapper.lpSeedWallet(),
    wrapper.reserveWallet(),
    wrapper.highWaterMark(),
    wrapper.estimatedGasCostUSDC(),
  ]);
  console.log("\nInitial state:");
  console.log("  teamWallet:           ", teamW);
  console.log("  holdbackWallet:       ", holdbackW);
  console.log("  lpSeedWallet:         ", lpW);
  console.log("  reserveWallet:        ", reserveW);
  console.log("  highWaterMark:        ", hwm.toString());
  console.log("  estimatedGasCostUSDC: ", gasCost.toString());

  const fs = require("fs");
  const info = {
    network:     network.name,
    chainId:     Number(network.chainId),
    deployedAt:  new Date().toISOString(),
    deployer:    deployer.address,
    proxyAddress,
    implAddress,
    config: cfg,
  };
  fs.writeFileSync("./deployments.json", JSON.stringify(info, null, 2));
  console.log("\n💾 deployments.json saved");

  console.log("\n📋 NEXT STEPS:");
  console.log("  1. Verify:   npm run verify:testnet");
  console.log("  2. Register Chainlink Automation at https://automation.chain.link");
  console.log("     — Custom Logic upkeep, contract:", proxyAddress);
  console.log("  3. Send test USDC to proxy, then call recordStakingYield()");
}

main().catch((err) => {
  console.error("❌ Deployment failed:", err);
  process.exit(1);
});
