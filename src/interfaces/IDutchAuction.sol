// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDutchAuction
 * @notice Interface for the Dutch Auction liquidation engine
 */
interface IDutchAuction {
    // ──────────────────────────────────────────────
    // Enums
    // ──────────────────────────────────────────────

    enum AuctionStatus {
        ACTIVE,
        SETTLED,
        EXPIRED
    }

    // ──────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────

    struct Auction {
        uint256 vaultId;
        uint256 debtAmount;
        uint256 startPrice;
        uint256 floorPrice;
        uint256 startTime;
        uint256 duration;
        address settler;
        uint256 settledPrice;
        AuctionStatus status;
    }

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 indexed vaultId,
        uint256 startPrice,
        uint256 floorPrice,
        uint256 duration
    );

    event AuctionBid(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 price
    );

    event AuctionSettled(
        uint256 indexed auctionId,
        address indexed settler,
        uint256 settledPrice,
        uint256 debtRepaid,
        uint256 surplus
    );

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    function startAuction(uint256 vaultId) external returns (uint256 auctionId);

    function bid(uint256 auctionId) external;

    function settleAuction(uint256 auctionId) external;

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getCurrentPrice(uint256 auctionId) external view returns (uint256);

    function getAuction(
        uint256 auctionId
    ) external view returns (Auction memory);
}
