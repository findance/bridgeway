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
///           1. Monthly harvest  — every 30 days, claim all protocol rewards,
///              swap to USDC, call vault.recordHarvest().
///           2. Buyback check    — any call, if accumulator >= threshold,
///              call vault.executeBuyback().
///           3. Rebalance check  — after harvest, if sleeve drift > threshold,
///              call vault.updateSleeveValues() with corrected values.
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

    uint256 public constant HARVEST_INTERVAL  = 30 days;
    uint256 public constant BUYBACK_THRESHOLD = 50e6;       // 50 USDC minimum
    uint256 public constant ORACLE_STALE      = 1 hours;

    // Upkeep action identifiers (packed into performData)
    bytes32 internal constant ACTION_HARVEST  = keccak256("HARVEST");
    bytes32 internal constant ACTION_BUYBACK  = keccak256("BUYBACK");

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    BGWVault public immutable vault;

    uint256 public lastHarvestTime;
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
        // Initialise to deployment time so the first harvest isn't immediately due (H-10)
        lastHarvestTime = block.timestamp;
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

        // Priority 2: Buyback if accumulator is large enough
        if (buybackEnabled && vault.buybackAccumulator() >= BUYBACK_THRESHOLD) {
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
            _buyback();
        } else {
            revert("BA: unknown action");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin: manual triggers (owner can call outside Chainlink schedule)
    // ─────────────────────────────────────────────────────────────────────────

    function manualHarvest() external onlyOwner {
        _harvest();
    }

    function manualBuyback() external onlyOwner {
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
    ///   4. Compute sleeve values post-harvest.
    ///   5. Call vault.recordHarvest() with net yield + new sleeve values.
    ///
    ///   NOTE: For MVP testnet phase, step 1-3 are stubs.
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
        //   - Lido wstETH: rebases automatically
        //   - Pendle: claim yield
        //   - GMX GLP: call rewardRouter.handleRewards(...)
        //   - Symbiotic/Karak: claim restaking rewards

        // ── Step 3: Swap rewards → USDC ──────────────────────────────────────
        // (rewards are in ETH/WETH/GLP/etc — swap on Camelot)
        // TODO: add per-reward-token swap logic

        // ── Step 4: Calculate net yield ──────────────────────────────────────
        uint256 usdcAfter   = IERC20(USDC).balanceOf(address(vault));
        uint256 netYieldUsdc = usdcAfter > usdcBefore ? usdcAfter - usdcBefore : 0;

        // ── Step 5: Report to vault ──────────────────────────────────────────
        // Sleeve values: use existing + any accrued yield proportionally
        uint256 nav = vault.totalNAV();
        uint256 newA = vault.sleeveAValue();
        uint256 newB = vault.sleeveBValue();
        uint256 newC = vault.sleeveCValue();

        // Distribute net yield to sleeves proportionally
        if (netYieldUsdc > 0 && nav > 0) {
            newA += (netYieldUsdc * FeeLib.SLEEVE_A_BPS) / FeeLib.BPS_DENOM;
            newB += (netYieldUsdc * FeeLib.SLEEVE_B_BPS) / FeeLib.BPS_DENOM;
            newC += (netYieldUsdc * FeeLib.SLEEVE_C_BPS) / FeeLib.BPS_DENOM;
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

        vault.executeBuyback(amount);
        emit BuybackTriggered(amount);
    }
}
