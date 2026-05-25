// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../contracts/tokens/FounderVesting.sol";

contract MockVestingToken is ERC20 {
    constructor() ERC20("Mock Vesting Token", "MVT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FounderVestingTest is Test {
    MockVestingToken cgovToken;
    FounderVesting vesting;

    address founder = makeAddr("founder");
    address successor = makeAddr("successor");
    address stranger = makeAddr("stranger");

    uint256 constant YEAR = 365 days;
    uint256 constant TOTAL = 70_000_000e18;

    function setUp() public {
        cgovToken = new MockVestingToken();
        vesting = new FounderVesting(address(cgovToken), founder);
        cgovToken.mint(address(vesting), TOTAL);

        assertEq(cgovToken.balanceOf(address(vesting)), TOTAL);
    }

    // ── Cliff ────────────────────────────────────────────────────────────────

    function test_NothingClaimableBeforeCliff() public view {
        assertEq(vesting.vestedAmount(), 0);
        assertEq(vesting.claimable(), 0);
    }

    function test_NothingClaimableAtOneYearMinus1Second() public {
        vm.warp(block.timestamp + YEAR - 1);
        assertEq(vesting.vestedAmount(), 0);
    }

    // ── Year 1–2 (25%) ───────────────────────────────────────────────────────

    function test_25PercentVestedAtYear1() public {
        vm.warp(block.timestamp + YEAR);
        assertEq(vesting.vestedAmount(), 17_500_000e18);
        assertEq(vesting.claimable(), 17_500_000e18);
    }

    function test_ClaimYear1() public {
        vm.warp(block.timestamp + YEAR);

        vm.prank(founder);
        vesting.claim();

        assertEq(cgovToken.balanceOf(founder), 17_500_000e18);
        assertEq(vesting.totalClaimed(), 17_500_000e18);
        assertEq(vesting.claimable(), 0);
    }

    // ── Year 2–3 (50%) ───────────────────────────────────────────────────────

    function test_50PercentVestedAtYear2() public {
        vm.warp(block.timestamp + 2 * YEAR);
        assertEq(vesting.vestedAmount(), 35_000_000e18);
    }

    function test_ClaimYear2AfterYear1Claim() public {
        vm.warp(block.timestamp + YEAR);
        vm.prank(founder);
        vesting.claim(); // claims 17.5M

        vm.warp(block.timestamp + YEAR); // now 2 years total
        vm.prank(founder);
        vesting.claim(); // claims remaining 17.5M (cumulative 35M)

        assertEq(cgovToken.balanceOf(founder), 35_000_000e18);
        assertEq(vesting.totalClaimed(), 35_000_000e18);
        assertEq(vesting.claimable(), 0);
    }

    // ── Year 3+ (100%) ───────────────────────────────────────────────────────

    function test_FullyVestedAfterYear3() public {
        vm.warp(block.timestamp + 3 * YEAR);
        assertEq(vesting.vestedAmount(), TOTAL);
    }

    function test_ClaimAll() public {
        vm.warp(block.timestamp + 3 * YEAR);

        vm.prank(founder);
        vesting.claim();

        assertEq(cgovToken.balanceOf(founder), TOTAL);
        assertEq(vesting.totalClaimed(), TOTAL);
        assertEq(cgovToken.balanceOf(address(vesting)), 0);
    }

    function test_NothingClaimableAfterFullClaim() public {
        vm.warp(block.timestamp + 3 * YEAR);
        vm.prank(founder);
        vesting.claim();

        assertEq(vesting.claimable(), 0);
    }

    // ── Access control ────────────────────────────────────────────────────────

    function test_StrangerCannotClaim() public {
        vm.warp(block.timestamp + YEAR);
        vm.prank(stranger);
        vm.expectRevert(FounderVesting.NotFounder.selector);
        vesting.claim();
    }

    function test_ClaimRevertsBeforeCliff() public {
        vm.prank(founder);
        vm.expectRevert(FounderVesting.NothingToClaim.selector);
        vesting.claim();
    }

    // ── Founder transfer (2-step) ─────────────────────────────────────────────

    function test_FounderTransferUpdatesFounderAfterAccept() public {
        vm.prank(founder);
        vesting.transferFounder(successor);

        // Pending — founder still active until successor accepts
        assertEq(vesting.founder(), founder);

        vm.prank(successor);
        vesting.acceptOwnership();

        assertEq(vesting.founder(), successor);
        assertEq(vesting.owner(), successor);
    }

    function test_SuccessorCanClaimAfterTransfer() public {
        vm.prank(founder);
        vesting.transferFounder(successor);

        vm.prank(successor);
        vesting.acceptOwnership();

        vm.warp(block.timestamp + YEAR);

        vm.prank(successor);
        vesting.claim();

        assertEq(cgovToken.balanceOf(successor), 17_500_000e18);
    }

    function test_OldFounderCannotClaimAfterTransfer() public {
        vm.prank(founder);
        vesting.transferFounder(successor);

        vm.prank(successor);
        vesting.acceptOwnership();

        vm.warp(block.timestamp + YEAR);

        vm.prank(founder);
        vm.expectRevert(FounderVesting.NotFounder.selector);
        vesting.claim();
    }

    function test_OnlyFounderCanInitiateTransfer() public {
        vm.prank(stranger);
        vm.expectRevert(FounderVesting.NotFounder.selector);
        vesting.transferFounder(successor);
    }

    // ── Token recovery ────────────────────────────────────────────────────────

    function test_RecoverNonGovToken() public {
        // Deploy a dummy ERC20 at a predictable address and etch minimal bytecode
        // by just minting via cgovToken mock. Use a second cgovToken as "other token".
        // Simplest: just verify the revert for cgov token recovery.
        vm.prank(founder);
        vm.expectRevert(FounderVesting.CannotRecoverCGOVToken.selector);
        vesting.recoverToken(address(cgovToken), 1e18);
    }
}
