// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IBGWGovTransferCompanion {
    function syncWithBGWTransfer(address from, address to, uint256 bgwAmount) external;
}

/// @title  BGWToken
/// @notice Bridgeway token (BGW).
///         Price = totalVaultNAV / totalSupply (pure NAV share model).
///         - Minted only by BGWVault when a whitelisted user deposits.
///         - Burned by BGWVault on redemption, by protocol mint-and-burn reserve
///           injections, or by public voluntary burns.
///         - Transfers restricted to whitelisted addresses.
///         - Non-upgradeable; all logic lives in BGWVault.
contract BGWToken is ERC20, AccessControl, Pausable {
    // ── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant MINTER_ROLE          = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE          = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE          = keccak256("PAUSER_ROLE");
    bytes32 public constant BLACKLIST_ADMIN_ROLE = keccak256("BLACKLIST_ADMIN_ROLE");
    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");

    // ── State ────────────────────────────────────────────────────────────────
    /// @notice Addresses allowed to hold and transfer BGW.
    mapping(address => bool) public whitelist;

    /// @notice Addresses permanently blocked from all token operations.
    mapping(address => bool) public blacklisted;

    /// @notice Optional BGW-GOV companion moved/burned alongside BGW transfers.
    address public governanceCompanion;

    /// @dev Scoped guard for protocol-only mint-and-burn cycles that must not
    ///      create or destroy paired BGW-GOV.
    bool private suppressGovernanceSync;

    // ── Events ───────────────────────────────────────────────────────────────
    event Whitelisted(address indexed account, bool status);
    event Blacklisted(address indexed account, bool status);
    event GovernanceCompanionSet(address indexed companion);

    // ── Errors ───────────────────────────────────────────────────────────────
    error NotWhitelisted(address account);
    error AccountBlacklisted(address account);
    error GovernanceCompanionAlreadySet();

    // ── Constructor ──────────────────────────────────────────────────────────
    /// @param admin  Address that receives DEFAULT_ADMIN_ROLE (founder multisig).
    constructor(address admin) ERC20("Bridgeway", "BGW") {
        if (admin == address(0)) revert("BGW: zero admin");
        _grantRole(DEFAULT_ADMIN_ROLE,    admin);
        _grantRole(PAUSER_ROLE,           admin);
        _grantRole(BLACKLIST_ADMIN_ROLE,  admin);
        _grantRole(WHITELIST_ADMIN_ROLE,  admin);
        // MINTER_ROLE is NOT granted here — it is granted to BGWVault after deploy.
    }

    // ── Minting & Burning (vault only) ───────────────────────────────────────

    /// @notice Mint BGW to `to`. Only callable by BGWVault (MINTER_ROLE).
    /// @dev    `to` must be whitelisted; enforced in _beforeTokenTransfer.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        _mint(to, amount);
    }

    /// @notice Mint BGW to `account` and burn it immediately without BGW-GOV sync.
    /// @dev Used by the vault when injecting the buyback reserve into sleeves.
    ///      The temporary BGW never enters circulation and must not mint/burn GOV.
    function protocolMintAndBurn(address account, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
        whenNotPaused
    {
        require(hasRole(BURNER_ROLE, msg.sender), "BGW: missing burner role");
        _mint(account, amount);
        suppressGovernanceSync = true;
        _burn(account, amount);
        suppressGovernanceSync = false;
    }

    /// @notice Burn BGW from `from`. Only callable by BGWVault (BURNER_ROLE).
    ///         Used during redemptions.
    function adminBurn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    /// @notice Public burn — anyone can burn their own BGW.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ── Whitelist Management ─────────────────────────────────────────────────

    /// @notice Add or remove an address from the whitelist.
    function setWhitelisted(address account, bool status)
        external
        onlyRole(WHITELIST_ADMIN_ROLE)
    {
        whitelist[account] = status;
        emit Whitelisted(account, status);
    }

    /// @notice Batch whitelist update for gas efficiency.
    function setWhitelistedBatch(address[] calldata accounts, bool status)
        external
        onlyRole(WHITELIST_ADMIN_ROLE)
    {
        require(accounts.length <= 200, "BGW: batch too large");
        for (uint256 i; i < accounts.length; ++i) {
            whitelist[accounts[i]] = status;
            emit Whitelisted(accounts[i], status);
        }
    }

    // ── Blacklist Management ─────────────────────────────────────────────────

    /// @notice Blacklist or un-blacklist an address (compliance).
    function setBlacklisted(address account, bool status)
        external
        onlyRole(BLACKLIST_ADMIN_ROLE)
    {
        blacklisted[account] = status;
        emit Blacklisted(account, status);
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── BGW-GOV Companion ───────────────────────────────────────────────────

    /// @notice Set the BGW-GOV companion once after both tokens are deployed.
    function setGovernanceCompanion(address companion) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governanceCompanion != address(0)) revert GovernanceCompanionAlreadySet();
        require(companion != address(0), "BGW: zero companion");
        governanceCompanion = companion;
        emit GovernanceCompanionSet(companion);
    }

    // ── Transfer Hook ────────────────────────────────────────────────────────

    /// @dev Enforces whitelist and blacklist on every transfer, mint, and burn.
    ///      - Mints:     `from` == address(0) — only `to` checked.
    ///      - Burns:     `to`   == address(0) — bypass pause so vault redemptions
    ///                   always succeed even when the token is paused (H-03).
    ///      - Transfers: both sides checked; blocked when paused.
    function _update(address from, address to, uint256 amount) internal override {
        bool isBurn = (to == address(0));

        // Mints and transfers are blocked when paused; burns are always allowed
        if (!isBurn) _requireNotPaused();

        // Blacklist check (both sides)
        if (from != address(0) && blacklisted[from]) revert AccountBlacklisted(from);
        if (to   != address(0) && blacklisted[to])   revert AccountBlacklisted(to);

        // Whitelist check — skip address(0) (mint/burn marker)
        // Transfers between two non-zero addresses both need whitelist
        if (from != address(0) && to != address(0)) {
            if (!whitelist[from]) revert NotWhitelisted(from);
            if (!whitelist[to])   revert NotWhitelisted(to);
        }

        // Minting: `to` must be whitelisted
        if (from == address(0) && to != address(0)) {
            if (!whitelist[to]) revert NotWhitelisted(to);
        }

        // Burns don't require `from` to be whitelisted —
        // a user being removed from whitelist can still burn their own tokens.

        super._update(from, to, amount);

        address companion = governanceCompanion;
        if (companion != address(0) && from != address(0) && !suppressGovernanceSync) {
            IBGWGovTransferCompanion(companion).syncWithBGWTransfer(from, to, amount);
        }
    }
}
