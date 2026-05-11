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
///           • 30,000,000 → BGWVault community pool (transferred via initVault)
///
///         Community pool is distributed to depositors at a FIXED RATE:
///           govToSend = (bgwMinted / TOTAL_SUPPLY) × COMMUNITY_ALLOC
///                     = bgwMinted × 30%
///         This gives every depositor the same governance rate regardless of
///         deposit order — no first-depositor advantage.
///
///         Supports ERC20Votes (on-chain governance snapshots).
contract BGWGovToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY    = 100_000_000e18;
    uint256 public constant FOUNDER_ALLOC   =  70_000_000e18;
    uint256 public constant COMMUNITY_ALLOC =  30_000_000e18;

    // ── Roles ────────────────────────────────────────────────────────────────
    /// @notice DISTRIBUTOR_ROLE is granted to BGWVault inside initVault().
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // ── State ────────────────────────────────────────────────────────────────
    address public immutable founderVestingContract;

    /// @notice BGWVault address — set once by initVault() after vault is deployed.
    address public vault;
    bool    public vaultInitialized;

    // ── Events ───────────────────────────────────────────────────────────────
    event VaultInitialized(address indexed vault);
    event CommunityDistributed(address indexed to, uint256 amount);

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param _founderVesting  FounderVesting contract address (receives 70 M)
    /// @param _admin           Governance admin (founder wallet / multisig)
    constructor(
        address _founderVesting,
        address _admin
    )
        ERC20("Bridgeway Governance", "BGW-GOV")
        ERC20Permit("Bridgeway Governance")
    {
        if (_founderVesting == address(0)) revert("GOV: zero vesting");
        if (_admin == address(0))          revert("GOV: zero admin");

        founderVestingContract = _founderVesting;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);

        // Mint fixed supply — no further minting is possible.
        _mint(_founderVesting, FOUNDER_ALLOC);
        // Community pool held by this contract until initVault() is called.
        _mint(address(this),   COMMUNITY_ALLOC);
    }

    // ── One-time vault wiring ─────────────────────────────────────────────────

    /// @notice Called once after BGWVault is deployed. Transfers the 30 M
    ///         community pool to the vault and grants it DISTRIBUTOR_ROLE.
    ///         Resolves the circular deploy dependency: vault address is not
    ///         needed at BGWGovToken construction time.
    function initVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!vaultInitialized, "GOV: already initialized");
        require(_vault != address(0), "GOV: zero vault");

        vaultInitialized = true;
        vault = _vault;

        _grantRole(DISTRIBUTOR_ROLE, _vault);
        _transfer(address(this), _vault, COMMUNITY_ALLOC);

        emit VaultInitialized(_vault);
    }

    // ── Distribution ─────────────────────────────────────────────────────────

    /// @notice Transfer `amount` BGW-GOV tokens from the vault's community
    ///         pool to `depositor`. Called by BGWVault on every deposit.
    /// @dev    Vault holds the community pool after initVault(). This function
    ///         moves tokens from the vault's own balance directly via _transfer
    ///         (no allowance needed — vault granted this role to authorise it).
    ///         If the pool is exhausted, silently skips.
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
