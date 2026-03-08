// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LenderSpoke} from "../src/LenderSpoke.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    Client
} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

// Mock router for intercepting ccipSend and fee estimation
contract MockRouterClient {
    uint256 public lastFeeCharged;

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure returns (uint256) {
        return 0.01 ether; // 0.01 native gas
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata
    ) external payable returns (bytes32) {
        lastFeeCharged = msg.value;
        return bytes32(uint256(1));
    }
}

// Mock router with LINK fee support
contract MockRouterClientWithLink {
    IERC20 public linkToken;

    constructor(address _link) {
        linkToken = IERC20(_link);
    }

    function getFee(
        uint64,
        Client.EVM2AnyMessage memory
    ) external pure returns (uint256) {
        return 1e18; // 1 LINK
    }

    function ccipSend(
        uint64,
        Client.EVM2AnyMessage calldata
    ) external returns (bytes32) {
        return bytes32(uint256(42));
    }
}

contract TestUSDC is ERC20 {
    constructor() ERC20("Test USDC", "tUSDC") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract TestLINK is ERC20 {
    constructor() ERC20("Test LINK", "tLINK") {
        _mint(msg.sender, 1_000_000 * 1e18);
    }
}

contract LenderSpokeTest is Test {
    LenderSpoke public spoke;
    TestUSDC public usdc;
    MockRouterClient public router;

    address public admin = address(1);
    address public lender = address(2);
    address public hubPool = address(3);
    uint64 public constant HUB_SELECTOR = 123456;

    function setUp() public {
        usdc = new TestUSDC();
        router = new MockRouterClient();

        vm.startPrank(admin);
        spoke = new LenderSpoke(
            admin,
            address(router),
            address(usdc),
            address(0) // Native gas for fees
        );
        spoke.setHubTarget(HUB_SELECTOR, hubPool);

        // Seed Spoke with Native Gas to pay the CCIP router
        vm.deal(address(spoke), 10 ether);
        vm.stopPrank();

        usdc.transfer(lender, 5000 * 10 ** 6);
    }

    // ──────────────────────────────────────────────
    // Constructor Tests
    // ──────────────────────────────────────────────

    function test_constructor_setsState() public view {
        assertEq(address(spoke.ccipRouter()), address(router));
        assertEq(address(spoke.underlyingAsset()), address(usdc));
        assertEq(spoke.hubPoolAddress(), hubPool);
        assertEq(spoke.hubChainSelector(), HUB_SELECTOR);
        assertTrue(spoke.hasRole(spoke.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(spoke.hasRole(spoke.PAUSER_ROLE(), admin));
    }

    function test_constructor_revertsZeroAdmin() public {
        vm.expectRevert(LenderSpoke.ZeroAddress.selector);
        new LenderSpoke(address(0), address(router), address(usdc), address(0));
    }

    function test_constructor_revertsZeroRouter() public {
        vm.expectRevert(LenderSpoke.ZeroAddress.selector);
        new LenderSpoke(admin, address(0), address(usdc), address(0));
    }

    function test_constructor_revertsZeroUsdc() public {
        vm.expectRevert(LenderSpoke.ZeroAddress.selector);
        new LenderSpoke(admin, address(router), address(0), address(0));
    }

    // ──────────────────────────────────────────────
    // setHubTarget Tests
    // ──────────────────────────────────────────────

    function test_setHubTarget_success() public {
        address newPool = makeAddr("newPool");
        uint64 newSelector = 789;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit LenderSpoke.HubUpdated(newSelector, newPool);
        spoke.setHubTarget(newSelector, newPool);

        assertEq(spoke.hubPoolAddress(), newPool);
        assertEq(spoke.hubChainSelector(), newSelector);
    }

    function test_setHubTarget_revertsIfNotAdmin() public {
        vm.prank(lender);
        vm.expectRevert();
        spoke.setHubTarget(789, makeAddr("pool"));
    }

    function test_setHubTarget_revertsZeroPool() public {
        vm.prank(admin);
        vm.expectRevert(LenderSpoke.ZeroAddress.selector);
        spoke.setHubTarget(789, address(0));
    }

    function test_setHubTarget_revertsZeroSelector() public {
        vm.prank(admin);
        vm.expectRevert(LenderSpoke.InvalidHub.selector);
        spoke.setHubTarget(0, makeAddr("pool"));
    }

    // ──────────────────────────────────────────────
    // depositToHub Tests
    // ──────────────────────────────────────────────

    function test_depositToHub_calculatesFeesAndSendsAcrossCCIP() public {
        vm.startPrank(lender);
        usdc.approve(address(spoke), 1000 * 10 ** 6);

        // Capture balance before
        uint256 spokeEthBefore = address(spoke).balance;

        bytes32 messageId = spoke.depositToHub(1000 * 10 ** 6);

        // Should have charged 0.01 ether based on MockRouterClient
        assertEq(address(spoke).balance, spokeEthBefore - 0.01 ether);
        assertEq(usdc.balanceOf(lender), 4000 * 10 ** 6);

        // The Spoke approves the router, so the USDC sits in the Spoke briefly
        // until the CCIP Router actually calls `transferFrom(spoke)`.
        // In local Mock, it just stays in the spoke.
        assertEq(usdc.balanceOf(address(spoke)), 1000 * 10 ** 6);
        assertNotEq(messageId, bytes32(0));
        vm.stopPrank();
    }

    function test_depositToHub_emitsDepositInitiated() public {
        vm.startPrank(lender);
        usdc.approve(address(spoke), 500 * 10 ** 6);

        vm.expectEmit(true, false, false, true);
        emit LenderSpoke.DepositInitiated(
            lender,
            500 * 10 ** 6,
            bytes32(uint256(1))
        );
        spoke.depositToHub(500 * 10 ** 6);
        vm.stopPrank();
    }

    function test_depositToHub_zeroAmountReverts() public {
        vm.prank(lender);
        vm.expectRevert(LenderSpoke.ZeroAmount.selector);
        spoke.depositToHub(0);
    }

    function test_depositToHub_unconfiguredHubReverts() public {
        vm.prank(admin);
        LenderSpoke unconfiguredSpoke = new LenderSpoke(
            admin,
            address(router),
            address(usdc),
            address(0)
        );

        vm.expectRevert(LenderSpoke.InvalidHub.selector);
        vm.prank(lender);
        unconfiguredSpoke.depositToHub(100);
    }

    function test_depositToHub_revertsWhenPaused() public {
        vm.prank(admin);
        spoke.pause();

        vm.startPrank(lender);
        usdc.approve(address(spoke), 100 * 10 ** 6);
        vm.expectRevert();
        spoke.depositToHub(100 * 10 ** 6);
        vm.stopPrank();
    }

    function test_depositToHub_multipleDeposits() public {
        vm.startPrank(lender);
        usdc.approve(address(spoke), 2000 * 10 ** 6);

        spoke.depositToHub(500 * 10 ** 6);
        spoke.depositToHub(500 * 10 ** 6);

        assertEq(usdc.balanceOf(lender), 4000 * 10 ** 6);
        assertEq(usdc.balanceOf(address(spoke)), 1000 * 10 ** 6);
        vm.stopPrank();
    }

    function test_depositToHub_insufficientNativeGasReverts() public {
        // Deploy a new spoke with no native gas
        vm.prank(admin);
        LenderSpoke brokeSpoke = new LenderSpoke(
            admin,
            address(router),
            address(usdc),
            address(0)
        );
        vm.prank(admin);
        brokeSpoke.setHubTarget(HUB_SELECTOR, hubPool);

        // Transfer USDC to lender and approve
        usdc.transfer(lender, 100 * 10 ** 6);
        vm.startPrank(lender);
        usdc.approve(address(brokeSpoke), 100 * 10 ** 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                LenderSpoke.NotEnoughBalance.selector,
                0, // spoke has 0 ETH
                0.01 ether // fee required
            )
        );
        brokeSpoke.depositToHub(100 * 10 ** 6);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // Pause / Unpause Tests
    // ──────────────────────────────────────────────

    function test_pause_onlyPauserRole() public {
        vm.prank(lender);
        vm.expectRevert();
        spoke.pause();
    }

    function test_unpause_onlyAdmin() public {
        vm.prank(admin);
        spoke.pause();

        vm.prank(lender);
        vm.expectRevert();
        spoke.unpause();

        // Admin can unpause
        vm.prank(admin);
        spoke.unpause();

        // Verify deposit works after unpause
        vm.startPrank(lender);
        usdc.approve(address(spoke), 100 * 10 ** 6);
        spoke.depositToHub(100 * 10 ** 6);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────
    // withdrawNative Tests
    // ──────────────────────────────────────────────

    function test_withdrawNative_success() public {
        uint256 spokeBalance = address(spoke).balance;
        address recipient = makeAddr("recipient");

        vm.prank(admin);
        spoke.withdrawNative(recipient);

        assertEq(address(spoke).balance, 0);
        assertEq(address(recipient).balance, spokeBalance);
    }

    function test_withdrawNative_revertsIfNotAdmin() public {
        vm.prank(lender);
        vm.expectRevert();
        spoke.withdrawNative(lender);
    }

    // ──────────────────────────────────────────────
    // receive() Tests
    // ──────────────────────────────────────────────

    function test_receive_acceptsNativeGas() public {
        uint256 balBefore = address(spoke).balance;

        vm.deal(lender, 5 ether);
        vm.prank(lender);
        (bool success, ) = address(spoke).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(address(spoke).balance, balBefore + 1 ether);
    }

    // ──────────────────────────────────────────────
    // LINK Fee Path Tests
    // ──────────────────────────────────────────────

    function test_depositToHub_withLinkFees() public {
        // Deploy LINK token
        TestLINK link = new TestLINK();
        MockRouterClientWithLink linkRouter = new MockRouterClientWithLink(
            address(link)
        );

        // Deploy spoke with LINK
        vm.startPrank(admin);
        LenderSpoke linkSpoke = new LenderSpoke(
            admin,
            address(linkRouter),
            address(usdc),
            address(link)
        );
        linkSpoke.setHubTarget(HUB_SELECTOR, hubPool);
        vm.stopPrank();

        // Fund spoke with LINK for fees
        link.transfer(address(linkSpoke), 10e18);
        // Fund lender with USDC
        usdc.transfer(lender, 1000 * 10 ** 6);

        vm.startPrank(lender);
        usdc.approve(address(linkSpoke), 500 * 10 ** 6);
        bytes32 messageId = linkSpoke.depositToHub(500 * 10 ** 6);
        vm.stopPrank();

        assertNotEq(messageId, bytes32(0));
        // Lender had 5000 (setUp) + 1000 (test transfer) - 500 (deposited) = 5500
        assertEq(usdc.balanceOf(lender), 5500 * 10 ** 6);
    }

    function test_depositToHub_withLinkFees_insufficientLinkReverts() public {
        TestLINK link = new TestLINK();
        MockRouterClientWithLink linkRouter = new MockRouterClientWithLink(
            address(link)
        );

        vm.startPrank(admin);
        LenderSpoke linkSpoke = new LenderSpoke(
            admin,
            address(linkRouter),
            address(usdc),
            address(link)
        );
        linkSpoke.setHubTarget(HUB_SELECTOR, hubPool);
        vm.stopPrank();

        // NO LINK funded to spoke — should revert
        usdc.transfer(lender, 1000 * 10 ** 6);

        vm.startPrank(lender);
        usdc.approve(address(linkSpoke), 500 * 10 ** 6);
        vm.expectRevert(
            abi.encodeWithSelector(
                LenderSpoke.NotEnoughBalance.selector,
                0, // spoke has 0 LINK
                1e18 // fee required
            )
        );
        linkSpoke.depositToHub(500 * 10 ** 6);
        vm.stopPrank();
    }
}
