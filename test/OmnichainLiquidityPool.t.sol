// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";

/// @dev Mock USDC with 6 decimals for LiquidityPool tests
contract MockUSDCForPool is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) {
        return 6;
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract LiquidityPoolTest is Test {
    OmnichainLiquidityPool public pool;
    MockUSDCForPool public usdc;

    address public admin = makeAddr("admin");
    address public ccipReceiver = makeAddr("ccipReceiver");
    address public lender = makeAddr("lender");
    address public borrower = makeAddr("borrower");

    uint256 constant BASE_RATE = 0.02e18;
    uint256 constant KINK = 0.8e18;
    uint256 constant SLOPE1 = 0.04e18;
    uint256 constant SLOPE2 = 0.75e18;
    uint256 constant RESERVE_FACTOR = 0.1e18;

    function setUp() public {
        usdc = new MockUSDCForPool();

        vm.startPrank(admin);
        pool = new OmnichainLiquidityPool(
            address(0x123),
            address(usdc),
            admin,
            0.02e18, // baseRate
            0.80e18, // kink
            0.04e18, // slope1
            0.75e18, // slope2
            0.10e18 // reserveFactor
        );
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), ccipReceiver);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Deposit Tests
    // ──────────────────────────────────────────────

    function test_deposit_success() public {
        uint256 amount6 = 1000e6;
        uint256 amount18 = 1000e18;
        _mintAndApprove(lender, amount6);

        vm.prank(lender);
        pool.deposit(amount6);

        assertEq(pool.balanceOf(lender), amount18);
        assertEq(pool.getTotalDeposits(), amount18);
        assertEq(usdc.balanceOf(address(pool)), amount6);
    }

    function test_deposit_zeroReverts() public {
        vm.prank(lender);
        vm.expectRevert(OmnichainLiquidityPool.ZeroAmount.selector);
        pool.deposit(0);
    }

    function test_deposit_multipleDepositors() public {
        address lender2 = makeAddr("lender2");
        _mintAndApprove(lender, 1000e6);
        _mintAndApprove(lender2, 500e6);

        vm.prank(lender);
        pool.deposit(1000e6);

        vm.prank(lender2);
        pool.deposit(500e6);

        assertEq(pool.getTotalDeposits(), 1500e18);
        assertEq(pool.balanceOf(lender), 1000e18);
        assertEq(pool.balanceOf(lender2), 500e18);
    }

    // ──────────────────────────────────────────────
    // Withdraw Tests
    // ──────────────────────────────────────────────

    function test_withdraw_success() public {
        uint256 amount6 = 1000e6;
        uint256 amount18 = 1000e18;
        _mintAndApprove(lender, amount6);

        vm.prank(lender);
        pool.deposit(amount6);

        vm.prank(lender);
        pool.withdraw(amount18);

        assertEq(pool.balanceOf(lender), 0);
        assertEq(usdc.balanceOf(lender), amount6);
    }

    function test_withdraw_insufficientShares() public {
        _mintAndApprove(lender, 1000e6);

        vm.prank(lender);
        pool.deposit(1000e6);

        vm.prank(lender);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmnichainLiquidityPool.InsufficientShares.selector,
                2000e18,
                1000e18
            )
        );
        pool.withdraw(2000e18);
    }

    // ──────────────────────────────────────────────
    // Loan Disbursement Tests
    // ──────────────────────────────────────────────

    function test_disburseLoan_success() public {
        _mintAndApprove(lender, 10000e6);
        vm.prank(lender);
        pool.deposit(10000e6);

        vm.prank(ccipReceiver);
        pool.disburseLoan(1, borrower, 1000e18);

        assertEq(usdc.balanceOf(borrower), 1000e6);
        assertEq(pool.getTotalBorrowed(), 1000e18);
        assertEq(pool.vaultDebt(1), 1000e18);
    }

    function test_disburseLoan_insufficientLiquidity() public {
        _mintAndApprove(lender, 1000e6);
        vm.prank(lender);
        pool.deposit(1000e6);

        vm.prank(ccipReceiver);
        vm.expectRevert(
            abi.encodeWithSelector(
                OmnichainLiquidityPool.InsufficientLiquidity.selector,
                5000e18,
                1000e18
            )
        );
        pool.disburseLoan(1, borrower, 5000e18);
    }

    function test_disburseLoan_onlyCCIPReceiver() public {
        _mintAndApprove(lender, 10000e6);
        vm.prank(lender);
        pool.deposit(10000e6);

        vm.prank(borrower);
        vm.expectRevert();
        pool.disburseLoan(1, borrower, 1000e6);
    }

    // ──────────────────────────────────────────────
    // Repayment Tests
    // ──────────────────────────────────────────────

    function test_repayLoan_full() public {
        _mintAndApprove(lender, 10000e6);
        vm.prank(lender);
        pool.deposit(10000e6);

        vm.prank(ccipReceiver);
        pool.disburseLoan(1, borrower, 1000e18);

        usdc.mint(borrower, 1000e6);
        vm.startPrank(borrower);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayLoan(1, 1000e6);
        vm.stopPrank();

        assertEq(pool.vaultDebt(1), 0);
    }

    // ──────────────────────────────────────────────
    // Utilization & Interest Rate Tests
    // ──────────────────────────────────────────────

    function test_utilizationRate_empty() public view {
        assertEq(pool.getUtilizationRate(), 0);
    }

    function test_utilizationRate_afterBorrow() public {
        _mintAndApprove(lender, 10000e6);
        vm.prank(lender);
        pool.deposit(10000e6);

        vm.prank(ccipReceiver);
        pool.disburseLoan(1, borrower, 5000e18);

        assertEq(pool.getUtilizationRate(), 0.5e18);
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _mintAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(pool), amount);
    }
}
