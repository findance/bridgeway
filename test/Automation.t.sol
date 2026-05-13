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
        // Strategy: use the first recordHarvest (lastHarvestTime==0 → no rate bounds)
        // to fill the accumulator, then warp 30 days for the buyback interval.

        // Step 1: deposit all 10_000e6 so sleeves are large enough that the buyback
        // share survives _reduceSleevesProRata and stays above BUYBACK_THRESHOLD.
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, 0);
        vm.stopPrank();
        // sleeves: A=7_000e6, B=2_500e6, C=500e6; alice has 10_000e18 BGW.

        // Step 2: pre-fund Camelot for directBurn (187.5 BGW needed at 1e12 rate).
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 200e18);

        // Step 3: mint yield USDC to vault and call first recordHarvest.
        // yield = 25_000e6 → perfFee 15% = 3_750e6 → buyback gross 562.5e6.
        // After _reduceSleevesProRata the net accumulator ≈ 503e6 > 500e6.
        // First harvest: lastHarvestTime==0, all rate bounds skipped.
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 25_000e6);
        vm.prank(address(automation));
        vault.recordHarvest(
            25_000e6,
            7_000e6 + (25_000e6 * 70) / 100,  // 7_000 + 17_500 = 24_500e6
            2_500e6 + (25_000e6 * 25) / 100,  // 2_500 +  6_250 =  8_750e6
              500e6 + (25_000e6 *  5) / 100   //   500 +  1_250 =  1_750e6
        );

        uint256 acc = vault.buybackAccumulator();
        assertGe(acc, BUYBACK_THRESHOLD, "accumulator should be above 500 USDC threshold");

        // Step 4: satisfy the 30-day buyback interval (M-07).
        // Warp also makes harvest due; reset with manualHarvest so buyback is priority.
        vm.warp(block.timestamp + BUYBACK_INTERVAL);
        vm.prank(founder);
        automation.manualHarvest(); // resets lastHarvestTime → harvest no longer due

        (bool needed, bytes memory data) = automation.checkUpkeep("");
        assertTrue(needed);
        bytes32 action = abi.decode(data, (bytes32));
        assertEq(action, keccak256("BUYBACK"));
    }

    function test_CheckUpkeepFalseWhenAccumulatorAboveThresholdButIntervalNotElapsed() public {
        // Same first-harvest approach but WITHOUT the 30-day warp:
        // accumulator fills but lastBuybackTime (set at automation deploy, ~48h ago) means
        // the 30-day interval has not elapsed → checkUpkeep must return false.

        // Step 1: deposit all 10_000e6 (same sizing as the "true" sibling test).
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 10_000e6);
        vault.deposit(10_000e6, 0);
        vm.stopPrank();

        // Step 2: pre-fund Camelot for directBurn.
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 200e18);

        // Step 3: first recordHarvest (unconstrained) fills the accumulator.
        MockUSDCAutomation(USDC_ADDR).mint(address(vault), 25_000e6);
        vm.prank(address(automation));
        vault.recordHarvest(
            25_000e6,
            7_000e6 + (25_000e6 * 70) / 100,
            2_500e6 + (25_000e6 * 25) / 100,
              500e6 + (25_000e6 *  5) / 100
        );

        assertGe(vault.buybackAccumulator(), BUYBACK_THRESHOLD);

        // Do NOT warp — only ~48h elapsed since automation deployment (setUp warp),
        // which is less than the 30-day BUYBACK_INTERVAL → buyback must not fire.
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
        // Accumulator is 0 → _buyback returns early, executeBuyback is a no-op
        // (no revert, just does nothing)
        vm.prank(founder);
        automation.manualBuyback(); // should not revert
    }
}
