// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title CCIDToken
 * @notice Cross-Chain Identity (CCID) — a non-transferable (soulbound) ERC-721
 *         token representing KYC/AML verification status.
 *
 * @dev Only authorized identity providers can mint CCID tokens.
 *      Tokens cannot be transferred between wallets (soulbound).
 *      Each wallet can hold at most one CCID token.
 *
 *      In the Prediction Box protocol, a valid CCID is required to
 *      deposit into the LiquidityPool (ACE compliance check).
 */
contract CCIDToken is ERC721, AccessControl {
    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant IDENTITY_PROVIDER_ROLE =
        keccak256("IDENTITY_PROVIDER_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    uint256 private _nextTokenId;

    /// @notice Maps wallet → tokenId (0 = no token)
    mapping(address => uint256) private _walletToken;

    /// @notice Expiry timestamp for each token (0 = no expiry)
    mapping(uint256 => uint256) public tokenExpiry;

    /// @notice Revocation status
    mapping(uint256 => bool) public isRevoked;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event CCIDMinted(
        address indexed wallet,
        uint256 indexed tokenId,
        uint256 expiry
    );
    event CCIDRevoked(uint256 indexed tokenId, address indexed wallet);
    event CCIDRenewed(uint256 indexed tokenId, uint256 newExpiry);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error AlreadyHasCCID(address wallet);
    error TransferDisabled();
    error TokenNotFound(uint256 tokenId);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(address admin) ERC721("Cross-Chain Identity", "CCID") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _nextTokenId = 1;
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Mint a CCID token for a KYC-verified wallet
     * @param wallet The wallet receiving the CCID
     * @param expiry Expiry timestamp (0 for no expiry)
     */
    function mint(
        address wallet,
        uint256 expiry
    ) external onlyRole(IDENTITY_PROVIDER_ROLE) returns (uint256 tokenId) {
        if (_walletToken[wallet] != 0) revert AlreadyHasCCID(wallet);

        tokenId = _nextTokenId++;
        _mint(wallet, tokenId);
        _walletToken[wallet] = tokenId;
        tokenExpiry[tokenId] = expiry;

        emit CCIDMinted(wallet, tokenId, expiry);
    }

    /**
     * @notice Revoke a CCID token (compromised identity, expired KYC, etc.)
     * @param tokenId The token to revoke
     */
    function revoke(uint256 tokenId) external onlyRole(IDENTITY_PROVIDER_ROLE) {
        address owner = ownerOf(tokenId);
        isRevoked[tokenId] = true;

        emit CCIDRevoked(tokenId, owner);
    }

    /**
     * @notice Renew the expiry on an existing CCID token
     * @param tokenId The token to renew
     * @param newExpiry New expiry timestamp
     */
    function renew(
        uint256 tokenId,
        uint256 newExpiry
    ) external onlyRole(IDENTITY_PROVIDER_ROLE) {
        if (_ownerOf(tokenId) == address(0)) revert TokenNotFound(tokenId);
        tokenExpiry[tokenId] = newExpiry;

        emit CCIDRenewed(tokenId, newExpiry);
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Check if a wallet has a valid (non-revoked, non-expired) CCID
     * @param wallet The wallet to check
     * @return valid True if the wallet holds a valid CCID
     */
    function isValid(address wallet) external view returns (bool valid) {
        uint256 tokenId = _walletToken[wallet];
        if (tokenId == 0) return false;
        if (isRevoked[tokenId]) return false;
        if (
            tokenExpiry[tokenId] != 0 && block.timestamp > tokenExpiry[tokenId]
        ) {
            return false;
        }
        return true;
    }

    /**
     * @notice Get the CCID token ID for a wallet
     * @param wallet The wallet to look up
     * @return tokenId (0 if no CCID)
     */
    function getTokenId(address wallet) external view returns (uint256) {
        return _walletToken[wallet];
    }

    // ──────────────────────────────────────────────
    // Soulbound: Block All Transfers
    // ──────────────────────────────────────────────

    /**
     * @dev Override _update to prevent transfers. Only mint (from=0) and
     *      burn (to=0) are allowed.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow minting (from == address(0)) and burning (to == address(0))
        if (from != address(0) && to != address(0)) {
            revert TransferDisabled();
        }

        // On burn, clear the wallet mapping
        if (to == address(0) && from != address(0)) {
            _walletToken[from] = 0;
        }

        return super._update(to, tokenId, auth);
    }

    // ──────────────────────────────────────────────
    // ERC-165 Support
    // ──────────────────────────────────────────────

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
