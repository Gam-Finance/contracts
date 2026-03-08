// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {PolymarketAdapter} from "../src/adapters/PolymarketAdapter.sol";

contract WireArbitrum is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        address lenderSpokeAddr = vm.envAddress("LENDER_SPOKE_ADDRESS");
        address borrowerSpokeAddr = vm.envAddress("BORROWER_SPOKE_ADDRESS");
        address adapterAddr = vm.envAddress("POLYMARKET_ADAPTER_ADDRESS");
        address hubReceiverAddr = vm.envAddress("HUB_RECEIVER_ADDRESS");
        address poolAddr = vm.envAddress("POOL_ADDRESS");
        address arbLink = vm.envAddress("ARB_LINK_ADDRESS");
        address arbUsdc = vm.envAddress("ARB_USDC_ADDRESS");
        address oracleAddr = vm.envOr("ORACLE_ADDRESS", deployer);

        uint64 baseSepoliaSelector = 10344971235874465080;

        console.log("Wiring Arbitrum Spokes...");
        console.log("LenderSpoke:", lenderSpokeAddr);
        console.log("BorrowerSpoke:", borrowerSpokeAddr);

        // Wiring 3: LenderSpoke (Arbitrum) -> Set Hub Target (Pool on Base)
        LenderSpoke(payable(lenderSpokeAddr)).setHubTarget(
            baseSepoliaSelector,
            poolAddr
        );

        // Wiring 4: BorrowerSpoke (Arbitrum) -> Set Hub Params
        BorrowerSpoke(payable(borrowerSpokeAddr)).setHubParams(
            hubReceiverAddr,
            arbLink,
            arbUsdc
        );

        // Wiring 5: PolymarketAdapter (Arbitrum) -> Link to BorrowerSpoke
        if (adapterAddr != address(0)) {
            BorrowerSpoke(payable(borrowerSpokeAddr)).setPolymarketAdapter(
                adapterAddr
            );
            BorrowerSpoke(payable(borrowerSpokeAddr)).grantRole(
                BorrowerSpoke(payable(borrowerSpokeAddr)).LIQUIDATOR_ROLE(),
                adapterAddr
            );

            // Grant Oracle Role to the DON/Admin
            PolymarketAdapter(adapterAddr).grantRole(
                PolymarketAdapter(adapterAddr).ORACLE_ROLE(),
                oracleAddr
            );
        }

        vm.stopBroadcast();
    }
}
