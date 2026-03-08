// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    CCIPReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {
    IAny2EVMMessageReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {CCIPMessageCodec} from "./libraries/CCIPMessageCodec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";
import {CollateralMath} from "./libraries/CollateralMath.sol";

/**
 * @title HubReceiver
 * @notice CCIP destination endpoint. Receives LoanRequests from ALL supported Spoke chains.
 *         Once a CCIP LoanRequest and an AI Valuation are both received for a vault,
 *         it instructs the OmnichainLiquidityPool to disburse the loan cross-chain.
 */
contract HubReceiver is CCIPReceiver, AccessControl {
    using SafeERC20 for IERC20;
    // ──────────────────────────────────────────────
    // Roles & State
    // ──────────────────────────────────────────────

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant LOCAL_SPOKE_ROLE = keccak256("LOCAL_SPOKE_ROLE");

    ILiquidityPool public immutable liquidityPool;

    // Dynamic spoke network authorization
    mapping(uint64 => address) public authorizedSpokes;

    // Async state matching
    mapping(uint256 => CCIPMessageCodec.LoanRequest) public pendingRequests;
    mapping(uint256 => CCIPMessageCodec.ValuationPayload)
        public oracleValuations;
    mapping(uint256 => bool) public loanDisbursed;

    // ──────────────────────────────────────────────
    // Events & Errors
    // ──────────────────────────────────────────────

    event LoanRequestQueued(
        uint256 indexed vaultId,
        address borrower,
        uint256 amount
    );
    event ValuationQueued(
        uint256 indexed vaultId,
        uint256 collateralValue,
        uint256 healthFactor
    );
    event LoanDisbursedFromReceiver(
        uint256 indexed vaultId,
        address borrower,
        uint256 loanAmount
    );
    event SpokeAuthorized(uint64 chainSelector, address spokeAddress);

    error UnauthorizedSpokeChain(uint64 sourceChainSelector);
    error InvalidSenderAddress(address sender);
    error LoanAlreadyDisbursed(uint256 vaultId);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address ccipRouter,
        address _liquidityPool,
        address _admin
    ) CCIPReceiver(ccipRouter) {
        liquidityPool = ILiquidityPool(_liquidityPool);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Register a Spoke contract (e.g. BorrowerSpoke) for a specific CCIP network
     */
    function setAuthorizedSpoke(
        uint64 chainSelector,
        address spokeAddress
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        authorizedSpokes[chainSelector] = spokeAddress;
        emit SpokeAuthorized(chainSelector, spokeAddress);
    }

    // ──────────────────────────────────────────────
    // CCIP Message Handling (Loan Request)
    // ──────────────────────────────────────────────

    /**
     * @notice Handles the incoming CCIP message from BorrowerSpoke
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        address expectedSpoke = authorizedSpokes[
            any2EvmMessage.sourceChainSelector
        ];

        if (expectedSpoke == address(0)) {
            revert UnauthorizedSpokeChain(any2EvmMessage.sourceChainSelector);
        }

        address sender = abi.decode(any2EvmMessage.sender, (address));
        if (sender != expectedSpoke) {
            revert InvalidSenderAddress(sender);
        }

        // If message has tokens, it's a repayment (Direct Liquidation settlement)
        if (any2EvmMessage.destTokenAmounts.length == 1) {
            uint256 vaultId = abi.decode(any2EvmMessage.data, (uint256));
            uint256 amount6 = any2EvmMessage.destTokenAmounts[0].amount;
            address token = any2EvmMessage.destTokenAmounts[0].token;

            IERC20(token).forceApprove(address(liquidityPool), amount6);
            liquidityPool.repayLoan(vaultId, amount6);
            return;
        }

        // Otherwise it's a LoanRequest
        CCIPMessageCodec.LoanRequest memory request = CCIPMessageCodec
            .decodeLoanRequest(any2EvmMessage.data);

        if (loanDisbursed[request.vaultId])
            revert LoanAlreadyDisbursed(request.vaultId);

        pendingRequests[request.vaultId] = request;
        emit LoanRequestQueued(
            request.vaultId,
            request.borrower,
            request.amount
        );

        _tryDisburse(request.vaultId);
    }

    /**
     * @notice Direct entry point for local Spokes (bypass CCIP)
     */
    function receiveLocalLoanRequest(
        CCIPMessageCodec.LoanRequest calldata request
    ) external onlyRole(LOCAL_SPOKE_ROLE) {
        if (loanDisbursed[request.vaultId])
            revert LoanAlreadyDisbursed(request.vaultId);

        pendingRequests[request.vaultId] = request;
        emit LoanRequestQueued(
            request.vaultId,
            request.borrower,
            request.amount
        );

        // MOCK VALUATION for local testing: 1 share = 1 USDC (1:1)
        // Note: request.amount is in 18 decimals WAD in local mocks
        // Protocol math uses 18 decimals for collateral value
        uint256 mockCollateralValue = request.amount;
        uint256 mockLoanAmount = CollateralMath.calculateMaxLoan(
            mockCollateralValue,
            request.requestedLTV
        );

        _applyValuation(
            CCIPMessageCodec.ValuationPayload({
                vaultId: request.vaultId,
                alpha: 1e18, // 100% alpha for mock
                collateralValue: mockCollateralValue,
                healthFactor: 2e18, // safe health factor
                loanAmount: mockLoanAmount,
                timestamp: block.timestamp
            })
        );
    }

    /**
     * @notice Simulates receiving a loan request LOCALLY with a specific AI-provided valuation (Local Demo/Testing Only)
     */
    function receiveLocalLoanRequestWithAIValue(
        CCIPMessageCodec.LoanRequest calldata request,
        uint256 aiValuation
    ) external {
        // In this local bypass, we skip CCIP security checks for brevity.
        // In production, this data is retrieved by the DON via receiveValuation.

        pendingRequests[request.vaultId] = request;

        uint256 mockLoanAmount = CollateralMath.calculateMaxLoan(
            aiValuation,
            request.requestedLTV
        );

        _applyValuation(
            CCIPMessageCodec.ValuationPayload({
                vaultId: request.vaultId,
                alpha: 1e18, // 100% alpha for mock
                collateralValue: aiValuation,
                healthFactor: 2e18, // safe health factor
                loanAmount: mockLoanAmount,
                timestamp: block.timestamp
            })
        );
    }

    // ──────────────────────────────────────────────
    // Oracle Handling (Valuation)
    // ──────────────────────────────────────────────

    /**
     * @notice Receives the valuation report from the DON
     */
    function receiveValuation(
        CCIPMessageCodec.ValuationPayload calldata payload
    ) external onlyRole(ORACLE_ROLE) {
        _applyValuation(payload);
    }

    /**
     * @notice Internal logic to apply a valuation
     */
    function _applyValuation(
        CCIPMessageCodec.ValuationPayload memory payload
    ) internal {
        if (loanDisbursed[payload.vaultId])
            revert LoanAlreadyDisbursed(payload.vaultId);

        oracleValuations[payload.vaultId] = payload;
        emit ValuationQueued(
            payload.vaultId,
            payload.collateralValue,
            payload.healthFactor
        );

        _tryDisburse(payload.vaultId);
    }

    // ──────────────────────────────────────────────
    // Internal Logic
    // ──────────────────────────────────────────────

    function _tryDisburse(uint256 vaultId) internal {
        CCIPMessageCodec.LoanRequest memory request = pendingRequests[vaultId];
        CCIPMessageCodec.ValuationPayload memory valuation = oracleValuations[
            vaultId
        ];

        if (request.borrower == address(0) || valuation.timestamp == 0) {
            return;
        }

        uint256 approvedLoanAmount = CollateralMath.calculateMaxLoan(
            valuation.collateralValue,
            request.requestedLTV
        );

        loanDisbursed[vaultId] = true;

        liquidityPool.disburseLoan(
            vaultId,
            request.borrower,
            approvedLoanAmount
        );

        emit LoanDisbursedFromReceiver(
            vaultId,
            request.borrower,
            approvedLoanAmount
        );
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override(CCIPReceiver, AccessControl) returns (bool) {
        return
            interfaceId == type(IAny2EVMMessageReceiver).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
