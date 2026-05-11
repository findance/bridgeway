// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";
import "../contracts/tokens/BGWGovToken.sol";
import "../contracts/tokens/FounderVesting.sol";
import "../contracts/core/BGWVault.sol";
import "../contracts/mocks/MockCamelotRouter.sol";
import "../contracts/libraries/FeeLib.sol";

/// @notice Minimal mock USDC (6 decimals) etched at the Arbitrum USDC address.
contract MockUSDC {
    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply   += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from]             -= amount;
        balanceOf[to]               += amount;
        return true;
    }
}

contract BGWVaultTest is Test {
    BGWToken       bgwToken;
    BGWGovToken    govToken;
    FounderVesting vesting;
    BGWVault       vault;

    address founder  = makeAddr("founder");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    address team     = makeAddr("team");
    address holdback = makeAddr("holdback");
    address lp       = makeAddr("lp");
    address reserve  = makeAddr("reserve");

    address constant USDC_ADDR     = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant CAMELOT_ADDR  = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;

    function setUp() public {
        // ── Mock USDC ──────────────────────────────────────────────────────────
        MockUSDC mockUsdc = new MockUSDC();
        vm.etch(USDC_ADDR, address(mockUsdc).code);

        // ── Deploy tokens ──────────────────────────────────────────────────────
        // BGWGovToken mints 70M to FounderVesting in its constructor.
        // Predict vesting address (govToken deploys at nonce N, vesting at N+1).
        address predictedVesting =
            computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        govToken = new BGWGovToken(predictedVesting, founder);        // nonce N
        vesting  = new FounderVesting(address(govToken), founder);    // nonce N+1
        require(address(vesting) == predictedVesting, "nonce drift");

        bgwToken = new BGWToken(founder);

        // ── Deploy vault ───────────────────────────────────────────────────────
        vault = new BGWVault(
            address(bgwToken),
            address(govToken),
            team,
            holdback,
            lp,
            reserve,
            founder
        );

        // ── Mock Camelot router ────────────────────────────────────────────────
        // Etch MockCamelotRouter bytecode (with bgwToken + rate baked in as
        // immutables) at the real Camelot address so buyback / _burnViaSwap work.
        MockCamelotRouter mockCamelot = new MockCamelotRouter(address(bgwToken), 1e12);
        vm.etch(CAMELOT_ADDR, address(mockCamelot).code);

        // ── Wire roles ─────────────────────────────────────────────────────────
        vm.startPrank(founder);

        bgwToken.grantRole(bgwToken.MINTER_ROLE(),           address(vault));
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(),  address(vault));
        // Vault must be whitelisted on BGWToken to receive BGW during buybacks.
        bgwToken.setWhitelisted(address(vault), true);
        // Camelot mock mints BGW during swap simulation — grant it MINTER_ROLE.
        bgwToken.grantRole(bgwToken.MINTER_ROLE(), CAMELOT_ADDR);
        bgwToken.setWhitelisted(CAMELOT_ADDR, true);

        // Transfer 30M BGW-GOV community pool to vault + grant DISTRIBUTOR_ROLE.
        govToken.initVault(address(vault));

        // Whitelist users on vault (also updates BGWToken whitelist via WHITELIST_ADMIN_ROLE).
        vault.setWhitelisted(founder, true);
        vault.setWhitelisted(alice,   true);
        vault.setWhitelisted(bob,     true);

        vm.stopPrank();

        // ── Seed USDC balances ─────────────────────────────────────────────────
        MockUSDC(USDC_ADDR).mint(alice,   10_000e6);
        MockUSDC(USDC_ADDR).mint(bob,     10_000e6);
        MockUSDC(USDC_ADDR).mint(founder, 10_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _setupAutomation() internal returns (address automationAddr) {
        automationAddr = makeAddr("automation");
        vm.prank(founder);
        vault.setAutomation(automationAddr);
    }

    // ── NAV bootstrapping ────────────────────────────────────────────────────

    function test_NavIsOneBeforeDeposit() public view {
        assertEq(vault.navPerBGW(), 1e6); // $1.00
    }

    // ── Deposit ──────────────────────────────────────────────────────────────

    function test_FirstDepositMintsBGW1to1() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // At $1.00 NAV: 1000 USDC → 1000 BGW
        assertEq(bgwToken.balanceOf(alice), 1_000e18);
        assertEq(vault.totalNAV(),          1_000e6);
    }

    function test_SecondDepositUsesUpdatedNAV() public {
        // Alice deposits 1000 USDC
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Simulate NAV growth via sleeve value update (no yield = no perf fee = no Camelot)
        address automationAddr = _setupAutomation();
        vm.prank(automationAddr);
        vault.updateSleeveValues(770e6, 275e6, 55e6); // total = 1100; NAV = $1.10/BGW

        // Bob deposits 1100 USDC at $1.10 NAV → should receive ~1000 BGW
        vm.startPrank(bob);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_100e6);
        vault.deposit(1_100e6);
        vm.stopPrank();

        assertApproxEqRel(bgwToken.balanceOf(bob), 1_000e18, 0.01e18);
    }

    function test_DepositRevertsIfNotWhitelisted() public {
        address stranger = makeAddr("stranger");
        MockUSDC(USDC_ADDR).mint(stranger, 1_000e6);

        vm.startPrank(stranger);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(BGWVault.NotWhitelisted.selector, stranger));
        vault.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_DepositRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(BGWVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    // ── BGW-GOV distribution ──────────────────────────────────────────────────

    function test_GovDistributedAtFixedRate() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Rate: bgwMinted × (30M / 100M) = 1000e18 × 0.3 = 300e18 BGW-GOV
        uint256 expected = (1_000e18 * 30_000_000e18) / 100_000_000e18;
        assertEq(govToken.balanceOf(alice), expected);
    }

    function test_GovRateIsEqualForAllDepositors() public {
        // Alice deposits first
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        uint256 aliceGov = govToken.balanceOf(alice);

        // Bob deposits the same amount later (NAV unchanged)
        vm.startPrank(bob);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Both should receive the same amount — no first-depositor advantage
        assertEq(govToken.balanceOf(bob), aliceGov);
    }

    function test_GovPoolDecreasesAfterDistribution() public {
        uint256 poolBefore = govToken.balanceOf(address(vault));

        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        uint256 poolAfter = govToken.balanceOf(address(vault));
        assertLt(poolAfter, poolBefore);
        assertEq(poolBefore - poolAfter, govToken.balanceOf(alice));
    }

    // ── Sleeve allocation ─────────────────────────────────────────────────────

    function test_DepositAllocatesCorrectSleeveWeights() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        assertEq(vault.sleeveAValue(), 700e6);
        assertEq(vault.sleeveBValue(), 250e6);
        assertEq(vault.sleeveCValue(),  50e6);
    }

    // ── Redeem ────────────────────────────────────────────────────────────────

    function test_RedeemReturnsUSDCMinusExitFee() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);

        uint256 bgwBalance = bgwToken.balanceOf(alice);
        uint256 usdcBefore = MockUSDC(USDC_ADDR).balanceOf(alice);

        vault.redeem(bgwBalance, 0);
        vm.stopPrank();

        uint256 received = MockUSDC(USDC_ADDR).balanceOf(alice) - usdcBefore;

        // 1000 USDC - 0.10% exit fee = 999 USDC (no perf fee at HWM)
        uint256 expectedFee = (1_000e6 * 10) / 10_000;
        assertApproxEqAbs(received, 1_000e6 - expectedFee, 1);
    }

    function test_RedeemBurnsBGW() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        uint256 bgwBefore = bgwToken.totalSupply();

        vault.redeem(bgwToken.balanceOf(alice), 0);
        vm.stopPrank();

        assertEq(bgwToken.totalSupply(), 0);
        assertGt(bgwBefore, 0);
    }

    function test_RedeemRevertsIfInsufficientBGW() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);

        vm.expectRevert();
        vault.redeem(99_999e18, 0);
        vm.stopPrank();
    }

    function test_RedeemRevertsOnSlippage() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Cache balance before vm.expectRevert so the balanceOf STATICCALL doesn't
        // interfere with the cheat code in Foundry v1.x.
        uint256 aliceBGW = bgwToken.balanceOf(alice);

        // Demand full gross value — fails because 0.10% exit fee is deducted
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(aliceBGW, 1_000e6);
    }

    // ── FeeLib math ──────────────────────────────────────────────────────────

    function test_FeeSplitSumsToTotal() public pure {
        uint256 total = 100e6;
        FeeLib.FeeSplit memory s = FeeLib.splitPerfFee(total);
        uint256 sum = s.team + s.holdback + s.buyback + s.lpSeed + s.reserve + s.directBurn;
        assertEq(sum, total);
    }

    function test_ExitFeeCalc() public pure {
        uint256 fee = FeeLib.calcExitFee(1_000e6, 10); // 0.10%
        assertEq(fee, 1e6);
    }

    function test_PerfFeeCalc() public pure {
        uint256 fee = FeeLib.calcPerfFee(100e6); // 15% of $100
        assertEq(fee, 15e6);
    }

    // ── High-water mark ───────────────────────────────────────────────────────

    function test_HWMNotUpdatedWhenNAVBelow() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        uint256 hwmBefore      = vault.highWaterMark();
        address automationAddr = _setupAutomation();

        vm.prank(automationAddr);
        vault.recordHarvest(0, 630e6, 215e6, 45e6); // 10% loss, no yield

        assertEq(vault.highWaterMark(), hwmBefore);
    }

    function test_HarvestWithYieldTakesPerfFeeAndUpdateHWM() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Give vault extra USDC to cover perf-fee distribution
        MockUSDC(USDC_ADDR).mint(address(vault), 100e6);

        address automationAddr = _setupAutomation();
        uint256 hwmBefore = vault.highWaterMark();

        // Pre-fund mock Camelot with Alice's BGW so directBurn can transfer
        // existing BGW (safeTransfer) rather than minting, keeping supply accurate.
        // directBurn = 5% of perfFee(100e6) = 5% of 15e6 = 0.75e6 USDC → 0.75e18 BGW.
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 5e18);

        // Record 100 USDC yield — triggers perf fee (Camelot mock handles directBurn)
        vm.prank(automationAddr);
        vault.recordHarvest(100e6, 770e6, 275e6, 55e6);

        // HWM must have increased
        assertGt(vault.highWaterMark(), hwmBefore);
        // Some USDC went to team wallet
        assertGt(MockUSDC(USDC_ADDR).balanceOf(team), 0);
    }

    // ── Stress mode ───────────────────────────────────────────────────────────

    function test_StressModeIncreasesExitFee() public {
        vm.prank(founder);
        vault.setStressMode(true);

        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);

        uint256 usdcBefore = MockUSDC(USDC_ADDR).balanceOf(alice);
        vault.redeem(bgwToken.balanceOf(alice), 0);
        vm.stopPrank();

        uint256 received = MockUSDC(USDC_ADDR).balanceOf(alice) - usdcBefore;
        uint256 expected = 1_000e6 - (1_000e6 * 75 / 10_000); // 0.75% stress fee
        assertApproxEqAbs(received, expected, 1);
    }

    // ── Buyback ───────────────────────────────────────────────────────────────

    function test_BuybackBurnsBGW() public {
        // Seed vault buyback accumulator by triggering a perf fee harvest
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        MockUSDC(USDC_ADDR).mint(address(vault), 100e6);

        address automationAddr = _setupAutomation();

        // Pre-fund mock Camelot with Alice's BGW so both directBurn (0.75e18) and the
        // subsequent executeBuyback (2.25e18) can safeTransfer existing BGW.
        // This makes the burn genuinely deflationary (removes circulating supply).
        vm.prank(alice);
        bgwToken.transfer(CAMELOT_ADDR, 5e18);

        vm.prank(automationAddr);
        vault.recordHarvest(100e6, 770e6, 275e6, 55e6);

        uint256 accumulator = vault.buybackAccumulator();
        assertGt(accumulator, 0);

        uint256 supplyBefore = bgwToken.totalSupply();

        // Execute buyback — mock Camelot mints BGW to vault, vault burns it
        vm.prank(automationAddr);
        vault.executeBuyback(accumulator);

        assertEq(vault.buybackAccumulator(), 0);
        assertLt(bgwToken.totalSupply(), supplyBefore);
    }
}
