// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";

/// @title  01_DeployTokens
/// @notice Deploy BGWToken and BGWGovToken.
///         Run BEFORE 02_DeployVault.s.sol.
///
///         Output (save these addresses for script 02):
///           BGWToken:       $BGW_TOKEN
///           BGWGovToken:    $GOV_TOKEN
///
/// @dev    Set env vars before running:
///           DEPLOYER_PRIVATE_KEY   = temporary deployer/admin key
///           FOUNDER_TREASURY       = founder treasury receiving founder BGW-GOV
///           BASE_RPC_URL           = Base RPC URL
///
///         Command:
///           forge script scripts/deploy/01_DeployTokens.s.sol \
///             --rpc-url $BASE_RPC_URL \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
contract DeployTokens is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy BGWToken with deployer as temporary admin so script 02 can wire roles.
        BGWToken bgwToken = new BGWToken(deployer);
        console.log("BGWToken:      ", address(bgwToken));

        // 2. Deploy BGWGovToken (inflationary, minted by the vault on deposit).
        BGWGovToken govToken = new BGWGovToken(
            founderTreasury,
            address(bgwToken),
            deployer
        );
        console.log("BGWGovToken:   ", address(govToken));

        bgwToken.setGovernanceCompanion(address(govToken));
        console.log("Set BGW-GOV companion on BGWToken");

        vm.stopBroadcast();

        // Print summary for script 02
        console.log("\n=== Save these for script 02 ===");
        console.log("BGW_TOKEN=",      address(bgwToken));
        console.log("GOV_TOKEN=",      address(govToken));
        console.log("Temporary token admin:", deployer);
        console.log("Founder treasury:", founderTreasury);
        console.log("Run script 02 next to wire the vault and hand token admin to TOKEN_ADMIN.");
    }
}
