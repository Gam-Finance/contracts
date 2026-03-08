// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPredictionBox
 * @notice Interface for the Prediction Box vault contract (source chain)
 */
interface IBorrowerSpoke {
    // ──────────────────────────────────────────────
    // Enums
    // ──────────────────────────────────────────────

    enum VaultStatus {
        PENDING, // Deposited, awaiting AI valuation
        ACTIVE, // Loan disbursed, position open
        LIQUIDATING, // Health factor breached, auction in progress
        CLOSED, // Loan repaid, collateral withdrawn
        FAILED // Cross-chain transaction failed, recovery needed
    }

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    struct Vault {
        address owner;
        address tokenContract; // Added for PolymarketAdapter execution
        uint256 conditionId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 loanAmount;
        uint256 collateralValue;
        uint256 healthFactor;
        uint64 hubChainSelector;
        uint256 requestedLTV;
        uint256 lastOracleUpdate;
        uint256 resolutionTimestamp; // When the underlying Polymarket market resolves
        VaultStatus status;
    }

    struct ValuationReport {
        uint256 vaultId;
        uint256 alpha; // 18 decimal fixed-point (e.g., 0.85e18)
        uint256 impliedProbability; // 18 decimal fixed-point
        uint256 collateralValue; // 18 decimal fixed-point
        uint256 healthFactor; // 18 decimal fixed-point
        uint256 timestamp;
    }

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event CollateralDeposited(
        uint256 indexed vaultId,
        address indexed owner,
        uint256 conditionId,
        uint256 outcomeIndex,
        uint256 amount,
        uint64 hubChainSelector,
        uint256 requestedLTV
    );

    event ValuationReceived(
        uint256 indexed vaultId,
        uint256 collateralValue,
        uint256 healthFactor,
        uint256 alpha
    );

    event LiquidationTriggered(uint256 indexed vaultId);

    event ResolutionCutoffTriggered(uint256 indexed vaultId);

    event CollateralWithdrawn(
        uint256 indexed vaultId,
        address indexed owner,
        uint256 amount
    );

    event CollateralRecovered(
        uint256 indexed vaultId,
        address indexed owner,
        uint256 amount
    );

    event VaultStatusChanged(
        uint256 indexed vaultId,
        VaultStatus oldStatus,
        VaultStatus newStatus
    );

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    function depositCollateral(
        address tokenContract,
        uint256 conditionId,
        uint256 outcomeIndex,
        uint256 amount,
        uint64 hubChainSelector,
        uint256 requestedLTV,
        uint256 resolutionTimestamp
    ) external;

    function receiveValuation(ValuationReport calldata report) external;

    function withdrawCollateral(uint256 vaultId) external;

    function recoverCollateral(uint256 vaultId) external;

    function handleLiquidationUSDC(
        uint256 vaultId,
        uint256 usdcAmount
    ) external;

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getVault(uint256 vaultId) external view returns (Vault memory);

    function getVaultCount() external view returns (uint256);

    function getVaultsByOwner(
        address owner
    ) external view returns (uint256[] memory);
}
