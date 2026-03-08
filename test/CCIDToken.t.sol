// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CCIDToken} from "../src/CCIDToken.sol";

contract CCIDTokenTest is Test {
    CCIDToken public ccid;
    address public admin = address(1);
    address public provider = address(2);
    address public user1 = address(3);
    address public user2 = address(4);
    address public user3 = address(5);

    function setUp() public {
        vm.startPrank(admin);
        ccid = new CCIDToken(admin);
        ccid.grantRole(ccid.IDENTITY_PROVIDER_ROLE(), provider);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Minting
    // ──────────────────────────────────────────────

    function test_MintCCID() public {
        vm.prank(provider);
        uint256 tokenId = ccid.mint(user1, 0);

        assertEq(tokenId, 1);
        assertEq(ccid.ownerOf(1), user1);
        assertTrue(ccid.isValid(user1));
        assertEq(ccid.getTokenId(user1), 1);
    }

    function test_MintWithExpiry() public {
        uint256 expiry = block.timestamp + 365 days;

        vm.prank(provider);
        ccid.mint(user1, expiry);

        assertTrue(ccid.isValid(user1));

        // Fast forward past expiry
        vm.warp(expiry + 1);
        assertFalse(ccid.isValid(user1));
    }

    function test_CannotMintTwice() public {
        vm.startPrank(provider);
        ccid.mint(user1, 0);

        vm.expectRevert(
            abi.encodeWithSelector(CCIDToken.AlreadyHasCCID.selector, user1)
        );
        ccid.mint(user1, 0);
        vm.stopPrank();
    }

    function test_OnlyProviderCanMint() public {
        vm.prank(user1);
        vm.expectRevert();
        ccid.mint(user2, 0);
    }

    // ──────────────────────────────────────────────
    // Revocation
    // ──────────────────────────────────────────────

    function test_RevokeCCID() public {
        vm.prank(provider);
        uint256 tokenId = ccid.mint(user1, 0);

        assertTrue(ccid.isValid(user1));

        vm.prank(provider);
        ccid.revoke(tokenId);

        assertFalse(ccid.isValid(user1));
    }

    // ──────────────────────────────────────────────
    // Renewal
    // ──────────────────────────────────────────────

    function test_RenewCCID() public {
        uint256 originalExpiry = block.timestamp + 30 days;
        uint256 newExpiry = block.timestamp + 365 days;

        vm.startPrank(provider);
        uint256 tokenId = ccid.mint(user1, originalExpiry);
        ccid.renew(tokenId, newExpiry);
        vm.stopPrank();

        assertEq(ccid.tokenExpiry(tokenId), newExpiry);

        // Warp past original but before new expiry
        vm.warp(originalExpiry + 1);
        assertTrue(ccid.isValid(user1));

        // Warp past new expiry
        vm.warp(newExpiry + 1);
        assertFalse(ccid.isValid(user1));
    }

    // ──────────────────────────────────────────────
    // Soulbound (Non-Transferable)
    // ──────────────────────────────────────────────

    function test_CannotTransfer() public {
        vm.prank(provider);
        ccid.mint(user1, 0);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(CCIDToken.TransferDisabled.selector)
        );
        ccid.transferFrom(user1, user2, 1);
    }

    function test_CannotSafeTransfer() public {
        vm.prank(provider);
        ccid.mint(user1, 0);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(CCIDToken.TransferDisabled.selector)
        );
        ccid.safeTransferFrom(user1, user2, 1);
    }

    // ──────────────────────────────────────────────
    // Validity Checks
    // ──────────────────────────────────────────────

    function test_InvalidWithoutToken() public view {
        assertFalse(ccid.isValid(user3));
    }

    function test_InvalidAfterRevoke() public {
        vm.startPrank(provider);
        uint256 tokenId = ccid.mint(user1, 0);
        ccid.revoke(tokenId);
        vm.stopPrank();

        assertFalse(ccid.isValid(user1));
    }

    function test_InvalidAfterExpiry() public {
        uint256 expiry = block.timestamp + 1 hours;

        vm.prank(provider);
        ccid.mint(user1, expiry);

        assertTrue(ccid.isValid(user1));

        vm.warp(expiry + 1);
        assertFalse(ccid.isValid(user1));
    }
}
