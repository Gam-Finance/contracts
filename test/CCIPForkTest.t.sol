// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    CCIPLocalSimulatorFork,
    Register
} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {Governance} from "../src/Governance.sol";
import {CCIDToken} from "../src/CCIDToken.sol";
import {ACEPolicyManager} from "../src/ACEPolicyManager.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {IBorrowerSpoke} from "../src/interfaces/IBorrowerSpoke.sol";
import {
    PolymarketAdapter,
    ICTFExchange
} from "../src/adapters/PolymarketAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockPredictionToken} from "../src/MockPredictionToken.sol";
import {CCIPMessageCodec} from "../src/libraries/CCIPMessageCodec.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {
    IRouterClient
} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

contract MockCTFExchange {
    address public usdc;
    constructor(address _usdc) {
        usdc = _usdc;
    }
    function fillOrder(bytes calldata, uint256, bytes calldata) external {
        // Simple manual deal won't work in a non-test contract
        // But we can just transfer if we fund this mock
        IERC20(usdc).transfer(msg.sender, 800 * 1e6);
    }
}

contract CCIPForkTest is Test {
    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    uint256 arbitrumSepoliaFork;
    uint256 baseSepoliaFork;

    BorrowerSpoke borrowerSpoke;
    LenderSpoke lenderSpoke;
    DutchAuction auction;
    HubReceiver hubReceiver;
    OmnichainLiquidityPool pool;
    CCIDToken ccid;
    ACEPolicyManager ace;
    Governance gov;
    MockPredictionToken pToken;
    ERC20 usdc;
    PolymarketAdapter adapter;

    address alice = makeAddr("pbcm_alice_unique");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory arbitrumRpc = vm.envString("ARBITRUM_SEPOLIA_RPC_URL");
        string memory baseRpc = vm.envString("BASE_SEPOLIA_RPC_URL");

        arbitrumSepoliaFork = vm.createSelectFork(arbitrumRpc);
        baseSepoliaFork = vm.createFork(baseRpc);

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork));

        // Setup Base Sepolia (Destination/Hub)
        vm.selectFork(baseSepoliaFork);
        Register.NetworkDetails memory baseDetails = ccipLocalSimulatorFork
            .getNetworkDetails(block.chainid);

        usdc = ERC20(baseDetails.ccipBnMAddress);

        gov = new Governance(
            address(this),
            0.85e18,
            1.1e18,
            5e16,
            0.1e18,
            1 hours,
            2 days
        );
        ccid = new CCIDToken(address(this));
        ccid.grantRole(ccid.IDENTITY_PROVIDER_ROLE(), address(this));
        ace = new ACEPolicyManager(address(this), address(ccid));

        pool = new OmnichainLiquidityPool(
            baseDetails.routerAddress,
            address(usdc),
            address(this),
            0.02e18,
            0.8e18,
            0.04e18,
            0.5e18,
            0.1e18
        );
        pool.setACEPolicyManager(address(ace));

        // We'll deploy auction later once we have borrowerSpoke address from other fork
        hubReceiver = new HubReceiver(
            baseDetails.routerAddress,
            address(pool),
            address(this)
        );

        // Setup Arbitrum Sepolia (Source/Spoke)
        vm.selectFork(arbitrumSepoliaFork);
        Register.NetworkDetails memory arbDetails = ccipLocalSimulatorFork
            .getNetworkDetails(block.chainid);

        borrowerSpoke = new BorrowerSpoke(
            address(this),
            arbDetails.routerAddress,
            0.85e18,
            1.1e18,
            1 days
        );
        borrowerSpoke.setHubParams(
            address(hubReceiver),
            arbDetails.linkAddress,
            arbDetails.ccipBnMAddress
        );

        adapter = new PolymarketAdapter(
            address(this),
            address(borrowerSpoke),
            address(0x1), // placeholder
            arbDetails.ccipBnMAddress
        );
        borrowerSpoke.setPolymarketAdapter(address(adapter));
        borrowerSpoke.grantRole(
            borrowerSpoke.LIQUIDATOR_ROLE(),
            address(adapter)
        );
        adapter.grantRole(adapter.ORACLE_ROLE(), address(this));

        lenderSpoke = new LenderSpoke(
            address(this),
            arbDetails.routerAddress,
            arbDetails.ccipBnMAddress,
            address(0)
        );
        lenderSpoke.setHubTarget(baseDetails.chainSelector, address(pool));

        pToken = new MockPredictionToken(address(this));

        // Go back to Base to finish wiring
        vm.selectFork(baseSepoliaFork);
        auction = new DutchAuction(
            address(this),
            address(usdc),
            address(pool),
            address(borrowerSpoke),
            1.5e18,
            0.5e18,
            24 hours,
            0.05e18,
            baseDetails.routerAddress,
            arbDetails.chainSelector
        );

        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), address(hubReceiver));
        pool.grantRole(pool.AUCTION_ROLE(), address(auction));
        hubReceiver.setAuthorizedSpoke(
            arbDetails.chainSelector,
            address(borrowerSpoke)
        );
        hubReceiver.grantRole(hubReceiver.ORACLE_ROLE(), address(this));
        // Fund pool with some USDC for loans
        deal(address(usdc), address(pool), 10_000 * 1e6);
    }

    function test_CrossChainDepositAndLoan() public {
        // 1. Alice deposits collateral on Arbitrum
        vm.selectFork(arbitrumSepoliaFork);
        uint256 conditionId = 123;
        uint256 amount = 1000 * 1e18;
        pToken.mint(alice, conditionId, amount, "");
        vm.startPrank(alice);
        pToken.setApprovalForAll(address(borrowerSpoke), true);

        // Fund BorrowerSpoke for CCIP fees (Worry-Free)
        vm.deal(address(borrowerSpoke), 1 ether);
        deal(
            address(borrowerSpoke.linkToken()),
            address(borrowerSpoke),
            10 ether
        );

        borrowerSpoke.depositCollateral(
            address(pToken),
            conditionId,
            0,
            amount,
            ccipLocalSimulatorFork.getNetworkDetails(84532).chainSelector, // Base Chain ID -> 84532 (Base Sepolia)
            0.5e18,
            block.timestamp + 10 days
        );
        vm.stopPrank();

        ccipLocalSimulatorFork.switchChainAndRouteMessage(baseSepoliaFork);
        // Now on Base Sepolia

        (
            uint256 vId,
            address borrowerAddr,
            uint256 ltv,
            uint256 cId,
            uint256 oIdx,
            uint256 amt
        ) = hubReceiver.pendingRequests(1);
        assertEq(borrowerAddr, alice);
        assertEq(vId, 1);
        assertEq(ltv, 0.5e18);
        assertEq(cId, conditionId);
        assertEq(oIdx, 0);
        assertEq(amt, amount);
    }
    function test_CrossChainSurplusReturn() public {
        // 1. Initial Deposit on Arbitrum
        test_CrossChainDepositAndLoan(); // Sets up vault 1 on Base in PENDING

        // 2. Active the vault on Base
        vm.selectFork(baseSepoliaFork);
        uint256 amount = 1000 * 1e18;
        vm.startPrank(address(this));
        hubReceiver.receiveValuation(
            CCIPMessageCodec.ValuationPayload({
                vaultId: 1,
                alpha: 0.1e18,
                collateralValue: amount,
                healthFactor: 2e18, // Very healthy for now
                loanAmount: 500 * 1e6, // $500 USDC
                timestamp: block.timestamp
            })
        );
        vm.stopPrank();

        // 3. Simulate Liquidation (Price drops below margin)
        // HubReceiver now has an active vault. Let's start an auction.
        // We need to grant ORACLE_ROLE to this address to start auction
        auction.grantRole(auction.ORACLE_ROLE(), address(this));

        // Fund Auction for CCIP fees
        vm.deal(address(auction), 1 ether);

        uint256 auctionId = auction.startAuction(1);

        // Bid after some time
        vm.warp(block.timestamp + 1 hours);
        uint256 price = auction.getCurrentPrice(auctionId);

        // Bob bids
        deal(address(usdc), bob, price);
        vm.startPrank(bob);
        usdc.approve(address(auction), type(uint256).max);
        auction.bid(auctionId);
        vm.stopPrank();

        // 4. Route Surplus back to Arbitrum
        ccipLocalSimulatorFork.switchChainAndRouteMessage(arbitrumSepoliaFork);

        // 5. Verify Surplus on Arbitrum
        vm.selectFork(arbitrumSepoliaFork);
        uint256 surplus = borrowerSpoke.getVaultSurplus(1);
        assertTrue(surplus > 0, "Surplus should be > 0");

        // Alice claims surplus
        vm.startPrank(alice);
        borrowerSpoke.claimSurplus(1);
        vm.stopPrank();

        assertEq(
            IERC20(address(borrowerSpoke.usdcToken())).balanceOf(alice),
            surplus,
            "Alice should have received surplus"
        );
    }

    function test_DirectPolymarketLiquidation() public {
        // 1. Initial Deposit and Loan
        test_CrossChainDepositAndLoan(); // Vault 1 on Base, but Spoke still thinks it's PENDING until valuation

        // 2. Mock Valuation to make it ACTIVE on Spoke
        vm.selectFork(arbitrumSepoliaFork);
        // We simulate the CRE valuation report arriving at the Spoke
        borrowerSpoke.grantRole(borrowerSpoke.ORACLE_ROLE(), address(this));
        borrowerSpoke.receiveValuation(
            IBorrowerSpoke.ValuationReport({
                vaultId: 1,
                alpha: 1e18,
                impliedProbability: 0.5e18,
                collateralValue: 1000 * 1e18,
                healthFactor: 2e18,
                timestamp: block.timestamp
            })
        );

        // 3. Trigger Liquidation on Spoke
        // In reality, this happens if Health Factor < Maintenance Margin
        // For test, we set the status directly (requires LIQUIDATOR_ROLE or similar if we had a forced liquidate)
        // Actually, let's just mock a bad valuation to trigger it naturally.
        borrowerSpoke.receiveValuation(
            IBorrowerSpoke.ValuationReport({
                vaultId: 1,
                alpha: 1e18,
                impliedProbability: 0.1e18,
                collateralValue: 1000 * 1e18,
                healthFactor: 0.5e18, // Below margin
                timestamp: block.timestamp
            })
        );

        assertEq(
            uint(borrowerSpoke.getVault(1).status),
            uint(IBorrowerSpoke.VaultStatus.LIQUIDATING)
        );

        // 4. Execute Polymarket Liquidation
        vm.selectFork(arbitrumSepoliaFork);
        MockCTFExchange mockCtfExchange = new MockCTFExchange(
            address(borrowerSpoke.usdcToken())
        );
        deal(
            address(borrowerSpoke.usdcToken()),
            address(mockCtfExchange),
            1000 * 1e6
        );

        adapter.grantRole(adapter.ORACLE_ROLE(), address(this));
        adapter.setCtfExchange(address(mockCtfExchange));

        // Execute dump
        adapter.executeLiquidateSwap(
            1,
            address(pToken),
            123,
            1000 * 1e18,
            "order_payload",
            "signature"
        );

        // 5. Route Repayment back to Hub
        ccipLocalSimulatorFork.switchChainAndRouteMessage(baseSepoliaFork);

        // 6. Verify Hub Debt is settled
        vm.selectFork(baseSepoliaFork);
        uint256 debtOnHub = pool.vaultDebt(1);
        assertEq(
            debtOnHub,
            0,
            "Debt on Hub should be 0 after direct liquidation"
        );

        // 7. Verify Spoke Surplus
        vm.selectFork(arbitrumSepoliaFork);
        uint256 surplus = borrowerSpoke.getVaultSurplus(1);
        uint256 expectedSurplus = (800 * 1e6) - (500 * 1e6); // Recov - Initial Loan
        assertEq(surplus, expectedSurplus, "Surplus mismatch on Spoke");
    }
    function test_CrossChainLenderDeposit() public {
        // 1. Make Bob compliant on Hub (Base)
        vm.selectFork(baseSepoliaFork);
        ccid.mint(bob, 0);

        // 2. Setup Lender on Arbitrum
        vm.selectFork(arbitrumSepoliaFork);
        address arbUsdc = address(lenderSpoke.underlyingAsset());
        uint256 depositAmount = 1000 * 1e6; // $1000 USDC
        deal(arbUsdc, bob, depositAmount);

        vm.startPrank(bob);
        IERC20(arbUsdc).approve(address(lenderSpoke), depositAmount);

        // Fund LenderSpoke for CCIP fees (Native)
        vm.deal(address(lenderSpoke), 1 ether);

        lenderSpoke.depositToHub(depositAmount);
        vm.stopPrank();

        // 2. Route Message to Base (Hub)
        ccipLocalSimulatorFork.switchChainAndRouteMessage(baseSepoliaFork);

        // 3. Verify Hub Pool State
        vm.selectFork(baseSepoliaFork);
        uint256 expectedShares = depositAmount * 1e12; // 1:1 at start, in WAD
        assertEq(
            pool.balanceOf(bob),
            expectedShares,
            "Bob should have received shares on Hub"
        );
        assertEq(
            pool.totalDeposited(),
            expectedShares,
            "Pool total deposits mismatch"
        );
    }
}
