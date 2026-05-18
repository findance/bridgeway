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
///           AUTOMATION_OWNER
///           VAULT              (from script 02 output)
///           USDC_ADDRESS
///
///         Optional env vars:
///           PROPOSE_AUTOMATION  true only when the vault owner should start the 48h timer
///
///         Command:
///           forge script scripts/deploy/03_SetupAutomation.s.sol \
///             --rpc-url $BASE_RPC_URL \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
///
///         AFTER running this script:
///           1. Register the automation contract on https://automation.chain.link
///              Network: Base
///              Trigger: Custom logic
///              Target:  $AUTOMATION address
///              Fund with LINK (~10-20 LINK recommended)
contract SetupAutomation is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address automationOwner = vm.envAddress("AUTOMATION_OWNER");
        address vaultAddr   = vm.envAddress("VAULT");
        address usdcAddr    = vm.envAddress("USDC_ADDRESS");
        bool proposeAutomation = vm.envOr("PROPOSE_AUTOMATION", false);

        BGWVault vault = BGWVault(vaultAddr);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BridgewayAutomation
        BridgewayAutomation automation = new BridgewayAutomation(vaultAddr, automationOwner, usdcAddr);
        console.log("BridgewayAutomation:", address(automation));

        // 2. Optionally propose automation -> vault (48-hour timelock).
        //    Keep PROPOSE_AUTOMATION=false during dry-run and integration testing.
        if (proposeAutomation) {
            vault.proposeAutomation(address(automation));
            console.log("Automation proposed - call executeAutomation() after 48 hours");
        } else {
            console.log("Automation not proposed. Set PROPOSE_AUTOMATION=true when ready to start the 48h timer.");
        }

        vm.stopBroadcast();

        console.log("\n=== Next steps ===");
        console.log("1. When testing is complete, propose automation from the vault owner Safe");
        console.log("2. Wait 48 hours, then call vault.executeAutomation() from the vault owner Safe");
        console.log("3. Go to https://automation.chain.link");
        console.log("4. Register upkeep:");
        console.log("   Network:  Base");
        console.log("   Trigger:  Custom logic");
        console.log("   Address: ", address(automation));
        console.log("   Gas limit: 500000");
        console.log("   Fund with 10-20 LINK");
        console.log("5. Verify contracts on Basescan");
        console.log("6. Make first deposit to bootstrap NAV at $1.00");
    }
}
