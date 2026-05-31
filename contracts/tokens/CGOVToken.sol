// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal vault interface — avoids a circular import with ClearcrestVault.sol.
interface IWhitelistVault {
    function whitelist(address account) external view returns (bool);
}

/// @title  CGOVToken
/// @notice Clearcrest Governance Token (CGOV).
///
///         Inflationary governance token minted alongside CCR vault shares:
///           • For every 1 CCR minted, 1 CGOV is minted.
///           • 30 % of each CGOV mint goes to the depositor.
///           • 70 % of each CGOV mint goes to the founder treasury.
///
///         Founder control is therefore replenished pro-rata with every deposit,
///         while depositor governance exposure scales with CCR ownership.
///
///         Supports ERC20Votes (on-chain governance snapshots).
contract CGOVToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant DEPOSITOR_GOV_BPS = 3_000;
    uint256 public constant FOUNDER_GOV_BPS = 7_000;

    /// @notice Reference minimum primary-sale price for one whole CGOV.
    /// @dev ERC-20 transfers cannot enforce secondary-market consideration.
    uint256 public constant FOUNDER_PRIMARY_SALE_PRICE_USDC = 100_000e6;

    // ── Roles ────────────────────────────────────────────────────────────────
    /// @notice MINTER_ROLE is granted to ClearcrestVault inside initVault().
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice CCRToken moves/burns depositor CGOV alongside CCR transfers/burns.
    bytes32 public constant CCR_COMPANION_ROLE = keccak256("CCR_COMPANION_ROLE");

    // ── State ────────────────────────────────────────────────────────────────
    address public immutable founderTreasury;
    address public immutable ccrToken;

    /// @notice ClearcrestVault address — set once by initVault(), updatable via timelock.
    address public vault;
    bool public vaultInitialized;
    bool public bootstrapMode = true;

    // ── Vault-reference timelock (H-05) ──────────────────────────────────────
    uint256 public constant VAULT_REF_DELAY = 48 hours;

    struct PendingVaultRef {
        address value;
        uint256 executeAfter;
    }
    PendingVaultRef public pendingVaultRef;

    // ── Events ───────────────────────────────────────────────────────────────
    event VaultInitialized(address indexed vault);
    event GovernanceMintedForDeposit(
        address indexed depositor,
        address indexed founderTreasury,
        uint256 totalMinted,
        uint256 depositorAmount,
        uint256 founderAmount
    );
    event VaultReferenceProposed(address indexed candidate, uint256 executeAfter);
    event VaultReferenceExecuted(address indexed oldVault, address indexed newVault);
    event VaultReferenceCancelled(address indexed candidate);
    event BootstrapFinalized();

    // ── Errors ───────────────────────────────────────────────────────────────
    error ZeroTreasury();
    error ZeroCCR();
    error ZeroAdmin();
    error AlreadyInitialized();
    error ZeroVault();
    error ZeroDepositor();
    error DepositorNotWhitelisted(address depositor);
    error TransfersFollowCCR();
    error RecipientNotWhitelisted(address recipient);
    error VaultNotInitialized();
    error NoPendingVaultRef();
    error VaultRefTimelockNotElapsed(uint256 executeAfter);
    error BootstrapAlreadyFinalized();

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param _founderTreasury Founder / treasury wallet receiving 70 % of each mint.
    /// @param _ccrToken        CCR share token that moves depositor CGOV.
    /// @param _admin           Governance admin (founder wallet / multisig)
    constructor(address _founderTreasury, address _ccrToken, address _admin)
        ERC20("Clearcrest-GOV", "CGOV")
        ERC20Permit("Clearcrest-GOV")
    {
        if (_founderTreasury == address(0)) revert ZeroTreasury();
        if (_ccrToken == address(0)) revert ZeroCCR();
        if (_admin == address(0)) revert ZeroAdmin();

        founderTreasury = _founderTreasury;
        ccrToken = _ccrToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(CCR_COMPANION_ROLE, _ccrToken);
    }

    // ── One-time vault wiring ─────────────────────────────────────────────────

    /// @notice Called once after ClearcrestVault is deployed. Grants it MINTER_ROLE.
    ///         Resolves the circular deploy dependency: vault address is not
    ///         needed at CGOVToken construction time.
    function initVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vaultInitialized) revert AlreadyInitialized();
        if (_vault == address(0)) revert ZeroVault();

        vaultInitialized = true;
        vault = _vault;

        _grantRole(MINTER_ROLE, _vault);

        emit VaultInitialized(_vault);
    }

    /// @notice Finalize deployment bootstrap mode. After this, vault reference
    ///         replacements require the 48 hour governance safety delay.
    function finalizeConfiguration() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!bootstrapMode) revert BootstrapAlreadyFinalized();
        bootstrapMode = false;
        emit BootstrapFinalized();
    }

    // ── Distribution ─────────────────────────────────────────────────────────

    /// @notice Mint CGOV alongside a CCR deposit.
    /// @param depositor   User receiving the depositor governance share.
    /// @param ccrMinted   CCR minted by the vault for the same deposit.
    /// @return depositorAmount CGOV minted to the depositor.
    /// @return founderAmount   CGOV minted to the founder treasury.
    function mintForDeposit(address depositor, uint256 ccrMinted)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 depositorAmount, uint256 founderAmount)
    {
        if (depositor == address(0)) revert ZeroDepositor();
        if (!IWhitelistVault(vault).whitelist(depositor)) revert DepositorNotWhitelisted(depositor);
        if (ccrMinted == 0) return (0, 0);

        depositorAmount = (ccrMinted * DEPOSITOR_GOV_BPS) / BPS_DENOM;
        founderAmount = ccrMinted - depositorAmount;

        if (depositorAmount > 0) _mint(depositor, depositorAmount);
        if (founderAmount > 0) _mint(founderTreasury, founderAmount);

        emit GovernanceMintedForDeposit(depositor, founderTreasury, ccrMinted, depositorAmount, founderAmount);
    }

    /// @notice Move or burn depositor CGOV when CCR moves or burns.
    /// @dev Founder treasury allocations are not touched by this companion path.
    function syncWithCCRTransfer(address from, address to, uint256 ccrAmount) external onlyRole(CCR_COMPANION_ROLE) {
        if (from == address(0) || ccrAmount == 0) return;

        uint256 govAmount = (ccrAmount * DEPOSITOR_GOV_BPS) / BPS_DENOM;
        if (govAmount == 0) return;

        if (to == address(0)) {
            _burn(from, govAmount);
        } else {
            _transfer(from, to, govAmount);
        }
    }

    // ── ERC20Votes overrides (required by OZ) ────────────────────────────────

    /// @dev H-11: restrict CGOV transfers to vault-whitelisted addresses and
    ///      prevent depositor CGOV from moving independently of CCR.
    ///      Exempt paths that must move tokens outside normal user transfers:
    ///        - Mints/burns (from or to == address(0))
    ///        - CCRToken companion movement
    ///        - Founder treasury primary allocations/sales
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        address operator = _msgSender();
        if (vaultInitialized && from != address(0) && to != address(0) && from != address(this) && from != vault) {
            if (operator != ccrToken && from != founderTreasury) revert TransfersFollowCCR();
            if (!IWhitelistVault(vault).whitelist(to)) revert RecipientNotWhitelisted(to);
        }
        super._update(from, to, amount);
    }

    // ── Vault-reference upgrade (H-05) ───────────────────────────────────────

    /// @notice Propose replacing the vault whitelist reference (48-hour timelock).
    ///         Required when the vault is redeployed so CGOV token transfers remain usable.
    function proposeVaultReference(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!vaultInitialized) revert VaultNotInitialized();
        if (_vault == address(0)) revert ZeroVault();
        if (bootstrapMode) {
            _executeVaultReference(_vault);
            return;
        }
        uint256 eta = block.timestamp + VAULT_REF_DELAY;
        pendingVaultRef = PendingVaultRef(_vault, eta);
        emit VaultReferenceProposed(_vault, eta);
    }

    /// @notice Execute a pending vault reference update once the 48-hour delay has elapsed.
    ///         Revokes MINTER_ROLE from the old vault and grants it to the new one.
    function executeVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingVaultRef memory p = pendingVaultRef;
        if (p.value == address(0)) revert NoPendingVaultRef();
        if (block.timestamp < p.executeAfter) revert VaultRefTimelockNotElapsed(p.executeAfter);
        delete pendingVaultRef;
        _executeVaultReference(p.value);
    }

    function _executeVaultReference(address newVault) internal {
        address oldVault = vault;
        vault = newVault;
        _revokeRole(MINTER_ROLE, oldVault);
        _grantRole(MINTER_ROLE, newVault);
        emit VaultReferenceExecuted(oldVault, newVault);
    }

    /// @notice Cancel a pending vault reference update before it executes.
    function cancelVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address candidate = pendingVaultRef.value;
        if (candidate == address(0)) revert NoPendingVaultRef();
        delete pendingVaultRef;
        emit VaultReferenceCancelled(candidate);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
