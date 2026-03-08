// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {BorrowerSpoke} from "../src/BorrowerSpoke.sol";
import {IBorrowerSpoke} from "../src/interfaces/IBorrowerSpoke.sol";

/// @dev Simple mock ERC-1155 token for testing
contract MockERC1155 is ERC1155 {
    constructor() ERC1155("https://mock.uri/{id}") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }
}

contract BorrowerSpokeTest is Test {
    BorrowerSpoke public spoke;
    MockERC1155 public mockToken;

    address public admin = makeAddr("admin");
    address public oracle = makeAddr("oracle");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant MAX_LTV = 0.7e18; // 70%
    uint256 constant MAINTENANCE_MARGIN = 1.2e18; // 120%
    uint256 constant STALENESS_TOLERANCE = 1 hours;

    uint256 constant CONDITION_ID = 1001;
    uint256 constant OUTCOME_YES = 1;
    uint256 constant SHARE_AMOUNT = 100e18;
    uint64 constant DEST_CHAIN = 16015286601757825753; // Base Sepolia

    function setUp() public {
        vm.startPrank(admin);
        spoke = new BorrowerSpoke(
            admin,
            address(0x123), // _ccipRouter
            0.70e18, // maxLTV (70%)
            1.25e18, // maintenanceMargin (125%)
            1 hours // oracleStalenessTolerance
        );
        spoke.grantRole(spoke.ORACLE_ROLE(), oracle);
        vm.stopPrank();

        mockToken = new MockERC1155();
    }

    // ──────────────────────────────────────────────
    // Deposit Tests
    // ──────────────────────────────────────────────

    function test_depositCollateral_success() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(alice);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18, // 40% LTV
            block.timestamp + 90 days
        );

        IBorrowerSpoke.Vault memory vault = spoke.getVault(1);
        assertEq(vault.owner, alice);
        assertEq(vault.conditionId, CONDITION_ID);
        assertEq(vault.outcomeIndex, OUTCOME_YES);
        assertEq(vault.amount, SHARE_AMOUNT);
        assertEq(vault.hubChainSelector, DEST_CHAIN);
        assertEq(vault.requestedLTV, 0.4e18);
        assertEq(
            uint8(vault.status),
            uint8(IBorrowerSpoke.VaultStatus.PENDING)
        );
    }

    function test_depositCollateral_emitsEvent() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit IBorrowerSpoke.CollateralDeposited(
            1,
            alice,
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18
        );

        vm.prank(alice);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );
    }

    function test_depositCollateral_revertZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(BorrowerSpoke.ZeroAmount.selector);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            0,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );
    }

    function test_depositCollateral_revertExceedsMaxLTV() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowerSpoke.InvalidLTV.selector,
                0.8e18,
                MAX_LTV
            )
        );
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.8e18,
            block.timestamp + 90 days
        );
    }

    function test_depositCollateral_transfersTokens() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(alice);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );

        assertEq(mockToken.balanceOf(alice, CONDITION_ID), 0);
        assertEq(
            mockToken.balanceOf(address(spoke), CONDITION_ID),
            SHARE_AMOUNT
        );
    }

    function test_depositCollateral_incrementsVaultId() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);
        _mintAndApprove(bob, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(alice);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT / 2,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );

        vm.prank(bob);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT / 2,
            DEST_CHAIN,
            0.3e18,
            block.timestamp + 90 days
        );

        assertEq(spoke.getVaultCount(), 2);
        assertEq(spoke.getVault(1).owner, alice);
        assertEq(spoke.getVault(2).owner, bob);
    }

    function test_depositCollateral_whenPaused_reverts() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(admin);
        spoke.pause();

        vm.prank(alice);
        vm.expectRevert();
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );
    }

    // ──────────────────────────────────────────────
    // Valuation Tests
    // ──────────────────────────────────────────────

    function test_receiveValuation_transitionsPendingToActive() public {
        uint256 vaultId = _createVault(alice);

        IBorrowerSpoke.ValuationReport memory report = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.85e18,
                impliedProbability: 0.65e18,
                collateralValue: 0.55e18,
                healthFactor: 1.5e18,
                timestamp: block.timestamp
            });

        vm.prank(oracle);
        spoke.receiveValuation(report);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        assertEq(uint8(vault.status), uint8(IBorrowerSpoke.VaultStatus.ACTIVE));
        assertEq(vault.collateralValue, 0.55e18);
        assertEq(vault.healthFactor, 1.5e18);
    }

    function test_receiveValuation_calculatesLoanAmount() public {
        uint256 vaultId = _createVault(alice);

        IBorrowerSpoke.ValuationReport memory report = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.85e18,
                impliedProbability: 0.65e18,
                collateralValue: 1e18, // 1.0 USDC worth
                healthFactor: 2.5e18,
                timestamp: block.timestamp
            });

        vm.prank(oracle);
        spoke.receiveValuation(report);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        // requestedLTV = 0.4e18, collateralValue = 1e18 → loan = 0.4e18
        assertEq(vault.loanAmount, 0.4e18);
    }

    function test_receiveValuation_triggersLiquidation() public {
        uint256 vaultId = _createVault(alice);

        // First valuation to activate
        IBorrowerSpoke.ValuationReport memory report1 = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.85e18,
                impliedProbability: 0.65e18,
                collateralValue: 1e18,
                healthFactor: 1.5e18,
                timestamp: block.timestamp
            });
        vm.prank(oracle);
        spoke.receiveValuation(report1);

        // Second valuation with low health factor
        IBorrowerSpoke.ValuationReport memory report2 = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.3e18,
                impliedProbability: 0.25e18,
                collateralValue: 0.2e18,
                healthFactor: 1.0e18, // Below 1.2e18 maintenance margin
                timestamp: block.timestamp + 1 hours
            });

        vm.expectEmit(true, false, false, false);
        emit IBorrowerSpoke.LiquidationTriggered(vaultId);

        vm.prank(oracle);
        spoke.receiveValuation(report2);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        assertEq(
            uint8(vault.status),
            uint8(IBorrowerSpoke.VaultStatus.LIQUIDATING)
        );
    }

    function test_receiveValuation_onlyOracle() public {
        uint256 vaultId = _createVault(alice);

        IBorrowerSpoke.ValuationReport memory report = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.85e18,
                impliedProbability: 0.65e18,
                collateralValue: 0.55e18,
                healthFactor: 1.5e18,
                timestamp: block.timestamp
            });

        vm.prank(alice);
        vm.expectRevert();
        spoke.receiveValuation(report);
    }

    // ──────────────────────────────────────────────
    // Withdrawal Tests
    // ──────────────────────────────────────────────

    function test_withdrawCollateral_pendingVault() public {
        uint256 vaultId = _createVault(alice);

        vm.prank(alice);
        spoke.withdrawCollateral(vaultId);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        assertEq(uint8(vault.status), uint8(IBorrowerSpoke.VaultStatus.CLOSED));
    }

    function test_withdrawCollateral_notOwnerReverts() public {
        uint256 vaultId = _createVault(alice);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowerSpoke.NotVaultOwner.selector,
                vaultId,
                bob
            )
        );
        spoke.withdrawCollateral(vaultId);
    }

    // ──────────────────────────────────────────────
    // Recovery Tests
    // ──────────────────────────────────────────────

    function test_recoverCollateral_failedVault() public {
        uint256 vaultId = _createVault(alice);

        vm.prank(oracle);
        spoke.markVaultFailed(vaultId);

        vm.prank(alice);
        spoke.recoverCollateral(vaultId);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        assertEq(uint8(vault.status), uint8(IBorrowerSpoke.VaultStatus.CLOSED));
    }

    // ──────────────────────────────────────────────
    // View Function Tests
    // ──────────────────────────────────────────────

    function test_getVaultsByOwner() public {
        _createVault(alice);
        _createVault(alice);

        uint256[] memory vaultIds = spoke.getVaultsByOwner(alice);
        assertEq(vaultIds.length, 2);
        assertEq(vaultIds[0], 1);
        assertEq(vaultIds[1], 2);
    }

    // ──────────────────────────────────────────────
    // Resolution Cutoff Tests (Phase 13)
    // ──────────────────────────────────────────────

    function test_depositCollateral_rejectsMarketTooCloseToResolution() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        // Resolution in 12 hours — less than minTimeToResolution (48h default)
        uint256 tooSoon = block.timestamp + 12 hours;

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                BorrowerSpoke.MarketTooCloseToResolution.selector,
                tooSoon,
                48 hours
            )
        );
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            tooSoon
        );
    }

    function test_depositCollateral_acceptsMarketWithSufficientTime() public {
        _mintAndApprove(alice, CONDITION_ID, SHARE_AMOUNT);

        // Resolution in 60 days — well above minTimeToResolution
        uint256 safeTime = block.timestamp + 60 days;

        vm.prank(alice);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            safeTime
        );

        IBorrowerSpoke.Vault memory vault = spoke.getVault(
            spoke.getVaultCount()
        );
        assertEq(vault.resolutionTimestamp, safeTime);
    }

    function test_triggerResolutionCutoff_success() public {
        uint256 vaultId = _createVault(alice);

        // Transition to ACTIVE via valuation report
        IBorrowerSpoke.ValuationReport memory report = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.9e18,
                impliedProbability: 0.7e18,
                collateralValue: 700e18,
                healthFactor: 2e18,
                timestamp: block.timestamp
            });
        vm.prank(oracle);
        spoke.receiveValuation(report);

        // Warp to within the resolution cutoff window (24h before resolution)
        // Vault has resolutionTimestamp = block.timestamp + 90 days
        // Jump to 23 hours before resolution
        vm.warp(block.timestamp + 90 days - 23 hours);

        vm.prank(oracle);
        spoke.triggerResolutionCutoff(vaultId);

        IBorrowerSpoke.Vault memory vault = spoke.getVault(vaultId);
        assertEq(
            uint8(vault.status),
            uint8(IBorrowerSpoke.VaultStatus.LIQUIDATING)
        );
    }

    function test_triggerResolutionCutoff_revertsBeforeCutoffWindow() public {
        uint256 vaultId = _createVault(alice);

        // Transition to ACTIVE
        IBorrowerSpoke.ValuationReport memory report = IBorrowerSpoke
            .ValuationReport({
                vaultId: vaultId,
                alpha: 0.9e18,
                impliedProbability: 0.7e18,
                collateralValue: 700e18,
                healthFactor: 2e18,
                timestamp: block.timestamp
            });
        vm.prank(oracle);
        spoke.receiveValuation(report);

        // Still 30 days before resolution — well outside cutoff window
        vm.warp(block.timestamp + 60 days);

        vm.prank(oracle);
        vm.expectRevert();
        spoke.triggerResolutionCutoff(vaultId);
    }

    function test_triggerResolutionCutoff_revertsIfNotOracle() public {
        uint256 vaultId = _createVault(alice);

        address unauthorized = makeAddr("unauthorized");

        vm.prank(unauthorized);
        vm.expectRevert();
        spoke.triggerResolutionCutoff(vaultId);
    }

    function test_setResolutionCutoff_configurable() public {
        // Verify defaults
        assertEq(spoke.resolutionCutoff(), 24 hours);
        assertEq(spoke.minTimeToResolution(), 48 hours);

        // Update cutoff to 12 hours (must be <= minTimeToResolution)
        vm.prank(admin);
        spoke.setResolutionCutoff(12 hours);
        assertEq(spoke.resolutionCutoff(), 12 hours);

        // Update minTimeToResolution to 36 hours (must stay >= cutoff)
        vm.prank(admin);
        spoke.setMinTimeToResolution(36 hours);
        assertEq(spoke.minTimeToResolution(), 36 hours);
    }

    function test_setResolutionCutoff_invariantEnforced() public {
        // Try to set cutoff higher than minTimeToResolution — should revert
        vm.prank(admin);
        vm.expectRevert("minTimeToResolution must be >= cutoff");
        spoke.setResolutionCutoff(72 hours); // 72h > 48h default minTime

        // Try to set minTime lower than cutoff — should revert
        vm.prank(admin);
        vm.expectRevert("minTime must be >= resolutionCutoff");
        spoke.setMinTimeToResolution(12 hours); // 12h < 24h default cutoff
    }

    // ──────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────

    function _mintAndApprove(
        address user,
        uint256 tokenId,
        uint256 amount
    ) internal {
        mockToken.mint(user, tokenId, amount);
        vm.prank(user);
        mockToken.setApprovalForAll(address(spoke), true);
    }

    function _createVault(address user) internal returns (uint256 vaultId) {
        _mintAndApprove(user, CONDITION_ID, SHARE_AMOUNT);

        vm.prank(user);
        spoke.depositCollateral(
            address(mockToken),
            CONDITION_ID,
            OUTCOME_YES,
            SHARE_AMOUNT,
            DEST_CHAIN,
            0.4e18,
            block.timestamp + 90 days
        );

        vaultId = spoke.getVaultCount();
    }
}
