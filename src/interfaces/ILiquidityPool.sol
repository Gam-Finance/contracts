// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILiquidityPool
 * @notice Interface for the USDC lending pool
 */
interface ILiquidityPool {
    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 amount, uint256 shares);
    event LoanDisbursed(uint256 indexed vaultId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed vaultId, uint256 amount, uint256 interest);
    event InterestAccrued(uint256 totalInterest, uint256 reserveAmount);

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    function deposit(uint256 amount) external;

    function withdraw(uint256 shares) external;

    function disburseLoan(
        uint256 vaultId,
        address borrower,
        uint256 amount
    ) external;

    function repayLoan(uint256 vaultId, uint256 amount) external;

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getUtilizationRate() external view returns (uint256);

    function getInterestRate() external view returns (uint256);

    function getTotalDeposits() external view returns (uint256);

    function getTotalBorrowed() external view returns (uint256);

    function getAvailableLiquidity() external view returns (uint256);
}
