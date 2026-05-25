// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./ClearcrestVault.sol";
import "../libraries/FeeLib.sol";

/// @title ClearcrestAdmin
/// @notice Timelocked governance controller for ClearcrestVault.
/// @dev The admin contract owns the vault. Users and automation call the vault
///      directly; the founder multisig owns this contract and schedules
///      governance/configuration operations here.
contract ClearcrestAdmin is Ownable2Step {
    struct Call {
        address target;
        bytes data;
    }

    struct PendingOperation {
        bytes32 callsHash;
        uint256 executeAfter;
    }

    ClearcrestVault public immutable vault;
    uint256 public immutable delay;

    mapping(bytes32 => PendingOperation) public pendingOperations;

    event OperationProposed(bytes32 indexed operationId, bytes32 callsHash, uint256 executeAfter);
    event OperationExecuted(bytes32 indexed operationId, bytes32 callsHash);
    event OperationCancelled(bytes32 indexed operationId, bytes32 callsHash);
    event BootstrapOperationExecuted(bytes32 callsHash);
    event SleeveEmergencyUnwound(uint8 indexed sleeve, uint256 routesTriggered, uint256 usdcArrivedAtVault);

    error ZeroAddress();
    error NotContract(address account);
    error OperationAlreadyPending(bytes32 operationId);
    error NoPendingOperation(bytes32 operationId);
    error OperationHashMismatch(bytes32 operationId, bytes32 expectedHash, bytes32 actualHash);
    error TimelockNotReady(uint256 executeAfter);
    error OperationCallFailed(bytes32 operationId, address target, bytes data);
    error OnlySelf();
    error BatchTooLarge(uint256 count, uint256 max);
    error BootstrapFinalized();

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    constructor(address vault_, address owner_, uint256 delay_) Ownable(owner_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();
        if (vault_.code.length == 0) revert NotContract(vault_);
        vault = ClearcrestVault(vault_);
        delay = delay_ == 0 ? FeeLib.AUTOMATION_TIMELOCK_DELAY : delay_;
    }

    /// @notice Schedule one or more calls. Pass the same calls to executeOperation.
    function proposeOperation(bytes32 operationId, Call[] calldata calls)
        external
        onlyOwner
        returns (uint256 executeAfter)
    {
        if (pendingOperations[operationId].executeAfter != 0) revert OperationAlreadyPending(operationId);
        bytes32 callsHash = operationHash(calls);
        executeAfter = block.timestamp + delay;
        pendingOperations[operationId] = PendingOperation({callsHash: callsHash, executeAfter: executeAfter});
        emit OperationProposed(operationId, callsHash, executeAfter);
    }

    /// @notice Execute launch-time configuration without delay while vault bootstrap is open.
    ///         Deployment scripts use this before finalizeBootstrap(); after that,
    ///         governance must use proposeOperation/executeOperation.
    function executeBootstrapOperation(Call[] calldata calls) external onlyOwner {
        if (!vault.bootstrapMode()) revert BootstrapFinalized();
        bytes32 callsHash = operationHash(calls);
        _executeCalls(bytes32(0), calls);
        emit BootstrapOperationExecuted(callsHash);
    }

    /// @notice Execute a previously scheduled operation once the timelock has elapsed.
    function executeOperation(bytes32 operationId, Call[] calldata calls) external onlyOwner {
        PendingOperation memory pending = pendingOperations[operationId];
        if (pending.executeAfter == 0) revert NoPendingOperation(operationId);
        if (block.timestamp < pending.executeAfter) revert TimelockNotReady(pending.executeAfter);

        bytes32 callsHash = operationHash(calls);
        if (callsHash != pending.callsHash) revert OperationHashMismatch(operationId, pending.callsHash, callsHash);

        delete pendingOperations[operationId];
        _executeCalls(operationId, calls);

        emit OperationExecuted(operationId, callsHash);
    }

    function cancelOperation(bytes32 operationId) external onlyOwner {
        PendingOperation memory pending = pendingOperations[operationId];
        if (pending.executeAfter == 0) revert NoPendingOperation(operationId);
        delete pendingOperations[operationId];
        emit OperationCancelled(operationId, pending.callsHash);
    }

    function operationHash(Call[] calldata calls) public pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    /// @notice Timelocked batch helper. Schedule by calling this contract through proposeOperation.
    function applyWhitelistedBatch(address[] calldata accounts, bool status) external onlySelf {
        if (accounts.length > 200) revert BatchTooLarge(accounts.length, 200);
        for (uint256 i; i < accounts.length; ++i) {
            vault.setWhitelisted(accounts[i], status);
        }
    }

    /// @notice Timelocked batch helper. Schedule by calling this contract through proposeOperation.
    function applyTrustedSleeveAssetBatch(uint8 sleeve, address[] calldata assets, bool trusted) external onlySelf {
        if (assets.length > 50) revert BatchTooLarge(assets.length, 50);
        for (uint256 i; i < assets.length; ++i) {
            vault.setTrustedSleeveAsset(sleeve, assets[i], trusted);
        }
    }

    /// @notice Timelocked batch helper. Schedule by calling this contract through proposeOperation.
    function applyProtectedTokenBatch(address[] calldata tokens, bool protectedToken) external onlySelf {
        if (tokens.length > 50) revert BatchTooLarge(tokens.length, 50);
        for (uint256 i; i < tokens.length; ++i) {
            vault.setProtectedToken(tokens[i], protectedToken);
        }
    }

    /// @notice Timelocked grouped fee update replacing repeated fee-specific timelock flows.
    function applyFeeConfig(uint256 exitFeeBps, uint256 stressExitFeeBps, uint256 managementFeeBps) external onlySelf {
        vault.setExitFeeBps(exitFeeBps);
        vault.setStressExitFeeBps(stressExitFeeBps);
        vault.setManagementFeeBps(managementFeeBps);
    }

    /// @notice Governance-triggered emergency unwind. Adapters return USDC to the vault;
    ///         this admin credits the arrived USDC to the redemption reserve.
    function emergencyUnwindSleeves(uint8 sleeve) external onlyOwner returns (uint256 usdcArrivedAtVault) {
        uint256 routeCount = vault.sleeveAdapterRouteCount(sleeve);
        if (routeCount == 0) {
            emit SleeveEmergencyUnwound(sleeve, 0, 0);
            return 0;
        }

        address usdc = vault.USDC();
        uint256 balanceBefore = IERC20(usdc).balanceOf(address(vault));
        uint256 triggered;
        for (uint256 i; i < routeCount; ++i) {
            (address adapter,,) = vault.sleeveAdapterRouteAt(sleeve, i);
            if (adapter == address(0)) continue;
            (bool ok,) = adapter.call(abi.encodeWithSignature("emergencyWithdrawAll()"));
            if (!ok) {
                (ok,) = adapter.call(abi.encodeWithSignature("emergencyUnwindAll()"));
            }
            if (ok) triggered += 1;
        }

        uint256 balanceAfter = IERC20(usdc).balanceOf(address(vault));
        usdcArrivedAtVault = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (usdcArrivedAtVault > 0) {
            vault.creditRedemptionReserveFromIdle(usdcArrivedAtVault);
        }

        emit SleeveEmergencyUnwound(sleeve, triggered, usdcArrivedAtVault);
    }

    function _executeCalls(bytes32 operationId, Call[] calldata calls) private {
        for (uint256 i; i < calls.length; ++i) {
            address target = calls[i].target;
            if (target == address(0)) revert ZeroAddress();
            if (target.code.length == 0) revert NotContract(target);
            (bool ok, bytes memory result) = target.call(calls[i].data);
            if (!ok) _bubbleOrRevert(operationId, target, result);
        }
    }

    function _bubbleOrRevert(bytes32 operationId, address target, bytes memory result) private pure {
        if (result.length > 0) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        revert OperationCallFailed(operationId, target, result);
    }
}
