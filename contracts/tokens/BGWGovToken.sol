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
contract BGWGovToken is ERC20, ERC20Permit, ERC20Votes, AccessControl {
    // ── Constants ────────────────────────────────────────────────────────────
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant DEPOSITOR_GOV_BPS = 3_000;
    uint256 public constant FOUNDER_GOV_BPS = 7_000;

    /// @notice Reference minimum primary-sale price for one whole CGOV.
    /// @dev ERC-20 transfers cannot enforce secondary-market consideration.
    uint256 public constant FOUNDER_PRIMARY_SALE_PRICE_USDC = 100_000e6;

    // ── Roles ────────────────────────────────────────────────────────────────
    /// @notice MINTER_ROLE is granted to BGWVault inside initVault().
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice BGWToken moves/burns depositor CGOV alongside CCR transfers/burns.
    bytes32 public constant BGW_COMPANION_ROLE = keccak256("BGW_COMPANION_ROLE");

    // ── State ────────────────────────────────────────────────────────────────
    address public immutable founderTreasury;
    address public immutable bgwToken;

    /// @notice BGWVault address — set once by initVault(), updatable via timelock.
    address public vault;
    bool public vaultInitialized;

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

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param _founderTreasury Founder / treasury wallet receiving 70 % of each mint.
    /// @param _bgwToken        CCR share token that moves depositor CGOV.
    /// @param _admin           Governance admin (founder wallet / multisig)
    constructor(address _founderTreasury, address _bgwToken, address _admin)
        ERC20("Clearcrest-GOV", "CGOV")
        ERC20Permit("Clearcrest-GOV")
    {
        if (_founderTreasury == address(0)) revert("GOV: zero treasury");
        if (_bgwToken == address(0)) revert("GOV: zero ccr");
        if (_admin == address(0)) revert("GOV: zero admin");

        founderTreasury = _founderTreasury;
        bgwToken = _bgwToken;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(BGW_COMPANION_ROLE, _bgwToken);
    }

    // ── One-time vault wiring ─────────────────────────────────────────────────

    /// @notice Called once after BGWVault is deployed. Grants it MINTER_ROLE.
    ///         Resolves the circular deploy dependency: vault address is not
    ///         needed at BGWGovToken construction time.
    function initVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!vaultInitialized, "GOV: already initialized");
        require(_vault != address(0), "GOV: zero vault");

        vaultInitialized = true;
        vault = _vault;

        _grantRole(MINTER_ROLE, _vault);

        emit VaultInitialized(_vault);
    }

    // ── Distribution ─────────────────────────────────────────────────────────

    /// @notice Mint CGOV alongside a CCR deposit.
    /// @param depositor   User receiving the depositor governance share.
    /// @param bgwMinted   CCR minted by the vault for the same deposit.
    /// @return depositorAmount CGOV minted to the depositor.
    /// @return founderAmount   CGOV minted to the founder treasury.
    function mintForDeposit(address depositor, uint256 bgwMinted)
        external
        onlyRole(MINTER_ROLE)
        returns (uint256 depositorAmount, uint256 founderAmount)
    {
        require(depositor != address(0), "GOV: zero depositor");
        require(IWhitelistVault(vault).whitelist(depositor), "GOV: depositor not whitelisted");
        if (bgwMinted == 0) return (0, 0);

        depositorAmount = (bgwMinted * DEPOSITOR_GOV_BPS) / BPS_DENOM;
        founderAmount = bgwMinted - depositorAmount;

        if (depositorAmount > 0) _mint(depositor, depositorAmount);
        if (founderAmount > 0) _mint(founderTreasury, founderAmount);

        emit GovernanceMintedForDeposit(depositor, founderTreasury, bgwMinted, depositorAmount, founderAmount);
    }

    /// @notice Move or burn depositor CGOV when CCR moves or burns.
    /// @dev Founder treasury allocations are not touched by this companion path.
    function syncWithBGWTransfer(address from, address to, uint256 bgwAmount) external onlyRole(BGW_COMPANION_ROLE) {
        if (from == address(0) || bgwAmount == 0) return;

        uint256 govAmount = (bgwAmount * DEPOSITOR_GOV_BPS) / BPS_DENOM;
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
    ///        - BGWToken companion movement
    ///        - Founder treasury primary allocations/sales
    function _update(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        address operator = _msgSender();
        if (vaultInitialized && from != address(0) && to != address(0) && from != address(this) && from != vault) {
            require(operator == bgwToken || from == founderTreasury, "CGOV: transfers follow CCR");
            require(IWhitelistVault(vault).whitelist(to), "GOV: recipient not whitelisted");
        }
        super._update(from, to, amount);
    }

    // ── Vault-reference upgrade (H-05) ───────────────────────────────────────

    /// @notice Propose replacing the vault whitelist reference (48-hour timelock).
    ///         Required when the vault is redeployed so GOV token transfers remain usable.
    function proposeVaultReference(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(vaultInitialized, "GOV: vault not initialized yet");
        require(_vault != address(0), "GOV: zero vault");
        uint256 eta = block.timestamp + VAULT_REF_DELAY;
        pendingVaultRef = PendingVaultRef(_vault, eta);
        emit VaultReferenceProposed(_vault, eta);
    }

    /// @notice Execute a pending vault reference update once the 48-hour delay has elapsed.
    ///         Revokes MINTER_ROLE from the old vault and grants it to the new one.
    function executeVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingVaultRef memory p = pendingVaultRef;
        require(p.value != address(0), "GOV: no pending vault ref");
        require(block.timestamp >= p.executeAfter, "GOV: timelock not elapsed");
        delete pendingVaultRef;
        address oldVault = vault;
        vault = p.value;
        _revokeRole(MINTER_ROLE, oldVault);
        _grantRole(MINTER_ROLE, p.value);
        emit VaultReferenceExecuted(oldVault, p.value);
    }

    /// @notice Cancel a pending vault reference update before it executes.
    function cancelVaultReference() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address candidate = pendingVaultRef.value;
        require(candidate != address(0), "GOV: no pending vault ref");
        delete pendingVaultRef;
        emit VaultReferenceCancelled(candidate);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
