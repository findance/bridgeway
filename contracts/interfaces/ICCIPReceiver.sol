// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal Chainlink CCIP receive interface used by Clearcrest.
///         Kept local so the core reporting path does not depend on a vendored
///         CCIP package version.
interface ICCIPReceiver {
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    struct Any2EVMMessage {
        bytes32 messageId;
        uint64 sourceChainSelector;
        bytes sender;
        bytes data;
        EVMTokenAmount[] destTokenAmounts;
    }

    function ccipReceive(Any2EVMMessage calldata message) external;
}
