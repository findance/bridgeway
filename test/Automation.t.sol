// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";
import "../contracts/tokens/BGWGovToken.sol";
import "../contracts/tokens/FounderVesting.sol";
import "../contracts/core/BGWVault.sol";
import "../contracts/core/BridgewayAutomation.sol";
import "../contracts/mocks/MockCamelotRouter.sol";

/// @notice Minimal mock USDC (duplicated to avoid test-file coupling).
contract MockUSDCAutomation {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8   public decimals = 6;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract AutomationTest is Test {
    BGWToken          bgwToken;
    BGWGovToken       govToken;
    FounderVesting    vesting;
    BGWVault          vault;
    BridgewayAutomation automation;

    address founder   = makeAddr("founder");
    address alice     = makeAddr("alice");
    address team      = makeAddr("team");
    address holdback  = makeAddr("holdback");
    address lp        = makeAddr("lp");
    address reserve   = makeAddr("reserve");
    address stranger  = makeAddr("stranger");

    address constant USDC_ADDR    = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CAMELOT_ADDR = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

    uint256 constant HARVEST_INTERVAL = 30 days;
    uint256 constant BUYBACK_THRESHOLD = 50e6; // 50 USDC

    function setUp() public {
        // Mock USDC
        MockUSDCAutomation mockUsdc = new MockUSDCAutomation();
        vm.etch(USDC_ADDR, address(mockUsdc).code);

        // Deploy tokens (nonce prediction for vesting)
        address predictedVesting =
            computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        govToken = new BGWGovToken(predictedVesting, founder);
        vesting  = new FounderVesting(address(govToken), founder);
        require(address(vesting) == predictedVesting, "nonce drift");

        bgwToken = new BGWToken(founder);

        vault = new BGWVault(
            address(bgwToken), address(govToken),
            team, holdback, lp, reserve, founder
        );

        // Mock Camelot
        MockCamelotRouter mockCamelot = new MockCamelotRouter(address(bgwToken), 1e12);
        vm.etch(CAMELOT_ADDR, address(mockCamelot).code);

        // Wire roles
        vm.startPrank(founder);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(),          address(vault));
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        bgwToken.setWhitelisted(address(vault), true);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(), CAMELOT_ADDR);
        bgwToken.setWhitelisted(CAMELOT_ADDR, true);
        govToken.initVault(address(vault));
        vault.setWhitelisted(founder, true);
        vault.setWhitelisted(alice,   true);
        vm.stopPrank();

        // Deploy automation and wire to vault
        automation = new BridgewayAutomation(address(vault), founder);
        vm.prank(founder);
        vault.setAutomation(address(automation));

        // Seed alice with USDC
        MockUSDCAutomation(USDC_ADDR).mint(alice, 10_000e6);
    }

    // ── checkUpkeep — harvest ─────────────────────────────────────────────────

    function test_CheckUpkeepFalseAfterRecentHarvest() public {
        // Do a harvest to set lastHarvestTime = now
        vm.prank(founder);
        automation.manualHarvest();

        (bool needed, ) = automation.checkUpkeep("");
        assertFalse(needed);
    }

    function test_CheckUpkeepTrueAfterHarvestInterval() public {
        vm.prank(founder);
        automation.manualHarvest();

        vm.warp(block.timestamp + HARVEST_INTERVAL);

        (bool needed, bytes memory data) = automation.checkUpkeep("");
        assertTrue(needed);
        bytes32 action = abi.decode(data, (bytes32));
        assertEq(action, keccak256("HARVEST"));
    }

    // ── checkUpkeep — buyback ─────────────────────────────────────────────────

    function test_CheckUpkeepFalseWhenAccumulatorBelowThreshold() public {
        // Harvest first so harvest isn't immediately due
        vm.prank(founder);
        automation.manualHarvest();

        // Accumulator starts at 0
        (bool needed, ) = automation.checkUpkeep("");
        assertFalse(needed);
    }

    function test_CheckUpkeepTrueWhenAccumulatorAboveThreshold() public {
        // Make harvest not due
        vm.prank(founder);
        automation.manualHarvest();

        // Deposit so vault has NAV, then record harvest with yield to fill accumulator.
        // Give vault extra USDC to cover fee distribution.
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 1_000e6);

        // Manually set buyback accumulator by recording a harvest with perf fee.
        // First give alice a deposit so BGW supply > 0.
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Pre-fund mock Camelot with Alice's BGW for the directBurn path in recordHarvest.
        // directBurn = 5% of perfFee(2500e6) = 5% of 375e6 = 18.75e6 USDC → 18.75e18 BGW.
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 25e18);

        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 100e6);

        // recordHarvest triggers perf fee → buyback accumulator gets 15% × 15% = 2.25 USDC
        // Need accumulator >= 50 USDC threshold. Trigger a large enough yield.
        // 15% perf fee of X; 15% of that to accumulator → need X × 0.15 × 0.15 ≥ 50
        // → X ≥ 2222 USDC yield. Let's use 2500e6 yield.
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 2_500e6);
        vm.prank(address(automation));
        vault.recordHarvest(2_500e6, 770e6, 275e6, 55e6);

        uint256 acc = vault.buybackAccumulator();
        assertGe(acc, BUYBACK_THRESHOLD, "accumulator should be above threshold");

        (bool needed, bytes memory data) = automation.checkUpkeep("");
        assertTrue(needed);
        bytes32 action = abi.decode(data, (bytes32));
        assertEq(action, keccak256("BUYBACK"));
    }

    // ── performUpkeep — harvest ───────────────────────────────────────────────

    function test_PerformUpkeepHarvestUpdatesLastHarvestTime() public {
        // Harvest due (lastHarvestTime = 0, block.timestamp > 30 days in fork default)
        // or after interval passes
        vm.warp(block.timestamp + HARVEST_INTERVAL + 1);

        uint256 timeBefore = automation.lastHarvestTime();

        bytes memory data = abi.encode(keccak256("HARVEST"));
        automation.performUpkeep(data);

        assertGt(automation.lastHarvestTime(), timeBefore);
    }

    function test_PerformUpkeepHarvestRevertsIfNotDue() public {
        // Execute harvest to reset timer
        vm.prank(founder);
        automation.manualHarvest();

        // Immediately try again — should revert
        bytes memory data = abi.encode(keccak256("HARVEST"));
        vm.expectRevert("BA: harvest not due");
        automation.performUpkeep(data);
    }

    function test_PerformUpkeepRevertsOnUnknownAction() public {
        bytes memory data = abi.encode(keccak256("UNKNOWN"));
        vm.expectRevert("BA: unknown action");
        automation.performUpkeep(data);
    }

    // ── Toggle controls ───────────────────────────────────────────────────────

    function test_DisablingHarvestSuppressesCheckUpkeep() public {
        vm.prank(founder);
        automation.setHarvestEnabled(false);

        vm.warp(block.timestamp + HARVEST_INTERVAL);

        (bool needed, ) = automation.checkUpkeep("");
        assertFalse(needed); // harvest suppressed
    }

    function test_OnlyOwnerCanToggle() public {
        vm.prank(stranger);
        vm.expectRevert();
        automation.setHarvestEnabled(false);
    }

    // ── Manual triggers ───────────────────────────────────────────────────────

    function test_ManualHarvestUpdatesTimestamp() public {
        uint256 before = automation.lastHarvestTime();
        vm.prank(founder);
        automation.manualHarvest();
        assertGt(automation.lastHarvestTime(), before);
    }

    function test_OnlyOwnerCanManualHarvest() public {
        vm.prank(stranger);
        vm.expectRevert();
        automation.manualHarvest();
    }

    function test_ManualBuybackRevertsWhenAccumulatorEmpty() public {
        // Accumulator is 0 → _buyback returns early, executeBuyback is a no-op
        // (no revert, just does nothing)
        vm.prank(founder);
        automation.manualBuyback(); // should not revert
    }
}
