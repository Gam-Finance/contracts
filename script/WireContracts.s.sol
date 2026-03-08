// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {PolymarketAdapter} from "../src/adapters/PolymarketAdapter.sol";
import {DutchAuction} from "../src/DutchAuction.sol";

contract WireContracts is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Addresses from your deployments
        address hubReceiverAddr = vm.envAddress("HUB_RECEIVER_ADDRESS");
        address poolAddr = vm.envAddress("POOL_ADDRESS");
        address auctionAddr = vm.envAddress("DUTCH_AUCTION_ADDRESS");
        address borrowerSpokeAddr = vm.envAddress("BORROWER_SPOKE_ADDRESS");
        address lenderSpokeAddr = vm.envAddress("LENDER_SPOKE_ADDRESS");
        address adapterAddr = vm.envAddress("POLYMARKET_ADAPTER_ADDRESS");

        // Hub-side Spokes
        address hubBorrowerSpokeAddr = vm.envAddress(
            "HUB_BORROWER_SPOKE_ADDRESS"
        );
        address hubLenderSpokeAddr = vm.envAddress("HUB_LENDER_SPOKE_ADDRESS");

        // Token Addresses
        address arbLink = vm.envOr("ARB_LINK_ADDRESS", address(0));
        address arbUsdc = vm.envOr("ARB_USDC_ADDRESS", address(0));
        address baseUsdc = vm.envOr("BASE_USDC_ADDRESS", address(0));
        address baseLink = vm.envOr("BASE_LINK_ADDRESS", address(0));

        // Oracle / DON Address
        address oracleAddr = vm.envOr(
            "ORACLE_ADDRESS",
            vm.addr(deployerPrivateKey)
        );

        // Chain Selectors
        uint64 arbSepoliaSelector = 3478487238524512106;
        uint64 baseSepoliaSelector = 10344971235874465080;

        uint256 currentChainId = block.chainid;

        // --- BASE SEPOLIA WIRING ---
        if (currentChainId == 84532) {
            console.log("Wiring contracts on Base Sepolia...");

            // Wiring 1: HubReceiver (Base) -> Authorize Spokes
            if (hubReceiverAddr != address(0)) {
                // Arbitrum Spoke
                HubReceiver(hubReceiverAddr).setAuthorizedSpoke(
                    arbSepoliaSelector,
                    borrowerSpokeAddr
                );
                // Hub Spoke (Local Bypass)
                if (hubBorrowerSpokeAddr != address(0)) {
                    HubReceiver(hubReceiverAddr).setAuthorizedSpoke(
                        baseSepoliaSelector,
                        hubBorrowerSpokeAddr
                    );
                }
            }

            // Wiring 2: DutchAuction (Base) -> Set Borrower Spokes
            if (auctionAddr != address(0)) {
                if (borrowerSpokeAddr != address(0)) {
                    DutchAuction(payable(auctionAddr)).setBorrowerSpoke(
                        borrowerSpokeAddr,
                        arbSepoliaSelector
                    );
                }
                if (hubBorrowerSpokeAddr != address(0)) {
                    DutchAuction(payable(auctionAddr)).setBorrowerSpoke(
                        hubBorrowerSpokeAddr,
                        baseSepoliaSelector
                    );
                }
            }

            // Wiring 3: Hub LenderSpoke (Base) -> Set Hub Target (Local Pool)
            if (hubLenderSpokeAddr != address(0)) {
                LenderSpoke(payable(hubLenderSpokeAddr)).setHubTarget(
                    baseSepoliaSelector,
                    poolAddr
                );
            }

            // Wiring 4: Hub BorrowerSpoke (Base) -> Set Hub Params (Local)
            if (hubBorrowerSpokeAddr != address(0)) {
                BorrowerSpoke(payable(hubBorrowerSpokeAddr)).setHubParams(
                    hubReceiverAddr,
                    baseLink,
                    baseUsdc
                );
            }

            // Wiring 6: Pool Local Bypass
            if (poolAddr != address(0) && hubBorrowerSpokeAddr != address(0)) {
                OmnichainLiquidityPool(poolAddr).setLocalBypass(
                    hubBorrowerSpokeAddr,
                    true
                );
            }
        }

        // --- ARBITRUM SEPOLIA WIRING ---
        if (currentChainId == 421614) {
            console.log("Wiring contracts on Arbitrum Sepolia...");

            // Wiring 3: LenderSpoke (Arbitrum) -> Set Hub Target (Pool on Base)
            if (lenderSpokeAddr != address(0)) {
                LenderSpoke(payable(lenderSpokeAddr)).setHubTarget(
                    baseSepoliaSelector,
                    poolAddr
                );
            }

            // Wiring 4: BorrowerSpoke (Arbitrum) -> Set Hub Params
            if (borrowerSpokeAddr != address(0)) {
                BorrowerSpoke(payable(borrowerSpokeAddr)).setHubParams(
                    hubReceiverAddr,
                    arbLink,
                    arbUsdc
                );
            }

            // Wiring 5: PolymarketAdapter (Arbitrum) -> Link to BorrowerSpoke
            if (borrowerSpokeAddr != address(0) && adapterAddr != address(0)) {
                BorrowerSpoke(payable(borrowerSpokeAddr)).setPolymarketAdapter(
                    adapterAddr
                );
                BorrowerSpoke(payable(borrowerSpokeAddr)).grantRole(
                    BorrowerSpoke(payable(borrowerSpokeAddr)).LIQUIDATOR_ROLE(),
                    adapterAddr
                );

                // Grant Oracle Role to the DON/Admin
                PolymarketAdapter(adapterAddr).grantRole(
                    KeccakR(PolymarketAdapter(adapterAddr).ORACLE_ROLE()),
                    oracleAddr
                );
            }
        }
    }

    function KeccakR(bytes32 r) internal pure returns (bytes32) {
        return r;
    }
}
