// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  BGWGovToken
/// @notice Bridgeway Governance Token (BGW-GOV).
///
///         Fixed supply of 100,000,000 tokens:
///           • 70,000,000 → FounderVesting contract (4-yr cliff-vested)
///           • 30,000,000 → BGWVault community pool
///
///         Community pool is distributed proportionally to BGW minters:
///           govToSend = (bgwMinted / newTotalBGWSupply) × communityPool
///
///         This dilutes existing community holders but never touches the
///         founder's 70 % allocation.
///
///         Supports ERC20Votes (on-chain governance snapshots via OpenZeppelin
///         Governor if added later).
contract BGWGovToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY    = 100_000_000e18;
    uint256 public constant FOUNDER_ALLOC   =  70_000_000e18;
    uint256 public constant COMMUNITY_ALLOC =  30_000_000e18;

    // ── Roles ────────────────────────────────────────────────────────────────
    /// @notice DISTRIBUTOR_ROLE is granted to BGWVault so it can distribute
    ///         community tokens on each deposit.
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // ── Immutables ───────────────────────────────────────────────────────────
    address public immutable founderVestingContract;
    address public immutable vault;

    // ── Events ───────────────────────────────────────────────────────────────
    event CommunityDistributed(address indexed to, uint256 amount);

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param _founderVesting  FounderVesting contract address (receives 70 M)
    /// @param _vault           BGWVault address (receives 30 M community pool)
    /// @param _admin           Governance admin (founder wallet / multisig)
    constructor(
        address _founderVesting,
        address _vault,
        address _admin
    )
        ERC20("Bridgeway Governance", "BGW-GOV")
        ERC20Permit("Bridgeway Governance")
    {
        if (_founderVesting == address(0)) revert("GOV: zero vesting");
        if (_vault == address(0))          revert("GOV: zero vault");
        if (_admin == address(0))          revert("GOV: zero admin");

        founderVestingContract = _founderVesting;
        vault = _vault;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(DISTRIBUTOR_ROLE,   _vault); // vault distributes on deposit

        // Mint fixed supply — no further minting is possible
        _mint(_founderVesting, FOUNDER_ALLOC);
        _mint(_vault,          COMMUNITY_ALLOC);
    }

    // ── Distribution ─────────────────────────────────────────────────────────

    /// @notice Transfer `amount` community BGW-GOV tokens from the vault's
    ///         pool to `depositor`. Called by BGWVault on every deposit.
    /// @dev    Vault holds the community pool. It simply transfers from itself.
    ///         If the pool is exhausted, silently skips (no revert).
    function distributeToDepositor(address depositor, uint256 amount)
        external
        onlyRole(DISTRIBUTOR_ROLE)
    {
        uint256 available = balanceOf(vault);
        if (available == 0 || amount == 0) return;

        uint256 toSend = amount > available ? available : amount;
        _transfer(vault, depositor, toSend);
        emit CommunityDistributed(depositor, toSend);
    }

    // ── ERC20Votes overrides (required by OZ) ────────────────────────────────

    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
