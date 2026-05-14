// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";
import "../contracts/tokens/BGWGovToken.sol";
import "../contracts/core/BGWVault.sol";
import "../contracts/core/BridgewayAutomation.sol";
import "../contracts/libraries/FeeLib.sol";

/// @notice Minimal mock USDC for deploy smoke test.
contract MockUSDCDeploy {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8   public decimals = 6;
    uint256 public totalSupply;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// @title  DeployTest
/// @notice C-04: smoke test that exercises the full deploy sequence (scripts 01–03) and
///         verifies role wiring, whitelist state, and automation timelock without a live fork.
contract DeployTest is Test {
    address constant USDC_ADDR    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CAMELOT_ADDR = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

    address founder  = makeAddr("founder");
    address team     = makeAddr("team");
    address holdback = makeAddr("holdback");
    address lp       = makeAddr("lp");
    address reserve  = makeAddr("reserve");
    address ethFeed  = makeAddr("ethFeed");

    BGWToken          bgwToken;
    BGWGovToken       govToken;
    BGWVault          vault;
    BridgewayAutomation automation;

    function setUp() public {
        MockUSDCDeploy mock = new MockUSDCDeploy();
        vm.etch(USDC_ADDR, address(mock).code);
    }

    // ── Script 01: DeployTokens ───────────────────────────────────────────────

    function _deployTokens() internal {
        bgwToken = new BGWToken(founder);
        govToken = new BGWGovToken(founder, address(bgwToken), founder);

        vm.prank(founder);
        bgwToken.setGovernanceCompanion(address(govToken));
    }

    function test_Script01_TokensDeployCorrectly() public {
        _deployTokens();

        assertEq(govToken.totalSupply(), 0);
        assertEq(govToken.founderTreasury(), founder);
        assertEq(govToken.bgwToken(), address(bgwToken));
        assertEq(bgwToken.governanceCompanion(), address(govToken));
        assertTrue(bgwToken.hasRole(bgwToken.DEFAULT_ADMIN_ROLE(), founder));
    }

    // ── Script 02: DeployVault ────────────────────────────────────────────────

    function _deployVault() internal {
        _deployTokens();
        vault = new BGWVault(
            address(bgwToken),
            address(govToken),
            team,
            holdback,
            lp,
            reserve,
            founder,
            USDC_ADDR,
            CAMELOT_ADDR,
            ethFeed
        );

        vm.startPrank(founder);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(),          address(vault));
        bgwToken.grantRole(bgwToken.BURNER_ROLE(),          address(vault)); // H-11
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        vault.setWhitelisted(address(vault), true);
        govToken.initVault(address(vault));
        vault.setWhitelisted(founder, true);
        vm.stopPrank();
    }

    function test_Script02_VaultRolesWiredCorrectly() public {
        _deployVault();

        assertTrue(bgwToken.hasRole(bgwToken.MINTER_ROLE(),          address(vault)));
        assertTrue(bgwToken.hasRole(bgwToken.BURNER_ROLE(),          address(vault)));
        assertTrue(bgwToken.hasRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault)));
        assertTrue(bgwToken.whitelist(address(vault)));
        assertTrue(govToken.vaultInitialized());
        assertEq(govToken.vault(), address(vault));
        assertTrue(govToken.hasRole(govToken.MINTER_ROLE(), address(vault)));
        assertEq(govToken.balanceOf(address(vault)), 0);
        assertTrue(vault.whitelist(founder));
    }

    function test_Script02_VaultConstructorArgsMatchABI() public {
        _deployVault();
        // Verify all immutables resolve correctly
        assertEq(vault.USDC(),       USDC_ADDR);
        assertEq(vault.ETH_USD_FEED(), ethFeed);
        assertEq(vault.camelotRouter(), CAMELOT_ADDR);
        assertEq(vault.teamWallet(),        team);
        assertEq(vault.holdbackWallet(),    holdback);
        assertEq(vault.lpSeedingWallet(),   lp);
        assertEq(vault.reserveFundWallet(), reserve);
    }

    // ── Script 03: SetupAutomation ────────────────────────────────────────────

    function test_Script03_AutomationTimelockSequence() public {
        _deployVault();

        // Deploy automation (script 03 step 1)
        automation = new BridgewayAutomation(address(vault), founder, USDC_ADDR);

        // Propose with 48-hour timelock (script 03 step 2)
        vm.prank(founder);
        vault.proposeAutomation(address(automation));

        assertEq(vault.pendingAutomation(), address(automation));
        assertEq(vault.automation(), address(0)); // not live yet

        // Executing before timelock must revert
        vm.prank(founder);
        vm.expectRevert("BGWVault: timelock not elapsed");
        vault.executeAutomation();

        // Advance past 48 hours and execute
        vm.warp(block.timestamp + FeeLib.AUTOMATION_TIMELOCK_DELAY + 1);
        vm.prank(founder);
        vault.executeAutomation();

        assertEq(vault.automation(), address(automation));
        assertEq(vault.pendingAutomation(), address(0));
    }

    function test_Script03_AutomationConstructorArgsMatchABI() public {
        _deployVault();
        automation = new BridgewayAutomation(address(vault), founder, USDC_ADDR);

        // BridgewayAutomation accepts vault, owner, usdc — verify linkage
        assertEq(address(automation.vault()), address(vault));
        assertEq(automation.owner(), founder);
    }
}
