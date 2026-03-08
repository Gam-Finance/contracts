// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {IDutchAuction} from "../src/interfaces/IDutchAuction.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 100_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DutchAuctionTest is Test {
    DutchAuction public auction;
    OmnichainLiquidityPool public pool;
    MockUSDC public usdc;

    address public admin = address(1);
    address public oracle = address(2);
    address public bidder = address(3);
    address public lender = address(4);
    address public borrower = address(5);
    address public borrowerSpoke = makeAddr("borrowerSpoke");

    uint256 constant VAULT_ID = 1;
    uint256 constant DEBT = 1000 * 1e18; // 1000 USDC in 18 decimals

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();

        pool = new OmnichainLiquidityPool(
            address(0x123), // ccipRouter
            address(usdc),
            admin,
            0.02e18, // baseRate
            0.80e18, // kink
            0.04e18, // slope1
            0.75e18, // slope2
            0.10e18 // reserveFactor
        );

        auction = new DutchAuction(
            admin,
            address(usdc),
            address(pool),
            borrowerSpoke,
            1.10e18, // 110% start price premium
            0.50e18, // 50% floor
            6 hours, // duration
            0.05e18, // 5% keeper incentive
            address(0), // No CCIP for local basic test
            0
        );

        // Grant roles
        auction.grantRole(auction.ORACLE_ROLE(), oracle);
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), admin);
        pool.grantRole(pool.AUCTION_ROLE(), address(auction));

        // Seed pool: lender deposits 10,000 USDC
        usdc.transfer(lender, 10_000 * 10 ** 6);
        usdc.transfer(bidder, 10_000 * 10 ** 6);
        vm.stopPrank();

        vm.startPrank(lender);
        usdc.approve(address(pool), 10_000 * 10 ** 6);
        pool.deposit(10_000 * 10 ** 6);
        vm.stopPrank();

        // Create a loan (vault debt) via CCIP receiver role
        vm.prank(admin);
        pool.disburseLoan(VAULT_ID, borrower, DEBT);
    }

    // ──────────────────────────────────────────────
    // Start Auction
    // ──────────────────────────────────────────────

    function test_startAuction_readsLiveDebt() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        DutchAuction.Auction memory a = auction.getAuction(auctionId);
        assertEq(a.debtAmount, DEBT);
        assertEq(a.startPrice, (DEBT * 1.10e18) / 1e18); // 110% of debt
    }

    function test_startAuction_preventsDoubleLiquidation() public {
        vm.prank(oracle);
        auction.startAuction(VAULT_ID);

        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(
                DutchAuction.VaultAlreadyInAuction.selector,
                VAULT_ID
            )
        );
        auction.startAuction(VAULT_ID);
    }

    function test_startAuction_zeroDebtReverts() public {
        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(DutchAuction.ZeroDebt.selector, 999)
        );
        auction.startAuction(999); // non-existent vault
    }

    function test_startAuction_onlyOracle() public {
        vm.prank(bidder);
        vm.expectRevert();
        auction.startAuction(VAULT_ID);
    }

    // ──────────────────────────────────────────────
    // Bidding & Keeper Incentive
    // ──────────────────────────────────────────────

    function test_bid_paysKeeperIncentive() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        uint256 price = auction.getCurrentPrice(auctionId);
        uint256 bidderBalanceBefore = usdc.balanceOf(bidder);

        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(auctionId);
        vm.stopPrank();

        // Bidder paid the full price but got 5% back as keeper incentive
        uint256 incentive = (price * 0.05e18) / 1e18;
        uint256 netCost = (price - incentive) / 1e12;
        assertEq(usdc.balanceOf(bidder), bidderBalanceBefore - netCost);
    }

    function test_bid_settlesAuction() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        uint256 price = auction.getCurrentPrice(auctionId);

        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(auctionId);
        vm.stopPrank();

        DutchAuction.Auction memory a = auction.getAuction(auctionId);
        assertTrue(a.status == IDutchAuction.AuctionStatus.SETTLED);
        assertEq(a.settler, bidder);
    }

    function test_bid_clearsActiveAuction() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        uint256 price = auction.getCurrentPrice(auctionId);

        vm.startPrank(bidder);
        usdc.approve(address(auction), price);
        auction.bid(auctionId);
        vm.stopPrank();

        // Can start a new auction now
        assertEq(auction.activeAuctionForVault(VAULT_ID), 0);
    }

    // ──────────────────────────────────────────────
    // Price Decay
    // ──────────────────────────────────────────────

    function test_getCurrentPrice_atStart() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        uint256 price = auction.getCurrentPrice(auctionId);
        uint256 expectedStart = (DEBT * 1.10e18) / 1e18;
        assertEq(price, expectedStart);
    }

    function test_getCurrentPrice_decaysOverTime() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        uint256 startPrice = auction.getCurrentPrice(auctionId);

        // Advance 3 hours (half the 6h duration)
        vm.warp(block.timestamp + 3 hours);
        uint256 midPrice = auction.getCurrentPrice(auctionId);

        assertTrue(midPrice < startPrice);
        assertTrue(midPrice > 0);
    }

    function test_getCurrentPrice_zeroAfterExpiry() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        vm.warp(block.timestamp + 7 hours);
        assertEq(auction.getCurrentPrice(auctionId), 0);
    }

    // ──────────────────────────────────────────────
    // Fuzz Testing (Security & Math Invariants)
    // ──────────────────────────────────────────────

    function testFuzz_getCurrentPrice_NeverUnderflows(
        uint256 timeElapsed
    ) public {
        // Bound timeElapsed to reasonable auction window to avoid extreme uint bounds
        timeElapsed = bound(timeElapsed, 0, 100 days);

        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        vm.warp(block.timestamp + timeElapsed);

        // This should never revert due to underflow
        uint256 price = auction.getCurrentPrice(auctionId);

        if (timeElapsed >= 6 hours) {
            assertEq(price, 0);
        } else {
            assertTrue(price > 0);
        }
    }

    function testFuzz_bid_NeverOverpays(
        uint256 debtAmount,
        uint256 timeElapsed
    ) public {
        // Bound debt strictly within available seeded liquidity (10,000 USDC max)
        debtAmount = bound(debtAmount, 1e6, 9_000 * 10 ** 6);
        timeElapsed = bound(timeElapsed, 0, 5.9 hours);

        // Setup custom vault debt
        vm.prank(admin);
        pool.disburseLoan(99, borrower, debtAmount);

        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(99);

        vm.warp(block.timestamp + timeElapsed);
        uint256 price = auction.getCurrentPrice(auctionId);

        // Ensure price is within bounds
        uint256 maxPrice = (debtAmount * 1.10e18) / 1e18;
        assertTrue(price <= maxPrice);
    }

    // ──────────────────────────────────────────────
    // Bad Debt Socialization
    // ──────────────────────────────────────────────

    function test_settleExpired_socializesBadDebt() public {
        vm.prank(oracle);
        uint256 auctionId = auction.startAuction(VAULT_ID);

        // Let the auction expire
        vm.warp(block.timestamp + 7 hours);

        uint256 depositsBefore = pool.totalDeposited();

        auction.settleAuction(auctionId);

        // Bad debt should reduce totalDeposited
        assertLt(pool.totalDeposited(), depositsBefore);
        assertEq(pool.totalBadDebt(), DEBT);
        assertEq(auction.totalBadDebt(), DEBT);
    }

    // ──────────────────────────────────────────────
    // Batch Liquidation
    // ──────────────────────────────────────────────

    function test_batchAuctions() public {
        // Create a second loan
        vm.prank(admin);
        pool.disburseLoan(2, borrower, 500 * 10 ** 6);

        uint256[] memory vaultIds = new uint256[](2);
        vaultIds[0] = VAULT_ID;
        vaultIds[1] = 2;

        vm.prank(oracle);
        uint256[] memory auctionIds = auction.startBatchAuctions(vaultIds);

        assertEq(auctionIds.length, 2);

        DutchAuction.Auction memory a1 = auction.getAuction(auctionIds[0]);
        DutchAuction.Auction memory a2 = auction.getAuction(auctionIds[1]);

        assertEq(a1.debtAmount, DEBT);
        assertEq(a2.debtAmount, 500 * 10 ** 6);
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function test_setAuctionParams() public {
        vm.prank(admin);
        auction.setAuctionParams(1.20e18, 0.40e18, 12 hours, 0.10e18);

        assertEq(auction.startPricePremium(), 1.20e18);
        assertEq(auction.floorPriceFraction(), 0.40e18);
        assertEq(auction.defaultAuctionDuration(), 12 hours);
        assertEq(auction.keeperIncentive(), 0.10e18);
    }
}
