// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/Create2.sol";

import "../tokens/BGWToken.sol";
import "../tokens/BGWGovToken.sol";

/// @notice Shared CREATE2 constants/helpers for canonical cross-chain deployments.
/// @dev Keep salts stable. Changing a salt intentionally creates a new canonical address.
library BridgewayDeterministicDeploy {
    address internal constant DEFAULT_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant BGW_TOKEN_SALT = keccak256("clearcrest.ccr.token.v1.2026-05-24");
    bytes32 internal constant BGW_GOV_TOKEN_SALT = keccak256("clearcrest.cgov.token.v1.2026-05-24");

    function defaultCreate2Factory() internal pure returns (address) {
        return DEFAULT_CREATE2_FACTORY;
    }

    function bgwTokenSalt() internal pure returns (bytes32) {
        return BGW_TOKEN_SALT;
    }

    function bgwGovTokenSalt() internal pure returns (bytes32) {
        return BGW_GOV_TOKEN_SALT;
    }

    function bgwTokenInitCode(address admin) internal pure returns (bytes memory) {
        return abi.encodePacked(type(BGWToken).creationCode, abi.encode(admin));
    }

    function bgwGovTokenInitCode(address founderTreasury, address bgwToken, address admin)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(type(BGWGovToken).creationCode, abi.encode(founderTreasury, bgwToken, admin));
    }

    function predictBGWToken(address factory, address admin) internal pure returns (address) {
        return Create2.computeAddress(BGW_TOKEN_SALT, keccak256(bgwTokenInitCode(admin)), factory);
    }

    function predictBGWGovToken(address factory, address founderTreasury, address bgwToken, address admin)
        internal
        pure
        returns (address)
    {
        return Create2.computeAddress(
            BGW_GOV_TOKEN_SALT, keccak256(bgwGovTokenInitCode(founderTreasury, bgwToken, admin)), factory
        );
    }
}
