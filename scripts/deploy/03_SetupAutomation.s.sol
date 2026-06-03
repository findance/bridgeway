// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/core/ClearcrestAdmin.sol";
import "../../contracts/core/ClearcrestAutomation.sol";
import "../../contracts/core/ClearcrestVault.sol";

/// @title  03_SetupAutomation
/// @notice Deploy ClearcrestAutomation and register with vault.
///         Run AFTER 02_DeployVault.s.sol.
///
///         Required env vars:
///           DEPLOYER           signer address used by --account
///           AUTOMATION_OWNER
///           VAULT              (from script 02 output)
///           USDC_ADDRESS
///
///         Optional env vars:
///           WIRE_AUTOMATION  true only when the vault owner should wire automation
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
        address deployer = vm.envAddress("DEPLOYER");
        address automationOwner = vm.envAddress("AUTOMATION_OWNER");
        address vaultAddr = vm.envAddress("VAULT");
        address adminAddr = vm.envOr("ADMIN", address(0));
        address usdcAddr = vm.envAddress("USDC_ADDRESS");
        bool wireAutomation = vm.envOr("WIRE_AUTOMATION", false);

        ClearcrestVault vault = ClearcrestVault(vaultAddr);

        vm.startBroadcast(deployer);

        // 1. Deploy ClearcrestAutomation
        ClearcrestAutomation automation = new ClearcrestAutomation(vaultAddr, automationOwner, usdcAddr);
        console.log("ClearcrestAutomation:", address(automation));

        // 2. Optionally wire automation -> vault.
        //    Keep WIRE_AUTOMATION=false during dry-run and integration testing.
        if (wireAutomation) {
            if (adminAddr == address(0)) {
                vault.setAutomation(address(automation));
            } else {
                ClearcrestAdmin.Call[] memory calls = new ClearcrestAdmin.Call[](1);
                calls[0] = ClearcrestAdmin.Call({
                    target: vaultAddr, data: abi.encodeCall(ClearcrestVault.setAutomation, (address(automation)))
                });
                ClearcrestAdmin(adminAddr).executeBootstrapOperation(calls);
            }
            console.log("Automation wired on vault");
        } else {
            console.log("Automation not wired. Set WIRE_AUTOMATION=true when ready.");
        }

        vm.stopBroadcast();

        console.log("\n=== Next steps ===");
        console.log("1. When testing is complete, wire automation from the vault owner Safe/controller");
        console.log("2. Go to https://automation.chain.link");
        console.log("3. Register upkeep:");
        console.log("   Network:  Base");
        console.log("   Trigger:  Custom logic");
        console.log("   Address: ", address(automation));
        console.log("   Gas limit: 500000");
        console.log("   Fund with 10-20 LINK");
        console.log("5. Verify contracts on Basescan");
        console.log("6. Make first deposit to bootstrap NAV at $1.00");
    }
}
