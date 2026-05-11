// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";
import "../contracts/tokens/BGWGovToken.sol";
import "../contracts/tokens/FounderVesting.sol";
import "../contracts/core/BGWVault.sol";
import "../contracts/libraries/FeeLib.sol";

/// @notice Mock USDC (6 decimals)
contract MockUSDC {
    string  public name     = "USD Coin";
    string  public symbol   = "USDC";
    uint8   public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}

/// @notice Minimal BGWVault wrapper that replaces the USDC constant
///         with a settable address (for unit testing without forking).
///         In a fork test, use the real Arbitrum USDC address.
contract BGWVaultTest is Test {
    // Note: these tests run against a locally deployed vault on a forked network.
    // For unit tests without a fork, we need to override USDC — see MockVault below.

    BGWToken       bgwToken;
    BGWGovToken    govToken;
    FounderVesting vesting;
    BGWVault       vault;

    address founder  = makeAddr("founder");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");

    // Fee wallets
    address team     = makeAddr("team");
    address holdback = makeAddr("holdback");
    address lp       = makeAddr("lp");
    address reserve  = makeAddr("reserve");

    // For tests: we'll deploy on a fork so real USDC works.
    // Fallback: use vm.etch to place mock code at the USDC address.
    address constant USDC_ADDR = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function setUp() public {
        // If running without fork: etch a mock ERC-20 at USDC_ADDR
        // If running with fork ($ARBITRUM_RPC): comment out the etch lines
        _etchMockUSDC();

        // Predict vesting address so gov can mint to it
        address deployerAddr = address(this);
        uint256 nonce        = vm.getNonce(deployerAddr);
        // govToken deploys first (nonce), vesting second (nonce+1)
        address predictedVesting = computeCreateAddress(deployerAddr, nonce + 1);

        // 1. Deploy tokens
        govToken = new BGWGovToken(predictedVesting, address(1), founder);
        vesting  = new FounderVesting(address(govToken), founder);

        require(address(vesting) == predictedVesting, "nonce drift");

        bgwToken = new BGWToken(founder);

        // 2. Deploy vault
        vault = new BGWVault(
            address(bgwToken),
            address(govToken),
            team,
            holdback,
            lp,
            reserve,
            founder
        );

        // 3. Wire roles
        vm.startPrank(founder);
        bgwToken.grantRole(bgwToken.MINTER_ROLE(),        address(vault));
        bgwToken.grantRole(bgwToken.WHITELIST_ADMIN_ROLE(), address(vault));
        govToken.grantRole(govToken.DISTRIBUTOR_ROLE(),   address(vault));

        // 4. Whitelist founder + test users
        vault.setWhitelisted(founder, true);
        vault.setWhitelisted(alice,   true);
        vault.setWhitelisted(bob,     true);
        vm.stopPrank();

        // 5. Give alice and bob USDC
        MockUSDC(USDC_ADDR).mint(alice,   10_000e6);
        MockUSDC(USDC_ADDR).mint(bob,     10_000e6);
        MockUSDC(USDC_ADDR).mint(founder, 10_000e6);
    }

    function _etchMockUSDC() internal {
        MockUSDC mock = new MockUSDC();
        vm.etch(USDC_ADDR, address(mock).code);
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

        // At $1.00 NAV: 1000 USDC → 1000 BGW (18 dec)
        assertEq(bgwToken.balanceOf(alice), 1_000e18);
        assertEq(vault.totalNAV(),          1_000e6);
    }

    function test_SecondDepositUsesUpdatedNAV() public {
        // Alice deposits 1000
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        // Simulate yield: automation reports +100 USDC yield
        address automationAddr = makeAddr("automation");
        vm.prank(founder);
        vault.setAutomation(automationAddr);

        vm.prank(automationAddr);
        vault.recordHarvest(100e6, 770e6, 275e6, 55e6); // 70/25/5 of 1100

        // NAV is now 1100/1000 = $1.10 per BGW
        // Bob deposits 1100 USDC → should get 1000 BGW
        vm.startPrank(bob);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_100e6);
        vault.deposit(1_100e6);
        vm.stopPrank();

        uint256 bobBGW = bgwToken.balanceOf(bob);
        // ~1000e18 (allow small rounding)
        assertApproxEqRel(bobBGW, 1_000e18, 0.01e18); // 1% tolerance
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
        vm.startPrank(alice);
        vm.expectRevert(BGWVault.ZeroAmount.selector);
        vault.deposit(0);
        vm.stopPrank();
    }

    // ── Sleeve allocation ─────────────────────────────────────────────────────

    function test_DepositAllocatesCorrectSleeveWeights() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        assertEq(vault.sleeveAValue(), 700e6);  // 70%
        assertEq(vault.sleeveBValue(), 250e6);  // 25%
        assertEq(vault.sleeveCValue(),  50e6);  //  5%
    }

    // ── Redeem ────────────────────────────────────────────────────────────────

    function test_RedeemReturnsUSDCMinusExitFee() public {
        // Alice deposits 1000 USDC
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);

        uint256 bgwBalance = bgwToken.balanceOf(alice);
        uint256 usdcBefore = MockUSDC(USDC_ADDR).balanceOf(alice);

        // Redeem all
        vault.redeem(bgwBalance, 0);
        vm.stopPrank();

        uint256 usdcAfter  = MockUSDC(USDC_ADDR).balanceOf(alice);
        uint256 received   = usdcAfter - usdcBefore;

        // Expected: 1000 USDC - 0.10% exit fee = 999 USDC
        // (no perf fee since NAV == HWM at bootstrap)
        uint256 expectedFee = (1_000e6 * 10) / 10_000; // 0.10%
        uint256 expected    = 1_000e6 - expectedFee;

        assertApproxEqAbs(received, expected, 1); // allow 1 wei rounding
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
        vault.redeem(99_999e18, 0); // more than alice has
        vm.stopPrank();
    }

    function test_RedeemRevertsSlippage() public {
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);

        // Demand 100% of gross — will fail due to exit fee
        vm.expectRevert();
        vault.redeem(bgwToken.balanceOf(alice), 1_000e6);
        vm.stopPrank();
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
        assertEq(fee, 1e6); // $1.00
    }

    function test_PerfFeeCalc() public pure {
        uint256 fee = FeeLib.calcPerfFee(100e6); // 15% of $100
        assertEq(fee, 15e6); // $15.00
    }

    // ── High-water mark ───────────────────────────────────────────────────────

    function test_HWMNotUpdatedWhenNAVBelow() public {
        // Deposit
        vm.startPrank(alice);
        MockUSDC(USDC_ADDR).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6);
        vm.stopPrank();

        uint256 hwmBefore = vault.highWaterMark();

        // Report a loss (sleeve values drop)
        address automationAddr = makeAddr("automation");
        vm.prank(founder);
        vault.setAutomation(automationAddr);

        vm.prank(automationAddr);
        vault.recordHarvest(0, 630e6, 215e6, 45e6); // 10% loss

        // HWM should not change
        assertEq(vault.highWaterMark(), hwmBefore);
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

        // 0.75% stress fee → received ≈ 992.5 USDC
        uint256 expected = 1_000e6 - (1_000e6 * 75 / 10_000);
        assertApproxEqAbs(received, expected, 1);
    }
}
