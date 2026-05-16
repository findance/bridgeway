// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal helper for encoding Chainlink CCIP EVM extra args.
library BridgewayCCIPClient {
    bytes4 internal constant EVM_EXTRA_ARGS_V1_TAG = 0x97a657c9;

    struct EVMExtraArgsV1 {
        uint256 gasLimit;
    }

    function argsToBytes(EVMExtraArgsV1 memory extraArgs) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }
}
