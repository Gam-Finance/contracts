// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {
    CCIPReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {
    IAny2EVMMessageReceiver
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {
    IAccessControl
} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ILiquidityPool} from "./interfaces/ILiquidityPool.sol";
import {CollateralMath} from "./libraries/CollateralMath.sol";
import {ACEPolicyManager} from "./ACEPolicyManager.sol";

/**
 * @title OmnichainLiquidityPool
 * @notice USDC Hub lending pool accepting deposits natively from any CCIP Spoke.
 */
contract OmnichainLiquidityPool is
    ILiquidityPool,
    ERC20,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    CCIPReceiver
{
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant CCIP_RECEIVER_ROLE =
        keccak256("CCIP_RECEIVER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant AUCTION_ROLE = keccak256("AUCTION_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    IERC20 public immutable underlyingAsset; // USDC

    uint256 public totalDeposited;
    uint256 public totalBorrowed;
    uint256 public totalReserves;
    uint256 public lastAccrualTimestamp;

    uint256 public baseRate;
    uint256 public kink;
    uint256 public slope1;
    uint256 public slope2;
    uint256 public reserveFactor;

    mapping(uint256 => uint256) public vaultDebt;
    bool public complianceEnabled;
    ACEPolicyManager public acePolicyManager;
    mapping(bytes32 => uint256) public categoryRateMultiplier;
    uint256 public totalBadDebt;
    address public borrowerSpoke;
    bool public localBypass;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InsufficientShares(uint256 requested, uint256 available);
    error ZeroAmount();
    error VaultDebtNotFound(uint256 vaultId);
    error NotCompliant(address wallet);
    error InvalidCCIPMessage();

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _ccipRouter,
        address _underlyingAsset,
        address admin,
        uint256 _baseRate,
        uint256 _kink,
        uint256 _slope1,
        uint256 _slope2,
        uint256 _reserveFactor
    ) ERC20("Prediction Box USDC", "pbUSDC") CCIPReceiver(_ccipRouter) {
        underlyingAsset = IERC20(_underlyingAsset);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);

        baseRate = _baseRate;
        kink = _kink;
        slope1 = _slope1;
        slope2 = _slope2;
        reserveFactor = _reserveFactor;
        lastAccrualTimestamp = block.timestamp;
    }

    // ──────────────────────────────────────────────
    // Core Functions (Direct & Cross-Chain)
    // ──────────────────────────────────────────────

    /**
     * @notice Handle cross-chain programmable token transfers
     *         The CCIP Router auto-transfers USDC to this contract, then calls this.
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        if (any2EvmMessage.destTokenAmounts.length != 1)
            revert InvalidCCIPMessage();

        Client.EVMTokenAmount memory coin = any2EvmMessage.destTokenAmounts[0];
        if (coin.token != address(underlyingAsset)) revert InvalidCCIPMessage();

        uint256 amount6 = coin.amount;
        if (amount6 == 0) revert ZeroAmount();

        // Normalize to 18 decimals (USDC is 6, so scale by 1e12)
        uint256 amount18 = amount6 * 1e12;

        // Decode the original lender's address from the Spoke chain payload
        address originalLender = abi.decode(any2EvmMessage.data, (address));

        // ACE compliance check
        if (address(acePolicyManager) != address(0)) {
            if (!acePolicyManager.checkCompliance(originalLender)) {
                revert NotCompliant(originalLender);
            }
        }

        _accrueInterest();

        uint256 shares = _calculateShares(amount18);
        totalDeposited += amount18;
        _mint(originalLender, shares);

        emit Deposited(originalLender, amount18, shares);
    }

    /**
     * @notice Deposit USDC directly (Hub chain users)
     */
    function deposit(
        uint256 amount
    ) external override whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        if (address(acePolicyManager) != address(0)) {
            if (!acePolicyManager.checkCompliance(msg.sender)) {
                revert NotCompliant(msg.sender);
            }
        }

        _accrueInterest();

        // Protocol uses 18 decimals; scale up if asset is USDC (6 decimals)
        uint256 amount18 = amount * 1e12;

        uint256 shares = _calculateShares(amount18);
        underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposited += amount18;
        _mint(msg.sender, shares);

        emit Deposited(msg.sender, amount18, shares);
    }

    function withdraw(uint256 shares) external override nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < shares)
            revert InsufficientShares(shares, balanceOf(msg.sender));

        _accrueInterest();

        uint256 amount18 = _calculateUnderlying(shares);
        uint256 available18 = getAvailableLiquidity();

        if (amount18 > available18)
            revert InsufficientLiquidity(amount18, available18);

        totalDeposited -= amount18;
        _burn(msg.sender, shares);

        // Scale down to 6 decimals for USDC transfer
        uint256 amount6 = amount18 / 1e12;
        underlyingAsset.safeTransfer(msg.sender, amount6);

        emit Withdrawn(msg.sender, amount18, shares);
    }

    function disburseLoan(
        uint256 vaultId,
        address borrower,
        uint256 amount
    ) external override onlyRole(CCIP_RECEIVER_ROLE) nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Both amount and available are in 18 decimals
        uint256 available = getAvailableLiquidity();
        if (amount > available) revert InsufficientLiquidity(amount, available);

        _accrueInterest();

        totalBorrowed += amount;
        vaultDebt[vaultId] += amount;

        // Scale down to 6 decimals for USDC transfer
        uint256 amount6 = amount / 1e12;
        underlyingAsset.safeTransfer(borrower, amount6);

        emit LoanDisbursed(vaultId, borrower, amount);
    }

    function repayLoan(
        uint256 vaultId,
        uint256 amount
    ) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (vaultDebt[vaultId] == 0) revert VaultDebtNotFound(vaultId);

        _accrueInterest();

        // amount is incoming in 6 decimals (USDC)
        uint256 amount18 = amount * 1e12;

        uint256 repayAmount18 = amount18 > vaultDebt[vaultId]
            ? vaultDebt[vaultId]
            : amount18;

        // Repay in 6 decimals
        uint256 repayAmount6 = repayAmount18 / 1e12;

        underlyingAsset.safeTransferFrom(
            msg.sender,
            address(this),
            repayAmount6
        );

        uint256 interest18 = 0;
        if (amount18 > vaultDebt[vaultId]) {
            interest18 = amount18 - vaultDebt[vaultId];
        }

        totalBorrowed -= repayAmount18;
        vaultDebt[vaultId] -= repayAmount18;

        if (localBypass && borrowerSpoke != address(0)) {
            // abi.encodeWithSignature for BorrowerSpoke.clearDebt(uint256,uint256)
            (bool success, ) = borrowerSpoke.call(
                abi.encodeWithSignature(
                    "clearDebt(uint256,uint256)",
                    vaultId,
                    repayAmount18
                )
            );
            // We don't revert on failure to avoid blocking repayment if bypass is misconfigured
            // though in local testing we expect it to work.
        }

        uint256 reserveAmount18 = (interest18 * reserveFactor) / 1e18;
        totalReserves += reserveAmount18;

        emit LoanRepaid(vaultId, repayAmount18, interest18);
    }

    function socializeBadDebt(uint256 amount) external onlyRole(AUCTION_ROLE) {
        // amount is in 18 decimals
        if (amount >= totalDeposited) {
            totalDeposited = 0;
        } else {
            totalDeposited -= amount;
        }

        if (amount >= totalBorrowed) {
            totalBorrowed = 0;
        } else {
            totalBorrowed -= amount;
        }

        totalBadDebt += amount;
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    function getUtilizationRate() public view override returns (uint256) {
        if (totalDeposited == 0) return 0;
        return (totalBorrowed * 1e18) / totalDeposited;
    }

    function getInterestRate() external view override returns (uint256) {
        return
            CollateralMath.calculateInterestRate(
                getUtilizationRate(),
                baseRate,
                kink,
                slope1,
                slope2
            );
    }

    function getCategoryInterestRate(
        bytes32 category
    ) external view returns (uint256 rate) {
        rate = CollateralMath.calculateInterestRate(
            getUtilizationRate(),
            baseRate,
            kink,
            slope1,
            slope2
        );
        uint256 multiplier = categoryRateMultiplier[category];
        if (multiplier > 0) {
            rate = (rate * multiplier) / 1e18;
        }
    }

    function getTotalDeposits() external view override returns (uint256) {
        return totalDeposited;
    }

    function getTotalBorrowed() external view override returns (uint256) {
        return totalBorrowed;
    }

    function getAvailableLiquidity() public view override returns (uint256) {
        // balance is in 6 decimals, scale to 18
        uint256 balance18 = underlyingAsset.balanceOf(address(this)) * 1e12;
        return balance18 > totalReserves ? balance18 - totalReserves : 0;
    }

    // ──────────────────────────────────────────────
    // Admin Functions
    // ──────────────────────────────────────────────

    function setInterestRateParams(
        uint256 _baseRate,
        uint256 _kink,
        uint256 _slope1,
        uint256 _slope2
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseRate = _baseRate;
        kink = _kink;
        slope1 = _slope1;
        slope2 = _slope2;
    }

    function setReserveFactor(
        uint256 _reserveFactor
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        reserveFactor = _reserveFactor;
    }

    function setACEPolicyManager(
        address _acePolicyManager
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        acePolicyManager = ACEPolicyManager(_acePolicyManager);
    }

    function withdrawReserves(
        uint256 amount18,
        address to
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount18 > totalReserves)
            revert InsufficientLiquidity(amount18, totalReserves);
        totalReserves -= amount18;

        // Scale down to 6 decimals for USDC transfer
        uint256 amount6 = amount18 / 1e12;
        underlyingAsset.safeTransfer(to, amount6);
    }

    function setCategoryRateMultiplier(
        bytes32 category,
        uint256 multiplier
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        categoryRateMultiplier[category] = multiplier;
    }

    function setLocalBypass(
        address _spoke,
        bool _enabled
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        borrowerSpoke = _spoke;
        localBypass = _enabled;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public pure virtual override(CCIPReceiver, AccessControl) returns (bool) {
        return
            interfaceId == type(IAny2EVMMessageReceiver).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 rate = CollateralMath.calculateInterestRate(
            getUtilizationRate(),
            baseRate,
            kink,
            slope1,
            slope2
        );

        uint256 interestAccrued = (totalBorrowed * rate * elapsed) /
            (365 days * 1e18);

        if (interestAccrued > 0) {
            totalBorrowed += interestAccrued;

            uint256 reservePortion = (interestAccrued * reserveFactor) / 1e18;
            totalReserves += reservePortion;

            emit InterestAccrued(interestAccrued, reservePortion);
        }

        lastAccrualTimestamp = block.timestamp;
    }

    function _calculateShares(uint256 amount) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || totalDeposited == 0) {
            return amount;
        }
        return (amount * supply) / totalDeposited;
    }

    function _calculateUnderlying(
        uint256 shares
    ) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        return (shares * totalDeposited) / supply;
    }
}
