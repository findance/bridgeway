// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../../contracts/libraries/BridgewayDeterministicDeploy.sol";

/// @title  00_PredictDeterministicTokens
/// @notice Preflight deterministic CCR/CGOV token addresses before broadcast.
///
/// Required env vars:
///   TOKEN_TEMP_ADMIN  temporary token admin; must match the deployer used by 01
///   FOUNDER_TREASURY  founder treasury receiving founder CGOV
///
/// Optional env vars:
///   CREATE2_FACTORY   defaults to canonical 0x4e59... factory
///
/// Command:
///   forge script scripts/deploy/00_PredictDeterministicTokens.s.sol --rpc-url $BASE_RPC_URL
contract PredictDeterministicTokens is Script {
    function run() external view {
        address temporaryAdmin = vm.envAddress("TOKEN_TEMP_ADMIN");
        address founderTreasury = vm.envAddress("FOUNDER_TREASURY");
        address factory = vm.envOr("CREATE2_FACTORY", BridgewayDeterministicDeploy.defaultCreate2Factory());

        address predictedBGW = BridgewayDeterministicDeploy.predictBGWToken(factory, temporaryAdmin);
        address predictedGov =
            BridgewayDeterministicDeploy.predictBGWGovToken(factory, founderTreasury, predictedBGW, temporaryAdmin);

        console.log("CREATE2 factory:", factory);
        console.log("CREATE2 factory code length:", factory.code.length);
        console.log("TOKEN_TEMP_ADMIN:", temporaryAdmin);
        console.log("FOUNDER_TREASURY:", founderTreasury);
        console.log("CCR_TOKEN_PREDICTED=", predictedBGW);
        console.log("CCR_TOKEN_CODE_LENGTH=", predictedBGW.code.length);
        console.log("CGOV_TOKEN_PREDICTED=", predictedGov);
        console.log("CGOV_TOKEN_CODE_LENGTH=", predictedGov.code.length);
        console.log("CCR_TOKEN_SALT:");
        console.logBytes32(BridgewayDeterministicDeploy.bgwTokenSalt());
        console.log("CGOV_TOKEN_SALT:");
        console.logBytes32(BridgewayDeterministicDeploy.bgwGovTokenSalt());
    }
}
