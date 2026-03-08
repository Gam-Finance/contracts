// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IRouterClient
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LenderSpoke
 * @notice Origin chain contract for lenders. Accepts USDC deposits and bridging
 *         them to the OmnichainLiquidityPool on the Hub via CCIP Programmable Token Transfers.
 */
contract LenderSpoke is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Constants & Roles
    // ──────────────────────────────────────────────

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ──────────────────────────────────────────────
    // State Variables
    // ──────────────────────────────────────────────

    IRouterClient public immutable ccipRouter;
    IERC20 public immutable underlyingAsset; // USDC
    IERC20 public immutable linkToken; // LINK for CCIP fees

    /// @notice Address of the central OmnichainLiquidityPool on the Hub
    address public hubPoolAddress;

    /// @notice CCIP Chain Selector for the Hub
    uint64 public hubChainSelector;

    // ──────────────────────────────────────────────
    // Events & Errors
    // ──────────────────────────────────────────────

    event HubUpdated(uint64 hubChainSelector, address poolAddress);
    event DepositInitiated(
        address indexed lender,
        uint256 amount,
        bytes32 messageId
    );

    error ZeroAddress();
    error ZeroAmount();
    error InvalidHub();
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _admin,
        address _ccipRouter,
        address _usdc,
        address _link
    ) {
        if (
            _admin == address(0) ||
            _ccipRouter == address(0) ||
            _usdc == address(0)
        ) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);

        ccipRouter = IRouterClient(_ccipRouter);
        underlyingAsset = IERC20(_usdc);
        if (_link != address(0)) {
            linkToken = IERC20(_link);
        }
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    function setHubTarget(
        uint64 _hubRouterSelector,
        address _hubPool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_hubPool == address(0)) revert ZeroAddress();
        if (_hubRouterSelector == 0) revert InvalidHub();

        hubChainSelector = _hubRouterSelector;
        hubPoolAddress = _hubPool;

        emit HubUpdated(hubChainSelector, hubPoolAddress);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Deposit USDC to the Omnichain hub.
     * @param amount The amount of USDC to supply.
     */
    function depositToHub(
        uint256 amount
    ) external whenNotPaused nonReentrant returns (bytes32 messageId) {
        if (amount == 0) revert ZeroAmount();
        if (hubChainSelector == 0 || hubPoolAddress == address(0))
            revert InvalidHub();

        // 1. Pull USDC from Lender
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);

        // 2. Build CCIP Token Transfer Payload
        // By embedding msg.sender in `data`, the Hub knows who to credit the pbUSDC to
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({
            token: address(underlyingAsset),
            amount: amount
        });

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(hubPoolAddress),
            data: abi.encode(msg.sender), // Forward the original depositor address
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                // Use strict GAS limit to prevent out-of-gas on receiver execution
                Client.EVMExtraArgsV1({gasLimit: 400_000})
            ),
            feeToken: address(linkToken) == address(0)
                ? address(0)
                : address(linkToken)
        });

        // 3. Approve CCIP Router to take tokens
        underlyingAsset.forceApprove(address(ccipRouter), amount);

        // 4. Calculate and Pay Fees
        uint256 fees = ccipRouter.getFee(hubChainSelector, evm2AnyMessage);

        if (address(linkToken) != address(0)) {
            if (fees > linkToken.balanceOf(address(this))) {
                revert NotEnoughBalance(
                    linkToken.balanceOf(address(this)),
                    fees
                );
            }
            linkToken.forceApprove(address(ccipRouter), fees);
            messageId = ccipRouter.ccipSend(hubChainSelector, evm2AnyMessage);
        } else {
            if (fees > address(this).balance) {
                revert NotEnoughBalance(address(this).balance, fees);
            }
            messageId = ccipRouter.ccipSend{value: fees}(
                hubChainSelector,
                evm2AnyMessage
            );
        }

        emit DepositInitiated(msg.sender, amount, messageId);
        return messageId;
    }

    // ──────────────────────────────────────────────
    // Utilities
    // ──────────────────────────────────────────────

    /// @notice Allows the owner to withdraw native ETH if stuck
    function withdrawNative(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool success, ) = to.call{value: address(this).balance}("");
        require(success, "Transfer failed");
    }

    /// @notice Allows the contract to receive native gas (for CCIP fees)
    receive() external payable {}
}
