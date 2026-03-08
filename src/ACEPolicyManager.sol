// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ICCIDToken
 * @notice Minimal interface for the CCID token used by ACEPolicyManager
 */
interface ICCIDToken {
    function isValid(address wallet) external view returns (bool);
}

/**
 * @title ACEPolicyManager
 * @notice On-chain compliance gateway for the Prediction Box protocol.
 *         Validates that wallets hold a valid CCID token before allowing
 *         participation in regulated protocol operations (e.g., LP deposits).
 *
 * @dev ACE = Access Control Engine. In production, this integrates with
 *      Chainlink's ACE infrastructure for cross-chain identity validation.
 *      This implementation uses CCID tokens as the compliance primitive.
 */
contract ACEPolicyManager is AccessControl {
    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    /// @notice The CCID token contract used for compliance checks
    ICCIDToken public ccidToken;

    /// @notice Whether compliance checking is enabled
    bool public complianceEnabled;

    /// @notice Wallets that are explicitly blocked (sanctions, fraud, etc.)
    mapping(address => bool) public blocklist;

    /// @notice Wallets that are explicitly allowed (override for testing)
    mapping(address => bool) public allowlist;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ComplianceStatusChanged(bool enabled);
    event WalletBlocked(address indexed wallet);
    event WalletUnblocked(address indexed wallet);
    event WalletAllowlisted(address indexed wallet);
    event CCIDTokenUpdated(address indexed newToken);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error WalletNotCompliant(address wallet);
    error WalletIsBlocked(address wallet);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address admin, address _ccidToken) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        ccidToken = ICCIDToken(_ccidToken);
        complianceEnabled = true;
    }

    // ──────────────────────────────────────────────
    // Compliance Check
    // ──────────────────────────────────────────────

    /**
     * @notice Check if a wallet is compliant with protocol policies
     * @param wallet The wallet to check
     * @return True if compliant
     */
    function checkCompliance(address wallet) external view returns (bool) {
        // Always block sanctioned/fraudulent wallets
        if (blocklist[wallet]) return false;

        // Always allow explicitly allowlisted wallets (testing/partners)
        if (allowlist[wallet]) return true;

        // If compliance is disabled, allow everyone
        if (!complianceEnabled) return true;

        // Check CCID validity
        return ccidToken.isValid(wallet);
    }

    /**
     * @notice Revert if wallet is not compliant (used as a modifier helper)
     * @param wallet The wallet to verify
     */
    function requireCompliance(address wallet) external view {
        if (blocklist[wallet]) revert WalletIsBlocked(wallet);

        if (allowlist[wallet]) return;
        if (!complianceEnabled) return;

        if (!ccidToken.isValid(wallet)) {
            revert WalletNotCompliant(wallet);
        }
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    function setComplianceEnabled(
        bool enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        complianceEnabled = enabled;
        emit ComplianceStatusChanged(enabled);
    }

    function setCCIDToken(
        address newToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ccidToken = ICCIDToken(newToken);
        emit CCIDTokenUpdated(newToken);
    }

    function blockWallet(address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blocklist[wallet] = true;
        emit WalletBlocked(wallet);
    }

    function unblockWallet(
        address wallet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        blocklist[wallet] = false;
        emit WalletUnblocked(wallet);
    }

    function addToAllowlist(
        address wallet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlist[wallet] = true;
        emit WalletAllowlisted(wallet);
    }

    function removeFromAllowlist(
        address wallet
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlist[wallet] = false;
    }
}
