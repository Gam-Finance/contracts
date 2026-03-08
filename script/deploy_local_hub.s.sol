// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Governance} from "../src/Governance.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployLocalHub is Script {
    function run() external {
        // Use default Anvil account 0 if PRIVATE_KEY isn't set
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(
                0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
            )
        );
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying Omnichain Hub to Local Node ===");
        console.log("Deployer:", deployer);

        // Dummy CCIP Router for Local Test
        address mockCcipRouter = address(
            0x1234567890123456789012345678901234567890
        );

        // 1. Deploy Governance
        Governance gov = new Governance(
            deployer, // admin
            0.70e18, // maxLTV = 70%
            1.25e18, // maintenanceMargin = 125%
            0.001e18, // timeDecayConstant
            0.10e18, // reserveFactor = 10%
            4 hours, // minAuctionDuration
            2 days // executionDelay
        );
        console.log("Governance deployed at:", address(gov));

        // 2. Deploy Mock USDC
        MockUSDC usdc = new MockUSDC();
        console.log("Mock USDC deployed at:", address(usdc));

        // 3. Deploy OmnichainLiquidityPool
        OmnichainLiquidityPool pool = new OmnichainLiquidityPool(
            mockCcipRouter,
            address(usdc),
            deployer,
            0.02e18, // baseRate
            0.80e18, // kink
            0.04e18, // slope1
            0.75e18, // slope2
            0.10e18 // reserveFactor
        );
        console.log("OmnichainLiquidityPool deployed at:", address(pool));

        // 4. Deploy HubReceiver
        HubReceiver receiver = new HubReceiver(
            mockCcipRouter,
            address(pool),
            deployer // admin
        );
        console.log("HubReceiver deployed at:", address(receiver));

        // 5. Deploy DutchAuction
        DutchAuction auction = new DutchAuction(
            deployer, // admin
            address(usdc),
            address(pool),
            address(receiver), // Use receiver as the PredictionBox callback source for simplicty locally
            1.10e18, // startPricePremium
            0.50e18, // floorPriceFraction
            6 hours, // defaultAuctionDuration
            0.05e18, // keeperIncentive
            mockCcipRouter,
            0 // local chain selector
        );
        console.log("DutchAuction deployed at:", address(auction));

        // 6. Connect receiver to pool
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), address(receiver));
        console.log("Granted CCIP_RECEIVER_ROLE to HubReceiver");

        // 7. Seed LiquidityPool Configuration
        usdc.approve(address(pool), 100_000 * 10 ** 6);
        pool.deposit(100_000 * 10 ** 6);
        console.log("Seeded OmnichainLiquidityPool with 100,000 mUSDC");

        console.log("=== Local Hub Deployment Complete ===");
        vm.stopBroadcast();
    }
}
