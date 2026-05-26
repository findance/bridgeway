// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../../libraries/FeeLib.sol";
import "./ClearcrestVaultModuleBase.sol";

/// @notice Replaceable delegatecall module for ClearcrestVault maintenance flows.
contract ClearcrestMaintenanceModule is ClearcrestVaultModuleBase {
    constructor(address ccrToken_, address cgovToken_, address usdc_, address usdcUsdFeed_)
        ClearcrestVaultModuleBase(ccrToken_, cgovToken_, usdc_, usdcUsdFeed_)
    {}

    function rebalanceSleevesOneWay(uint256 maxMoveUsdc)
        external
        onlyDelegated
        returns (uint256 movedCToB, uint256 movedBToA)
    {
        if (maxMoveUsdc == 0) return (0, 0);

        uint256 nav = _totalLocalNAV();
        if (nav == 0) return (0, 0);

        uint256 targetA = (nav * sleeveADepositBps) / FeeLib.BPS_DENOM;
        uint256 targetB = (nav * sleeveBDepositBps) / FeeLib.BPS_DENOM;
        uint256 targetC = nav - targetA - targetB;

        uint256 moved;
        uint256 cValue = _sleeveValue(SLEEVE_C);
        if (cValue > targetC) {
            uint256 amount = cValue - targetC;
            uint256 remainingCap = maxMoveUsdc - moved;
            if (amount > remainingCap) amount = remainingCap;

            movedCToB = _moveSleeveValue(SLEEVE_C, SLEEVE_B, amount);
            moved += movedCToB;
        }

        if (moved < maxMoveUsdc) {
            uint256 bValue = _sleeveValue(SLEEVE_B);
            if (bValue > targetB) {
                uint256 amount = bValue - targetB;
                uint256 remainingCap = maxMoveUsdc - moved;
                if (amount > remainingCap) amount = remainingCap;

                movedBToA = _moveSleeveValue(SLEEVE_B, SLEEVE_A, amount);
            }
        }
    }

    function deployIdleReserve(uint256 amount) external onlyDelegated {
        if (idleRedemptionReserveUsdc < amount + 5e6) return;
        unchecked {
            idleRedemptionReserveUsdc -= amount;
        }
        _deployToSleevesUnbuffered(amount);
    }
}
