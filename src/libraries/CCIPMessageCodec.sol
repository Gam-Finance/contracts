// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CCIPMessageCodec
 * @notice ABI encoding/decoding helpers for CCIP cross-chain message payloads
 */
library CCIPMessageCodec {
    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    struct LoanRequest {
        uint256 vaultId;
        address borrower;
        uint256 requestedLTV;     // 18 decimal fixed-point
        uint256 conditionId;
        uint256 outcomeIndex;
        uint256 amount;           // Number of prediction shares locked
    }

    struct ValuationPayload {
        uint256 vaultId;
        uint256 alpha;            // 18 decimal fixed-point
        uint256 collateralValue;  // 18 decimal fixed-point
        uint256 healthFactor;     // 18 decimal fixed-point
        uint256 loanAmount;       // Calculated loan to disburse
        uint256 timestamp;
    }

    struct RepaymentMessage {
        uint256 vaultId;
        uint256 amountRepaid;
        bool fullRepayment;
    }

    struct GovernanceMessage {
        bytes32 parameterKey;
        uint256 parameterValue;
        uint256 effectiveTimestamp;
    }

    // ──────────────────────────────────────────────
    // Loan Request Encoding
    // ──────────────────────────────────────────────

    function encodeLoanRequest(LoanRequest memory request) internal pure returns (bytes memory) {
        return abi.encode(
            request.vaultId,
            request.borrower,
            request.requestedLTV,
            request.conditionId,
            request.outcomeIndex,
            request.amount
        );
    }

    function decodeLoanRequest(bytes memory data) internal pure returns (LoanRequest memory request) {
        (
            request.vaultId,
            request.borrower,
            request.requestedLTV,
            request.conditionId,
            request.outcomeIndex,
            request.amount
        ) = abi.decode(data, (uint256, address, uint256, uint256, uint256, uint256));
    }

    // ──────────────────────────────────────────────
    // Valuation Payload Encoding
    // ──────────────────────────────────────────────

    function encodeValuationPayload(ValuationPayload memory payload) internal pure returns (bytes memory) {
        return abi.encode(
            payload.vaultId,
            payload.alpha,
            payload.collateralValue,
            payload.healthFactor,
            payload.loanAmount,
            payload.timestamp
        );
    }

    function decodeValuationPayload(bytes memory data) internal pure returns (ValuationPayload memory payload) {
        (
            payload.vaultId,
            payload.alpha,
            payload.collateralValue,
            payload.healthFactor,
            payload.loanAmount,
            payload.timestamp
        ) = abi.decode(data, (uint256, uint256, uint256, uint256, uint256, uint256));
    }

    // ──────────────────────────────────────────────
    // Repayment Message Encoding
    // ──────────────────────────────────────────────

    function encodeRepaymentMessage(RepaymentMessage memory message) internal pure returns (bytes memory) {
        return abi.encode(message.vaultId, message.amountRepaid, message.fullRepayment);
    }

    function decodeRepaymentMessage(bytes memory data) internal pure returns (RepaymentMessage memory message) {
        (message.vaultId, message.amountRepaid, message.fullRepayment) =
            abi.decode(data, (uint256, uint256, bool));
    }

    // ──────────────────────────────────────────────
    // Governance Message Encoding
    // ──────────────────────────────────────────────

    function encodeGovernanceMessage(GovernanceMessage memory message) internal pure returns (bytes memory) {
        return abi.encode(message.parameterKey, message.parameterValue, message.effectiveTimestamp);
    }

    function decodeGovernanceMessage(bytes memory data) internal pure returns (GovernanceMessage memory message) {
        (message.parameterKey, message.parameterValue, message.effectiveTimestamp) =
            abi.decode(data, (bytes32, uint256, uint256));
    }
}
