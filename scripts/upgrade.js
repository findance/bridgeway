// Usage: npx hardhat run scripts/upgrade.js --network arbitrumSepolia
const { ethers, upgrades } = require("hardhat");
require("dotenv").config();

async function main() {
  if (process.env.ALLOW_LEGACY_WRAPPER_DEPLOY !== "true") {
    throw new Error(
      "Legacy BridgewayAutomationWrapper upgrade is disabled. The current audited path is the non-upgradeable core vault plus automation deployment scripts. Set ALLOW_LEGACY_WRAPPER_DEPLOY=true only for an intentional legacy testnet upgrade."
    );
  }

  const [deployer]  = await ethers.getSigners();
  const deployments = require("../deployments.json");

  console.log("================================================================");
  console.log("BRIDGEWAY (BGW) — Upgrading BridgewayAutomationWrapper");
  console.log("================================================================");
  console.log("Deployer:      ", deployer.address);
  console.log("Proxy address: ", deployments.proxyAddress);
  console.log("Old impl:      ", deployments.implAddress);

  const Factory = await ethers.getContractFactory("BridgewayAutomationWrapper");

  console.log("\n⏳ Deploying new implementation...");
  const upgraded = await upgrades.upgradeProxy(
    deployments.proxyAddress,
    Factory,
    {
      kind: "uups",
      constructorArgs: [
        deployments.config.enzymeVault,
        deployments.config.bgwToken,
        deployments.config.usdcToken,
        deployments.config.camelotRouter,
        deployments.config.priceFeed,
      ],
    }
  );

  await upgraded.waitForDeployment();
  const newImpl = await upgrades.erc1967.getImplementationAddress(deployments.proxyAddress);

  console.log("\n✅ UPGRADE SUCCESSFUL");
  console.log("New implementation: ", newImpl);
  console.log("Proxy unchanged:    ", deployments.proxyAddress);

  const fs = require("fs");
  deployments.implAddress = newImpl;
  deployments.upgradedAt  = new Date().toISOString();
  fs.writeFileSync("./deployments.json", JSON.stringify(deployments, null, 2));
  console.log("💾 deployments.json updated");

  console.log("\n🔙 To rollback:");
  console.log("   Set implAddress in deployments.json to the old address,");
  console.log("   then call upgradeTo(oldAddress) directly on the proxy.");
}

main().catch((err) => {
  console.error("❌ Upgrade failed:", err);
  process.exit(1);
});
