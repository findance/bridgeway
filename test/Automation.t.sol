// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";
import "../contracts/tokens/BGWGovToken.sol";
import "../contracts/tokens/FounderVesting.sol";
import "../contracts/core/BGWVault.sol";
import "../contracts/core/BridgewayAutomation.sol";
import "../contracts/mocks/MockCamelotRouter.sol";
import "../contracts/libraries/FeeLib.sol";

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

    uint256 constant HARVEST_INTERVAL  = 30 days;
    uint256 constant BUYBACK_INTERVAL  = 30 days;
    uint256 constant BUYBACK_THRESHOLD = 500e6; // 500 USDC (M-07)

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

        // Mock Camelot
        MockCamelotRouter mockCamelot = new MockCamelotRouter(address(bgwToken), 1e12);
        vm.etch(CAMELOT_ADDR, address(mockCamelot).code);

        vault = new BGWVault(
            address(bgwToken), address(govToken),
            team, holdback, lp, reserve, founder,
            USDC_ADDR, CAMELOT_ADDR, address(1)
        );

        // Wire roles
        vm.startPrank(founder);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(),          address(vault));
        bgwToken.grantRole(bgwToken.BURNER_ROLE(),          address(vault)); // H-11
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        bgwToken.setWhitelisted(address(vault), true);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(), CAMELOT_ADDR);
        bgwToken.setWhitelisted(CAMELOT_ADDR, true);
        govToken.initVault(address(vault));
        vault.setWhitelisted(founder, true);
        vault.setWhitelisted(alice,   true);
        vm.stopPrank();

        // Deploy automation and wire to vault via 48-hour timelock (C-01).
        automation = new BridgewayAutomation(address(vault), founder, USDC_ADDR);
        vm.prank(founder);
        vault.proposeAutomation(address(automation));
        vm.warp(block.timestamp + FeeLib.AUTOMATION_TIMELOCK_DELAY + 1);
        vm.prank(founder);
        vault.executeAutomation();

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
        // Strategy: use a large enough deposit and elapsed time so the bounded
        // harvest can fill the accumulator, then warp for the buyback interval.

        // Step 1: deposit 1,000,000e6 so sleeves are large enough that the buyback
        // share survives _reduceSleevesProRata and stays above BUYBACK_THRESHOLD.
        MockUSDCAutomation(USDC_ADDR).mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, 0);
        vm.stopPrank();

        // Step 2: pre-fund Camelot for directBurn (187.5 BGW needed at 1e12 rate).
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 1_000e18);

        // Step 3: after 30 days, 40,000e6 yield is within the 50% APR cap.
        // perfFee 15% = 6,000e6 → buyback gross 900e6.
        vm.warp(block.timestamp + BUYBACK_INTERVAL);
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 40_000e6);
        vm.prank(address(automation));
        vault.recordHarvest(
            40_000e6,
            700_000e6 + (40_000e6 * 70) / 100,
            250_000e6 + (40_000e6 * 25) / 100,
             50_000e6 + (40_000e6 *  5) / 100
        );

        uint256 acc = vault.buybackAccumulator();
        assertGe(acc, BUYBACK_THRESHOLD, "accumulator should be above 500 USDC threshold");

        // Step 4: this test is about buyback priority, so suppress harvest.
        vm.prank(founder);
        automation.setHarvestEnabled(false);

        (bool needed, bytes memory data) = automation.checkUpkeep("");
        assertTrue(needed);
        bytes32 action = abi.decode(data, (bytes32));
        assertEq(action, keccak256("BUYBACK"));
    }

    function test_CheckUpkeepFalseWhenAccumulatorAboveThresholdButIntervalNotElapsed() public {
        // Accumulator fills before the 30-day buyback interval has elapsed.

        // Step 1: deposit all 1,000,000e6 (same sizing as the "true" sibling test).
        MockUSDCAutomation(USDC_ADDR).mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, 0);
        vm.stopPrank();

        // Step 2: pre-fund Camelot for directBurn.
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 1_000e18);

        // Step 3: bounded harvest after 27 days fills the accumulator while
        // keeping lastBuybackTime below the 30-day interval.
        vm.warp(block.timestamp + 27 days);
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 35_000e6);
        vm.prank(address(automation));
        vault.recordHarvest(
            35_000e6,
            700_000e6 + (35_000e6 * 70) / 100,
            250_000e6 + (35_000e6 * 25) / 100,
             50_000e6 + (35_000e6 *  5) / 100
        );

        assertGe(vault.buybackAccumulator(), BUYBACK_THRESHOLD);

        // Only ~29 days elapsed since automation deployment, which is less than
        // the 30-day BUYBACK_INTERVAL → buyback must not fire.
        (bool needed, ) = automation.checkUpkeep("");
        assertFalse(needed, "buyback must not fire before interval elapses");
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
        vm.warp(block.timestamp + 1); // advance time so harvest records a new timestamp
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
        // H-01: manualBuyback now enforces the threshold guard
        vm.prank(founder);
        vm.expectRevert("BA: accumulator too low");
        automation.manualBuyback();
    }

    // ── H-01: manual trigger rate-limiting ───────────────────────────────────

    function test_ManualHarvestRevertsIfTooSoon() public {
        // First harvest — more than MIN_HARVEST_GAP has passed since construction (setUp warp = 48h+1)
        vm.prank(founder);
        automation.manualHarvest();

        // Immediately try again — must revert because MIN_HARVEST_GAP (12h) has not elapsed
        vm.prank(founder);
        vm.expectRevert("BA: harvest too soon");
        automation.manualHarvest();
    }

    function test_ManualHarvestSucceedsAfterGap() public {
        vm.prank(founder);
        automation.manualHarvest();

        vm.warp(block.timestamp + FeeLib.MIN_HARVEST_GAP);

        vm.prank(founder);
        automation.manualHarvest(); // must succeed after the gap
    }

    function test_ManualBuybackRevertsIfIntervalNotElapsed() public {
        // Fill the accumulator above BUYBACK_THRESHOLD using a bounded harvest.
        MockUSDCAutomation(USDC_ADDR).mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, 0);
        vm.stopPrank();

        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 1_000e18); // pre-fund Camelot for directBurn

        vm.warp(block.timestamp + 27 days);
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 35_000e6);
        vm.prank(address(automation));
        vault.recordHarvest(
            35_000e6,
            700_000e6 + (35_000e6 * 70) / 100,
            250_000e6 + (35_000e6 * 25) / 100,
             50_000e6 + (35_000e6 *  5) / 100
        );

        assertGe(vault.buybackAccumulator(), BUYBACK_THRESHOLD);

        // lastBuybackTime is set at construction; interval (30d) has NOT elapsed.
        vm.prank(founder);
        vm.expectRevert("BA: buyback interval not elapsed");
        automation.manualBuyback();
    }
}
