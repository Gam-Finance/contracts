// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Governance} from "../src/Governance.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {CCIDToken} from "../src/CCIDToken.sol";
import {ACEPolicyManager} from "../src/ACEPolicyManager.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";

// Use official Circle testnet USDC
address constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

contract DeployDestination is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Official Base Sepolia USDC
        address usdc = BASE_SEPOLIA_USDC;

        // 2. Base Sepolia CCIP Router
        address baseSepoliaRouter = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;

        // 3. Deploy Governance
        // args: admin, _maxLTV, _maintenanceMargin, _timeDecayConstant, _reserveFactor, _minAuctionDuration, _executionDelay
        Governance governance = new Governance(
            admin,
            0.85e18, // maxLTV 85%
            1.1e18, // maintenanceMargin 1.1
            5e16, // timeDecayConstant (0.05 per hour)
            0.1e18, // reserveFactor 10%
            1 hours, // min auction duration
            2 days // execution delay
        );

        // 4. Deploy KYC and Compliance
        CCIDToken ccidToken = new CCIDToken(admin);
        ACEPolicyManager aceManager = new ACEPolicyManager(
            admin,
            address(ccidToken)
        );

        // 5. Deploy Liquidity Pool
        // args: _ccipRouter, _usdc, admin, _baseRate, _kink, _slope1, _slope2, _reserveFactor
        OmnichainLiquidityPool pool = new OmnichainLiquidityPool(
            baseSepoliaRouter,
            address(usdc),
            admin,
            0.02e18, // 2% base
            0.8e18, // 80% kink
            0.04e18, // 4% slope 1
            0.5e18, // 50% slope 2
            0.1e18 // 10% reserve factor
        );
        pool.setACEPolicyManager(address(aceManager));

        // 6. Deploy Dutch Auction
        // args: admin, _paymentToken, _liquidityPool, _borrowerSpoke, _startPricePremium, _floorPriceFraction, _defaultAuctionDuration, _keeperIncentive
        address borrowerSpoke = vm.envOr("BORROWER_SPOKE_ADDRESS", address(0));

        DutchAuction auction = new DutchAuction(
            admin,
            address(usdc),
            address(pool),
            borrowerSpoke,
            1.1e18, // 110% start premium
            0.5e18, // 50% floor price fraction
            24 hours, // default duration
            0.05e18, // 5% keeper incentive
            baseSepoliaRouter,
            3478487238524512106 // Arbitrum Sepolia Selector
        );

        // 7. Deploy Hub Receiver
        HubReceiver hubReceiver = new HubReceiver(
            baseSepoliaRouter,
            address(pool),
            admin
        );

        // 8. Deploy BorrowerSpoke to Hub (Base Sepolia)
        BorrowerSpoke hubBorrowerSpoke = new BorrowerSpoke(
            admin,
            baseSepoliaRouter,
            0.85e18, // 85% LTV max
            1.1e18, // 110% Maintenance Margin
            1 days, // 24H Staleness Tolerance
            10344971235874465080 // Base Sepolia Selector
        );

        // 9. Deploy LenderSpoke to Hub (Base Sepolia)
        LenderSpoke hubLenderSpoke = new LenderSpoke(
            admin,
            baseSepoliaRouter,
            address(usdc),
            address(0) // Will set hub pool after
        );

        // 8. Whitelist Hub on Pool and Auction
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), address(hubReceiver));
        pool.grantRole(pool.AUCTION_ROLE(), address(auction));

        vm.stopBroadcast();

        console.log("=== DESTINATION (Base Sepolia) DEPLOYMENT ===");
        console.log("Deployer / Admin:", admin);
        console.log("Official USDC:", usdc);
        console.log("Governance:", address(governance));
        console.log("CCIDToken:", address(ccidToken));
        console.log("ACEPolicyManager:", address(aceManager));
        console.log("OmnichainLiquidityPool:", address(pool));
        console.log("DutchAuction:", address(auction));
        console.log("HubReceiver:", address(hubReceiver));
        console.log("BorrowerSpoke:", address(hubBorrowerSpoke));
        console.log("LenderSpoke:", address(hubLenderSpoke));
    }
}
