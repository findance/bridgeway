// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "../../interfaces/IClearcrestHubNAV.sol";
import "../../libraries/FeeLib.sol";
import "./ClearcrestVaultModuleBase.sol";

/// @notice Replaceable delegatecall module for ClearcrestVault redemption flows.
contract ClearcrestRedemptionModule is ClearcrestVaultModuleBase {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct RedemptionQuote {
        uint256 grossUsdc;
        uint256 netUsdc;
        uint256 exitFeeUsdc;
        uint256 perfFeeUsdc;
        uint256 currentNav18;
        uint256 effectiveHwm;
    }

    struct SpokeAssetClaimRequest {
        uint64 destinationChainId;
        address destinationRecipient;
        address settlementAsset;
        uint256 assetAmount;
        uint256 minUsdcOut;
        bool preferInKind;
        bytes32 termsHash;
    }

    struct QueuedClaimPayout {
        uint256 baseNetUsdc;
        uint256 baseExitFeeUsdc;
        uint256 basePerfFeeUsdc;
    }

    constructor(address ccrToken_, address cgovToken_, address usdc_, address usdcUsdFeed_)
        ClearcrestVaultModuleBase(ccrToken_, cgovToken_, usdc_, usdcUsdFeed_)
    {}

    function redeem(uint256 ccrAmount, uint256 minUSDC) external onlyDelegated {
        if (ccrAmount == 0) revert ZeroAmount();

        uint256 grossUsdc = _redemptionUSDCAmount((ccrAmount * _navPerCCR()) / 1e18);
        uint256 feeBps = stressModeActive ? stressExitFeeBps : exitFeeBps;
        uint256 exitFeeUsdc = FeeLib.calcExitFee(grossUsdc, feeBps);

        uint256 perfFeeUsdc;
        uint256 currentNav18 = _navPerCCR18();
        uint256 effectiveHwm = _decayedHWM();
        if (currentNav18 > effectiveHwm) {
            uint256 yieldPerCCR18 = currentNav18 - effectiveHwm;
            uint256 yieldUsdc = (ccrAmount * yieldPerCCR18) / 1e30;
            perfFeeUsdc = FeeLib.calcPerfFee(yieldUsdc);
        }
        uint256 quotedNetUsdc = grossUsdc - exitFeeUsdc - perfFeeUsdc;
        bool crystalliseHwm =
            perfFeeUsdc > 0 && currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM;
        if (crystalliseHwm) {
            highWaterMark = currentNav18;
            lastHWMUpdateTime = block.timestamp;
        }

        uint256 userBalance = ccrToken.balanceOf(msg.sender);
        if (userBalance < ccrAmount) revert InsufficientCCR(userBalance, ccrAmount);

        _reducePrincipalForBurn(ccrAmount);

        if (grossUsdc > _totalLocalNAV()) {
            _queueRedemption(
                msg.sender, ccrAmount, grossUsdc, quotedNetUsdc, exitFeeUsdc, perfFeeUsdc, currentNav18, effectiveHwm
            );
            ccrToken.adminBurn(msg.sender, ccrAmount);
            return;
        }

        ccrToken.adminBurn(msg.sender, ccrAmount);

        _fundRedemptionFromLiquidSleeves(grossUsdc);

        uint256 realisedGrossUsdc = _availableUSDC();
        if (realisedGrossUsdc > grossUsdc) realisedGrossUsdc = grossUsdc;
        if (realisedGrossUsdc < grossUsdc) {
            exitFeeUsdc = (exitFeeUsdc * realisedGrossUsdc) / grossUsdc;
            perfFeeUsdc = (perfFeeUsdc * realisedGrossUsdc) / grossUsdc;
        }
        uint256 netUsdc = realisedGrossUsdc - exitFeeUsdc - perfFeeUsdc;
        if (netUsdc < minUSDC) revert SlippageTooHigh(netUsdc, minUSDC);

        if (perfFeeUsdc > 0) {
            _distributePerfFee(perfFeeUsdc);
        }

        if (exitFeeUsdc > 0) _tryTransferFee(holdbackWallet, exitFeeUsdc);

        IERC20(USDC).safeTransfer(msg.sender, netUsdc);
        emit Redeemed(msg.sender, ccrAmount, netUsdc, exitFeeUsdc, perfFeeUsdc);
    }

    function redeemWithSpokeClaim(
        uint256 ccrAmount,
        uint256 minUSDC,
        address ethRecipient,
        uint256 ptAmount,
        uint256 minUsdcOut,
        bool preferInKind,
        bytes32 termsHash
    ) external onlyDelegated {
        _redeemWithSpokeAssetClaim(
            ccrAmount,
            minUSDC,
            SpokeAssetClaimRequest({
                destinationChainId: 1,
                destinationRecipient: ethRecipient,
                settlementAsset: address(0),
                assetAmount: ptAmount,
                minUsdcOut: minUsdcOut,
                preferInKind: preferInKind,
                termsHash: termsHash
            }),
            true
        );
    }

    function redeemWithSpokeAssetClaim(
        uint256 ccrAmount,
        uint256 minUSDC,
        uint64 destinationChainId,
        address destinationRecipient,
        address settlementAsset,
        uint256 assetAmount,
        uint256 minUsdcOut,
        bool preferInKind,
        bytes32 termsHash
    ) external onlyDelegated {
        _redeemWithSpokeAssetClaim(
            ccrAmount,
            minUSDC,
            SpokeAssetClaimRequest({
                destinationChainId: destinationChainId,
                destinationRecipient: destinationRecipient,
                settlementAsset: settlementAsset,
                assetAmount: assetAmount,
                minUsdcOut: minUsdcOut,
                preferInKind: preferInKind,
                termsHash: termsHash
            }),
            false
        );
    }

    function _redeemWithSpokeAssetClaim(
        uint256 ccrAmount,
        uint256 minUSDC,
        SpokeAssetClaimRequest memory request,
        bool allowZeroSettlementAsset
    ) internal {
        if (ccrAmount == 0) revert ZeroAmount();
        if (
            request.destinationChainId == 0 || request.destinationRecipient == address(0) || request.assetAmount == 0
                || request.termsHash == bytes32(0)
                || (!allowZeroSettlementAsset && request.settlementAsset == address(0))
        ) {
            revert InvalidSpokeClaim();
        }

        RedemptionQuote memory quote = _quoteRedemption(ccrAmount);
        if (quote.grossUsdc <= _totalLocalNAV()) revert NoSpokeRedemptionRequired();
        if (quote.netUsdc < minUSDC) revert SlippageTooHigh(quote.netUsdc, minUSDC);

        uint256 userBalance = ccrToken.balanceOf(msg.sender);
        if (userBalance < ccrAmount) revert InsufficientCCR(userBalance, ccrAmount);

        _reducePrincipalForBurn(ccrAmount);
        uint256 redemptionId = _queueRedemption(
            msg.sender,
            ccrAmount,
            quote.grossUsdc,
            quote.netUsdc,
            quote.exitFeeUsdc,
            quote.perfFeeUsdc,
            quote.currentNav18,
            quote.effectiveHwm
        );
        ccrToken.adminBurn(msg.sender, ccrAmount);

        uint256 spokeReserved = _queuedRedemptions[redemptionId].spokeNavReservedUsdc;
        _recordSpokeAssetClaim(redemptionId, spokeReserved, request);
    }

    function _recordSpokeAssetClaim(uint256 redemptionId, uint256 spokeReserved, SpokeAssetClaimRequest memory request)
        internal
    {
        bytes32 claimId = keccak256(
            abi.encodePacked(
                address(this),
                redemptionId,
                msg.sender,
                request.destinationChainId,
                request.destinationRecipient,
                request.settlementAsset,
                spokeReserved,
                request.assetAmount,
                request.minUsdcOut,
                request.preferInKind,
                request.termsHash
            )
        );
        _queuedSpokeRedemptionClaims[redemptionId] = QueuedSpokeRedemptionClaim({
            redemptionId: redemptionId,
            claimant: msg.sender,
            destinationChainId: request.destinationChainId,
            destinationRecipient: request.destinationRecipient,
            settlementAsset: request.settlementAsset,
            spokeValueUsdc: spokeReserved,
            assetAmount: request.assetAmount,
            minUsdcOut: request.minUsdcOut,
            preferInKind: request.preferInKind,
            termsHash: request.termsHash,
            claimId: claimId,
            recorded: true
        });

        emit QueuedSpokeRedemptionClaimRecorded(
            redemptionId,
            claimId,
            msg.sender,
            request.destinationChainId,
            request.destinationRecipient,
            request.settlementAsset,
            spokeReserved,
            request.assetAmount,
            request.minUsdcOut,
            request.preferInKind,
            request.termsHash
        );
    }

    function claimQueuedRedemption(uint256 redemptionId) external onlyDelegated {
        QueuedRedemption storage redemption = _queuedRedemptions[redemptionId];
        if (redemption.claimant == address(0)) revert UnknownQueuedRedemption(redemptionId);
        if (redemption.claimant != msg.sender) revert NotQueuedRedemptionClaimant(redemptionId, msg.sender);
        if (redemption.claimed) revert QueuedRedemptionAlreadyClaimed(redemptionId);
        if (redemption.navLiabilityUsdc > 0) {
            revert QueuedRedemptionNotReady(redemptionId, redemption.navLiabilityUsdc);
        }

        uint256 accountingGrossUsdc = redemption.netUsdc + redemption.exitFeeUsdc + redemption.perfFeeUsdc;
        QueuedClaimPayout memory payout = _queuedClaimPayout(redemptionId, redemption, accountingGrossUsdc);
        uint256 requiredUsdc = payout.baseNetUsdc + payout.baseExitFeeUsdc + payout.basePerfFeeUsdc;
        uint256 availableUsdc = _availableUSDC();
        if (availableUsdc < requiredUsdc) revert InsufficientLocalLiquidity(availableUsdc, requiredUsdc);

        redemption.claimed = true;
        totalQueuedRedemptionGross -= accountingGrossUsdc;
        _consumeIdleRedemptionReserve(requiredUsdc);

        if (payout.basePerfFeeUsdc > 0) _distributePerfFee(payout.basePerfFeeUsdc);
        if (payout.baseExitFeeUsdc > 0) _tryTransferFee(holdbackWallet, payout.baseExitFeeUsdc);

        if (payout.baseNetUsdc > 0) IERC20(USDC).safeTransfer(msg.sender, payout.baseNetUsdc);
        emit QueuedRedemptionClaimed(
            redemptionId, msg.sender, payout.baseNetUsdc, payout.baseExitFeeUsdc, payout.basePerfFeeUsdc
        );
    }

    function _queuedClaimPayout(uint256 redemptionId, QueuedRedemption storage redemption, uint256 accountingGrossUsdc)
        internal
        view
        returns (QueuedClaimPayout memory payout)
    {
        QueuedSpokeRedemptionClaim storage claim = _queuedSpokeRedemptionClaims[redemptionId];
        if (!claim.recorded || claim.spokeValueUsdc == 0 || accountingGrossUsdc == 0) {
            return QueuedClaimPayout({
                baseNetUsdc: redemption.netUsdc,
                baseExitFeeUsdc: redemption.exitFeeUsdc,
                basePerfFeeUsdc: redemption.perfFeeUsdc
            });
        }

        uint256 spokeGrossUsdc = claim.spokeValueUsdc > accountingGrossUsdc ? accountingGrossUsdc : claim.spokeValueUsdc;
        uint256 baseGrossUsdc = accountingGrossUsdc - spokeGrossUsdc;
        payout.baseNetUsdc = Math.mulDiv(redemption.netUsdc, baseGrossUsdc, accountingGrossUsdc);
        payout.baseExitFeeUsdc = Math.mulDiv(redemption.exitFeeUsdc, baseGrossUsdc, accountingGrossUsdc);
        payout.basePerfFeeUsdc = Math.mulDiv(redemption.perfFeeUsdc, baseGrossUsdc, accountingGrossUsdc);
    }

    function acknowledgeQueuedRedemptionLiquidity(uint256 redemptionId, uint256 amount) external onlyDelegated {
        if (msg.sender != owner() && msg.sender != automation) revert OnlyAutomation();
        QueuedRedemption storage redemption = _queuedRedemptions[redemptionId];
        if (redemption.claimant == address(0)) revert UnknownQueuedRedemption(redemptionId);
        if (redemption.claimed) revert QueuedRedemptionAlreadyClaimed(redemptionId);
        if (amount > redemption.navLiabilityUsdc) amount = redemption.navLiabilityUsdc;

        uint256 reservedRelease = amount > redemption.spokeNavReservedUsdc ? redemption.spokeNavReservedUsdc : amount;
        uint256 previousSpokeSnapshot = redemption.spokeNavSnapshotUsdc;

        redemption.navLiabilityUsdc -= amount;
        totalQueuedRedemptionNAVLiability -= amount;

        if (reservedRelease > 0) redemption.spokeNavReservedUsdc -= reservedRelease;

        // @dev Aderyn H-1 false positive. `hubNAV` is a deployment-time-trusted
        //      contract and this is a pure NAV read; the only post-read state write
        //      records the value just read (snapshot used to gate liquidity release).
        //      No fund-moving call follows. Caller is restricted to owner()/automation
        //      above. Accepted per SECURITY_PROCESS.md §B/§E.
        // slither-disable-next-line reentrancy-benign
        // aderyn-ignore-next-line(reentrancy-state-change)
        if (reservedRelease > 0 && hubNAV != address(0) && previousSpokeSnapshot > 0) {
            uint256 currentSpokeNav = IClearcrestHubNAV(hubNAV).totalSpokeNAVUSDC();
            uint256 spokeDrop = previousSpokeSnapshot > currentSpokeNav ? previousSpokeSnapshot - currentSpokeNav : 0;
            if (spokeDrop < reservedRelease) revert QueuedRedemptionNotReady(redemptionId, reservedRelease);
            redemption.spokeNavSnapshotUsdc = currentSpokeNav;
        }

        emit QueuedRedemptionLiquidityAcknowledged(redemptionId, amount, redemption.navLiabilityUsdc);
    }

    function _fundRedemptionFromLiquidSleeves(uint256 grossUsdc) internal returns (uint256 usdcReturned) {
        uint256 nav = _totalLocalNAV();
        if (nav == 0) return 0;
        if (grossUsdc > nav) revert InsufficientLocalLiquidity(nav, grossUsdc);

        uint256 idle = idleRedemptionReserveUsdc;
        uint256 availableUsdc = _availableUSDC();
        if (idle > availableUsdc) idle = availableUsdc;
        if (idle >= grossUsdc) {
            idleRedemptionReserveUsdc = idle - grossUsdc;
            return 0;
        }

        uint256 remaining = grossUsdc - idle;
        if (idle > 0) idleRedemptionReserveUsdc = 0;

        uint256 sleeveB = _sleeveValue(SLEEVE_B);
        uint256 request = sleeveB > remaining ? remaining : sleeveB;
        if (request > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_B, request);
            usdcReturned += returned;
            if (returned > request) idleRedemptionReserveUsdc += returned - request;
            remaining = returned >= remaining ? 0 : remaining - returned;
        }

        uint256 sleeveC = _sleeveValue(SLEEVE_C);
        request = sleeveC > remaining ? remaining : sleeveC;
        if (request > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_C, request);
            usdcReturned += returned;
            if (returned > request) idleRedemptionReserveUsdc += returned - request;
            remaining = returned >= remaining ? 0 : remaining - returned;
        }

        if (remaining > 0) {
            uint256 returned = _withdrawFromSleeve(SLEEVE_A, remaining);
            usdcReturned += returned;
            if (returned > remaining) idleRedemptionReserveUsdc += returned - remaining;
        }
    }

    function _quoteRedemption(uint256 ccrAmount) internal view returns (RedemptionQuote memory quote) {
        quote.grossUsdc = _redemptionUSDCAmount((ccrAmount * _navPerCCR()) / 1e18);
        quote.exitFeeUsdc = FeeLib.calcExitFee(quote.grossUsdc, stressModeActive ? stressExitFeeBps : exitFeeBps);
        quote.currentNav18 = _navPerCCR18();
        quote.effectiveHwm = _decayedHWM();
        if (quote.currentNav18 > quote.effectiveHwm) {
            quote.perfFeeUsdc = FeeLib.calcPerfFee((ccrAmount * (quote.currentNav18 - quote.effectiveHwm)) / 1e30);
        }
        quote.netUsdc = quote.grossUsdc - quote.exitFeeUsdc - quote.perfFeeUsdc;
    }

    function _queueRedemption(
        address claimant,
        uint256 ccrBurned,
        uint256 grossUsdc,
        uint256 netUsdc,
        uint256 exitFeeUsdc,
        uint256 perfFeeUsdc,
        uint256 currentNav18,
        uint256 effectiveHwm
    ) internal returns (uint256 redemptionId) {
        uint256 localNav = _totalLocalNAV();
        uint256 spokeReserved = grossUsdc > localNav ? grossUsdc - localNav : 0;
        address nav = hubNAV;
        uint256 spokeSnapshot = nav == address(0) ? 0 : IClearcrestHubNAV(nav).totalSpokeNAVUSDC();

        redemptionId = ++queuedRedemptionCount;
        _queuedRedemptions[redemptionId] = QueuedRedemption({
            claimant: claimant,
            netUsdc: netUsdc,
            exitFeeUsdc: exitFeeUsdc,
            perfFeeUsdc: perfFeeUsdc,
            navLiabilityUsdc: grossUsdc,
            spokeNavSnapshotUsdc: spokeSnapshot,
            spokeNavReservedUsdc: spokeReserved,
            claimed: false
        });
        totalQueuedRedemptionGross += grossUsdc;
        totalQueuedRedemptionNAVLiability += grossUsdc;

        if (perfFeeUsdc > 0 && currentNav18 > (effectiveHwm * FeeLib.HWM_MIN_CRYSTALLISE_BPS) / FeeLib.BPS_DENOM) {
            highWaterMark = currentNav18;
            lastHWMUpdateTime = block.timestamp;
        }

        emit RedemptionQueued(redemptionId, claimant, ccrBurned, grossUsdc, netUsdc, exitFeeUsdc, perfFeeUsdc);
    }

    function _consumeIdleRedemptionReserve(uint256 amount) internal {
        uint256 reserve = idleRedemptionReserveUsdc;
        if (reserve == 0 || amount == 0) return;
        idleRedemptionReserveUsdc = amount >= reserve ? 0 : reserve - amount;
    }
}
