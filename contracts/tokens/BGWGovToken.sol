// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal vault interface — avoids a circular import with BGWVault.sol.
interface IWhitelistVault {
    function whitelist(address account) external view returns (bool);
}

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

    /// @notice BGWVault address — set once by initVault(), updatable via timelock.
    address public vault;
    bool    public vaultInitialized;

    // ── Vault-reference timelock (H-05) ──────────────────────────────────────
    uint256 public constant VAULT_REF_DELAY = 48 hours;

    struct PendingVaultRef {
        address value;
        uint256 executeAfter;
    }
    PendingVaultRef public pendingVaultRef;

    // ── Events ───────────────────────────────────────────────────────────────
    event VaultInitialized(address indexed vault);
    event CommunityDistributed(address indexed to, uint256 amount);
    event VaultReferenceProposed(address indexed candidate, uint256 executeAfter);
    event VaultReferenceExecuted(address indexed oldVault, address indexed newVault);
    event VaultReferenceCancelled(address indexed candidate);

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

    /// @dev H-11: restrict GOV transfers to vault-whitelisted addresses.
    ///      Exempt paths that must move tokens outside normal user transfers:
    ///        - Mints/burns (from or to == address(0))
    ///        - initVault seed: address(this) → vault
    ///        - Vault distributing community pool: vault → depositor
    ///        - FounderVesting releasing to founder: founderVestingContract → founder
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        if (
            vaultInitialized       &&
            from != address(0)     &&
            to   != address(0)     &&
            from != address(this)  &&
            from != vault          &&
            from != founderVestingContract
        ) {
            require(
                IWhitelistVault(vault).whitelist(to),
                "GOV: recipient not whitelisted"
            );
        }
        super._update(from, to, amount);
    }

    // ── Vault-reference upgrade (H-05) ───────────────────────────────────────

    /// @notice Propose replacing the vault whitelist reference (48-hour timelock).
    ///         Required when the vault is redeployed so GOV token transfers remain usable.
    function proposeVaultReference(address _vault)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(vaultInitialized, "GOV: vault not initialized yet");
        require(_vault != address(0), "GOV: zero vault");
        uint256 eta = block.timestamp + VAULT_REF_DELAY;
        pendingVaultRef = PendingVaultRef(_vault, eta);
        emit VaultReferenceProposed(_vault, eta);
    }

    /// @notice Execute a pending vault reference update once the 48-hour delay has elapsed.
    ///         Revokes DISTRIBUTOR_ROLE from the old vault and grants it to the new one.
    function executeVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingVaultRef memory p = pendingVaultRef;
        require(p.value != address(0), "GOV: no pending vault ref");
        require(block.timestamp >= p.executeAfter, "GOV: timelock not elapsed");
        delete pendingVaultRef;
        address oldVault = vault;
        vault = p.value;
        _revokeRole(DISTRIBUTOR_ROLE, oldVault);
        _grantRole(DISTRIBUTOR_ROLE, p.value);
        emit VaultReferenceExecuted(oldVault, p.value);
    }

    /// @notice Cancel a pending vault reference update before it executes.
    function cancelVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address candidate = pendingVaultRef.value;
        require(candidate != address(0), "GOV: no pending vault ref");
        delete pendingVaultRef;
        emit VaultReferenceCancelled(candidate);
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
