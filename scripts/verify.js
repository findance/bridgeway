// Usage: npx hardhat run scripts/verify.js --network arbitrumSepolia
const { run } = require("hardhat");
require("dotenv").config();

async function main() {
  const deployments = require("../deployments.json");

  console.log("================================================================");
  console.log("BRIDGEWAY (BGW) — Verifying on Arbiscan");
  console.log("================================================================");
  console.log("Implementation: ", deployments.implAddress);

  try {
    await run("verify:verify", {
      address: deployments.implAddress,
      constructorArguments: [
        deployments.config.enzymeVault,
        deployments.config.bgwToken,
        deployments.config.usdcToken,
        deployments.config.camelotRouter,
        deployments.config.priceFeed,
      ],
    });
    console.log("✅ Implementation verified");
    console.log(`   https://sepolia.arbiscan.io/address/${deployments.implAddress}`);
  } catch (err) {
    if (err.message.includes("Already Verified")) {
      console.log("✅ Already verified");
    } else {
      throw err;
    }
  }
}

main().catch((err) => {
  console.error("❌ Verification failed:", err);
  process.exit(1);
});
