// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  FeeLib
/// @notice Pure fee-math helpers for the Bridgeway Protocol.
///         All USD amounts use 6 decimal precision (USDC-denominated).
///         All BGW amounts use 18 decimal precision.
library FeeLib {
    // ── Basis-point constants ────────────────────────────────────────────────
    uint256 internal constant BPS_DENOM        = 10_000;

    uint256 internal constant PERF_FEE_BPS     = 1_500;   // 15 %  performance fee
    uint256 internal constant EXIT_FEE_BPS     = 10;      // 0.10% normal exit fee
    uint256 internal constant STRESS_EXIT_BPS  = 75;      // 0.75% stress exit fee

    // ── Management fee ───────────────────────────────────────────────────────
    uint256 internal constant MANAGEMENT_FEE_BPS      = 50; // 0.50% annual when NAV > HWM
    uint256 internal constant BASE_MGMT_FEE_BPS       = 10; // 0.10% annual floor, always charged

    // ── HWM decay ────────────────────────────────────────────────────────────
    // If NAV stays below the HWM for HWM_DECAY_START, the HWM begins to slide
    // linearly from its crystallised value toward HWM_FLOOR over HWM_DECAY_PERIOD.
    // Fees can resume once NAV > effective (decayed) HWM.
    uint256 internal constant HWM_DECAY_START  = 365 days; // 1 year grace before decay
    uint256 internal constant HWM_DECAY_PERIOD = 730 days; // 2 years to reach HWM_FLOOR
    uint256 internal constant HWM_FLOOR        = 1e18;     // $1.00 — minimum HWM floor

    // ── Performance-fee distribution (must sum to BPS_DENOM) ─────────────────
    uint256 internal constant TEAM_BPS         = 4_500;   // 45 %
    uint256 internal constant HOLDBACK_BPS     = 2_000;   // 20 %
    uint256 internal constant BUYBACK_BPS      = 1_500;   // 15 %
    uint256 internal constant LP_SEED_BPS      = 1_000;   // 10 %
    uint256 internal constant RESERVE_BPS      = 500;     //  5 %
    uint256 internal constant DIRECT_BURN_BPS  = 500;     //  5 %

    // ── Sleeve targets (must sum to BPS_DENOM) ───────────────────────────────
    uint256 internal constant SLEEVE_A_BPS     = 7_000;   // 70 %
    uint256 internal constant SLEEVE_B_BPS     = 2_500;   // 25 %
    uint256 internal constant SLEEVE_C_BPS     = 500;     //  5 %

    // ── Drift triggers ───────────────────────────────────────────────────────
    uint256 internal constant DRIFT_AB_BPS     = 800;     //  8 %  → rebalance A+B
    uint256 internal constant DRIFT_C_BPS      = 200;     //  2 %  → rebalance C

    // ── Redemption thresholds ────────────────────────────────────────────────
    uint256 internal constant LARGE_REDEEM_USD = 10_000e6; // $10,000 in USDC (6 dec)

    // ── Struct returned by splitPerfFee ──────────────────────────────────────
    struct FeeSplit {
        uint256 team;
        uint256 holdback;
        uint256 buyback;
        uint256 lpSeed;
        uint256 reserve;
        uint256 directBurn;
    }

    // ── Functions ────────────────────────────────────────────────────────────

    /// @notice Calculate 15 % performance fee on a given yield amount.
    /// @param  yieldUSD  Net yield in USDC (6 dec)
    /// @return fee       15 % of yieldUSD
    function calcPerfFee(uint256 yieldUSD) internal pure returns (uint256 fee) {
        fee = (yieldUSD * PERF_FEE_BPS) / BPS_DENOM;
    }

    /// @notice Split a total performance fee into its 6 components.
    ///         All values in the same denomination as `totalFee`.
    function splitPerfFee(uint256 totalFee) internal pure returns (FeeSplit memory s) {
        s.team       = (totalFee * TEAM_BPS)        / BPS_DENOM;
        s.holdback   = (totalFee * HOLDBACK_BPS)    / BPS_DENOM;
        s.buyback    = (totalFee * BUYBACK_BPS)     / BPS_DENOM;
        s.lpSeed     = (totalFee * LP_SEED_BPS)     / BPS_DENOM;
        s.reserve    = (totalFee * RESERVE_BPS)     / BPS_DENOM;
        // Direct burn gets the remainder to avoid dust from rounding
        s.directBurn = totalFee
            - s.team
            - s.holdback
            - s.buyback
            - s.lpSeed
            - s.reserve;
    }

    /// @notice Calculate exit fee on gross redemption amount.
    /// @param  grossUSDC  Gross USDC value of the redemption (6 dec)
    /// @param  feeBps     Fee in basis points (use EXIT_FEE_BPS or STRESS_EXIT_BPS)
    /// @return fee        Amount of USDC to withhold
    function calcExitFee(uint256 grossUSDC, uint256 feeBps)
        internal
        pure
        returns (uint256 fee)
    {
        fee = (grossUSDC * feeBps) / BPS_DENOM;
    }

    /// @notice Calculate target allocation for a sleeve given total NAV.
    /// @param  totalNAV  Total vault NAV in USDC (6 dec)
    /// @param  sleeveBps Target weight in basis points
    function targetAlloc(uint256 totalNAV, uint256 sleeveBps)
        internal
        pure
        returns (uint256)
    {
        return (totalNAV * sleeveBps) / BPS_DENOM;
    }

    /// @notice Compute absolute drift between actual and target in basis points.
    /// @param  actual  Current sleeve value (same denom as total)
    /// @param  target  Target sleeve value  (same denom as total)
    /// @param  total   Total NAV            (same denom)
    /// @return driftBps  Absolute drift in basis points (0 if total==0)
    function driftBps(uint256 actual, uint256 target, uint256 total)
        internal
        pure
        returns (uint256)
    {
        if (total == 0) return 0;
        uint256 diff = actual > target ? actual - target : target - actual;
        return (diff * BPS_DENOM) / total;
    }

    /// @notice True when Sleeve A or B has drifted beyond 8 %.
    function needsRebalanceAB(
        uint256 sleeveAVal,
        uint256 sleeveBVal,
        uint256 total
    ) internal pure returns (bool) {
        uint256 targetA = targetAlloc(total, SLEEVE_A_BPS);
        uint256 targetB = targetAlloc(total, SLEEVE_B_BPS);
        return driftBps(sleeveAVal, targetA, total) > DRIFT_AB_BPS
            || driftBps(sleeveBVal, targetB, total) > DRIFT_AB_BPS;
    }

    /// @notice True when Sleeve C has drifted beyond 2 %.
    function needsRebalanceC(uint256 sleeveCVal, uint256 total)
        internal
        pure
        returns (bool)
    {
        uint256 targetC = targetAlloc(total, SLEEVE_C_BPS);
        return driftBps(sleeveCVal, targetC, total) > DRIFT_C_BPS;
    }
}
