// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBorrowerSpoke} from "../interfaces/IBorrowerSpoke.sol";

/**
 * @title ICTFExchange
 * @notice Minimal interface for the Polymarket Conditional Token Framework Exchange
 */
interface ICTFExchange {
    function fillOrder(
        bytes calldata order,
        uint256 fillAmount,
        bytes calldata signature
    ) external;
}

/**
 * @title IBorrowerSpokeDebt
 * @notice Minimal interface to clear internal vault debt mapping
 */
interface IBorrowerSpokeDebt {
    function getVaultDebt(uint256 vaultId) external view returns (uint256);
    function clearDebt(uint256 vaultId) external;
}

/**
 * @title PolymarketAdapter
 * @notice Execution layer for Protocol-Native Liquidations.
 *         Allows the Chainlink DON to submit an exact 0x or CTF order payload
 *         to dump ERC-1155 prediction collateral directly on the Polymarket CLOB.
 */
contract PolymarketAdapter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    address public borrowerSpoke;
    address public ctfExchange;
    IERC20 public usdc;

    event CollateralDumped(
        uint256 indexed vaultId,
        uint256 collateralSold,
        uint256 usdcReceived
    );

    constructor(
        address _admin,
        address _borrowerSpoke,
        address _ctfExchange,
        address _usdc
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        borrowerSpoke = _borrowerSpoke;
        ctfExchange = _ctfExchange;
        usdc = IERC20(_usdc);
    }

    function setCtfExchange(
        address _ctfExchange
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ctfExchange = _ctfExchange;
    }

    /**
     * @notice Executed by the Chainlink CRE Workflow to instantly dump toxic collateral
     * @param vaultId The ID of the LIQUIDATING vault
     * @param tokenContract The specific ERC-1155 condition contract
     * @param tokenId The Polymarket ERC-1155 Condition/Token ID
     * @param amount The number of shares to sell
     * @param orderPayload The signed CTF/0x order matching the best CLOB bids
     * @param signature The maker's signature for the order
     */
    function executeLiquidateSwap(
        uint256 vaultId,
        address tokenContract,
        uint256 tokenId,
        uint256 amount,
        bytes calldata orderPayload,
        bytes calldata signature
    ) external onlyRole(ORACLE_ROLE) nonReentrant {
        // 1. Pull the ERC-1155 collateral from the BorrowerSpoke
        IERC1155 token = IERC1155(tokenContract);

        // This requires BorrowerSpoke to `setApprovalForAll(address(this), true)`
        token.safeTransferFrom(
            borrowerSpoke,
            address(this),
            tokenId,
            amount,
            ""
        );

        // 2. Approve Polymarket CTF Exchange to spend the tokens
        token.setApprovalForAll(ctfExchange, true);

        uint256 usdcBalanceBefore = usdc.balanceOf(address(this));

        // 3. Execute the fill on Polymarket CTF
        // The payload instructs the CTF exchange to take `amount` of our tokens
        // and send the agreed USDC amount to `address(this)`
        ICTFExchange(ctfExchange).fillOrder(orderPayload, amount, signature);

        uint256 usdcReceived = usdc.balanceOf(address(this)) -
            usdcBalanceBefore;
        require(usdcReceived > 0, "No USDC recovered from CTF Exchage swap");

        // 4. Send the USDC to the BorrowerSpoke to settle debt and surplus
        usdc.forceApprove(borrowerSpoke, usdcReceived);
        IBorrowerSpoke(borrowerSpoke).handleLiquidationUSDC(
            vaultId,
            usdcReceived
        );

        emit CollateralDumped(vaultId, amount, usdcReceived);
    }
    // ──────────────────────────────────────────────
    // ERC-1155 Receiver required for safeTransfer
    // ──────────────────────────────────────────────

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
