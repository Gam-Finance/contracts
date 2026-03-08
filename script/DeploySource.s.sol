// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {PolymarketAdapter} from "../src/adapters/PolymarketAdapter.sol";

// Use official Circle testnet USDC for Arbitrum Sepolia
address constant ARBITRUM_SEPOLIA_USDC = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
address constant ARBITRUM_SEPOLIA_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;

contract DeploySource is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy BorrowerSpoke to Arbitrum Sepolia
        BorrowerSpoke borrowerSpoke = new BorrowerSpoke(
            admin,
            ARBITRUM_SEPOLIA_ROUTER,
            0.85e18, // 85% LTV max
            1.1e18, // 110% Maintenance Margin
            1 days, // 24H Staleness Tolerance
            3478487238524512106 // Arbitrum Sepolia Selector
        );

        // 2. Deploy LenderSpoke to Arbitrum Sepolia
        LenderSpoke lenderSpoke = new LenderSpoke(
            admin,
            ARBITRUM_SEPOLIA_ROUTER,
            ARBITRUM_SEPOLIA_USDC,
            address(0)
        );

        // 3. Deploy PolymarketAdapter (CTF Mock for testnet)
        address ctfExchange = vm.envOr("ARB_CTF_EXCHANGE", address(0x1));
        PolymarketAdapter adapter = new PolymarketAdapter(
            admin,
            address(borrowerSpoke),
            ctfExchange,
            ARBITRUM_SEPOLIA_USDC
        );

        vm.stopBroadcast();

        console.log("=== SOURCE (Arbitrum Sepolia) DEPLOYMENT ===");
        console.log("Deployer / Admin:", admin);
        console.log("Official USDC:", ARBITRUM_SEPOLIA_USDC);
        console.log("BorrowerSpoke:", address(borrowerSpoke));
        console.log("LenderSpoke:", address(lenderSpoke));
        console.log("PolymarketAdapter:", address(adapter));
    }
}
