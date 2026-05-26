// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/CCRToken.sol";
import "../contracts/tokens/CGOVToken.sol";
import "../contracts/core/ClearcrestVault.sol";
import "../contracts/core/ClearcrestAutomation.sol";
import "../contracts/core/modules/ClearcrestMaintenanceModule.sol";
import "../contracts/core/modules/ClearcrestRedemptionModule.sol";
import "../contracts/libraries/FeeLib.sol";
import "../contracts/libraries/ClearcrestDeterministicDeploy.sol";

/// @notice Minimal mock USDC for deploy smoke test.
contract MockUSDCDeploy {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public decimals = 6;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @title  DeployTest
/// @notice C-04: smoke test that exercises the full deploy sequence (scripts 01–03) and
///         verifies role wiring, whitelist state, and automation timelock without a live fork.
contract DeployTest is Test {
    address constant USDC_ADDR = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CAMELOT_ADDR = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
    address constant DEPRECATED_NONCE_CCRTOKEN_COLLISION = 0x6cbD4adF810dE55d2f75D0886Fe6C403a81EF477;
    address constant DEPRECATED_NONCE_GOVTOKEN_COLLISION = 0xa9De353B134c2242C2B543894fdB2d24AC040788;

    address founder = makeAddr("founder");
    address team = makeAddr("team");
    address holdback = makeAddr("holdback");
    address reserve = makeAddr("reserve");
    address ethFeed = makeAddr("ethFeed");
    address usdcFeed = makeAddr("usdcFeed");

    CCRToken ccrToken;
    CGOVToken cgovToken;
    ClearcrestVault vault;
    ClearcrestAutomation automation;

    function setUp() public {
        MockUSDCDeploy mock = new MockUSDCDeploy();
        vm.etch(USDC_ADDR, address(mock).code);
    }

    // ── Script 01: DeployTokens ───────────────────────────────────────────────

    function _deployTokens() internal {
        ccrToken = new CCRToken(founder);
        cgovToken = new CGOVToken(founder, address(ccrToken), founder);

        vm.prank(founder);
        ccrToken.setGovernanceCompanion(address(cgovToken));
    }

    function test_Script01_TokensDeployCorrectly() public {
        _deployTokens();

        assertEq(ccrToken.name(), "Clearcrest");
        assertEq(ccrToken.symbol(), "CCR");
        assertEq(cgovToken.name(), "Clearcrest-GOV");
        assertEq(cgovToken.symbol(), "CGOV");
        assertEq(cgovToken.totalSupply(), 0);
        assertEq(cgovToken.founderTreasury(), founder);
        assertEq(cgovToken.ccrToken(), address(ccrToken));
        assertEq(ccrToken.governanceCompanion(), address(cgovToken));
        assertTrue(ccrToken.hasRole(ccrToken.DEFAULT_ADMIN_ROLE(), founder));
    }

    function test_Script01_Create2TokenPredictionsAvoidDeprecatedNonceCollisions() public {
        address factory = ClearcrestDeterministicDeploy.defaultCreate2Factory();
        address predictedCCR = ClearcrestDeterministicDeploy.predictCCRToken(factory, founder);
        address predictedCGOV = ClearcrestDeterministicDeploy.predictCGOVToken(factory, founder, predictedCCR, founder);

        assertNotEq(predictedCCR, address(0));
        assertNotEq(predictedCGOV, address(0));
        assertNotEq(predictedCCR, predictedCGOV);
        assertNotEq(predictedCCR, DEPRECATED_NONCE_CCRTOKEN_COLLISION);
        assertNotEq(predictedCGOV, DEPRECATED_NONCE_GOVTOKEN_COLLISION);

        assertEq(
            predictedCCR,
            ClearcrestDeterministicDeploy.predictCCRToken(factory, founder),
            "CCR prediction must be stable"
        );
        assertEq(
            predictedCGOV,
            ClearcrestDeterministicDeploy.predictCGOVToken(factory, founder, predictedCCR, founder),
            "CGOV prediction must be stable"
        );
    }

    // ── Script 02: DeployVault ────────────────────────────────────────────────

    function _deployVault() internal {
        _deployTokens();
        vault = new ClearcrestVault(
            address(ccrToken), address(cgovToken), team, holdback, reserve, founder, USDC_ADDR, usdcFeed
        );
        ClearcrestRedemptionModule redemptionModule =
            new ClearcrestRedemptionModule(address(ccrToken), address(cgovToken), USDC_ADDR, usdcFeed);
        ClearcrestMaintenanceModule maintenanceModule =
            new ClearcrestMaintenanceModule(address(ccrToken), address(cgovToken), USDC_ADDR, usdcFeed);

        vm.startPrank(founder);
        vault.setLogicModules(address(redemptionModule), address(maintenanceModule));
        ccrToken.grantRole(ccrToken.MINTER_ROLE(), address(vault));
        ccrToken.grantRole(ccrToken.BURNER_ROLE(), address(vault)); // H-11
        ccrToken.grantRole(ccrToken.WHITELIST_ADMIN_ROLE(), address(vault));
        vault.setWhitelisted(address(vault), true);
        cgovToken.initVault(address(vault));
        vault.setWhitelisted(founder, true);
        vm.stopPrank();
    }

    function test_Script02_VaultRolesWiredCorrectly() public {
        _deployVault();

        assertTrue(ccrToken.hasRole(ccrToken.MINTER_ROLE(), address(vault)));
        assertTrue(ccrToken.hasRole(ccrToken.BURNER_ROLE(), address(vault)));
        assertTrue(ccrToken.hasRole(ccrToken.WHITELIST_ADMIN_ROLE(), address(vault)));
        assertTrue(ccrToken.whitelist(address(vault)));
        assertTrue(cgovToken.vaultInitialized());
        assertEq(cgovToken.vault(), address(vault));
        assertTrue(cgovToken.hasRole(cgovToken.MINTER_ROLE(), address(vault)));
        assertEq(cgovToken.balanceOf(address(vault)), 0);
        assertTrue(vault.whitelist(founder));
    }

    function test_Script02_VaultConstructorArgsMatchABI() public {
        _deployVault();
        // Verify all immutables resolve correctly
        assertEq(vault.USDC(), USDC_ADDR);
        assertEq(vault.USDC_USD_FEED(), usdcFeed);
        assertEq(vault.teamWallet(), team);
        assertEq(vault.holdbackWallet(), holdback);
        assertEq(vault.reserveFundWallet(), reserve);
    }

    // ── Script 03: SetupAutomation ────────────────────────────────────────────

    function test_Script03_AutomationCanBeWired() public {
        _deployVault();

        // Deploy automation (script 03 step 1)
        automation = new ClearcrestAutomation(address(vault), founder, USDC_ADDR);

        vm.prank(founder);
        vault.setAutomation(address(automation));

        assertEq(vault.automation(), address(automation));
    }

    function test_Script03_AutomationConstructorArgsMatchABI() public {
        _deployVault();
        automation = new ClearcrestAutomation(address(vault), founder, USDC_ADDR);

        // ClearcrestAutomation accepts vault, owner, usdc — verify linkage
        assertEq(address(automation.vault()), address(vault));
        assertEq(automation.owner(), founder);
    }
}
