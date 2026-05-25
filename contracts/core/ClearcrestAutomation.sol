// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ClearcrestVault.sol";
import "../libraries/FeeLib.sol";
import "../interfaces/IAaveV3.sol";
import "../interfaces/ICamelotRouter.sol";
import "../interfaces/IChainlinkAggregator.sol";

// Inlined to avoid Chainlink package path fragility across install methods.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

/// @title  ClearcrestAutomation
/// @notice Chainlink Automation-compatible upkeep contract.
///
///         Triggers:
///           1. Monthly harvest — intended to run from a Chainlink Automation
///              time-based schedule during a low-activity window. Trigger each
///              sleeve adapter harvest, then call vault.recordHarvest().
///           2. Buyback check    — any call, if accumulator >= threshold,
///              call vault.executeBuyback().
///           3. Rebalance policy — A/B rebalance toward configured vault targets.
///              Sleeve C is a one-way sleeve during automatic rebalancing: value
///              may leave C, but automatic rebalancing must not fund C from A or B.
///
/// @dev    This contract is intentionally thin — it reads Aave/Morpho balances
///         and instructs the vault. It does NOT hold user funds.
///         All USDC from rewards flows through the vault.
contract ClearcrestAutomation is AutomationCompatibleInterface, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC token address — set at deploy for testnet / mainnet flexibility (M-06).
    address public immutable USDC;

    /// @notice Minimum spacing for monthly jobs.
    ///         Exact calendar scheduling is handled off-chain by Automation.
    uint256 public constant HARVEST_INTERVAL = 30 days;
    uint256 public constant REBALANCE_INTERVAL = 30 days;
    uint256 public constant BUYBACK_THRESHOLD = 500e6; // 500 USDC minimum (M-07)
    uint256 public constant BUYBACK_INTERVAL = 30 days; // min gap between buybacks (M-07)
    uint256 public constant ORACLE_STALE = 1 hours;

    // Upkeep action identifiers (packed into performData)
    bytes32 internal constant ACTION_HARVEST = keccak256("HARVEST");
    bytes32 internal constant ACTION_BUYBACK = keccak256("BUYBACK");
    bytes32 internal constant ACTION_REBALANCE = keccak256("REBALANCE");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    ClearcrestVault public immutable vault;

    uint256 public lastHarvestTime;
    uint256 public lastBuybackTime;
    uint256 public lastRebalanceTime;
    uint256 public maxRebalanceMoveUsdc = type(uint256).max;
    bool public harvestEnabled = true;
    bool public buybackEnabled = true;
    bool public rebalanceEnabled = true;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event HarvestTriggered(uint256 timestamp, uint256 yieldUsdc);
    event BuybackTriggered(uint256 usdcSpent);
    event RebalanceTriggered(uint256 movedCToB, uint256 movedBToA);
    event HarvestToggled(bool enabled);
    event BuybackToggled(bool enabled);
    event RebalanceToggled(bool enabled);
    event MaxRebalanceMoveUpdated(uint256 maxMoveUsdc);

    error ZeroVault();
    error ZeroUSDC();
    error HarvestNotDue();
    error RebalanceNotDue();
    error BuybackThresholdNotMet();
    error BuybackIntervalNotElapsed(uint256 executeAfter);
    error UnknownAction(bytes32 action);
    error HarvestTooSoon(uint256 executeAfter);
    error AccumulatorTooLow();

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _vault, address _admin, address _usdc) Ownable(_admin) {
        if (_vault == address(0)) revert ZeroVault();
        if (_usdc == address(0)) revert ZeroUSDC();
        vault = ClearcrestVault(_vault);
        USDC = _usdc;
        // Initialise to deployment time so neither harvest nor buyback fires immediately.
        lastHarvestTime = block.timestamp;
        lastBuybackTime = block.timestamp;
        lastRebalanceTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Chainlink Automation Interface
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called off-chain by Chainlink nodes every block to determine
    ///         whether upkeep is needed.
    /// @return upkeepNeeded  True if performUpkeep should be called.
    /// @return performData   Encoded action identifier.
    function checkUpkeep(
        bytes calldata /* checkData */
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Priority 1: Monthly harvest
        if (harvestEnabled && _harvestDue()) {
            return (true, abi.encode(ACTION_HARVEST));
        }

        // Priority 2: Monthly one-way rebalance. For exact "second Sunday
        // night" timing, register this contract with a time-based Automation
        // schedule and performData = abi.encode(ACTION_REBALANCE).
        if (rebalanceEnabled && _rebalanceDue()) {
            return (true, abi.encode(ACTION_REBALANCE));
        }

        // Priority 3: Buyback — both conditions must be met (M-07):
        //   accumulator >= 500 USDC  AND  >= 30 days since last buyback.
        //   "Whichever is last" — neither condition alone is sufficient.
        if (
            buybackEnabled && vault.buybackAccumulator() >= BUYBACK_THRESHOLD
                && block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL
        ) {
            return (true, abi.encode(ACTION_BUYBACK));
        }

        return (false, "");
    }

    /// @notice Called on-chain by the Chainlink Automation network when
    ///         checkUpkeep returns true.
    function performUpkeep(bytes calldata performData) external override {
        bytes32 action = abi.decode(performData, (bytes32));

        if (action == ACTION_HARVEST) {
            if (!_harvestDue()) revert HarvestNotDue();
            _harvest();
        } else if (action == ACTION_REBALANCE) {
            if (!_rebalanceDue()) revert RebalanceNotDue();
            _rebalance(maxRebalanceMoveUsdc);
        } else if (action == ACTION_BUYBACK) {
            if (vault.buybackAccumulator() < BUYBACK_THRESHOLD) revert BuybackThresholdNotMet();
            uint256 buybackAfter = lastBuybackTime + BUYBACK_INTERVAL;
            if (block.timestamp < buybackAfter) revert BuybackIntervalNotElapsed(buybackAfter);
            _buyback();
        } else {
            revert UnknownAction(action);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin: manual triggers (owner can call outside Chainlink schedule)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Owner-triggered harvest. Enforces the same MIN_HARVEST_GAP as
    ///         the vault to prevent management-fee spam via repeated manual calls (H-01).
    function manualHarvest() external onlyOwner {
        uint256 harvestAfter = lastHarvestTime + FeeLib.MIN_HARVEST_GAP;
        if (block.timestamp < harvestAfter) revert HarvestTooSoon(harvestAfter);
        _harvest();
    }

    /// @notice Owner-triggered buyback. Enforces the same threshold and interval
    ///         checks as performUpkeep to prevent bypassing the 30-day cooldown (H-01).
    function manualBuyback() external onlyOwner {
        if (vault.buybackAccumulator() < BUYBACK_THRESHOLD) revert AccumulatorTooLow();
        uint256 buybackAfter = lastBuybackTime + BUYBACK_INTERVAL;
        if (block.timestamp < buybackAfter) revert BuybackIntervalNotElapsed(buybackAfter);
        _buyback();
    }

    /// @notice Owner-triggered one-way rebalance. This is the same vault-level
    ///         policy used by scheduled Automation: C -> B, then B -> A.
    function manualRebalance(uint256 maxMoveUsdc) external onlyOwner {
        _rebalance(maxMoveUsdc);
    }

    function setHarvestEnabled(bool enabled) external onlyOwner {
        harvestEnabled = enabled;
        emit HarvestToggled(enabled);
    }

    function setBuybackEnabled(bool enabled) external onlyOwner {
        buybackEnabled = enabled;
        emit BuybackToggled(enabled);
    }

    function setRebalanceEnabled(bool enabled) external onlyOwner {
        rebalanceEnabled = enabled;
        emit RebalanceToggled(enabled);
    }

    function setMaxRebalanceMoveUsdc(uint256 maxMoveUsdc) external onlyOwner {
        maxRebalanceMoveUsdc = maxMoveUsdc;
        emit MaxRebalanceMoveUpdated(maxMoveUsdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — harvest
    // ─────────────────────────────────────────────────────────────────────────

    function _harvestDue() internal view returns (bool) {
        return block.timestamp >= lastHarvestTime + HARVEST_INTERVAL;
    }

    function _rebalanceDue() internal view returns (bool) {
        return block.timestamp >= lastRebalanceTime + REBALANCE_INTERVAL;
    }

    /// @dev
    ///   1. Trigger every sleeve adapter's harvest path.
    ///      - Sleeve A compounds back into Sleeve A.
    ///      - Sleeve B compounds back into Sleeve B.
    ///      - Sleeve C realised yield routes into Sleeve B.
    ///   2. Count the realised sleeve yield returned by each harvest call,
    ///      even when it is immediately redeployed into a sleeve.
    ///   3. Calculate any extra USDC that arrived at the vault from external
    ///      reward claims not handled by sleeve adapters.
    ///   4. Call vault.recordHarvest() so performance fees, management fees,
    ///      and sleeve-value sanity checks run on the refreshed adapter NAV.
    function _harvest() internal {
        lastHarvestTime = block.timestamp;

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));

        (uint256 yieldA,) = vault.harvestSleeves(0);
        (uint256 yieldB,) = vault.harvestSleeves(1);
        (uint256 yieldC,) = vault.harvestSleeves(2);

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(vault));
        uint256 externalYieldUsdc = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;
        uint256 netYieldUsdc = yieldA + yieldB + yieldC + externalYieldUsdc;

        uint256 nav = vault.totalNAV();
        uint256 newA = vault.sleeveAValue();
        uint256 newB = vault.sleeveBValue();
        uint256 newC = vault.sleeveCValue();

        // Any non-adapter USDC reward still observed at the vault is treated as
        // stable compounding capital for manual-sleeve accounting. Routed
        // adapters report their own NAV directly in vault.recordHarvest().
        if (externalYieldUsdc > 0 && nav > 0) {
            newB += externalYieldUsdc;
        }

        vault.recordHarvest(netYieldUsdc, newA, newB, newC);

        emit HarvestTriggered(block.timestamp, netYieldUsdc);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — buyback
    // ─────────────────────────────────────────────────────────────────────────

    function _buyback() internal {
        uint256 amount = vault.buybackAccumulator();
        if (amount == 0) return;

        lastBuybackTime = block.timestamp;
        vault.executeBuyback(amount);
        emit BuybackTriggered(amount);
    }

    function _rebalance(uint256 maxMoveUsdc) internal {
        lastRebalanceTime = block.timestamp;
        (uint256 movedCToB, uint256 movedBToA) = vault.rebalanceSleevesOneWay(maxMoveUsdc);
        emit RebalanceTriggered(movedCToB, movedBToA);
    }
}
