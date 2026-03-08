// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {HubReceiver} from "../src/HubReceiver.sol";
import {OmnichainLiquidityPool} from "../src/OmnichainLiquidityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CCIPMessageCodec} from "../src/libraries/CCIPMessageCodec.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

// Mock USDC
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract HubReceiverTest is Test {
    HubReceiver public receiver;
    OmnichainLiquidityPool public pool;
    MockUSDC public usdc;

    address public admin = address(1);
    address public oracle = address(2);
    address public borrower = address(5);
    address public spoke1 = address(6);

    uint64 public constant SPOKE_1_CHAIN_SELECTOR = 111111;
    uint256 public constant VAULT_ID = 99;

    function setUp() public {
        vm.startPrank(admin);

        usdc = new MockUSDC();

        pool = new OmnichainLiquidityPool(
            address(0x888),
            address(usdc),
            admin,
            0.02e18,
            0.80e18,
            0.04e18,
            0.75e18,
            0.10e18
        );

        receiver = new HubReceiver(
            address(0x123), // mock router must be non-zero
            address(pool),
            admin
        );

        // Authorize Spoke
        receiver.setAuthorizedSpoke(SPOKE_1_CHAIN_SELECTOR, spoke1);

        // Grant Roles
        receiver.grantRole(receiver.ORACLE_ROLE(), oracle);
        pool.grantRole(pool.CCIP_RECEIVER_ROLE(), address(receiver));

        usdc.approve(address(pool), 100_000 * 10 ** 6);
        pool.deposit(100_000 * 10 ** 6);

        vm.stopPrank();
    }

    function test_ccipReceive_unauthorizedSpokeReverts() public {
        CCIPMessageCodec.LoanRequest memory req = CCIPMessageCodec.LoanRequest({
            vaultId: VAULT_ID,
            borrower: borrower,
            requestedLTV: 0.5e18,
            conditionId: 1,
            outcomeIndex: 0,
            amount: 50 * 10 ** 18
        });

        bytes[] memory emptyTokens;

        Client.Any2EVMMessage memory msgPayload = Client.Any2EVMMessage({
            messageId: bytes32(0),
            sourceChainSelector: 999999, // Unknown chain
            sender: abi.encode(spoke1),
            data: CCIPMessageCodec.encodeLoanRequest(req),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                HubReceiver.UnauthorizedSpokeChain.selector,
                999999
            )
        );

        vm.prank(address(0x123)); // router prank
        receiver.ccipReceive(msgPayload);
    }
}
