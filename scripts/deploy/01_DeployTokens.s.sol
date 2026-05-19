// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/tokens/BGWToken.sol";
import "../../contracts/tokens/BGWGovToken.sol";
import "../../contracts/libraries/BridgewayDeterministicDeploy.sol";

/// @title  01_DeployTokens
/// @notice Deploy BGWToken and BGWGovToken through CREATE2.
///         Run BEFORE 02_DeployVault.s.sol.
///         The token addresses are deterministic across EVM chains when the
///         CREATE2 factory, salts, bytecode, and constructor args are identical.
///
///         Output (save these addresses for script 02):
///           BGWToken:       $BGW_TOKEN
///           BGWGovToken:    $GOV_TOKEN
///
/// @dev    Set env vars before running:
///           DEPLOYER_PRIVATE_KEY   = temporary deployer/admin key
///           TOKEN_TEMP_ADMIN       = optional; defaults to deployer and must equal deployer
///           FOUNDER_TREASURY       = founder treasury receiving founder BGW-GOV
///           BASE_RPC_URL           = Base RPC URL
///           CREATE2_FACTORY        = optional; defaults to canonical 0x4e59... factory
///
///         Command:
///           forge script scripts/deploy/01_DeployTokens.s.sol \
///             --rpc-url $BASE_RPC_URL \
///             --broadcast \
///             --verify \
///             --etherscan-api-key $ARBISCAN_KEY
contract DeployTokens is Script {
    error Create2FactoryMissing(address factory);
    error PredictedAddressOccupied(address predicted);
    error Create2DeployFailed(address predicted);
    error TemporaryAdminMustBeDeployer(address temporaryAdmin, address deployer);

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address temporaryAdmin = vm.envOr("TOKEN_TEMP_ADMIN", deployer);
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");
        address factory = vm.envOr(
            "CREATE2_FACTORY",
            BridgewayDeterministicDeploy.defaultCreate2Factory()
        );

        if (temporaryAdmin != deployer) revert TemporaryAdminMustBeDeployer(temporaryAdmin, deployer);
        if (factory.code.length == 0) revert Create2FactoryMissing(factory);

        address predictedBGW = BridgewayDeterministicDeploy.predictBGWToken(factory, temporaryAdmin);
        address predictedGov =
            BridgewayDeterministicDeploy.predictBGWGovToken(factory, founderTreasury, predictedBGW, temporaryAdmin);

        console.log("CREATE2 factory:", factory);
        console.log("BGWToken predicted:", predictedBGW);
        console.log("BGWGovToken predicted:", predictedGov);
        console.log("BGWToken salt:");
        console.logBytes32(BridgewayDeterministicDeploy.bgwTokenSalt());
        console.log("BGWGovToken salt:");
        console.logBytes32(BridgewayDeterministicDeploy.bgwGovTokenSalt());

        if (predictedBGW.code.length != 0) revert PredictedAddressOccupied(predictedBGW);
        if (predictedGov.code.length != 0) revert PredictedAddressOccupied(predictedGov);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BGWToken with deployer as temporary admin so script 02 can wire roles.
        _deployViaFactory(
            factory,
            BridgewayDeterministicDeploy.bgwTokenSalt(),
            BridgewayDeterministicDeploy.bgwTokenInitCode(temporaryAdmin),
            predictedBGW
        );
        BGWToken bgwToken = BGWToken(predictedBGW);
        console.log("BGWToken:      ", address(bgwToken));

        // 2. Deploy BGWGovToken (inflationary, minted by the vault on deposit).
        _deployViaFactory(
            factory,
            BridgewayDeterministicDeploy.bgwGovTokenSalt(),
            BridgewayDeterministicDeploy.bgwGovTokenInitCode(founderTreasury, address(bgwToken), temporaryAdmin),
            predictedGov
        );
        BGWGovToken govToken = BGWGovToken(predictedGov);
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

    function _deployViaFactory(
        address factory,
        bytes32 salt,
        bytes memory initCode,
        address predicted
    ) internal {
        (bool success,) = factory.call(abi.encodePacked(salt, initCode));
        if (!success || predicted.code.length == 0) revert Create2DeployFailed(predicted);
    }
}
