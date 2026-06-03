// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/tokens/CCRToken.sol";
import "../../contracts/tokens/CGOVToken.sol";
import "../../contracts/libraries/ClearcrestDeterministicDeploy.sol";

/// @title  01_DeployTokens
/// @notice Deploy Clearcrest CCR and Clearcrest-GOV CGOV through CREATE2.
///         Run BEFORE 02_DeployVault.s.sol.
///         The token addresses are deterministic across EVM chains when the
///         CREATE2 factory, salts, bytecode, and constructor args are identical.
///
///         Output (save these addresses for script 02):
///           CCR token:      $CCR_TOKEN
///           CGOV token:     $CGOV_TOKEN
///
/// @dev    Set env vars before running:
///           DEPLOYER               = temporary deployer/admin address used by --account
///           TOKEN_TEMP_ADMIN       = optional; defaults to deployer and must equal deployer
///           FOUNDER_TREASURY       = founder treasury receiving founder CGOV
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
        address deployer = vm.envAddress("DEPLOYER");
        address temporaryAdmin = vm.envOr("TOKEN_TEMP_ADMIN", deployer);
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");
        address factory = vm.envOr("CREATE2_FACTORY", ClearcrestDeterministicDeploy.defaultCreate2Factory());

        if (temporaryAdmin != deployer) revert TemporaryAdminMustBeDeployer(temporaryAdmin, deployer);
        if (factory.code.length == 0) revert Create2FactoryMissing(factory);

        address predictedCCR = ClearcrestDeterministicDeploy.predictCCRToken(factory, temporaryAdmin);
        address predictedCGOV =
            ClearcrestDeterministicDeploy.predictCGOVToken(factory, founderTreasury, predictedCCR, temporaryAdmin);

        console.log("CREATE2 factory:", factory);
        console.log("Clearcrest CCR predicted:", predictedCCR);
        console.log("Clearcrest-GOV CGOV predicted:", predictedCGOV);
        console.log("CCR token salt:");
        console.logBytes32(ClearcrestDeterministicDeploy.ccrTokenSalt());
        console.log("CGOV token salt:");
        console.logBytes32(ClearcrestDeterministicDeploy.cgovTokenSalt());

        if (predictedCCR.code.length != 0) revert PredictedAddressOccupied(predictedCCR);
        if (predictedCGOV.code.length != 0) revert PredictedAddressOccupied(predictedCGOV);

        vm.startBroadcast(deployer);

        // 1. Deploy CCR token with deployer as temporary admin so script 02 can wire roles.
        _deployViaFactory(
            factory,
            ClearcrestDeterministicDeploy.ccrTokenSalt(),
            ClearcrestDeterministicDeploy.ccrTokenInitCode(temporaryAdmin),
            predictedCCR
        );
        CCRToken ccrToken = CCRToken(predictedCCR);
        console.log("Clearcrest CCR:", address(ccrToken));

        // 2. Deploy CGOV token (inflationary, minted by the vault on deposit).
        _deployViaFactory(
            factory,
            ClearcrestDeterministicDeploy.cgovTokenSalt(),
            ClearcrestDeterministicDeploy.cgovTokenInitCode(founderTreasury, address(ccrToken), temporaryAdmin),
            predictedCGOV
        );
        CGOVToken cgovToken = CGOVToken(predictedCGOV);
        console.log("Clearcrest-GOV CGOV:", address(cgovToken));

        ccrToken.setGovernanceCompanion(address(cgovToken));
        console.log("Set CGOV companion on CCR token");

        vm.stopBroadcast();

        // Print summary for script 02
        console.log("\n=== Save these for script 02 ===");
        console.log("CCR_TOKEN=", address(ccrToken));
        console.log("CGOV_TOKEN=", address(cgovToken));
        console.log("Temporary token admin:", deployer);
        console.log("Founder treasury:", founderTreasury);
        console.log("Run script 02 next to wire the vault and hand token admin to TOKEN_ADMIN.");
    }

    function _deployViaFactory(address factory, bytes32 salt, bytes memory initCode, address predicted) internal {
        (bool success,) = factory.call(abi.encodePacked(salt, initCode));
        if (!success || predicted.code.length == 0) revert Create2DeployFailed(predicted);
    }
}
