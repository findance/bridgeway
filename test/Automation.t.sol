// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/CCRToken.sol";
import "../contracts/tokens/CGOVToken.sol";
import "../contracts/core/ClearcrestVault.sol";
import "../contracts/core/ClearcrestAutomation.sol";
import "../contracts/core/modules/ClearcrestMaintenanceModule.sol";
import "../contracts/core/modules/ClearcrestRedemptionModule.sol";
import "../contracts/mocks/MockCamelotRouter.sol";
import "../contracts/mocks/MockSleeveAdapter.sol";
import "../contracts/libraries/FeeLib.sol";

/// @notice Minimal mock USDC (duplicated to avoid test-file coupling).
contract MockUSDCAutomation {
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

contract AutomationTest is Test {
    CCRToken ccrToken;
    CGOVToken cgovToken;
    ClearcrestVault vault;
    ClearcrestAutomation automation;

    address founder = makeAddr("founder");
    address alice = makeAddr("alice");
    address team = makeAddr("team");
    address holdback = makeAddr("holdback");
    address lp = makeAddr("lp");
    address reserve = makeAddr("reserve");
    address stranger = makeAddr("stranger");

    address constant USDC_ADDR = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CAMELOT_ADDR = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

    uint256 constant HARVEST_INTERVAL = 30 days;
    uint256 constant REBALANCE_INTERVAL = 30 days;
    uint256 constant BUYBACK_INTERVAL = 30 days;
    uint256 constant BUYBACK_THRESHOLD = 500e6; // 500 USDC (M-07)

    function setUp() public {
        // Mock USDC
        MockUSDCAutomation mockUsdc = new MockUSDCAutomation();
        vm.etch(USDC_ADDR, address(mockUsdc).code);

        ccrToken = new CCRToken(founder);
        cgovToken = new CGOVToken(founder, address(ccrToken), founder);

        // Mock Camelot
        MockCamelotRouter mockCamelot = new MockCamelotRouter(address(ccrToken), 1e12);
        vm.etch(CAMELOT_ADDR, address(mockCamelot).code);

        vault = new ClearcrestVault(
            address(ccrToken), address(cgovToken), team, holdback, reserve, founder, USDC_ADDR, address(2)
        );
        ClearcrestRedemptionModule redemptionModule =
            new ClearcrestRedemptionModule(address(ccrToken), address(cgovToken), USDC_ADDR, address(2));
        ClearcrestMaintenanceModule maintenanceModule =
            new ClearcrestMaintenanceModule(address(ccrToken), address(cgovToken), USDC_ADDR, address(2));

        // Wire roles
        vm.startPrank(founder);
        vault.setLogicModules(address(redemptionModule), address(maintenanceModule));
        ccrToken.setGovernanceCompanion(address(cgovToken));
        ccrToken.grantRole(ccrToken.MINTER_ROLE(), address(vault));
        ccrToken.grantRole(ccrToken.BURNER_ROLE(), address(vault)); // H-11
        ccrToken.grantRole(ccrToken.WHITELIST_ADMIN_ROLE(), address(vault));
        vault.setWhitelisted(address(vault), true);
        ccrToken.setWhitelisted(CAMELOT_ADDR, true);
        cgovToken.initVault(address(vault));
        vault.setWhitelisted(CAMELOT_ADDR, true);
        vault.setWhitelisted(founder, true);
        vault.setWhitelisted(alice, true);
        vm.stopPrank();

        // Deploy automation and wire to vault.
        automation = new ClearcrestAutomation(address(vault), founder, USDC_ADDR);
        vm.prank(founder);
        vault.setAutomation(address(automation));
        vm.warp(block.timestamp + FeeLib.MIN_HARVEST_GAP + 1);

        // Seed alice with USDC
        MockUSDCAutomation(USDC_ADDR).mint(alice, 10_000e6);
    }

    // ── checkUpkeep — harvest ─────────────────────────────────────────────────

    function test_CheckUpkeepFalseAfterRecentHarvest() public {
        // Do a harvest to set lastHarvestTime = now
        vm.prank(founder);
        automation.manualHarvest();

        (bool needed,) = automation.checkUpkeep("");
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

    function test_CheckUpkeepTrueAfterRebalanceIntervalWhenHarvestDisabled() public {
        vm.prank(founder);
        automation.setHarvestEnabled(false);

        vm.warp(block.timestamp + REBALANCE_INTERVAL);

        (bool needed, bytes memory data) = automation.checkUpkeep("");
        assertTrue(needed);
        bytes32 action = abi.decode(data, (bytes32));
        assertEq(action, keccak256("REBALANCE"));
    }

    // ── checkUpkeep — buyback ─────────────────────────────────────────────────

    function test_CheckUpkeepFalseWhenAccumulatorBelowThreshold() public {
        // Harvest first so harvest isn't immediately due
        vm.prank(founder);
        automation.manualHarvest();

        // Accumulator starts at 0
        (bool needed,) = automation.checkUpkeep("");
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

        // Step 2: after 30 days, 25,000e6 yield is within the 50% APR cap.
        // perfFee 15% = 3,750e6 -> buyback gross 562.5e6.
        vm.warp(block.timestamp + BUYBACK_INTERVAL);
        vm.prank(address(automation));
        vault.recordHarvest(25_000e6, 703_500e6, 251_250e6, 50_250e6);

        uint256 acc = vault.buybackAccumulator();
        assertGe(acc, BUYBACK_THRESHOLD, "accumulator should be above 500 USDC threshold");

        // Step 4: this test is about buyback priority, so suppress other actions.
        vm.startPrank(founder);
        automation.setHarvestEnabled(false);
        automation.setRebalanceEnabled(false);
        vm.stopPrank();

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

        // Step 3: bounded harvest after 27 days fills the accumulator while
        // keeping lastBuybackTime below the 30-day interval.
        vm.warp(block.timestamp + 27 days);
        vm.prank(address(automation));
        vault.recordHarvest(25_000e6, 703_500e6, 251_250e6, 50_250e6);

        assertGe(vault.buybackAccumulator(), BUYBACK_THRESHOLD);

        // Only ~29 days elapsed since automation deployment, which is less than
        // the 30-day BUYBACK_INTERVAL → buyback must not fire.
        (bool needed,) = automation.checkUpkeep("");
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

    function test_PerformUpkeepHarvestCallsSleevesBeforeRecordHarvest() public {
        MockSleeveAdapter adapterA = new MockSleeveAdapter(address(vault), USDC_ADDR);
        MockSleeveAdapter adapterB = new MockSleeveAdapter(address(vault), USDC_ADDR);
        MockSleeveAdapter adapterC = new MockSleeveAdapter(address(vault), USDC_ADDR);

        _wireRoute(vault.SLEEVE_A(), address(adapterA));
        _wireRoute(vault.SLEEVE_B(), address(adapterB));
        _wireRoute(vault.SLEEVE_C(), address(adapterC));

        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, 0);
        vm.stopPrank();

        MockUSDCAutomation(USDC_ADDR).mint(address(adapterA), 10e6);
        MockUSDCAutomation(USDC_ADDR).mint(address(adapterB), 5e6);
        MockUSDCAutomation(USDC_ADDR).mint(address(adapterC), 7e6);
        adapterA.simulateYield(10e6);
        adapterB.simulateYield(5e6);
        adapterC.simulateYield(7e6);

        uint256 aBefore = adapterA.totalAssetsUSDC();
        uint256 bBefore = adapterB.totalAssetsUSDC();
        uint256 cBefore = adapterC.totalAssetsUSDC();

        vm.warp(block.timestamp + HARVEST_INTERVAL + 1);
        automation.performUpkeep(abi.encode(keccak256("HARVEST")));

        assertGt(adapterA.totalAssetsUSDC(), aBefore, "A yield must compound into A before fee settlement");
        assertLt(adapterA.totalAssetsUSDC(), aBefore + 10e6, "performance fee reduces A pro rata");
        assertGt(adapterB.totalAssetsUSDC(), bBefore, "B must receive B yield plus C yield before fee settlement");
        assertLt(adapterB.totalAssetsUSDC(), bBefore + 12e6, "performance fee reduces B pro rata");
        assertEq(adapterC.totalAssetsUSDC(), cBefore, "C yield must leave C");
    }

    function test_PerformUpkeepHarvestReportsRedeployedSleeveYieldForPerformanceFee() public {
        MockSleeveAdapter adapterA = new MockSleeveAdapter(address(vault), USDC_ADDR);
        MockSleeveAdapter adapterB = new MockSleeveAdapter(address(vault), USDC_ADDR);
        MockSleeveAdapter adapterC = new MockSleeveAdapter(address(vault), USDC_ADDR);

        _wireRoute(vault.SLEEVE_A(), address(adapterA));
        _wireRoute(vault.SLEEVE_B(), address(adapterB));
        _wireRoute(vault.SLEEVE_C(), address(adapterC));

        vm.prank(founder);
        vault.setManagementFeeBps(0);

        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, 0);
        vm.stopPrank();

        MockUSDCAutomation(USDC_ADDR).mint(address(adapterA), 4e6);
        MockUSDCAutomation(USDC_ADDR).mint(address(adapterB), 3e6);
        MockUSDCAutomation(USDC_ADDR).mint(address(adapterC), 3e6);
        adapterA.simulateYield(4e6);
        adapterB.simulateYield(3e6);
        adapterC.simulateYield(3e6);

        vm.warp(block.timestamp + HARVEST_INTERVAL + 1);
        automation.performUpkeep(abi.encode(keccak256("HARVEST")));

        uint256 expectedPerfFee = FeeLib.calcPerfFee(10e6);
        uint256 expectedBuyback = FeeLib.splitPerfFee(expectedPerfFee).buyback;
        assertEq(vault.buybackAccumulator(), expectedBuyback);
        assertGt(vault.totalPendingFees(), 0);
    }

    function test_PerformUpkeepHarvestRevertsIfNotDue() public {
        // Execute harvest to reset timer
        vm.prank(founder);
        automation.manualHarvest();

        // Immediately try again — should revert
        bytes memory data = abi.encode(keccak256("HARVEST"));
        vm.expectRevert(ClearcrestAutomation.HarvestNotDue.selector);
        automation.performUpkeep(data);
    }

    function test_PerformUpkeepRevertsOnUnknownAction() public {
        bytes memory data = abi.encode(keccak256("UNKNOWN"));
        vm.expectRevert(abi.encodeWithSelector(ClearcrestAutomation.UnknownAction.selector, keccak256("UNKNOWN")));
        automation.performUpkeep(data);
    }

    function test_PerformUpkeepRebalanceMovesCToBThenBToA() public {
        vm.prank(founder);
        vault.setSleeveDepositWeights(0, 0, 10_000);

        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, 0);
        vm.stopPrank();

        vm.startPrank(founder);
        vault.setSleeveDepositWeights(6_500, 3_500, 0);
        automation.setHarvestEnabled(false);
        vm.stopPrank();

        vm.warp(block.timestamp + REBALANCE_INTERVAL);
        automation.performUpkeep(abi.encode(keccak256("REBALANCE")));

        assertEq(vault.holderIdleUSDC(), 20e6);
        assertEq(vault.sleeveAValue(), 630e6);
        assertEq(vault.sleeveBValue(), 350e6);
        assertEq(vault.sleeveCValue(), 0);
    }

    // ── Toggle controls ───────────────────────────────────────────────────────

    function test_DisablingHarvestSuppressesCheckUpkeep() public {
        vm.startPrank(founder);
        automation.setHarvestEnabled(false);
        automation.setRebalanceEnabled(false);
        vm.stopPrank();

        vm.warp(block.timestamp + HARVEST_INTERVAL);

        (bool needed,) = automation.checkUpkeep("");
        assertFalse(needed); // harvest suppressed
    }

    function test_DisablingRebalanceSuppressesCheckUpkeep() public {
        vm.startPrank(founder);
        automation.setHarvestEnabled(false);
        automation.setRebalanceEnabled(false);
        vm.stopPrank();

        vm.warp(block.timestamp + REBALANCE_INTERVAL);

        (bool needed,) = automation.checkUpkeep("");
        assertFalse(needed);
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
        vm.expectRevert(ClearcrestAutomation.AccumulatorTooLow.selector);
        automation.manualBuyback();
    }

    function test_ManualRebalanceUpdatesTimestamp() public {
        uint256 before = automation.lastRebalanceTime();
        vm.warp(block.timestamp + 1);
        vm.prank(founder);
        automation.manualRebalance(type(uint256).max);
        assertGt(automation.lastRebalanceTime(), before);
    }

    // ── H-01: manual trigger rate-limiting ───────────────────────────────────

    function test_ManualHarvestRevertsIfTooSoon() public {
        // First harvest — more than MIN_HARVEST_GAP has passed since construction (setUp warp = 48h+1)
        vm.prank(founder);
        automation.manualHarvest();

        // Immediately try again — must revert because MIN_HARVEST_GAP (12h) has not elapsed
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearcrestAutomation.HarvestTooSoon.selector, automation.lastHarvestTime() + FeeLib.MIN_HARVEST_GAP
            )
        );
        vm.prank(founder);
        automation.manualHarvest();
    }

    function test_ManualHarvestSucceedsAfterGap() public {
        vm.prank(founder);
        automation.manualHarvest();

        vm.warp(block.timestamp + FeeLib.MIN_HARVEST_GAP);

        vm.prank(founder);
        automation.manualHarvest(); // must succeed after the gap
    }

    function _wireRoute(uint8 sleeve, address adapter) internal {
        address[] memory adapters = new address[](1);
        adapters[0] = adapter;
        uint16[] memory bps = new uint16[](1);
        bps[0] = 10_000;
        bool[] memory active = new bool[](1);
        active[0] = true;
        vm.prank(founder);
        vault.configureSleeveAdapterRoutes(sleeve, adapters, bps, active);
    }

    function test_ManualBuybackRevertsIfIntervalNotElapsed() public {
        // Fill the accumulator above BUYBACK_THRESHOLD using a bounded harvest.
        MockUSDCAutomation(USDC_ADDR).mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        MockUSDCAutomation(USDC_ADDR).approve(address(vault), 1_000_000e6);
        vault.deposit(1_000_000e6, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 27 days);
        vm.prank(address(automation));
        vault.recordHarvest(25_000e6, 703_500e6, 251_250e6, 50_250e6);

        assertGe(vault.buybackAccumulator(), BUYBACK_THRESHOLD);

        // lastBuybackTime is set at construction; interval (30d) has NOT elapsed.
        vm.expectRevert(
            abi.encodeWithSelector(
                ClearcrestAutomation.BuybackIntervalNotElapsed.selector, automation.lastBuybackTime() + BUYBACK_INTERVAL
            )
        );
        vm.prank(founder);
        automation.manualBuyback();
    }
}
