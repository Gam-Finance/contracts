// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CCIDToken} from "../src/CCIDToken.sol";
import {ACEPolicyManager} from "../src/ACEPolicyManager.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock USDC for testing
contract TestUSDC is ERC20 {
    constructor() ERC20("Test USDC", "tUSDC") {
        _mint(msg.sender, 10_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract ACEPolicyManagerTest is Test {
    CCIDToken public ccid;
    ACEPolicyManager public ace;
    OmnichainLiquidityPool public pool;
    TestUSDC public usdc;

    address public admin = address(1);
    address public provider = address(2);
    address public compliantUser = address(3);
    address public nonCompliantUser = address(4);
    address public blockedUser = address(5);

    function setUp() public {
        vm.startPrank(admin);

        // Deploy CCID Token
        ccid = new CCIDToken(admin);
        ccid.grantRole(ccid.IDENTITY_PROVIDER_ROLE(), provider);

        // Deploy ACE Policy Manager
        ace = new ACEPolicyManager(admin, address(ccid));

        // Deploy USDC and LiquidityPool
        usdc = new TestUSDC();
        pool = new OmnichainLiquidityPool(
            address(0x123), // mock router
            address(usdc),
            admin,
            0.02e18, // baseRate
            0.80e18, // kink
            0.04e18, // slope1
            0.75e18, // slope2
            0.10e18 // reserveFactor
        );

        // Wire up ACE to the pool
        pool.setACEPolicyManager(address(ace));

        // Fund users with USDC
        usdc.transfer(compliantUser, 100_000 * 10 ** 6);
        usdc.transfer(nonCompliantUser, 100_000 * 10 ** 6);
        usdc.transfer(blockedUser, 100_000 * 10 ** 6);

        vm.stopPrank();

        // Mint CCID for compliant user
        vm.prank(provider);
        ccid.mint(compliantUser, 0);
    }

    // ──────────────────────────────────────────────
    // ACE Policy Manager Core
    // ──────────────────────────────────────────────

    function test_CompliantUserPasses() public view {
        assertTrue(ace.checkCompliance(compliantUser));
    }

    function test_NonCompliantUserFails() public view {
        assertFalse(ace.checkCompliance(nonCompliantUser));
    }

    function test_BlockedUserAlwaysFails() public {
        // Mint CCID for blocked user first
        vm.prank(provider);
        ccid.mint(blockedUser, 0);

        // Now block them
        vm.prank(admin);
        ace.blockWallet(blockedUser);

        assertFalse(ace.checkCompliance(blockedUser));
    }

    function test_AllowlistedUserAlwaysPasses() public {
        vm.prank(admin);
        ace.addToAllowlist(nonCompliantUser);

        assertTrue(ace.checkCompliance(nonCompliantUser));
    }

    function test_DisabledCompliancePassesAll() public {
        vm.prank(admin);
        ace.setComplianceEnabled(false);

        assertTrue(ace.checkCompliance(nonCompliantUser));
    }

    function test_RequireComplianceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ACEPolicyManager.WalletNotCompliant.selector,
                nonCompliantUser
            )
        );
        ace.requireCompliance(nonCompliantUser);
    }

    function test_RequireComplianceBlockedReverts() public {
        vm.prank(provider);
        ccid.mint(blockedUser, 0);

        vm.prank(admin);
        ace.blockWallet(blockedUser);

        vm.expectRevert(
            abi.encodeWithSelector(
                ACEPolicyManager.WalletIsBlocked.selector,
                blockedUser
            )
        );
        ace.requireCompliance(blockedUser);
    }

    // ──────────────────────────────────────────────
    // LiquidityPool Integration
    // ──────────────────────────────────────────────

    function test_CompliantUserCanDeposit() public {
        vm.startPrank(compliantUser);
        usdc.approve(address(pool), 1000 * 10 ** 6);
        pool.deposit(1000 * 10 ** 6);
        vm.stopPrank();

        assertEq(pool.balanceOf(compliantUser), 1000 * 1e18);
    }

    function test_NonCompliantUserCannotDeposit() public {
        vm.startPrank(nonCompliantUser);
        usdc.approve(address(pool), 1000 * 10 ** 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                OmnichainLiquidityPool.NotCompliant.selector,
                nonCompliantUser
            )
        );
        pool.deposit(1000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_DepositWorksWithoutPolicyManager() public {
        // Remove the policy manager
        vm.prank(admin);
        pool.setACEPolicyManager(address(0));

        // Non-compliant user should be able to deposit now
        vm.startPrank(nonCompliantUser);
        usdc.approve(address(pool), 1000 * 10 ** 6);
        pool.deposit(1000 * 10 ** 6);
        vm.stopPrank();

        assertEq(pool.balanceOf(nonCompliantUser), 1000 * 1e18);
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    function test_OnlyAdminCanBlockWallet() public {
        vm.prank(nonCompliantUser);
        vm.expectRevert();
        ace.blockWallet(compliantUser);
    }

    function test_UnblockWallet() public {
        vm.startPrank(admin);
        ace.blockWallet(compliantUser);
        assertFalse(ace.checkCompliance(compliantUser));

        ace.unblockWallet(compliantUser);
        assertTrue(ace.checkCompliance(compliantUser));
        vm.stopPrank();
    }

    function test_UpdateCCIDToken() public {
        CCIDToken newCcid = new CCIDToken(admin);

        vm.prank(admin);
        ace.setCCIDToken(address(newCcid));

        // Old CCID no longer valid since new contract is empty
        assertFalse(ace.checkCompliance(compliantUser));
    }
}
