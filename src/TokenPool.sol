// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    IERC1155Receiver
} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TokenPool
 * @notice Custom token pool for CCIP ERC-1155 lock/burn handling.
 *         Locks ERC-1155 prediction tokens on the source chain when
 *         collateral is being transferred cross-chain via CCIP.
 *
 * @dev This is a Phase 1 stub. Full CCIP TokenPool integration
 *      (extending the Chainlink TokenPool base contract) will be
 *      implemented in Phase 4 when CCIP lanes are configured.
 *
 *      The stub provides the core lock/release logic that the full
 *      implementation will wrap.
 */
contract TokenPool is IERC1155Receiver, AccessControl {
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    struct LockedPosition {
        address tokenContract;
        uint256 tokenId;
        uint256 amount;
        address originalOwner;
        bool released;
    }

    mapping(uint256 => LockedPosition) public lockedPositions;
    uint256 public nextLockId;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event TokensLocked(
        uint256 indexed lockId,
        address indexed tokenContract,
        uint256 tokenId,
        uint256 amount,
        address originalOwner
    );

    event TokensReleased(
        uint256 indexed lockId,
        address indexed recipient,
        uint256 amount
    );

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error LockNotFound(uint256 lockId);
    error AlreadyReleased(uint256 lockId);
    error ZeroAmount();

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        nextLockId = 1;
    }

    // ──────────────────────────────────────────────
    // Lock / Release (CCIP stub)
    // ──────────────────────────────────────────────

    /**
     * @notice Lock ERC-1155 tokens (called during cross-chain transfer initiation)
     * @param tokenContract Address of the ERC-1155 token contract
     * @param tokenId Token ID to lock
     * @param amount Amount to lock
     * @param originalOwner The owner of the tokens
     * @return lockId The ID of the locked position
     */
    function lockTokens(
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        address originalOwner
    ) external onlyRole(BRIDGE_ROLE) returns (uint256 lockId) {
        if (amount == 0) revert ZeroAmount();

        lockId = nextLockId++;

        // Transfer tokens from BorrowerSpoke to this pool
        IERC1155(tokenContract).safeTransferFrom(
            msg.sender, // BorrowerSpoke
            address(this),
            tokenId,
            amount,
            ""
        );

        lockedPositions[lockId] = LockedPosition({
            tokenContract: tokenContract,
            tokenId: tokenId,
            amount: amount,
            originalOwner: originalOwner,
            released: false
        });

        emit TokensLocked(
            lockId,
            tokenContract,
            tokenId,
            amount,
            originalOwner
        );
    }

    /**
     * @notice Release locked ERC-1155 tokens (called upon loan repayment or recovery)
     * @param lockId The lock ID to release
     * @param recipient The address to receive the tokens
     */
    function releaseTokens(
        uint256 lockId,
        address recipient
    ) external onlyRole(BRIDGE_ROLE) {
        LockedPosition storage pos = lockedPositions[lockId];
        if (pos.amount == 0) revert LockNotFound(lockId);
        if (pos.released) revert AlreadyReleased(lockId);

        pos.released = true;

        IERC1155(pos.tokenContract).safeTransferFrom(
            address(this),
            recipient,
            pos.tokenId,
            pos.amount,
            ""
        );

        emit TokensReleased(lockId, recipient, pos.amount);
    }

    // ──────────────────────────────────────────────
    // ERC-1155 Receiver
    // ──────────────────────────────────────────────

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(AccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
