// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./BGWVault.sol";
import "../libraries/FeeLib.sol";
import "../interfaces/IAaveV3.sol";
import "../interfaces/ICamelotRouter.sol";
import "../interfaces/IChainlinkAggregator.sol";

// Inlined to avoid Chainlink package path fragility across install methods.
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

/// @title  BridgewayAutomation
/// @notice Chainlink Automation-compatible upkeep contract.
///
///         Triggers:
///           1. Monthly harvest/rebalance — intended to run on the 15th of
///              each month via Chainlink Automation scheduling. Claim all
///              protocol rewards, swap to USDC, call vault.recordHarvest().
///           2. Buyback check    — any call, if accumulator >= threshold,
///              call vault.executeBuyback().
///           3. Rebalance policy — A/B rebalance toward 70/25. Sleeve C is a
///              one-way sleeve during automatic rebalancing: value may leave C,
///              but automatic rebalancing must not fund C from A or B.
///
/// @dev    This contract is intentionally thin — it reads Aave/Morpho balances
///         and instructs the vault. It does NOT hold user funds.
///         All USDC from rewards flows through the vault.
contract BridgewayAutomation is AutomationCompatibleInterface, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC token address — set at deploy for testnet / mainnet flexibility (M-06).
    address public immutable USDC;

    /// @notice Minimum spacing for the monthly 15th harvest/rebalance job.
    ///         Exact calendar scheduling is handled off-chain by Automation.
    uint256 public constant HARVEST_INTERVAL  = 30 days;
    uint256 public constant BUYBACK_THRESHOLD = 500e6;      // 500 USDC minimum (M-07)
    uint256 public constant BUYBACK_INTERVAL  = 30 days;    // min gap between buybacks (M-07)
    uint256 public constant ORACLE_STALE      = 1 hours;

    // Upkeep action identifiers (packed into performData)
    bytes32 internal constant ACTION_HARVEST  = keccak256("HARVEST");
    bytes32 internal constant ACTION_BUYBACK  = keccak256("BUYBACK");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    BGWVault public immutable vault;

    uint256 public lastHarvestTime;
    uint256 public lastBuybackTime;
    bool    public harvestEnabled = true;
    bool    public buybackEnabled = true;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event HarvestTriggered(uint256 timestamp, uint256 yieldUsdc);
    event BuybackTriggered(uint256 usdcSpent);
    event HarvestToggled(bool enabled);
    event BuybackToggled(bool enabled);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    constructor(address _vault, address _admin, address _usdc) Ownable(_admin) {
        require(_vault != address(0), "BA: zero vault");
        require(_usdc  != address(0), "BA: zero usdc");
        vault = BGWVault(_vault);
        USDC  = _usdc;
        // Initialise to deployment time so neither harvest nor buyback fires immediately.
        lastHarvestTime = block.timestamp;
        lastBuybackTime = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Chainlink Automation Interface
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Called off-chain by Chainlink nodes every block to determine
    ///         whether upkeep is needed.
    /// @return upkeepNeeded  True if performUpkeep should be called.
    /// @return performData   Encoded action identifier.
    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // Priority 1: Monthly harvest
        if (harvestEnabled && _harvestDue()) {
            return (true, abi.encode(ACTION_HARVEST));
        }

        // Priority 2: Buyback — both conditions must be met (M-07):
        //   accumulator >= 500 USDC  AND  >= 30 days since last buyback.
        //   "Whichever is last" — neither condition alone is sufficient.
        if (buybackEnabled &&
            vault.buybackAccumulator() >= BUYBACK_THRESHOLD &&
            block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL) {
            return (true, abi.encode(ACTION_BUYBACK));
        }

        return (false, "");
    }

    /// @notice Called on-chain by the Chainlink Automation network when
    ///         checkUpkeep returns true.
    function performUpkeep(bytes calldata performData) external override {
        bytes32 action = abi.decode(performData, (bytes32));

        if (action == ACTION_HARVEST) {
            require(_harvestDue(), "BA: harvest not due");
            _harvest();
        } else if (action == ACTION_BUYBACK) {
            require(
                vault.buybackAccumulator() >= BUYBACK_THRESHOLD,
                "BA: buyback threshold not met"
            );
            require(
                block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL,
                "BA: buyback interval not elapsed"
            );
            _buyback();
        } else {
            revert("BA: unknown action");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin: manual triggers (owner can call outside Chainlink schedule)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Owner-triggered harvest. Enforces the same MIN_HARVEST_GAP as
    ///         the vault to prevent management-fee spam via repeated manual calls (H-01).
    function manualHarvest() external onlyOwner {
        require(
            block.timestamp >= lastHarvestTime + FeeLib.MIN_HARVEST_GAP,
            "BA: harvest too soon"
        );
        _harvest();
    }

    /// @notice Owner-triggered buyback. Enforces the same threshold and interval
    ///         checks as performUpkeep to prevent bypassing the 30-day cooldown (H-01).
    function manualBuyback() external onlyOwner {
        require(vault.buybackAccumulator() >= BUYBACK_THRESHOLD, "BA: accumulator too low");
        require(
            block.timestamp >= lastBuybackTime + BUYBACK_INTERVAL,
            "BA: buyback interval not elapsed"
        );
        _buyback();
    }

    function setHarvestEnabled(bool enabled) external onlyOwner {
        harvestEnabled = enabled;
        emit HarvestToggled(enabled);
    }

    function setBuybackEnabled(bool enabled) external onlyOwner {
        buybackEnabled = enabled;
        emit BuybackToggled(enabled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal — harvest
    // ─────────────────────────────────────────────────────────────────────────

    function _harvestDue() internal view returns (bool) {
        return block.timestamp >= lastHarvestTime + HARVEST_INTERVAL;
    }

    /// @dev
    ///   1. Read current Aave/Morpho/Lido balances from vault positions.
    ///   2. Claim any pending rewards (this must be wired up per protocol).
    ///   3. Swap reward tokens → USDC via Camelot.
    ///   4. Route realised Sleeve C yield into Sleeve B for stablecoin compounding.
    ///   5. Compute sleeve values post-harvest.
    ///   6. Call vault.recordHarvest() with net yield + new sleeve values.
    ///
    ///   NOTE: For MVP testnet phase, step 1-4 are stubs.
    ///         The vault tracks sleeve values via the amounts we report back.
    function _harvest() internal {
        lastHarvestTime = block.timestamp;

        // ── Step 1: Read current NAV from on-chain positions ────────────────
        // In production: query aToken balances, Morpho position shares, etc.
        // For MVP, we report the existing vault sleeve values unchanged,
        // plus any USDC that arrived in the vault from external reward claims.

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));

        // ── Step 2: Claim rewards ────────────────────────────────────────────
        // TODO (per protocol):
        //   - Aave: no explicit claim needed (aToken auto-accrues)
        //   - Morpho Blue: call morpho.accrueInterest(marketParams)
        //   - Pendle: claim yield
        //   - GMX GLP: call rewardRouter.handleRewards(...)
        //   - Symbiotic/Karak: claim restaking rewards

        // ── Step 3: Swap rewards → USDC ──────────────────────────────────────
        // (rewards are in ETH/WETH/GLP/etc — swap on Camelot)
        // TODO: add per-reward-token swap logic

        // ── Step 4: Calculate net yield ──────────────────────────────────────
        uint256 usdcAfter   = IERC20(USDC).balanceOf(address(vault));
        uint256 netYieldUsdc = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;

        // ── Step 6: Report to vault ──────────────────────────────────────────
        // Sleeve values: use existing + realised yield. Policy requires
        // realised Sleeve C yield to be converted to USDC and compounded in
        // Sleeve B, not compounded back into Sleeve C.
        uint256 nav = vault.totalNAV();
        uint256 newA = vault.sleeveAValue();
        uint256 newB = vault.sleeveBValue();
        uint256 newC = vault.sleeveCValue();

        // MVP placeholder: all USDC rewards observed at the vault are treated
        // as stable compounding capital and credited to Sleeve B. Production
        // adapters should report source-specific values so non-C yield can be
        // handled by its approved adapter policy while C yield always flows to B.
        if (netYieldUsdc > 0 && nav > 0) {
            newB += netYieldUsdc;
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
}
