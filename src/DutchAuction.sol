// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDutchAuction} from "./interfaces/IDutchAuction.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

/**
 * @title ILiquidityPoolDebt
 * @notice Minimal interface for reading vault debt from LiquidityPool
 */
interface ILiquidityPoolDebt {
    function vaultDebt(uint256 vaultId) external view returns (uint256);
    function socializeBadDebt(uint256 amount) external;
}

/**
 * @title DutchAuction
 * @notice Liquidation engine using descending-price (Dutch) auctions.
 *         When a vault's health factor drops below the maintenance margin,
 *         the oracle triggers an auction that starts at a premium above the
 *         last valuation and decreases linearly until a bidder accepts.
 *
 *         Phase 7 additions:
 *         - Live vault debt lookup from LiquidityPool
 *         - Keeper incentive distribution (5% of settled price)
 *         - Bad debt socialization when auction proceeds < debt
 *         - Batch liquidation via startBatchAuctions()
 */
contract DutchAuction is IDutchAuction, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    // Roles
    // ──────────────────────────────────────────────

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // ──────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────

    mapping(uint256 => Auction) private _auctions;
    uint256 private _nextAuctionId;

    /// @notice The stablecoin used for bidding (USDC)
    IERC20 public immutable paymentToken;

    /// @notice Address of the liquidity pool (debt repayment destination)
    address public liquidityPool;

    /// @notice Address of the BorrowerSpoke contract (for vault reference)
    address public borrowerSpoke;

    /// @notice Price premium for auction start (18 decimals, e.g., 1.10e18 = 10% above last valuation)
    uint256 public startPricePremium;

    /// @notice Floor price as fraction of start price (18 decimals, e.g., 0.50e18 = 50%)
    uint256 public floorPriceFraction;

    /// @notice Default auction duration in seconds
    uint256 public defaultAuctionDuration;

    /// @notice Keeper incentive (18 decimals, e.g., 0.05e18 = 5% bonus)
    uint256 public keeperIncentive;

    /// @notice Total bad debt socialized to LPs
    uint256 public totalBadDebt;

    /// @notice CCIP Router for cross-chain surplus return
    IRouterClient public ccipRouter;

    /// @notice Destination Chain Selector for the BorrowerSpoke
    uint64 public borrowerSpokeChainSelector;

    /// @notice Mapping of vaultId → active auctionId (prevents duplicate auctions)
    mapping(uint256 => uint256) public activeAuctionForVault;

    // ──────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────

    event KeeperIncentivePaid(
        uint256 indexed auctionId,
        address indexed keeper,
        uint256 amount
    );

    event BadDebtSocialized(uint256 indexed auctionId, uint256 shortfall);

    event BatchAuctionsStarted(uint256[] auctionIds, uint256[] vaultIds);

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error AuctionNotActive(uint256 auctionId);
    error AuctionExpired(uint256 auctionId);
    error BidTooLow(uint256 bid, uint256 currentPrice);
    error AuctionAlreadySettled(uint256 auctionId);
    error VaultAlreadyInAuction(uint256 vaultId);
    error ZeroDebt(uint256 vaultId);

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address admin,
        address _paymentToken,
        address _liquidityPool,
        address _borrowerSpoke,
        uint256 _startPricePremium,
        uint256 _floorPriceFraction,
        uint256 _defaultAuctionDuration,
        uint256 _keeperIncentive,
        address _ccipRouter,
        uint64 _borrowerSpokeChainSelector
    ) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        paymentToken = IERC20(_paymentToken);
        liquidityPool = _liquidityPool;
        borrowerSpoke = _borrowerSpoke;
        startPricePremium = _startPricePremium;
        floorPriceFraction = _floorPriceFraction;
        defaultAuctionDuration = _defaultAuctionDuration;
        keeperIncentive = _keeperIncentive;
        ccipRouter = IRouterClient(_ccipRouter);
        borrowerSpokeChainSelector = _borrowerSpokeChainSelector;
        _nextAuctionId = 1;
    }

    // ──────────────────────────────────────────────
    // Core Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Start a Dutch auction for a liquidatable vault
     * @param vaultId The vault being liquidated
     * @return auctionId The ID of the created auction
     */
    function startAuction(
        uint256 vaultId
    ) public override onlyRole(ORACLE_ROLE) returns (uint256 auctionId) {
        // Prevent duplicate auctions for the same vault
        if (activeAuctionForVault[vaultId] != 0)
            revert VaultAlreadyInAuction(vaultId);

        // Read live debt from LiquidityPool
        uint256 debtAmount = _getVaultDebt(vaultId);
        if (debtAmount == 0) revert ZeroDebt(vaultId);

        auctionId = _nextAuctionId++;

        // Start price = debt × premium (e.g., 110% of debt)
        uint256 startPrice = (debtAmount * startPricePremium) / 1e18;
        uint256 floorPrice = (startPrice * floorPriceFraction) / 1e18;

        _auctions[auctionId] = Auction({
            vaultId: vaultId,
            debtAmount: debtAmount,
            startPrice: startPrice,
            floorPrice: floorPrice,
            startTime: block.timestamp,
            duration: defaultAuctionDuration,
            settler: address(0),
            settledPrice: 0,
            status: AuctionStatus.ACTIVE
        });

        activeAuctionForVault[vaultId] = auctionId;

        emit AuctionStarted(
            auctionId,
            vaultId,
            startPrice,
            floorPrice,
            defaultAuctionDuration
        );
    }

    /**
     * @notice Start batch auctions for multiple vaults in one transaction
     * @param vaultIds Array of vault IDs to liquidate
     * @return auctionIds Array of created auction IDs
     */
    function startBatchAuctions(
        uint256[] calldata vaultIds
    ) external onlyRole(ORACLE_ROLE) returns (uint256[] memory auctionIds) {
        auctionIds = new uint256[](vaultIds.length);
        for (uint256 i = 0; i < vaultIds.length; i++) {
            auctionIds[i] = startAuction(vaultIds[i]);
        }
        emit BatchAuctionsStarted(auctionIds, vaultIds);
    }

    /**
     * @notice Place a bid at the current auction price
     * @dev The bidder pays the current descending price and receives the collateral
     */
    function bid(uint256 auctionId) external override nonReentrant {
        Auction storage auction = _auctions[auctionId];
        if (auction.status != AuctionStatus.ACTIVE)
            revert AuctionNotActive(auctionId);

        uint256 currentPrice18 = getCurrentPrice(auctionId);
        if (currentPrice18 == 0) {
            // Auction expired
            auction.status = AuctionStatus.EXPIRED;
            revert AuctionExpired(auctionId);
        }

        // Scale down to 6 decimals for USDC transfer
        uint256 currentPrice6 = currentPrice18 / 1e12;

        // Transfer payment from bidder
        paymentToken.safeTransferFrom(msg.sender, address(this), currentPrice6);

        // Settle the auction
        auction.settler = msg.sender;
        auction.settledPrice = currentPrice18;
        auction.status = AuctionStatus.SETTLED;

        // Clear active auction mapping
        activeAuctionForVault[auction.vaultId] = 0;

        // Distribute proceeds
        _distributeProceeds(auctionId);

        emit AuctionBid(auctionId, msg.sender, currentPrice18);
    }

    /**
     * @notice Settle an expired auction — triggers bad debt socialization
     */
    function settleAuction(uint256 auctionId) external override {
        Auction storage auction = _auctions[auctionId];
        if (auction.status == AuctionStatus.SETTLED)
            revert AuctionAlreadySettled(auctionId);

        if (block.timestamp >= auction.startTime + auction.duration) {
            auction.status = AuctionStatus.EXPIRED;

            // Clear active auction mapping
            activeAuctionForVault[auction.vaultId] = 0;

            // Bad debt: full debt amount is socialized since no bidder stepped in
            // debtAmount is already in 18 decimals WAD
            if (auction.debtAmount > 0) {
                totalBadDebt += auction.debtAmount;
                ILiquidityPoolDebt(liquidityPool).socializeBadDebt(
                    auction.debtAmount
                );
                emit BadDebtSocialized(auctionId, auction.debtAmount);
            }
        }
    }

    // ──────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Get the current descending price for an auction
     * @return price The current price (decreasing linearly from start to floor)
     */
    function getCurrentPrice(
        uint256 auctionId
    ) public view override returns (uint256 price) {
        Auction memory auction = _auctions[auctionId];
        if (auction.status != AuctionStatus.ACTIVE) return 0;

        uint256 elapsed = block.timestamp - auction.startTime;
        if (elapsed >= auction.duration) return 0; // Expired

        // Linear price decay: startPrice → floorPrice over duration
        // All auction metrics (startPrice, floorPrice) are in 18 decimals WAD
        uint256 priceDrop = auction.startPrice - auction.floorPrice;
        uint256 decay = (priceDrop * elapsed) / auction.duration;
        price = auction.startPrice - decay;

        // Floor
        if (price < auction.floorPrice) price = auction.floorPrice;
    }

    function getAuction(
        uint256 auctionId
    ) external view override returns (Auction memory) {
        return _auctions[auctionId];
    }

    // ──────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────

    function setAuctionParams(
        uint256 _startPricePremium,
        uint256 _floorPriceFraction,
        uint256 _defaultAuctionDuration,
        uint256 _keeperIncentive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        startPricePremium = _startPricePremium;
        floorPriceFraction = _floorPriceFraction;
        defaultAuctionDuration = _defaultAuctionDuration;
        keeperIncentive = _keeperIncentive;
    }

    function setBorrowerSpoke(
        address _borrowerSpoke,
        uint64 _selector
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        borrowerSpoke = _borrowerSpoke;
        borrowerSpokeChainSelector = _selector;
    }

    // ──────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────

    function _distributeProceeds(uint256 auctionId) internal {
        Auction memory auction = _auctions[auctionId];

        uint256 proceeds18 = auction.settledPrice;

        // 1. Pay keeper incentive (e.g., 5% of settled price)
        uint256 incentive18 = (proceeds18 * keeperIncentive) / 1e18;
        if (incentive18 > 0) {
            uint256 incentive6 = incentive18 / 1e12;
            paymentToken.safeTransfer(auction.settler, incentive6);
            proceeds18 -= incentive18;
            emit KeeperIncentivePaid(auctionId, auction.settler, incentive18);
        }

        // 2. Pay debt to liquidity pool
        uint256 debtRepayment18;
        if (proceeds18 >= auction.debtAmount) {
            debtRepayment18 = auction.debtAmount;
        } else {
            debtRepayment18 = proceeds18;
        }

        if (debtRepayment18 > 0) {
            uint256 debtRepayment6 = debtRepayment18 / 1e12;
            paymentToken.safeTransfer(liquidityPool, debtRepayment6);
        }

        // 3. Bad debt socialization: if proceeds < debt, spread the shortfall
        if (proceeds18 < auction.debtAmount) {
            uint256 shortfall18 = auction.debtAmount - proceeds18;
            totalBadDebt += shortfall18;
            ILiquidityPoolDebt(liquidityPool).socializeBadDebt(shortfall18);
            emit BadDebtSocialized(auctionId, shortfall18);
        }

        // 4. Surplus goes back to the vault owner (via BorrowerSpoke)
        uint256 surplus18 = 0;
        if (proceeds18 > auction.debtAmount) {
            surplus18 = proceeds18 - auction.debtAmount;
            // Transfer surplus to BorrowerSpoke for vault owner claim
            if (surplus18 > 0) {
                uint256 surplus6 = surplus18 / 1e12;
                if (borrowerSpokeChainSelector == 0) {
                    // Local transfer
                    paymentToken.safeTransfer(borrowerSpoke, surplus6);
                } else {
                    // Cross-chain transfer via CCIP Token Transfer
                    Client.EVMTokenAmount[]
                        memory tokenAmounts = new Client.EVMTokenAmount[](1);
                    tokenAmounts[0] = Client.EVMTokenAmount({
                        token: address(paymentToken),
                        amount: surplus6
                    });

                    Client.EVM2AnyMessage memory message = Client
                        .EVM2AnyMessage({
                            receiver: abi.encode(borrowerSpoke),
                            data: abi.encode(auction.vaultId), // Send vaultId as data
                            tokenAmounts: tokenAmounts,
                            extraArgs: Client._argsToBytes(
                                Client.EVMExtraArgsV1({gasLimit: 200_000})
                            ),
                            feeToken: address(0) // Pay in native gas
                        });

                    uint256 fees = ccipRouter.getFee(
                        borrowerSpokeChainSelector,
                        message
                    );
                    paymentToken.forceApprove(address(ccipRouter), surplus6);
                    ccipRouter.ccipSend{value: fees}(
                        borrowerSpokeChainSelector,
                        message
                    );
                }
            }
        }

        emit AuctionSettled(
            auctionId,
            auction.settler,
            auction.settledPrice,
            debtRepayment18,
            surplus18
        );
    }

    /**
     * @notice Read vault debt from LiquidityPool
     * @param vaultId The vault ID to query
     * @return debt The outstanding debt amount
     */
    function _getVaultDebt(uint256 vaultId) internal view returns (uint256) {
        return ILiquidityPoolDebt(liquidityPool).vaultDebt(vaultId);
    }

    /**
     * @notice Allows the contract to receive native gas (for CCIP fees)
     */
    receive() external payable {}
}
