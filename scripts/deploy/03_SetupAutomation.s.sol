// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/BridgewayAutomation.sol";
import "../../contracts/core/BGWVault.sol";

/// @title  03_SetupAutomation
/// @notice Deploy BridgewayAutomation and register with vault.
///         Run AFTER 02_DeployVault.s.sol.
///
///         Required env vars:
///           DEPLOYER_PRIVATE_KEY
///           FOUNDER_ADDRESS
///           VAULT              (from script 02 output)
///
///         Command:
///           forge script scripts/deploy/03_SetupAutomation.s.sol \
///             --rpc-url $ARBITRUM_RPC \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
///
///         AFTER running this script:
///           1. Register the automation contract on https://automation.chain.link
///              Network: Arbitrum One
///              Trigger: Custom logic
///              Target:  $AUTOMATION address
///              Fund with LINK (~10-20 LINK recommended)
contract SetupAutomation is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address founderAddr = vm.envAddress("FOUNDER_ADDRESS");
        address vaultAddr   = vm.envAddress("VAULT");
        address usdcAddr    = vm.envAddress("USDC_ADDRESS");

        BGWVault vault = BGWVault(vaultAddr);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BridgewayAutomation
        BridgewayAutomation automation = new BridgewayAutomation(vaultAddr, founderAddr, usdcAddr);
        console.log("BridgewayAutomation:", address(automation));

        // 2. Propose automation → vault (48-hour timelock — C-01).
        //    Call vault.executeAutomation() from the founder multisig after 48 hours.
        vault.proposeAutomation(address(automation));
        console.log("Automation proposed - call executeAutomation() after 48 hours");

        vm.stopBroadcast();

        console.log("\n=== Next steps ===");
        console.log("1. Wait 48 hours, then call vault.executeAutomation() from founder multisig");
        console.log("2. Go to https://automation.chain.link");
        console.log("3. Register upkeep:");
        console.log("   Network:  Arbitrum One");
        console.log("   Trigger:  Custom logic");
        console.log("   Address: ", address(automation));
        console.log("   Gas limit: 500000");
        console.log("   Fund with 10-20 LINK");
        console.log("4. Verify contracts on Arbiscan");
        console.log("5. Make first deposit to bootstrap NAV at $1.00");
    }
}
