// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {Governance} from "../src/Governance.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {CCIDToken} from "../src/CCIDToken.sol";
import {ACEPolicyManager} from "../src/ACEPolicyManager.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {PolymarketAdapter} from "../src/adapters/PolymarketAdapter.sol";

/**
 * @title SimulateAll
 * @notice Executes the entire cross-chain deployment and wiring flow in a single simulation.
 */
contract SimulateAll is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        address poolAddr;
        address hubReceiverAddr;
        address auctionAddr;
        address borrowerSpokeAddr;
        address adapterAddr;
        address hubBorrowerSpokeAddr;
        address hubLenderSpokeAddr;

        // 1. Deploy Hub Components (Base Sepolia Simulation)
        {
            address baseSepoliaRouter = 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93;
            address baseUsdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

            CCIDToken ccidToken = new CCIDToken(admin);
            ACEPolicyManager aceManager = new ACEPolicyManager(
                admin,
                address(ccidToken)
            );

            OmnichainLiquidityPool pool = new OmnichainLiquidityPool(
                baseSepoliaRouter,
                baseUsdc,
                admin,
                0.02e18,
                0.8e18,
                0.04e18,
                0.5e18,
                0.1e18
            );
            pool.setACEPolicyManager(address(aceManager));
            poolAddr = address(pool);

            DutchAuction auction = new DutchAuction(
                admin,
                baseUsdc,
                address(pool),
                address(0),
                1.1e18,
                0.5e18,
                24 hours,
                0.05e18,
                baseSepoliaRouter,
                3478487238524512106
            );
            auctionAddr = address(auction);

            HubReceiver hubReceiver = new HubReceiver(
                baseSepoliaRouter,
                address(pool),
                admin
            );
            hubReceiverAddr = address(hubReceiver);

            pool.grantRole(pool.CCIP_RECEIVER_ROLE(), address(hubReceiver));
            pool.grantRole(pool.AUCTION_ROLE(), address(auction));

            // Deploy Hub-side Spokes
            BorrowerSpoke hubBorrowerSpoke = new BorrowerSpoke(
                admin,
                baseSepoliaRouter,
                0.85e18,
                1.1e18,
                1 days,
                10344971235874465080 // Base Sepolia Selector
            );
            hubBorrowerSpokeAddr = address(hubBorrowerSpoke);

            LenderSpoke hubLenderSpoke = new LenderSpoke(
                admin,
                baseSepoliaRouter,
                baseUsdc,
                address(0)
            );
            hubLenderSpokeAddr = address(hubLenderSpoke);
        }

        // 2. Deploy Spoke Components (Arbitrum Sepolia Simulation)
        {
            address arbSepoliaRouter = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
            address arbUsdc = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

            BorrowerSpoke borrowerSpoke = new BorrowerSpoke(
                admin,
                arbSepoliaRouter,
                0.85e18,
                1.1e18,
                1 days,
                3478487238524512106 // Arbitrum Sepolia Selector
            );
            borrowerSpokeAddr = address(borrowerSpoke);

            new LenderSpoke(admin, arbSepoliaRouter, arbUsdc, address(0));

            PolymarketAdapter adapter = new PolymarketAdapter(
                admin,
                address(borrowerSpoke),
                address(0x1),
                arbUsdc
            );
            adapterAddr = address(adapter);
        }

        // 3. Wiring Phase
        {
            uint64 arbSepoliaSelector = 3478487238524512106;
            uint64 baseSepoliaSelector = 10344971235874465080;
            address arbLink = 0xb1d4538B4571D411f07960eF26384447283d8985;
            address arbUsdc = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

            HubReceiver(hubReceiverAddr).setAuthorizedSpoke(
                arbSepoliaSelector,
                borrowerSpokeAddr
            );
            DutchAuction(payable(auctionAddr)).setBorrowerSpoke(
                borrowerSpokeAddr,
                arbSepoliaSelector
            );
            BorrowerSpoke(payable(borrowerSpokeAddr)).setHubParams(
                hubReceiverAddr,
                arbLink,
                arbUsdc
            );
            BorrowerSpoke(payable(borrowerSpokeAddr)).setPolymarketAdapter(
                adapterAddr
            );
            BorrowerSpoke(payable(borrowerSpokeAddr)).grantRole(
                BorrowerSpoke(payable(borrowerSpokeAddr)).LIQUIDATOR_ROLE(),
                adapterAddr
            );
            PolymarketAdapter(adapterAddr).grantRole(
                PolymarketAdapter(adapterAddr).ORACLE_ROLE(),
                admin
            );

            // Hub-side Wiring
            OmnichainLiquidityPool(poolAddr).setLocalBypass(
                hubBorrowerSpokeAddr,
                true
            );
            BorrowerSpoke(payable(hubBorrowerSpokeAddr)).setHubParams(
                hubReceiverAddr,
                address(0),
                0x036CbD53842c5426634e7929541eC2318f3dCF7e
            );
            LenderSpoke(payable(hubLenderSpokeAddr)).setHubTarget(
                baseSepoliaSelector,
                poolAddr
            );
            DutchAuction(payable(auctionAddr)).setBorrowerSpoke(
                hubBorrowerSpokeAddr,
                baseSepoliaSelector
            );
            HubReceiver(hubReceiverAddr).setAuthorizedSpoke(
                baseSepoliaSelector,
                hubBorrowerSpokeAddr
            );
        }

        vm.stopBroadcast();

        console.log("=== FULL UNIFIED SIMULATION SUCCESSFUL ===");
        console.log("Hub Receiver:", hubReceiverAddr);
        console.log("Borrower Spoke:", borrowerSpokeAddr);
        console.log("Polymarket Adapter:", adapterAddr);
    }
}
