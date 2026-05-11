// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  FounderVesting
/// @notice Vests 70,000,000 BGW-GOV tokens to the founder over 4 years
///         with a 1-year cliff.
///
///         Vesting schedule (cumulative, measured from `vestingStart`):
///           Year 0–1 : 0 %         (cliff — nothing available)
///           Year 1–2 : 25 %  →  17,500,000 BGW-GOV
///           Year 2–3 : 50 %  →  35,000,000 BGW-GOV
///           Year 3–4 : 100 % →  70,000,000 BGW-GOV
///
///         Founder can transfer the entire vesting stake to a designated
///         successor (irreversible, requires the new address to accept).
///
///         The governance token's DISTRIBUTOR_ROLE remains on BGWVault;
///         this contract only holds and releases the founder's allocation.
contract FounderVesting is Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant TOTAL   = 70_000_000e18;
    uint256 public constant Y1_CUM  = 0;               // year-1 cliff
    uint256 public constant Y2_CUM  = 17_500_000e18;   // 25 %
    uint256 public constant Y3_CUM  = 35_000_000e18;   // 50 %
    uint256 public constant Y4_CUM  = 70_000_000e18;   // 100 %

    uint256 public constant YEAR    = 365 days;

    // ── State ────────────────────────────────────────────────────────────────
    IERC20  public immutable govToken;
    address public           founder;
    uint256 public immutable vestingStart;
    uint256 public           totalClaimed;

    // ── Events ───────────────────────────────────────────────────────────────
    event Claimed(address indexed founder, uint256 amount, uint256 totalClaimed);
    event FounderTransferred(address indexed oldFounder, address indexed newFounder);

    // ── Errors ───────────────────────────────────────────────────────────────
    error NothingToClaim();
    error NotFounder();

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param _govToken  BGWGovToken address
    /// @param _founder   Founder wallet (receives tokens on claim)
    constructor(address _govToken, address _founder)
        Ownable(_founder)
    {
        if (_govToken  == address(0)) revert("FV: zero token");
        if (_founder   == address(0)) revert("FV: zero founder");

        govToken     = IERC20(_govToken);
        founder      = _founder;
        vestingStart = block.timestamp;
    }

    // ── View: how much is vested right now ───────────────────────────────────

    /// @notice Returns cumulative tokens vested up to the current timestamp.
    ///         Not yet claimed tokens = vestedAmount() - totalClaimed.
    function vestedAmount() public view returns (uint256) {
        uint256 elapsed = block.timestamp - vestingStart;

        if (elapsed < YEAR) {
            return 0;                   // cliff not reached
        } else if (elapsed < 2 * YEAR) {
            return Y2_CUM;              // year 1-2: 25 %
        } else if (elapsed < 3 * YEAR) {
            return Y3_CUM;              // year 2-3: 50 %
        } else {
            return Y4_CUM;              // year 3+:  100 %
        }
    }

    /// @notice Tokens available to claim right now.
    function claimable() public view returns (uint256) {
        uint256 vested = vestedAmount();
        if (vested <= totalClaimed) return 0;
        return vested - totalClaimed;
    }

    // ── Claim ────────────────────────────────────────────────────────────────

    /// @notice Founder claims all currently vested tokens.
    function claim() external {
        if (msg.sender != founder) revert NotFounder();

        uint256 amount = claimable();
        if (amount == 0) revert NothingToClaim();

        totalClaimed += amount;
        govToken.safeTransfer(founder, amount);

        emit Claimed(founder, amount, totalClaimed);
    }

    // ── Founder Transfer ─────────────────────────────────────────────────────

    /// @notice Transfer the entire vesting position to a new address.
    ///         Uses Ownable2Step — new owner must call acceptOwnership().
    ///         Once accepted, the successor becomes `founder` and can claim.
    /// @dev    Old founder loses all future claims permanently.
    function transferFounder(address newFounder) external {
        if (msg.sender != founder) revert NotFounder();
        if (newFounder == address(0)) revert("FV: zero successor");
        transferOwnership(newFounder); // initiates 2-step transfer
    }

    /// @dev Called by the successor to complete the 2-step ownership transfer.
    ///      Also updates the `founder` field so claim() works correctly.
    function acceptOwnership() public override {
        super.acceptOwnership();
        founder = owner();
        emit FounderTransferred(msg.sender, founder);
    }

    // ── Emergency: recover non-GOV tokens sent accidentally ─────────────────
    /// @notice Recover ERC-20 tokens other than the gov token.
    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(govToken), "FV: cannot recover gov token");
        IERC20(token).safeTransfer(owner(), amount);
    }
}
