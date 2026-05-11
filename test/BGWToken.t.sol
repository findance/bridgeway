// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../contracts/tokens/BGWToken.sol";

contract BGWTokenTest is Test {
    BGWToken token;

    address admin    = makeAddr("admin");
    address minter   = makeAddr("minter");   // simulates vault
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address charlie  = makeAddr("charlie");  // not whitelisted

    function setUp() public {
        vm.prank(admin);
        token = new BGWToken(admin);

        // Grant minter role to simulated vault
        vm.prank(admin);
        token.grantRole(token.MINTER_ROLE(), minter);

        // Whitelist alice and bob
        vm.startPrank(admin);
        token.setWhitelisted(alice, true);
        token.setWhitelisted(bob,   true);
        // Also whitelist the minter (vault) so it can receive tokens during buyback
        token.setWhitelisted(minter, true);
        vm.stopPrank();
    }

    // ── Minting ───────────────────────────────────────────────────────────────

    function test_MintToWhitelisted() public {
        vm.prank(minter);
        token.mint(alice, 100e18);
        assertEq(token.balanceOf(alice), 100e18);
    }

    function test_MintRevertsIfNotMinterRole() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100e18);
    }

    function test_MintRevertsIfRecipientNotWhitelisted() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(BGWToken.NotWhitelisted.selector, charlie));
        token.mint(charlie, 100e18);
    }

    function test_MintRevertsWhenPaused() public {
        vm.prank(admin);
        token.pause();

        vm.prank(minter);
        vm.expectRevert();
        token.mint(alice, 100e18);
    }

    // ── Transfers ─────────────────────────────────────────────────────────────

    function test_TransferBetweenWhitelisted() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.transfer(bob, 50e18);

        assertEq(token.balanceOf(alice), 50e18);
        assertEq(token.balanceOf(bob),   50e18);
    }

    function test_TransferRevertsIfRecipientNotWhitelisted() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BGWToken.NotWhitelisted.selector, charlie));
        token.transfer(charlie, 50e18);
    }

    function test_TransferRevertsIfSenderNotWhitelisted() public {
        // Give charlie tokens directly via a prank workaround
        // (normally impossible — but simulate by removing alice from whitelist after mint)
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(admin);
        token.setWhitelisted(alice, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BGWToken.NotWhitelisted.selector, alice));
        token.transfer(bob, 50e18);
    }

    // ── Blacklist ─────────────────────────────────────────────────────────────

    function test_BlacklistedCannotReceive() public {
        vm.prank(admin);
        token.setBlacklisted(alice, true);

        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(BGWToken.AccountBlacklisted.selector, alice));
        token.mint(alice, 100e18);
    }

    function test_BlacklistedCannotSend() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(admin);
        token.setBlacklisted(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BGWToken.AccountBlacklisted.selector, alice));
        token.transfer(bob, 50e18);
    }

    // ── Burning ──────────────────────────────────────────────────────────────

    function test_PublicBurn() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.burn(40e18);

        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.totalSupply(),     60e18);
    }

    function test_BurnFromByMinter() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(minter);
        token.burnFrom(alice, 40e18);

        assertEq(token.balanceOf(alice), 60e18);
    }

    function test_BurnFromRevertsIfNotMinter() public {
        vm.prank(minter);
        token.mint(alice, 100e18);

        vm.prank(bob);
        vm.expectRevert();
        token.burnFrom(alice, 40e18);
    }

    // ── Whitelist management ──────────────────────────────────────────────────

    function test_BatchWhitelist() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("d1");
        accounts[1] = makeAddr("d2");

        vm.prank(admin);
        token.setWhitelistedBatch(accounts, true);

        assertTrue(token.whitelist(accounts[0]));
        assertTrue(token.whitelist(accounts[1]));
    }

    // ── Pause ────────────────────────────────────────────────────────────────

    function test_PauseUnpause() public {
        vm.prank(admin);
        token.pause();
        assertTrue(token.paused());

        vm.prank(admin);
        token.unpause();
        assertFalse(token.paused());
    }
}
