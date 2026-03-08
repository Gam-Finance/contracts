// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FETestUSDC is ERC20 {
    constructor() ERC20("FE Test USDC", "feUSDC") {
        _mint(msg.sender, 100_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/**
 * @title FinancialEngineTest
 * @notice End-to-end integration test:
 *         deposit → borrow → health factor drop → liquidation → settlement → bad debt
 */
contract FinancialEngineTest is Test {
    DutchAuction public auctionEngine;
    OmnichainLiquidityPool public pool;
    FETestUSDC public usdc;

    address public admin = address(1);
    address public oracle = address(2);
    address public lender1 = address(3);
    address public lender2 = address(4);
    address public borrower = address(5);
    address public liquidator = address(6);
    address public borrowerSpoke = address(7);

    function setUp() public {
        vm.startPrank(admin);

        usdc = new FETestUSDC();

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

        auctionEngine = new DutchAuction(
            admin,
            address(usdc),
            address(pool),
            borrowerSpoke,
            1.10e18, // 110% premium
            0.50e18, // 50% floor
            6 hours,
            0.05e18, // 5% keeper incentive
            address(0), // No CCIP for local basic test
            0
        );

        // Grant roles
        auctionEngine.grantRole(auctionEngine.ORACLE_ROLE(), oracle);
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), admin);
        pool.grantRole(pool.AUCTION_ROLE(), address(auctionEngine));

        // Fund participants
        usdc.transfer(lender1, 50_000 * 10 ** 6);
        usdc.transfer(lender2, 30_000 * 10 ** 6);
        usdc.transfer(liquidator, 20_000 * 10 ** 6);

        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Test: Full Lifecycle — Deposit → Borrow → Liquidation → Settlement
    // ──────────────────────────────────────────────

    function test_fullLifecycle_depositBorrowLiquidate() public {
        // 1. Lenders deposit into pool
        vm.startPrank(lender1);
        usdc.approve(address(pool), 50_000 * 10 ** 6);
        pool.deposit(50_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(lender2);
        usdc.approve(address(pool), 30_000 * 10 ** 6);
        pool.deposit(30_000 * 10 ** 6);
        vm.stopPrank();

        assertEq(pool.totalDeposited(), 80_000 * 1e18);

        // 2. Borrower gets a loan via CCIP (simulated by admin role)
        uint256 loanAmount18 = 5_000 * 1e18;
        uint256 loanAmount6 = 5_000 * 1e6;
        vm.prank(admin);
        pool.disburseLoan(1, borrower, loanAmount18);

        assertEq(pool.vaultDebt(1), loanAmount18);
        assertEq(usdc.balanceOf(borrower), loanAmount6);

        // 3. Check utilization increased
        uint256 utilization = pool.getUtilizationRate();
        assertTrue(utilization > 0);

        // 4. Oracle triggers liquidation
        vm.prank(oracle);
        uint256 auctionId = auctionEngine.startAuction(1);

        DutchAuction.Auction memory a = auctionEngine.getAuction(auctionId);
        assertEq(a.debtAmount, loanAmount18);

        // 5. Liquidator bids at current price
        uint256 price = auctionEngine.getCurrentPrice(auctionId);
        assertTrue(price > 0);

        vm.startPrank(liquidator);
        usdc.approve(address(auctionEngine), price);
        auctionEngine.bid(auctionId);
        vm.stopPrank();

        // 6. Verify auction settled
        a = auctionEngine.getAuction(auctionId);
        assertTrue(uint(a.status) == uint(IDutchAuction.AuctionStatus.SETTLED));
        assertEq(a.settler, liquidator);
    }

    // ──────────────────────────────────────────────
    // Test: Bad Debt Path — Auction Expires
    // ──────────────────────────────────────────────

    function test_badDebt_expiredAuctionSocializesLoss() public {
        // 1. Lender deposits
        vm.startPrank(lender1);
        usdc.approve(address(pool), 50_000 * 10 ** 6);
        pool.deposit(50_000 * 10 ** 6);
        vm.stopPrank();

        // 2. Borrower gets a loan
        uint256 loanAmount18 = 10_000 * 1e18;
        vm.prank(admin);
        pool.disburseLoan(1, borrower, loanAmount18);

        uint256 depositsBefore = pool.totalDeposited();

        // 3. Auction started but nobody bids
        vm.prank(oracle);
        uint256 auctionId = auctionEngine.startAuction(1);

        // 4. Auction expires
        vm.warp(block.timestamp + 7 hours);
        auctionEngine.settleAuction(auctionId);

        // 5. Bad debt socialized
        uint256 depositsAfter = pool.totalDeposited();
        assertTrue(depositsAfter < depositsBefore);
        assertEq(pool.totalBadDebt(), loanAmount18);

        // 6. Share value decreased for lender
        // lender1 has 50k shares but deposits decreased by loanAmount
        uint256 lender1Shares = pool.balanceOf(lender1);
        assertTrue(lender1Shares > 0);
    }

    // ──────────────────────────────────────────────
    // Test: Interest Accrual Over Time
    // ──────────────────────────────────────────────

    function test_interestAccrual_increasesTotalBorrowed() public {
        vm.startPrank(lender1);
        usdc.approve(address(pool), 50_000 * 10 ** 6);
        pool.deposit(50_000 * 10 ** 6);
        vm.stopPrank();

        vm.prank(admin);
        pool.disburseLoan(1, borrower, 10_000 * 1e18);

        uint256 borrowedBefore = pool.totalBorrowed();

        // Advance 30 days
        vm.warp(block.timestamp + 30 days);

        // Trigger accrual via a deposit
        vm.startPrank(lender2);
        usdc.approve(address(pool), 1 * 10 ** 6);
        pool.deposit(1 * 10 ** 6);
        vm.stopPrank();

        assertTrue(pool.totalBorrowed() > borrowedBefore);
    }

    // ──────────────────────────────────────────────
    // Test: Category Rate Multiplier
    // ──────────────────────────────────────────────

    function test_categoryRateMultiplier() public {
        bytes32 geoCategory = keccak256("geopolitical");

        // Set 1.5x multiplier for geopolitical markets
        vm.prank(admin);
        pool.setCategoryRateMultiplier(geoCategory, 1.5e18);

        vm.startPrank(lender1);
        usdc.approve(address(pool), 50_000 * 10 ** 6);
        pool.deposit(50_000 * 10 ** 6);
        vm.stopPrank();

        vm.prank(admin);
        pool.disburseLoan(1, borrower, 10_000 * 1e18);

        uint256 baseRate = pool.getInterestRate();
        uint256 categoryRate = pool.getCategoryInterestRate(geoCategory);

        // Category rate should be ~1.5x the base rate
        assertGt(categoryRate, baseRate);
        // Allow for rounding by checking within 1 wei
        assertApproxEqAbs(categoryRate, (baseRate * 1.5e18) / 1e18, 1);
    }

    // ──────────────────────────────────────────────
    // Test: CollateralMath — PWERM Formula Verification
    // ──────────────────────────────────────────────

    function test_pwermFormula_basicCase() public pure {
        // P=0.65, α=0.85, MRP=0.12, T=86400s, λ=0.001e18/s
        uint256 value = CollateralMath.calculateCollateralValue(
            0.65e18, // pImplied
            0.85e18, // alpha
            0.12e18, // mrpCategory
            86400, // tRemaining (1 day)
            0.001e18 // lambda
        );

        // Result should be in range (0, 0.65)
        assertTrue(value > 0);
        assertTrue(value < 0.65e18);
    }

    function test_pwermFormula_zeroTimeDecay() public pure {
        // With T=0, decay = e^0 = 1, so value = P × α × (1 - MRP)
        uint256 value = CollateralMath.calculateCollateralValue(
            0.65e18,
            0.85e18,
            0.12e18,
            0, // T = 0
            0.001e18
        );

        // Expected: 0.65 × 0.85 × 0.88 = 0.4862
        assertApproxEqAbs(value, 0.4862e18, 0.001e18);
    }

    function test_healthFactor_liquidationThreshold() public pure {
        // collateral worth 1000, debt 800 → HF = 1.25
        uint256 hf = CollateralMath.calculateHealthFactor(1000e18, 800e18);
        assertEq(hf, 1.25e18);

        // Not liquidatable at 1.20 maintenance margin
        assertFalse(CollateralMath.isLiquidatable(hf, 1.20e18));

        // Liquidatable at 1.30 maintenance margin
        assertTrue(CollateralMath.isLiquidatable(hf, 1.30e18));
    }
}
