// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PolymarketAdapter} from "../src/adapters/PolymarketAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// ═══════════════════════════════════════════════
// Mock Contracts
// ═══════════════════════════════════════════════

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://mock.uri/{id}") {}
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

/// @dev A CTF mock exchange that simulates a successful fill: burns ERC-1155 and mints USDC
contract MockCTFExchange {
    MockUSDC public usdc;
    MockERC1155 public ctfToken;

    constructor(address _usdc, address _ctfToken) {
        usdc = MockUSDC(_usdc);
        ctfToken = MockERC1155(_ctfToken);
    }

    function fillOrder(
        bytes calldata /* order */,
        uint256 fillAmount,
        bytes calldata /* signature */
    ) external {
        ctfToken.safeTransferFrom(
            msg.sender,
            address(this),
            1001,
            fillAmount,
            ""
        );
        // 1 USDC per share
        usdc.mint(msg.sender, fillAmount * 1e6);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

/// @dev A broken exchange that does NOT send any USDC back (simulates zero-recovery)
contract MockCTFExchangeZeroReturn {
    MockERC1155 public ctfToken;

    constructor(address _ctfToken) {
        ctfToken = MockERC1155(_ctfToken);
    }

    function fillOrder(
        bytes calldata,
        uint256 fillAmount,
        bytes calldata
    ) external {
        // Takes the tokens but does NOT mint any USDC back
        ctfToken.safeTransferFrom(
            msg.sender,
            address(this),
            1001,
            fillAmount,
            ""
        );
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

contract MockBorrowerSpoke {
    ERC20 public usdc;
    constructor(address _usdc) {
        usdc = ERC20(_usdc);
    }
    function handleLiquidationUSDC(uint256, uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

// ═══════════════════════════════════════════════
// Test Suite
// ═══════════════════════════════════════════════

contract PolymarketAdapterTest is Test {
    PolymarketAdapter public adapter;
    MockUSDC public usdc;
    MockERC1155 public ctfToken;
    MockCTFExchange public exchange;
    MockBorrowerSpoke public borrowerSpokeContract;

    address public admin = makeAddr("admin");
    address public oracle = makeAddr("oracle");
    address public mockBorrowerSpoke;

    uint256 constant CONDITION_ID = 1001;
    uint256 constant AMOUNT_TO_SELL = 50;

    function setUp() public {
        usdc = new MockUSDC();
        ctfToken = new MockERC1155();
        exchange = new MockCTFExchange(address(usdc), address(ctfToken));
        borrowerSpokeContract = new MockBorrowerSpoke(address(usdc));
        mockBorrowerSpoke = address(borrowerSpokeContract);

        adapter = new PolymarketAdapter(
            admin,
            mockBorrowerSpoke,
            address(exchange),
            address(usdc)
        );

        vm.startPrank(admin);
        adapter.grantRole(adapter.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        // Give the borrower spoke the collateral tokens
        ctfToken.mint(mockBorrowerSpoke, CONDITION_ID, AMOUNT_TO_SELL);

        // BorrowerSpoke approves the Adapter
        vm.prank(mockBorrowerSpoke);
        ctfToken.setApprovalForAll(address(adapter), true);
    }

    // ─────────────────────────────────────────────
    // 1. Constructor & State Initialization
    // ─────────────────────────────────────────────

    function test_constructor_sets_state_correctly() public view {
        assertEq(adapter.borrowerSpoke(), mockBorrowerSpoke);
        assertEq(adapter.ctfExchange(), address(exchange));
        assertEq(address(adapter.usdc()), address(usdc));
        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.ORACLE_ROLE(), oracle));
    }

    // ─────────────────────────────────────────────
    // 2. Successful Liquidation Swap (happy path)
    // ─────────────────────────────────────────────

    function test_executeLiquidateSwap_success() public {
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";
        uint256 vaultId = 1;

        // Verify initial state
        assertEq(
            ctfToken.balanceOf(mockBorrowerSpoke, CONDITION_ID),
            AMOUNT_TO_SELL
        );
        assertEq(usdc.balanceOf(mockBorrowerSpoke), 0);

        // Execute dump
        vm.prank(oracle);
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );

        // Verify final state
        assertEq(ctfToken.balanceOf(mockBorrowerSpoke, CONDITION_ID), 0);
        assertEq(
            ctfToken.balanceOf(address(exchange), CONDITION_ID),
            AMOUNT_TO_SELL
        );
        assertEq(usdc.balanceOf(mockBorrowerSpoke), AMOUNT_TO_SELL * 1e6);
    }

    // ─────────────────────────────────────────────
    // 3. Event Emission
    // ─────────────────────────────────────────────

    function test_executeLiquidateSwap_emits_CollateralDumped() public {
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";
        uint256 vaultId = 7;

        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit PolymarketAdapter.CollateralDumped(
            vaultId,
            AMOUNT_TO_SELL,
            AMOUNT_TO_SELL * 1e6
        );
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );
    }

    // ─────────────────────────────────────────────
    // 4. Access Control — reverts for unauthorized
    // ─────────────────────────────────────────────

    function test_executeLiquidateSwap_reverts_if_not_oracle() public {
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";
        uint256 vaultId = 1;

        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert();
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );
    }

    function test_executeLiquidateSwap_reverts_if_admin_but_not_oracle()
        public
    {
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";
        uint256 vaultId = 1;

        // Admin does NOT have ORACLE_ROLE
        vm.prank(admin);
        vm.expectRevert();
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );
    }

    // ─────────────────────────────────────────────
    // 5. Zero USDC Recovery — revert guard
    // ─────────────────────────────────────────────

    function test_executeLiquidateSwap_reverts_on_zero_usdc_recovery() public {
        // Deploy a broken exchange that doesn't return any USDC
        MockCTFExchangeZeroReturn brokenExchange = new MockCTFExchangeZeroReturn(
                address(ctfToken)
            );

        PolymarketAdapter brokenAdapter = new PolymarketAdapter(
            admin,
            mockBorrowerSpoke,
            address(brokenExchange),
            address(usdc)
        );

        vm.startPrank(admin);
        brokenAdapter.grantRole(brokenAdapter.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        // Re-approve for the broken adapter
        vm.prank(mockBorrowerSpoke);
        ctfToken.setApprovalForAll(address(brokenAdapter), true);

        vm.prank(oracle);
        vm.expectRevert("No USDC recovered from CTF Exchage swap");
        brokenAdapter.executeLiquidateSwap(
            1,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            "0xdeadbeef",
            "0xabcdef"
        );
    }

    // ─────────────────────────────────────────────
    // 6. ERC-1155 Receiver Hooks
    // ─────────────────────────────────────────────

    function test_onERC1155Received_returns_correct_selector() public view {
        bytes4 result = adapter.onERC1155Received(
            address(0),
            address(0),
            0,
            0,
            ""
        );
        assertEq(result, adapter.onERC1155Received.selector);
    }

    function test_onERC1155BatchReceived_returns_correct_selector()
        public
        view
    {
        uint256[] memory ids = new uint256[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes4 result = adapter.onERC1155BatchReceived(
            address(0),
            address(0),
            ids,
            amounts,
            ""
        );
        assertEq(result, adapter.onERC1155BatchReceived.selector);
    }

    // ─────────────────────────────────────────────
    // 7. Partial Fill — different amounts & vaults
    // ─────────────────────────────────────────────

    function test_executeLiquidateSwap_with_different_vault_id() public {
        uint256 vaultId = 999;
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";

        vm.prank(oracle);
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );

        // Full amount cleared
        assertEq(ctfToken.balanceOf(mockBorrowerSpoke, CONDITION_ID), 0);
        assertEq(usdc.balanceOf(mockBorrowerSpoke), AMOUNT_TO_SELL * 1e6);
    }

    function test_executeLiquidateSwap_partial_amount() public {
        uint256 partialAmount = 10;
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";
        uint256 vaultId = 1;

        vm.prank(oracle);
        adapter.executeLiquidateSwap(
            vaultId,
            address(ctfToken),
            CONDITION_ID,
            partialAmount,
            orderPayload,
            signature
        );

        // Only partial amount cleared
        assertEq(
            ctfToken.balanceOf(mockBorrowerSpoke, CONDITION_ID),
            AMOUNT_TO_SELL - partialAmount
        );
        assertEq(usdc.balanceOf(mockBorrowerSpoke), partialAmount * 1e6);
    }

    // ─────────────────────────────────────────────
    // 8. Adapter holds no residual tokens after swap
    // ─────────────────────────────────────────────

    function test_adapter_holds_no_residual_tokens() public {
        bytes memory orderPayload = "0xdeadbeef";
        bytes memory signature = "0xabcdef";

        vm.prank(oracle);
        adapter.executeLiquidateSwap(
            1,
            address(ctfToken),
            CONDITION_ID,
            AMOUNT_TO_SELL,
            orderPayload,
            signature
        );

        // Adapter should have zero ERC-1155 and zero USDC
        assertEq(ctfToken.balanceOf(address(adapter), CONDITION_ID), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }
}
