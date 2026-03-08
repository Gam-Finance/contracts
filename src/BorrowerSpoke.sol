// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    IERC1155Receiver
} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    CCIPReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {
    IAny2EVMMessageReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";

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
import {IBorrowerSpoke} from "./interfaces/IBorrowerSpoke.sol";
import {CollateralMath} from "./libraries/CollateralMath.sol";
import {CCIPMessageCodec} from "./libraries/CCIPMessageCodec.sol";

/**
 * @title BorrowerSpoke
 * @notice Origin chain contract for borrowers. Escrows ERC-1155 prediction market
 *         collateral and triggers a cross-chain loan request to the central Hub.
 *
 * @dev Key design decisions:
 *      - ERC-1155 tokens are escrowed directly (not wrapped) on the source chain
 *      - CollateralDeposited events are consumed by CRE DON for AI valuation
 *      - Oracle reports update health factors; liquidation is delegated to DutchAuction
 *      - Vault state machine prevents invalid transitions
 */
contract BorrowerSpoke is
    IBorrowerSpoke,
    IERC1155Receiver,
    CCIPReceiver,
    AccessControl,
    Pausable,
    ReentrancyGuard
{
    using CollateralMath for uint256;
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(uint256 => Vault) private _vaults;
    mapping(address => uint256[]) private _ownerVaults;
    mapping(uint256 => uint256) private _vaultSurplus; // vaultId => surplus amount (6 decimals)
    uint256 private _nextVaultId;

    /// @notice Maximum allowed LTV ratio (18 decimals)
    uint256 public maxLTV;

    /// @notice Maintenance margin — health factor below this triggers liquidation
    uint256 public maintenanceMargin;

    /// @notice Maximum staleness for oracle reports (seconds)
    uint256 public oracleStalenessTolerance;

    /// @notice Address of the PolymarketAdapter authorized to dump collateral
    address public polymarketAdapter;

    /// @notice Force-liquidate vaults within this many seconds of market resolution
    uint256 public resolutionCutoff;

    /// @notice Minimum time-to-resolution required when opening a new vault
    uint256 public minTimeToResolution;

    /// @notice CCIP Router
    IRouterClient public immutable ccipRouter;

    /// @notice Hub Receiver address on the destination chain
    address public hubReceiver;

    /// @notice LINK token for fees
    IERC20 public linkToken;

    /// @notice Underlying stablecoin (USDC) for surplus claims
    IERC20 public usdcToken;

    /// @notice The CCIP chain selector for the current local chain (for bypass)
    uint64 public localChainSelector;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error ZeroAmount();
    error InvalidLTV(uint256 requestedLTV, uint256 maxAllowed);
    error VaultNotFound(uint256 vaultId);
    error NotVaultOwner(uint256 vaultId, address caller);
    error InvalidStatusTransition(VaultStatus current, VaultStatus target);
    error LoanNotRepaid(uint256 vaultId, uint256 outstandingDebt);
    error InsufficientProtocolFees();
    error OracleReportStale(uint256 lastUpdate, uint256 tolerance);
    error MarketTooCloseToResolution(
        uint256 resolutionTimestamp,
        uint256 minTimeRequired
    );
    error ResolutionCutoffNotReached(
        uint256 resolutionTimestamp,
        uint256 cutoff
    );
    error VaultNotActive(uint256 vaultId, VaultStatus currentStatus);

    event SurplusClaimed(
        uint256 indexed vaultId,
        address indexed owner,
        uint256 amount
    );

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address admin,
        address _ccipRouter,
        uint256 _maxLTV,
        uint256 _maintenanceMargin,
        uint256 _oracleStalenessTolerance,
        uint64 _localChainSelector
    ) CCIPReceiver(_ccipRouter) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        ccipRouter = IRouterClient(_ccipRouter);
        maxLTV = _maxLTV;
        maintenanceMargin = _maintenanceMargin;
        oracleStalenessTolerance = _oracleStalenessTolerance;
        resolutionCutoff = 24 hours; // Default: 24 hours
        minTimeToResolution = 48 hours; // Default: 48 hours
        localChainSelector = _localChainSelector;
        _nextVaultId = 1; // Start from 1 (0 = invalid)
    }

    /**
     * @notice Set the Hub Receiver address and LINK token
     */
    function setHubParams(
        address _hubReceiver,
        address _linkToken,
        address _usdcToken
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hubReceiver = _hubReceiver;
        if (_linkToken != address(0)) {
            linkToken = IERC20(_linkToken);
        }
        if (_usdcToken != address(0)) {
            usdcToken = IERC20(_usdcToken);
        }
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Deposit ERC-1155 prediction tokens as collateral and request a cross-chain loan
     * @dev Emits CollateralDeposited event consumed by CRE Workflow DON
     */
    function depositCollateral(
        address tokenContract,
        uint256 conditionId,
        uint256 outcomeIndex,
        uint256 amount,
        uint64 hubChainSelector,
        uint256 requestedLTV,
        uint256 resolutionTimestamp
    ) external override whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (requestedLTV > maxLTV) revert InvalidLTV(requestedLTV, maxLTV);

        // Borrow gate: reject markets that are too close to resolution
        if (resolutionTimestamp < block.timestamp + minTimeToResolution) {
            revert MarketTooCloseToResolution(
                resolutionTimestamp,
                minTimeToResolution
            );
        }

        // Transfer ERC-1155 tokens into this contract
        IERC1155(tokenContract).safeTransferFrom(
            msg.sender,
            address(this),
            conditionId, // tokenId = conditionId for Gnosis CTF
            amount,
            ""
        );

        // Create vault
        uint256 vaultId = _nextVaultId++;

        _vaults[vaultId] = Vault({
            owner: msg.sender,
            tokenContract: tokenContract,
            conditionId: conditionId,
            outcomeIndex: outcomeIndex,
            amount: amount,
            loanAmount: 0,
            collateralValue: 0,
            healthFactor: type(uint256).max,
            hubChainSelector: hubChainSelector,
            requestedLTV: requestedLTV,
            lastOracleUpdate: 0,
            resolutionTimestamp: resolutionTimestamp,
            status: VaultStatus.PENDING
        });

        _ownerVaults[msg.sender].push(vaultId);

        // ──────────────────────────────────────────────
        // CCIP Loan Request (or Local Bypass)
        // ──────────────────────────────────────────────
        if (hubReceiver != address(0)) {
            CCIPMessageCodec.LoanRequest memory request = CCIPMessageCodec
                .LoanRequest({
                    vaultId: vaultId,
                    borrower: msg.sender,
                    requestedLTV: requestedLTV,
                    conditionId: conditionId,
                    outcomeIndex: outcomeIndex,
                    amount: amount
                });

            if (hubChainSelector == localChainSelector) {
                // LOCAL BYPASS: Call HubReceiver directly
                // This assumes HubReceiver has the receiveLocalLoanRequest function
                (bool success, bytes memory data) = hubReceiver.call(
                    abi.encodeWithSignature(
                        "receiveLocalLoanRequest((uint256,address,uint256,uint256,uint256,uint256))",
                        request.vaultId,
                        request.borrower,
                        request.requestedLTV,
                        request.conditionId,
                        request.outcomeIndex,
                        request.amount
                    )
                );
                if (!success) {
                    if (data.length > 0) {
                        // bubble up the revert reason
                        assembly {
                            revert(add(32, data), mload(data))
                        }
                    } else {
                        revert("Local bypass call failed");
                    }
                }
            } else {
                // CCIP Path
                bytes memory payload = CCIPMessageCodec.encodeLoanRequest(
                    request
                );

                Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
                    receiver: abi.encode(hubReceiver),
                    data: payload,
                    tokenAmounts: new Client.EVMTokenAmount[](0),
                    extraArgs: Client._argsToBytes(
                        Client.EVMExtraArgsV1({gasLimit: 400_000})
                    ),
                    feeToken: address(linkToken)
                });

                uint256 fees = ccipRouter.getFee(hubChainSelector, message);

                // WORRY-FREE FEES: Protocol pays from its own balance
                if (address(linkToken) != address(0)) {
                    // Ensure contract has enough LINK
                    uint256 linkBalance = linkToken.balanceOf(address(this));
                    if (linkBalance < fees) revert InsufficientProtocolFees();

                    linkToken.forceApprove(address(ccipRouter), fees);
                    ccipRouter.ccipSend(hubChainSelector, message);
                } else {
                    // Ensure contract has enough Native Gas
                    if (address(this).balance < fees)
                        revert InsufficientProtocolFees();

                    ccipRouter.ccipSend{value: fees}(hubChainSelector, message);
                }
            }

            if (hubChainSelector == localChainSelector) {
                // Apply mock valuation locally so vault moves to ACTIVE
                _applyMockValuation(vaultId, amount);
            }
        }

        emit CollateralDeposited(
            vaultId,
            msg.sender,
            conditionId,
            outcomeIndex,
            amount,
            hubChainSelector,
            requestedLTV
        );
    }

    /**
     * @notice Local Demo bypass for depositing collateral while explicitly passing the AI valuation.
     * @dev This skips CCIP and DON completely. Do NOT deploy or use in production.
     */
    function depositCollateralWithAIValue(
        address tokenContract,
        uint256 conditionId,
        uint256 outcomeIndex,
        uint256 amount,
        uint64 hubChainSelector,
        uint256 requestedLTV,
        uint256 resolutionTimestamp,
        uint256 aiValuation
    ) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (requestedLTV > maxLTV) revert InvalidLTV(requestedLTV, maxLTV);

        if (resolutionTimestamp < block.timestamp + minTimeToResolution) {
            revert MarketTooCloseToResolution(
                resolutionTimestamp,
                minTimeToResolution
            );
        }

        IERC1155(tokenContract).safeTransferFrom(
            msg.sender,
            address(this),
            conditionId,
            amount,
            ""
        );

        uint256 vaultId = _nextVaultId++;
        _vaults[vaultId] = Vault({
            owner: msg.sender,
            tokenContract: tokenContract,
            conditionId: conditionId,
            outcomeIndex: outcomeIndex,
            amount: amount,
            loanAmount: 0,
            collateralValue: 0,
            healthFactor: type(uint256).max,
            hubChainSelector: hubChainSelector,
            requestedLTV: requestedLTV,
            lastOracleUpdate: 0,
            resolutionTimestamp: resolutionTimestamp,
            status: VaultStatus.PENDING
        });
        _ownerVaults[msg.sender].push(vaultId);

        if (
            hubReceiver != address(0) && hubChainSelector == localChainSelector
        ) {
            CCIPMessageCodec.LoanRequest memory request = CCIPMessageCodec
                .LoanRequest({
                    vaultId: vaultId,
                    borrower: msg.sender,
                    requestedLTV: requestedLTV,
                    conditionId: conditionId,
                    outcomeIndex: outcomeIndex,
                    amount: amount
                });

            (bool success, bytes memory data) = hubReceiver.call(
                abi.encodeWithSignature(
                    "receiveLocalLoanRequestWithAIValue((uint256,address,uint256,uint256,uint256,uint256),uint256)",
                    request,
                    aiValuation
                )
            );
            if (!success) {
                if (data.length > 0) {
                    assembly {
                        revert(add(32, data), mload(data))
                    }
                } else {
                    revert("Local bypass call failed");
                }
            }

            _vaults[vaultId].collateralValue = aiValuation;
            _vaults[vaultId].status = VaultStatus.ACTIVE;
        } else {
            revert("This function is ONLY for local bypass testing");
        }

        emit CollateralDeposited(
            vaultId,
            msg.sender,
            conditionId,
            outcomeIndex,
            amount,
            hubChainSelector,
            requestedLTV
        );
    }

    /**
     * @notice Receive and apply an AI valuation report from the CRE DON
     * @dev Restricted to ORACLE_ROLE — only DON-authorized report submitters
     */
    function receiveValuation(
        ValuationReport calldata report
    ) external override onlyRole(ORACLE_ROLE) {
        _applyValuation(
            report.vaultId,
            report.collateralValue,
            report.healthFactor,
            report.timestamp
        );

        emit ValuationReceived(
            report.vaultId,
            report.collateralValue,
            report.healthFactor,
            report.alpha
        );
    }

    /**
     * @notice Internal logic to apply a valuation
     */
    function _applyValuation(
        uint256 vaultId,
        uint256 collateralValue,
        uint256 healthFactor,
        uint256 timestamp
    ) internal {
        Vault storage vault = _getVault(vaultId);

        // Valuation can be received for PENDING or ACTIVE vaults
        if (
            vault.status != VaultStatus.PENDING &&
            vault.status != VaultStatus.ACTIVE
        ) {
            revert InvalidStatusTransition(vault.status, VaultStatus.ACTIVE);
        }

        vault.collateralValue = collateralValue;
        vault.healthFactor = healthFactor;
        vault.lastOracleUpdate = timestamp;

        // Transition PENDING → ACTIVE on first valuation
        if (vault.status == VaultStatus.PENDING) {
            _transitionStatus(vaultId, VaultStatus.ACTIVE);

            // Calculate loan amount based on collateral value and requested LTV
            vault.loanAmount = CollateralMath.calculateMaxLoan(
                collateralValue,
                vault.requestedLTV
            );
        }

        // Check if liquidation should be triggered
        if (CollateralMath.isLiquidatable(healthFactor, maintenanceMargin)) {
            _transitionStatus(vaultId, VaultStatus.LIQUIDATING);
            emit LiquidationTriggered(vaultId);
        }
    }

    /**
     * @notice Apply a mock 1:1 valuation for local testing
     */
    function _applyMockValuation(uint256 vaultId, uint256 amount) internal {
        // Mock valuation: 1 share = 1 USDC (18 decimals)
        // Note: amount is already in 18 decimals in the seeding script
        _applyValuation(
            vaultId,
            amount, // 1:1 collateral value
            2e18, // safe health factor
            block.timestamp
        );
    }

    /**
     * @notice Withdraw collateral after loan is fully repaid
     */
    function withdrawCollateral(
        uint256 vaultId
    ) external override nonReentrant {
        Vault storage vault = _getVault(vaultId);
        if (vault.owner != msg.sender)
            revert NotVaultOwner(vaultId, msg.sender);
        if (vault.loanAmount > 0)
            revert LoanNotRepaid(vaultId, vault.loanAmount);

        // Must be ACTIVE (loan was repaid externally) or PENDING (no loan was disbursed)
        if (
            vault.status != VaultStatus.ACTIVE &&
            vault.status != VaultStatus.PENDING
        ) {
            revert InvalidStatusTransition(vault.status, VaultStatus.CLOSED);
        }

        _transitionStatus(vaultId, VaultStatus.CLOSED);

        // Return collateral to owner
        IERC1155(vault.tokenContract).safeTransferFrom(
            address(this),
            msg.sender,
            vault.conditionId,
            vault.amount,
            ""
        );

        emit CollateralWithdrawn(vaultId, msg.sender, vault.amount);
    }

    /**
     * @notice Emergency recovery for failed cross-chain transactions
     */
    function recoverCollateral(uint256 vaultId) external override nonReentrant {
        Vault storage vault = _getVault(vaultId);
        if (vault.owner != msg.sender)
            revert NotVaultOwner(vaultId, msg.sender);

        if (vault.status != VaultStatus.FAILED) {
            revert InvalidStatusTransition(vault.status, VaultStatus.CLOSED);
        }

        _transitionStatus(vaultId, VaultStatus.CLOSED);

        IERC1155(vault.tokenContract).safeTransferFrom(
            address(this),
            msg.sender,
            vault.conditionId,
            vault.amount,
            ""
        );

        emit CollateralRecovered(vaultId, msg.sender, vault.amount);
    }

    /**
     * @notice Claim surplus USDC from a liquidated vault
     */
    function claimSurplus(uint256 vaultId) external nonReentrant {
        Vault storage vault = _getVault(vaultId);
        if (vault.owner != msg.sender)
            revert NotVaultOwner(vaultId, msg.sender);

        uint256 surplus = _vaultSurplus[vaultId];
        if (surplus == 0) revert ZeroAmount();

        _vaultSurplus[vaultId] = 0;
        usdcToken.safeTransfer(msg.sender, surplus);

        emit SurplusClaimed(vaultId, msg.sender, surplus);
    }

    function getVaultSurplus(uint256 vaultId) external view returns (uint256) {
        return _vaultSurplus[vaultId];
    }

    /**
     * @notice Mark a vault as FAILED (for cross-chain transaction failures)
     * @dev Restricted to ORACLE_ROLE or contracts with authorized relay access
     */
    function markVaultFailed(uint256 vaultId) external onlyRole(ORACLE_ROLE) {
        Vault storage vault = _getVault(vaultId);
        if (vault.status != VaultStatus.PENDING) {
            revert InvalidStatusTransition(vault.status, VaultStatus.FAILED);
        }
        _transitionStatus(vaultId, VaultStatus.FAILED);
    }

    /**
     * @notice Clear debt for a vault after repayment (called by cross-chain receiver)
     */
    function clearDebt(
        uint256 vaultId,
        uint256 amountRepaid
    ) external onlyRole(ORACLE_ROLE) {
        Vault storage vault = _getVault(vaultId);
        if (amountRepaid >= vault.loanAmount) {
            vault.loanAmount = 0;
            _transitionStatus(vaultId, VaultStatus.CLOSED);
        } else {
            vault.loanAmount -= amountRepaid;
        }
    }

    /**
     * @notice Handle incoming USDC from PolymarketAdapter liquidation
     * @param vaultId The ID of the vault being liquidated
     * @param usdcAmount The amount of USDC recovered from the sale (6 decimals)
     */
    function handleLiquidationUSDC(
        uint256 vaultId,
        uint256 usdcAmount
    ) external onlyRole(LIQUIDATOR_ROLE) nonReentrant {
        Vault storage vault = _getVault(vaultId);
        if (vault.status != VaultStatus.LIQUIDATING) {
            revert InvalidStatusTransition(
                vault.status,
                VaultStatus.LIQUIDATING
            );
        }

        // 1. Pull USDC from the adapter
        usdcToken.safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Identify debt and surplus
        uint256 debt18 = vault.loanAmount;
        uint256 usdcAmount18 = usdcAmount * 1e12;

        uint256 repayAmount18 = usdcAmount18 > debt18 ? debt18 : usdcAmount18;
        uint256 surplus18 = usdcAmount18 > debt18 ? usdcAmount18 - debt18 : 0;

        // 3. Send repayment to Hub via CCIP
        if (repayAmount18 > 0) {
            uint256 repayAmount6 = repayAmount18 / 1e12;

            Client.EVMTokenAmount[]
                memory tokenAmounts = new Client.EVMTokenAmount[](1);
            tokenAmounts[0] = Client.EVMTokenAmount({
                token: address(usdcToken),
                amount: repayAmount6
            });

            Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
                receiver: abi.encode(hubReceiver),
                data: abi.encode(vaultId),
                tokenAmounts: tokenAmounts,
                extraArgs: Client._argsToBytes(
                    Client.EVMExtraArgsV1({gasLimit: 200_000})
                ),
                feeToken: address(linkToken)
            });

            // If we have enough LINK, use it. Otherwise use native.
            uint256 fees = ccipRouter.getFee(vault.hubChainSelector, message);
            if (linkToken.balanceOf(address(this)) >= fees) {
                linkToken.forceApprove(address(ccipRouter), fees);
                usdcToken.forceApprove(address(ccipRouter), repayAmount6);
                ccipRouter.ccipSend(vault.hubChainSelector, message);
            } else {
                if (address(this).balance < fees)
                    revert InsufficientProtocolFees();
                message.feeToken = address(0);
                usdcToken.forceApprove(address(ccipRouter), repayAmount6);
                ccipRouter.ccipSend{value: fees}(
                    vault.hubChainSelector,
                    message
                );
            }

            vault.loanAmount -= repayAmount18;
        }

        // 4. Store surplus for the user
        if (surplus18 > 0) {
            _vaultSurplus[vaultId] += surplus18 / 1e12;
        }

        // 5. Close vault if debt is cleared
        if (vault.loanAmount == 0) {
            _transitionStatus(vaultId, VaultStatus.CLOSED);
        }
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getVault(
        uint256 vaultId
    ) external view override returns (Vault memory) {
        return _vaults[vaultId];
    }

    function getVaultCount() external view override returns (uint256) {
        return _nextVaultId - 1;
    }

    function getVaultsByOwner(
        address owner
    ) external view override returns (uint256[] memory) {
        return _ownerVaults[owner];
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    function setMaxLTV(
        uint256 newMaxLTV
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxLTV = newMaxLTV;
    }

    function setMaintenanceMargin(
        uint256 newMargin
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maintenanceMargin = newMargin;
    }

    function setOracleStalenessTolerance(
        uint256 newTolerance
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        oracleStalenessTolerance = newTolerance;
    }

    function setPolymarketAdapter(
        address _adapter
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        polymarketAdapter = _adapter;
    }

    function setResolutionCutoff(
        uint256 _cutoff
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_cutoff > 0, "Cutoff must be > 0");
        require(
            minTimeToResolution >= _cutoff,
            "minTimeToResolution must be >= cutoff"
        );
        resolutionCutoff = _cutoff;
    }

    function setMinTimeToResolution(
        uint256 _minTime
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            _minTime >= resolutionCutoff,
            "minTime must be >= resolutionCutoff"
        );
        minTimeToResolution = _minTime;
    }

    /**
     * @notice Force-liquidate a vault whose market is within the resolution cutoff window
     * @dev Callable by ORACLE_ROLE (Chainlink DON). Transitions vault to LIQUIDATING regardless of health.
     */
    function triggerResolutionCutoff(
        uint256 vaultId
    ) external onlyRole(ORACLE_ROLE) {
        Vault storage vault = _getVault(vaultId);

        if (
            vault.status != VaultStatus.ACTIVE &&
            vault.status != VaultStatus.PENDING
        ) {
            revert VaultNotActive(vaultId, vault.status);
        }

        if (block.timestamp < vault.resolutionTimestamp - resolutionCutoff) {
            revert ResolutionCutoffNotReached(
                vault.resolutionTimestamp,
                resolutionCutoff
            );
        }

        _transitionStatus(vaultId, VaultStatus.LIQUIDATING);
        emit ResolutionCutoffTriggered(vaultId);
        emit LiquidationTriggered(vaultId);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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
    )
        public
        pure
        override(AccessControl, CCIPReceiver, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IAny2EVMMessageReceiver).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _getVault(uint256 vaultId) internal view returns (Vault storage) {
        Vault storage vault = _vaults[vaultId];
        if (vault.owner == address(0)) revert VaultNotFound(vaultId);
        return vault;
    }

    function _transitionStatus(
        uint256 vaultId,
        VaultStatus newStatus
    ) internal {
        Vault storage vault = _vaults[vaultId];
        VaultStatus oldStatus = vault.status;
        vault.status = newStatus;

        // If entering liquidation, authorize the PolymarketAdapter to pull tokens
        if (
            newStatus == VaultStatus.LIQUIDATING &&
            polymarketAdapter != address(0)
        ) {
            IERC1155(vault.tokenContract).setApprovalForAll(
                polymarketAdapter,
                true
            );
        }

        emit VaultStatusChanged(vaultId, oldStatus, newStatus);
    }

    /**
     * @notice Handle incoming CCIP messages for surplus returns
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        // Decode vaultId from data
        uint256 vaultId = abi.decode(any2EvmMessage.data, (uint256));

        // We expect exactly one token (USDC)
        if (any2EvmMessage.destTokenAmounts.length == 1) {
            uint256 amount = any2EvmMessage.destTokenAmounts[0].amount;
            _vaultSurplus[vaultId] += amount;
        }
    }

    /**
     * @notice Recover unused fee tokens (LINK or Native)
     */
    function withdrawFees(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) {
            payable(msg.sender).transfer(amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }
    }

    receive() external payable {}
}
