// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {Governance} from "../src/Governance.sol";
import {CCIDToken} from "../src/CCIDToken.sol";
import {ACEPolicyManager} from "../src/ACEPolicyManager.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockPredictionToken} from "../src/MockPredictionToken.sol";
import {
    MockCCIPRouter
} from "@chainlink/contracts-ccip/src/v0.8/ccip/test/mocks/MockRouter.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract DeployLocal is Script {
    uint64 constant MOCK_SELECTOR = 16015286601757825753;

    struct Core {
        MockCCIPRouter router;
        Governance gov;
        MockUSDC usdc;
        CCIDToken ccid;
        ACEPolicyManager ace;
        OmnichainLiquidityPool pool;
        HubReceiver receiver;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envOr(
            "PRIVATE_KEY",
            uint256(
                0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
            )
        );
        address deployer = vm.addr(deployerPrivateKey);
        address seedAddress = vm.envOr("SEED_ADDRESS", deployer);

        vm.startBroadcast(deployerPrivateKey);

        console.log("=== Deploying Full PBCM Ecosystem (No-IR) ===");

        Core memory core = _deployCore(deployer);
        _deploySpokesAndSeed(core, deployer, seedAddress);

        console.log("=== Local PBCM Deployment Complete ===");
        vm.stopBroadcast();
    }

    function _deployCore(address deployer) internal returns (Core memory c) {
        c.router = new MockCCIPRouter();
        address rAddr = address(c.router);
        console.log("MockCCIPRouter:", rAddr);

        c.gov = new Governance(
            deployer,
            0.70e18,
            1.25e18,
            0.001e18,
            0.10e18,
            4 hours,
            2 days
        );
        console.log("Governance:", address(c.gov));

        c.usdc = new MockUSDC();
        console.log("MockUSDC:", address(c.usdc));

        c.ccid = new CCIDToken(deployer);
        c.ccid.grantRole(c.ccid.IDENTITY_PROVIDER_ROLE(), deployer);
        c.ccid.mint(deployer, 0);
        console.log("CCIDToken & Compliance Minted.");

        c.ace = new ACEPolicyManager(deployer, address(c.ccid));
        console.log("ACEPolicyManager:", address(c.ace));

        c.pool = new OmnichainLiquidityPool(
            rAddr,
            address(c.usdc),
            deployer,
            0.02e18,
            0.80e18,
            0.04e18,
            0.75e18,
            0.10e18
        );
        c.pool.setACEPolicyManager(address(c.ace));
        console.log("OmnichainLiquidityPool:", address(c.pool));

        c.receiver = new HubReceiver(rAddr, address(c.pool), deployer);
        console.log("HubReceiver:", address(c.receiver));
    }

    function _deploySpokesAndSeed(
        Core memory c,
        address deployer,
        address seedAddress
    ) internal {
        BorrowerSpoke bSpoke = new BorrowerSpoke(
            deployer,
            address(c.router),
            0.85e18,
            1.1e18,
            1 days,
            31337 // Local Hub selector
        );
        console.log("BorrowerSpoke:", address(bSpoke));

        DutchAuction auction = new DutchAuction(
            deployer,
            address(c.usdc),
            address(c.pool),
            address(bSpoke),
            1.10e18,
            0.50e18,
            6 hours,
            0.05e18,
            address(c.router),
            MOCK_SELECTOR
        );
        console.log("DutchAuction:", address(auction));

        LenderSpoke lSpoke = new LenderSpoke(
            deployer,
            address(c.router),
            address(c.usdc),
            address(0)
        );
        lSpoke.setHubTarget(MOCK_SELECTOR, address(c.pool));
        lSpoke.grantRole(lSpoke.PAUSER_ROLE(), deployer);
        console.log("LenderSpoke:", address(lSpoke));

        // BorrowerSpoke Hub Wiring (HubReceiver, LINK, USDC)
        bSpoke.setHubParams(address(c.receiver), address(0), address(c.usdc));

        // Oracle Roles for local testing
        bSpoke.grantRole(bSpoke.ORACLE_ROLE(), deployer);
        bSpoke.grantRole(bSpoke.ORACLE_ROLE(), address(c.pool));
        c.receiver.grantRole(c.receiver.ORACLE_ROLE(), deployer);
        console.log("Oracle Roles granted to deployer and pool.");

        // Wiring
        c.pool.grantRole(c.pool.CCIP_RECEIVER_ROLE(), address(c.receiver));
        c.pool.grantRole(c.pool.AUCTION_ROLE(), address(auction));
        c.pool.setLocalBypass(address(bSpoke), true);
        c.receiver.setAuthorizedSpoke(MOCK_SELECTOR, address(bSpoke));
        c.receiver.grantRole(c.receiver.LOCAL_SPOKE_ROLE(), address(bSpoke));

        // Seeding
        c.usdc.approve(address(c.pool), 100_000 * 10 ** 6);
        c.pool.deposit(100_000 * 10 ** 6);

        MockPredictionToken pToken = new MockPredictionToken(deployer);
        pToken.mint(seedAddress, 1001, 5000 * 1e18, "");
        console.log("Seeding Complete for:", seedAddress);
    }
}
