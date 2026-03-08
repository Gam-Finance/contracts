// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    TimelockController
} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Governance
 * @notice Decentralized parameter management for the Prediction Box protocol.
 *         Uses a Timelock-based pattern where parameter changes are proposed,
 *         delayed, and then executed. Includes an emergency Guardian role
 *         with limited powers (pause only).
 *
 * @dev In Phase 4, governance will use CCIP Arbitrary Messaging to
 *      propagate parameter changes across all deployed chains.
 */
contract Governance is AccessControl {
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    uint256 public maxLTV;
    uint256 public maintenanceMargin;
    uint256 public timeDecayConstant;
    uint256 public reserveFactor;
    uint256 public minAuctionDuration;
    uint256 public resolutionCutoff; // seconds before resolution to trigger auto-liquidation
    uint256 public minTimeToResolution; // minimum time-to-resolution to accept collateral

    /// @notice Market Risk Premium per category (bytes32 key → 18 decimal value)
    mapping(bytes32 => uint256) public categoryRiskPremiums;

    /// @notice Minimum delay before a parameter change takes effect (seconds)
    uint256 public executionDelay;

    // ──────────────────────────────────────────────
    // Proposal Queue
    // ──────────────────────────────────────────────

    struct ParameterProposal {
        bytes32 parameterKey;
        uint256 newValue;
        uint256 proposedAt;
        uint256 executionTime;
        bool executed;
        bool cancelled;
        address proposer;
    }

    mapping(uint256 => ParameterProposal) public proposals;
    uint256 public nextProposalId;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event ParameterProposed(
        uint256 indexed proposalId,
        bytes32 indexed parameterKey,
        uint256 newValue,
        uint256 executionTime,
        address proposer
    );

    event ParameterExecuted(
        uint256 indexed proposalId,
        bytes32 indexed parameterKey,
        uint256 oldValue,
        uint256 newValue
    );

    event ProposalCancelled(uint256 indexed proposalId);

    event CategoryRiskPremiumSet(bytes32 indexed category, uint256 premium);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ProposalNotFound(uint256 proposalId);
    error ProposalAlreadyExecuted(uint256 proposalId);
    error ProposalCancelledError(uint256 proposalId);
    error ExecutionDelayNotMet(uint256 executionTime, uint256 currentTime);
    error InvalidParameterKey(bytes32 key);
    error ParameterOutOfBounds(bytes32 key, uint256 value);

    // ──────────────────────────────────────────────
    // Parameter Keys
    // ──────────────────────────────────────────────

    bytes32 public constant KEY_MAX_LTV = keccak256("MAX_LTV");
    bytes32 public constant KEY_MAINTENANCE_MARGIN =
        keccak256("MAINTENANCE_MARGIN");
    bytes32 public constant KEY_TIME_DECAY_CONSTANT =
        keccak256("TIME_DECAY_CONSTANT");
    bytes32 public constant KEY_RESERVE_FACTOR = keccak256("RESERVE_FACTOR");
    bytes32 public constant KEY_MIN_AUCTION_DURATION =
        keccak256("MIN_AUCTION_DURATION");
    bytes32 public constant KEY_RESOLUTION_CUTOFF =
        keccak256("RESOLUTION_CUTOFF");
    bytes32 public constant KEY_MIN_TIME_TO_RESOLUTION =
        keccak256("MIN_TIME_TO_RESOLUTION");

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address admin,
        uint256 _maxLTV,
        uint256 _maintenanceMargin,
        uint256 _timeDecayConstant,
        uint256 _reserveFactor,
        uint256 _minAuctionDuration,
        uint256 _executionDelay
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PROPOSER_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        maxLTV = _maxLTV;
        maintenanceMargin = _maintenanceMargin;
        timeDecayConstant = _timeDecayConstant;
        reserveFactor = _reserveFactor;
        minAuctionDuration = _minAuctionDuration;
        resolutionCutoff = 24 hours; // Default: 24 hours
        minTimeToResolution = 48 hours; // Default: 48 hours
        executionDelay = _executionDelay;
        nextProposalId = 1;
    }

    // ──────────────────────────────────────────────
    // Proposal Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Propose a parameter change (subject to execution delay)
     */
    function proposeParameterChange(
        bytes32 parameterKey,
        uint256 newValue
    ) external onlyRole(PROPOSER_ROLE) returns (uint256 proposalId) {
        _validateParameter(parameterKey, newValue);

        proposalId = nextProposalId++;
        uint256 executionTime = block.timestamp + executionDelay;

        proposals[proposalId] = ParameterProposal({
            parameterKey: parameterKey,
            newValue: newValue,
            proposedAt: block.timestamp,
            executionTime: executionTime,
            executed: false,
            cancelled: false,
            proposer: msg.sender
        });

        emit ParameterProposed(
            proposalId,
            parameterKey,
            newValue,
            executionTime,
            msg.sender
        );
    }

    /**
     * @notice Execute a parameter change after the delay period
     */
    function executeProposal(
        uint256 proposalId
    ) external onlyRole(EXECUTOR_ROLE) {
        ParameterProposal storage proposal = proposals[proposalId];
        if (proposal.proposedAt == 0) revert ProposalNotFound(proposalId);
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);
        if (proposal.cancelled) revert ProposalCancelledError(proposalId);
        if (block.timestamp < proposal.executionTime) {
            revert ExecutionDelayNotMet(
                proposal.executionTime,
                block.timestamp
            );
        }

        proposal.executed = true;
        uint256 oldValue = _getParameter(proposal.parameterKey);
        _setParameter(proposal.parameterKey, proposal.newValue);

        emit ParameterExecuted(
            proposalId,
            proposal.parameterKey,
            oldValue,
            proposal.newValue
        );
    }

    /**
     * @notice Cancel a pending proposal
     */
    function cancelProposal(
        uint256 proposalId
    ) external onlyRole(GUARDIAN_ROLE) {
        ParameterProposal storage proposal = proposals[proposalId];
        if (proposal.proposedAt == 0) revert ProposalNotFound(proposalId);
        if (proposal.executed) revert ProposalAlreadyExecuted(proposalId);

        proposal.cancelled = true;

        emit ProposalCancelled(proposalId);
    }

    // ──────────────────────────────────────────────
    // Category Risk Premiums (immediate, admin-only)
    // ──────────────────────────────────────────────

    function setCategoryRiskPremium(
        bytes32 category,
        uint256 premium
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (premium > 1e18) revert ParameterOutOfBounds(category, premium);
        categoryRiskPremiums[category] = premium;
        emit CategoryRiskPremiumSet(category, premium);
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getProposal(
        uint256 proposalId
    ) external view returns (ParameterProposal memory) {
        return proposals[proposalId];
    }

    function getAllParameters()
        external
        view
        returns (
            uint256 _maxLTV,
            uint256 _maintenanceMargin,
            uint256 _timeDecayConstant,
            uint256 _reserveFactor,
            uint256 _minAuctionDuration,
            uint256 _resolutionCutoff,
            uint256 _minTimeToResolution
        )
    {
        return (
            maxLTV,
            maintenanceMargin,
            timeDecayConstant,
            reserveFactor,
            minAuctionDuration,
            resolutionCutoff,
            minTimeToResolution
        );
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _getParameter(bytes32 key) internal view returns (uint256) {
        if (key == KEY_MAX_LTV) return maxLTV;
        if (key == KEY_MAINTENANCE_MARGIN) return maintenanceMargin;
        if (key == KEY_TIME_DECAY_CONSTANT) return timeDecayConstant;
        if (key == KEY_RESERVE_FACTOR) return reserveFactor;
        if (key == KEY_MIN_AUCTION_DURATION) return minAuctionDuration;
        if (key == KEY_RESOLUTION_CUTOFF) return resolutionCutoff;
        if (key == KEY_MIN_TIME_TO_RESOLUTION) return minTimeToResolution;
        revert InvalidParameterKey(key);
    }

    function _setParameter(bytes32 key, uint256 value) internal {
        if (key == KEY_MAX_LTV) {
            maxLTV = value;
            return;
        }
        if (key == KEY_MAINTENANCE_MARGIN) {
            maintenanceMargin = value;
            return;
        }
        if (key == KEY_TIME_DECAY_CONSTANT) {
            timeDecayConstant = value;
            return;
        }
        if (key == KEY_RESERVE_FACTOR) {
            reserveFactor = value;
            return;
        }
        if (key == KEY_MIN_AUCTION_DURATION) {
            minAuctionDuration = value;
            return;
        }
        if (key == KEY_RESOLUTION_CUTOFF) {
            resolutionCutoff = value;
            return;
        }
        if (key == KEY_MIN_TIME_TO_RESOLUTION) {
            minTimeToResolution = value;
            return;
        }
        revert InvalidParameterKey(key);
    }

    function _validateParameter(bytes32 key, uint256 value) internal pure {
        if (key == KEY_MAX_LTV && value > 0.95e18)
            revert ParameterOutOfBounds(key, value);
        if (key == KEY_MAINTENANCE_MARGIN && (value < 1e18 || value > 2e18))
            revert ParameterOutOfBounds(key, value);
        if (key == KEY_RESERVE_FACTOR && value > 0.5e18)
            revert ParameterOutOfBounds(key, value);
        if (key == KEY_MIN_AUCTION_DURATION && value < 1 hours)
            revert ParameterOutOfBounds(key, value);
        // Resolution cutoff: must be >= 1 hour and <= 7 days
        if (key == KEY_RESOLUTION_CUTOFF && (value < 1 hours || value > 7 days))
            revert ParameterOutOfBounds(key, value);
        // Min time to resolution: must be >= 1 hour and <= 30 days
        if (
            key == KEY_MIN_TIME_TO_RESOLUTION &&
            (value < 1 hours || value > 30 days)
        ) revert ParameterOutOfBounds(key, value);

        // TIME_DECAY_CONSTANT has no upper bound restriction by default
        if (
            key != KEY_MAX_LTV &&
            key != KEY_MAINTENANCE_MARGIN &&
            key != KEY_TIME_DECAY_CONSTANT &&
            key != KEY_RESERVE_FACTOR &&
            key != KEY_MIN_AUCTION_DURATION &&
            key != KEY_RESOLUTION_CUTOFF &&
            key != KEY_MIN_TIME_TO_RESOLUTION
        ) {
            revert InvalidParameterKey(key);
        }
    }
}
