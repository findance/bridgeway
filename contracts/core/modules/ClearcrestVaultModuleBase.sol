// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../../tokens/CCRToken.sol";
import "../../tokens/CGOVToken.sol";
import "../../interfaces/IChainlinkAggregator.sol";
import "../../interfaces/IClearcrestHubNAV.sol";
import "../../interfaces/ISleeveAdapter.sol";
import "../../libraries/ClearcrestSleeveGovernance.sol";
import "../../libraries/FeeLib.sol";

abstract contract ClearcrestVaultModuleBase is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using ClearcrestSleeveGovernance for ClearcrestSleeveGovernance.Layout;

    uint256 public constant USD_PRICE_SCALE = 1e8;

    uint8 public constant SLEEVE_A = 0;
    uint8 public constant SLEEVE_B = 1;
    uint8 public constant SLEEVE_C = 2;

    address public immutable USDC;
    address public immutable USDC_USD_FEED;

    CCRToken public immutable ccrToken;
    CGOVToken public immutable cgovToken;

    address public teamWallet;
    address public holdbackWallet;
    address public reserveFundWallet;
    address public automation;
    uint256 public sleeveAValue;
    uint256 public sleeveBValue;
    uint256 public sleeveCValue;
    ClearcrestSleeveGovernance.Layout private _sleeveGovernance;
    uint16 public sleeveADepositBps = 6_500;
    uint16 public sleeveBDepositBps = 3_500;
    uint16 public sleeveCDepositBps = 0;
    address public hubNAV;
    uint256 public highWaterMark;
    uint256 public lastHWMUpdateTime;
    uint256 public performanceFeeProfitCheckpointUsdc;
    uint256 public managementFeeBps = FeeLib.MANAGEMENT_FEE_BPS;
    uint256 public buybackAccumulator;
    uint256 public lastHarvestTime;
    uint256 public exitFeeBps = FeeLib.EXIT_FEE_BPS;
    uint256 public stressExitFeeBps = FeeLib.STRESS_EXIT_BPS;
    bool public stressModeActive;
    uint256 public cumulativePrincipal;
    uint256 public authorisedLosses;
    mapping(address => bool) public whitelist;
    uint256 public maxDepositUsdc;
    uint256 public minDepositUsdc = 1e6;
    uint256 public minSleeveRouteDepositUsdc = 20e6;
    uint256 public smallDepositStableOnlyThresholdUsdc = 20e6;
    uint16 public redemptionBufferBps = 200;
    uint256 public minRedemptionBufferUsdc = 2e6;
    uint256 public idleRedemptionReserveUsdc;
    uint256 public usdcRedemptionMaxStale;
    bool public bootstrapMode = true;
    mapping(address => uint256) public pendingFees;
    uint256 public totalPendingFees;

    struct QueuedRedemption {
        address claimant;
        uint256 netUsdc;
        uint256 exitFeeUsdc;
        uint256 perfFeeUsdc;
        uint256 navLiabilityUsdc;
        uint256 spokeNavSnapshotUsdc;
        uint256 spokeNavReservedUsdc;
        bool claimed;
    }

    uint256 public queuedRedemptionCount;
    uint256 public totalQueuedRedemptionGross;
    uint256 public totalQueuedRedemptionNAVLiability;
    mapping(uint256 => QueuedRedemption) internal _queuedRedemptions;
    mapping(address => uint256) public lastFeeAccrual;
    address public redemptionModule;
    address public maintenanceModule;

    address private immutable SELF;

    event Redeemed(address indexed user, uint256 ccrBurned, uint256 usdcPaid, uint256 exitFeeUsdc, uint256 perfFeeUsdc);
    event RedemptionQueued(
        uint256 indexed redemptionId,
        address indexed user,
        uint256 ccrBurned,
        uint256 grossUsdc,
        uint256 netUsdc,
        uint256 exitFeeUsdc,
        uint256 perfFeeUsdc
    );
    event QueuedRedemptionClaimed(
        uint256 indexed redemptionId, address indexed user, uint256 netUsdc, uint256 exitFeeUsdc, uint256 perfFeeUsdc
    );
    event QueuedRedemptionLiquidityAcknowledged(
        uint256 indexed redemptionId, uint256 amount, uint256 remainingNAVLiability
    );
    event SleeveRebalanced(uint8 indexed fromSleeve, uint8 indexed toSleeve, uint256 requestedUsdc, uint256 movedUsdc);

    error ZeroAmount();
    error SlippageTooHigh(uint256 received, uint256 minimum);
    error StaleOracle(uint256 updatedAt);
    error OnlyAutomation();
    error InsufficientCCR(uint256 have, uint256 need);
    error UnknownQueuedRedemption(uint256 redemptionId);
    error NotQueuedRedemptionClaimant(uint256 redemptionId, address caller);
    error QueuedRedemptionAlreadyClaimed(uint256 redemptionId);
    error QueuedRedemptionNotReady(uint256 redemptionId, uint256 navLiabilityRemaining);
    error InsufficientLocalLiquidity(uint256 available, uint256 required);
    error InvalidOracleRound(uint80 roundId, uint80 answeredInRound);
    error InvalidOraclePrice(int256 answer);
    error InvalidSleeve(uint8 sleeve);
    error DirectModuleCall();

    modifier onlyDelegated() {
        if (address(this) == SELF) revert DirectModuleCall();
        _;
    }

    constructor(address _ccrToken, address _cgovToken, address _usdc, address _usdcUsdFeed) Ownable(address(1)) {
        ccrToken = CCRToken(_ccrToken);
        cgovToken = CGOVToken(_cgovToken);
        USDC = _usdc;
        USDC_USD_FEED = _usdcUsdFeed;
        SELF = address(this);
    }

    function _totalSpokeNAV() internal view returns (uint256) {
        address nav = hubNAV;
        if (nav == address(0)) return 0;
        return IClearcrestHubNAV(nav).totalSpokeNAVUSDC();
    }

    function _totalNAV() internal view returns (uint256) {
        uint256 grossNav = _totalLocalNAV() + _totalSpokeNAV();
        uint256 queued = totalQueuedRedemptionNAVLiability;
        return grossNav > queued ? grossNav - queued : 0;
    }

    function _totalLocalNAV() internal view returns (uint256) {
        return _sleeveValue(SLEEVE_A) + _sleeveValue(SLEEVE_B) + _sleeveValue(SLEEVE_C) + idleRedemptionReserveUsdc;
    }

    function _navPerCCR() internal view returns (uint256) {
        uint256 supply = ccrToken.totalSupply();
        if (supply == 0) return 1e6;
        return (_totalNAV() * 1e18) / supply;
    }

    function _navPerCCR18() internal view returns (uint256) {
        return _navPerCCR() * 1e12;
    }

    function _availableUSDC() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 reserved = totalPendingFees + buybackAccumulator;
        return usdcBalance > reserved ? usdcBalance - reserved : 0;
    }

    function _availableUSDCForFees() internal view returns (uint256) {
        uint256 usdcBalance = IERC20(USDC).balanceOf(address(this));
        uint256 reserved = totalPendingFees + buybackAccumulator + idleRedemptionReserveUsdc;
        return usdcBalance > reserved ? usdcBalance - reserved : 0;
    }

    function _tryTransferFee(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = USDC.call(abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount));
        bool success = ok && (ret.length == 0 || abi.decode(ret, (bool)));
        if (!success) {
            pendingFees[recipient] += amount;
            totalPendingFees += amount;
            lastFeeAccrual[recipient] = block.timestamp;
        }
    }

    function _tryTransferAvailableFee(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (amount > _availableUSDCForFees()) {
            pendingFees[recipient] += amount;
            totalPendingFees += amount;
            lastFeeAccrual[recipient] = block.timestamp;
            return;
        }
        _tryTransferFee(recipient, amount);
    }

    function _distributePerfFee(uint256 totalFee) internal {
        if (totalFee == 0) return;

        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(totalFee);

        _tryTransferAvailableFee(teamWallet, s.team);
        _tryTransferAvailableFee(holdbackWallet, s.holdback);
        _tryTransferAvailableFee(reserveFundWallet, s.reserve);

        buybackAccumulator += s.buyback;
    }

    function _reducePrincipalForBurn(uint256 ccrAmount) internal {
        uint256 supply = ccrToken.totalSupply();
        if (supply > 0 && cumulativePrincipal > 0) {
            uint256 principalSlice = (ccrAmount * cumulativePrincipal) / supply;
            cumulativePrincipal -= principalSlice;
        }
        if (supply > 0 && performanceFeeProfitCheckpointUsdc > 0) {
            uint256 profitSlice = (ccrAmount * performanceFeeProfitCheckpointUsdc) / supply;
            performanceFeeProfitCheckpointUsdc -= profitSlice;
        }
    }

    function _redemptionUSDCAmount(uint256 usdValue6) internal view returns (uint256) {
        return (usdValue6 * _usdcPriceForRedemption()) / USD_PRICE_SCALE;
    }

    function _usdcPriceForRedemption() internal view returns (uint256 price) {
        price = _usdPrice8(USDC_USD_FEED);
        if (price > USD_PRICE_SCALE) return USD_PRICE_SCALE;
    }

    function _usdPrice8(address feed) internal view returns (uint256 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkAggregator(feed).latestRoundData();
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StaleOracle(updatedAt);
        uint256 maxStale = usdcRedemptionMaxStale;
        if (maxStale != 0 && block.timestamp - updatedAt > maxStale) revert StaleOracle(updatedAt);
        if (answeredInRound < roundId) revert InvalidOracleRound(roundId, answeredInRound);
        if (answer <= 0) revert InvalidOraclePrice(answer);

        uint8 decimals = IChainlinkAggregator(feed).decimals();
        uint256 unsignedAnswer = answer.toUint256();
        if (decimals == 8) return unsignedAnswer;
        if (decimals < 8) return unsignedAnswer * (10 ** (8 - decimals));
        return unsignedAnswer / (10 ** (decimals - 8));
    }

    function _decayedHWM() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastHWMUpdateTime;
        if (elapsed <= FeeLib.HWM_DECAY_START) return highWaterMark;

        uint256 decayElapsed = elapsed - FeeLib.HWM_DECAY_START;
        if (decayElapsed >= FeeLib.HWM_DECAY_PERIOD) return FeeLib.HWM_FLOOR;

        if (highWaterMark <= FeeLib.HWM_FLOOR) return highWaterMark;
        uint256 gap = highWaterMark - FeeLib.HWM_FLOOR;
        uint256 decayed = (gap * decayElapsed) / FeeLib.HWM_DECAY_PERIOD;
        return highWaterMark - decayed;
    }

    function _sleeveValue(uint8 sleeve) internal view returns (uint256) {
        if (_sleeveGovernance.routeCount(sleeve) > 0) {
            return _manualSleeveValue(sleeve) + _sleeveGovernance.routeAssetsUSDC(sleeve);
        }
        return _manualSleeveValue(sleeve);
    }

    function _manualSleeveValue(uint8 sleeve) internal view returns (uint256) {
        if (sleeve == SLEEVE_A) return sleeveAValue;
        if (sleeve == SLEEVE_B) return sleeveBValue;
        if (sleeve == SLEEVE_C) return sleeveCValue;
        revert InvalidSleeve(sleeve);
    }

    function _setSleeveValue(uint8 sleeve, uint256 value) internal {
        if (sleeve == SLEEVE_A) {
            sleeveAValue = value;
        } else if (sleeve == SLEEVE_B) {
            sleeveBValue = value;
        } else if (sleeve == SLEEVE_C) {
            sleeveCValue = value;
        } else {
            revert InvalidSleeve(sleeve);
        }
    }

    function _withdrawFromSleeve(uint8 sleeve, uint256 usdcAmount) internal returns (uint256 usdcReturned) {
        if (usdcAmount == 0) return 0;
        uint256 routeCount = _sleeveGovernance.routeCount(sleeve);
        if (routeCount > 0) {
            uint256 remaining = usdcAmount;
            uint256 manual = _manualSleeveValue(sleeve);
            uint256 fromManual = manual > remaining ? remaining : manual;
            if (fromManual > 0) {
                _setSleeveValue(sleeve, manual - fromManual);
                remaining -= fromManual;
                usdcReturned += fromManual;
            }

            for (uint256 i; i < routeCount && remaining > 0; ++i) {
                (address routeAdapter,,) = _sleeveGovernance.routeAt(sleeve, i);
                uint256 routeAssets = ISleeveAdapter(routeAdapter).totalAssetsUSDC();
                if (routeAssets == 0) continue;

                uint256 request = routeAssets > remaining ? remaining : routeAssets;
                uint256 returned = ISleeveAdapter(routeAdapter).withdraw(request);
                usdcReturned += returned;
                remaining = returned >= remaining ? 0 : remaining - returned;
            }
            return usdcReturned;
        }

        uint256 current = _manualSleeveValue(sleeve);
        usdcReturned = usdcAmount > current ? current : usdcAmount;
        _setSleeveValue(sleeve, current - usdcReturned);
    }

    function _deployToSleevesUnbuffered(uint256 usdcAmount) internal {
        if (usdcAmount == 0) return;
        uint256 stableOnlyThreshold = smallDepositStableOnlyThresholdUsdc;
        if (stableOnlyThreshold != 0 && usdcAmount < stableOnlyThreshold) {
            _deployToSleeve(SLEEVE_B, usdcAmount, true);
            return;
        }

        uint256 postDepositNav = _totalLocalNAV() + usdcAmount;
        uint256 targetA = (postDepositNav * sleeveADepositBps) / FeeLib.BPS_DENOM;
        uint256 targetB = (postDepositNav * sleeveBDepositBps) / FeeLib.BPS_DENOM;
        uint256 targetC = postDepositNav - targetA - targetB;

        uint256 remaining = usdcAmount;
        (uint256 toB, uint256 afterB) = _allocateDepositDeficit(targetB, _sleeveValue(SLEEVE_B), remaining);
        remaining = afterB;

        uint256 allocation;
        (allocation, remaining) = _allocateDepositDeficit(targetA, _sleeveValue(SLEEVE_A), remaining);
        uint256 toA = allocation;

        (allocation, remaining) = _allocateDepositDeficit(targetC, _sleeveValue(SLEEVE_C), remaining);
        uint256 toC = allocation;

        if (remaining > 0) {
            uint256 extraA = (remaining * sleeveADepositBps) / FeeLib.BPS_DENOM;
            uint256 extraB = (remaining * sleeveBDepositBps) / FeeLib.BPS_DENOM;
            uint256 extraC = remaining - extraA - extraB;
            toA += extraA;
            toB += extraB;
            toC += extraC;
        }

        _deployToSleeve(SLEEVE_A, toA, false);
        _deployToSleeve(SLEEVE_B, toB, false);
        _deployToSleeve(SLEEVE_C, toC, false);
    }

    function _allocateDepositDeficit(uint256 target, uint256 current, uint256 remaining)
        internal
        pure
        returns (uint256 allocation, uint256 newRemaining)
    {
        if (remaining == 0 || current >= target) return (0, remaining);
        uint256 deficit = target - current;
        allocation = deficit > remaining ? remaining : deficit;
        newRemaining = remaining - allocation;
    }

    function _deployToSleeve(uint8 sleeve, uint256 usdcAmount, bool forceExternalDeploy) internal {
        if (usdcAmount == 0) return;
        uint256 routeCount = _sleeveGovernance.routeCount(sleeve);
        if (routeCount > 0) {
            uint256 allocated;
            for (uint256 i; i < routeCount; ++i) {
                (address adapter, uint16 depositBps, bool active) = _sleeveGovernance.routeAt(sleeve, i);
                if (!active || depositBps == 0) continue;

                uint256 routeAmount = (usdcAmount * depositBps) / FeeLib.BPS_DENOM;
                if (routeAmount == 0) continue;
                if (!forceExternalDeploy && minSleeveRouteDepositUsdc > 0 && routeAmount < minSleeveRouteDepositUsdc) {
                    continue;
                }

                allocated += routeAmount;
                IERC20(USDC).safeTransfer(adapter, routeAmount);
                ISleeveAdapter(adapter).deploy(routeAmount);
            }

            uint256 remainder = usdcAmount - allocated;
            if (remainder > 0) idleRedemptionReserveUsdc += remainder;
            return;
        }

        _setSleeveValue(sleeve, _manualSleeveValue(sleeve) + usdcAmount);
    }

    function _moveSleeveValue(uint8 fromSleeve, uint8 toSleeve, uint256 usdcAmount)
        internal
        returns (uint256 movedUsdc)
    {
        movedUsdc = _withdrawFromSleeve(fromSleeve, usdcAmount);
        if (movedUsdc == 0) return 0;

        _deployToSleeve(toSleeve, movedUsdc, true);
        emit SleeveRebalanced(fromSleeve, toSleeve, usdcAmount, movedUsdc);
    }
}
