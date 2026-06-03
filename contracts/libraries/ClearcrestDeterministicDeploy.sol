// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/Create2.sol";

import "../tokens/CCRToken.sol";
import "../tokens/CGOVToken.sol";

/// @notice Shared CREATE2 constants/helpers for canonical cross-chain deployments.
/// @dev Keep salts stable. Changing a salt intentionally creates a new canonical address.
library ClearcrestDeterministicDeploy {
    address internal constant DEFAULT_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant CCR_TOKEN_SALT = keccak256("clearcrest.ccr.token.v5.2026-06-03");
    bytes32 internal constant CGOV_TOKEN_SALT = keccak256("clearcrest.cgov.token.v5.2026-06-03");

    function defaultCreate2Factory() internal pure returns (address) {
        return DEFAULT_CREATE2_FACTORY;
    }

    function ccrTokenSalt() internal pure returns (bytes32) {
        return CCR_TOKEN_SALT;
    }

    function cgovTokenSalt() internal pure returns (bytes32) {
        return CGOV_TOKEN_SALT;
    }

    function ccrTokenInitCode(address admin) internal pure returns (bytes memory) {
        return bytes.concat(type(CCRToken).creationCode, abi.encode(admin));
    }

    function cgovTokenInitCode(address founderTreasury, address ccrToken, address admin)
        internal
        pure
        returns (bytes memory)
    {
        return bytes.concat(type(CGOVToken).creationCode, abi.encode(founderTreasury, ccrToken, admin));
    }

    function predictCCRToken(address factory, address admin) internal pure returns (address) {
        return Create2.computeAddress(CCR_TOKEN_SALT, keccak256(ccrTokenInitCode(admin)), factory);
    }

    function predictCGOVToken(address factory, address founderTreasury, address ccrToken, address admin)
        internal
        pure
        returns (address)
    {
        return Create2.computeAddress(
            CGOV_TOKEN_SALT, keccak256(cgovTokenInitCode(founderTreasury, ccrToken, admin)), factory
        );
    }
}
