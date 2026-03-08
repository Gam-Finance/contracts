// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";

/// @dev Wrapper contract to expose library functions externally (for expectRevert)
contract CollateralMathWrapper {
    function calculateCollateralValue(
        uint256 pImplied,
        uint256 alpha,
        uint256 mrpCategory,
        uint256 tRemaining,
        uint256 lambda
    ) external pure returns (uint256) {
        return
            CollateralMath.calculateCollateralValue(
                pImplied,
                alpha,
                mrpCategory,
                tRemaining,
                lambda
            );
    }
}

contract CollateralMathTest is Test {
    CollateralMathWrapper public wrapper;
    uint256 constant WAD = 1e18;

    function setUp() public {
        wrapper = new CollateralMathWrapper();
    }

    // ──────────────────────────────────────────────
    // calculateCollateralValue Tests
    // ──────────────────────────────────────────────

    function test_collateralValue_basicCase() public view {
        // P=0.65, α=0.85, MRP=0.05, T=0 (no decay), λ=0
        uint256 value = wrapper.calculateCollateralValue(
            0.65e18, // pImplied
            0.85e18, // alpha
            0.05e18, // mrpCategory
            0, // tRemaining (no time decay)
            0 // lambda
        );

        // Expected: 0.65 × 0.85 × (1 - 0.05) = 0.65 × 0.85 × 0.95 = 0.524875
        assertApproxEqRel(value, 0.524875e18, 0.001e18); // 0.1% tolerance
    }

    function test_collateralValue_withTimeDecay() public view {
        // With meaningful time decay: λ=1e12 (scaled), T=3600
        // e^(-1e12 * 3600) at 18 decimal scale — let's use larger λ for visible effect
        uint256 value = wrapper.calculateCollateralValue(
            0.65e18,
            0.85e18,
            0.05e18,
            3600, // 1 hour remaining
            1e14 // λ = 0.0001 at WAD scale — multiply to see effect
        );

        // Without decay: 0.524875e18
        // With decay: should be meaningfully less
        uint256 noDecay = wrapper.calculateCollateralValue(
            0.65e18,
            0.85e18,
            0.05e18,
            0,
            0
        );
        assertLe(value, noDecay);
    }

    function test_collateralValue_zeroProbability() public view {
        uint256 value = wrapper.calculateCollateralValue(
            0,
            0.85e18,
            0.05e18,
            3600,
            0.0001e18
        );
        assertEq(value, 0);
    }

    function test_collateralValue_zeroAlpha() public view {
        uint256 value = wrapper.calculateCollateralValue(
            0.65e18,
            0,
            0.05e18,
            3600,
            0.0001e18
        );
        assertEq(value, 0);
    }

    function test_collateralValue_fullProbability() public view {
        // P=1.0, α=1.0, MRP=0, T=0 → value should be 1.0
        uint256 value = wrapper.calculateCollateralValue(1e18, 1e18, 0, 0, 0);
        assertEq(value, 1e18);
    }

    function test_collateralValue_revertInvalidProbability() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralMath.InvalidProbability.selector,
                1.1e18
            )
        );
        wrapper.calculateCollateralValue(1.1e18, 0.85e18, 0.05e18, 0, 0);
    }

    function test_collateralValue_revertInvalidAlpha() public {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralMath.InvalidAlpha.selector, 1.1e18)
        );
        wrapper.calculateCollateralValue(0.65e18, 1.1e18, 0.05e18, 0, 0);
    }

    function test_collateralValue_revertInvalidMRP() public {
        vm.expectRevert(
            abi.encodeWithSelector(CollateralMath.InvalidMRP.selector, 1.1e18)
        );
        wrapper.calculateCollateralValue(0.65e18, 0.85e18, 1.1e18, 0, 0);
    }

    // ──────────────────────────────────────────────
    // Fuzz Tests
    // ──────────────────────────────────────────────

    function testFuzz_collateralValue_bounded(
        uint256 p,
        uint256 alpha,
        uint256 mrp
    ) public view {
        p = bound(p, 0, WAD);
        alpha = bound(alpha, 0, WAD);
        mrp = bound(mrp, 0, WAD);

        uint256 value = wrapper.calculateCollateralValue(p, alpha, mrp, 0, 0);
        assertLe(value, WAD);
    }

    // ──────────────────────────────────────────────
    // Health Factor Tests
    // ──────────────────────────────────────────────

    function test_healthFactor_basic() public pure {
        uint256 hf = CollateralMath.calculateHealthFactor(1.5e18, 1e18);
        assertEq(hf, 1.5e18);
    }

    function test_healthFactor_zeroDebt() public pure {
        uint256 hf = CollateralMath.calculateHealthFactor(1e18, 0);
        assertEq(hf, type(uint256).max);
    }

    function test_healthFactor_undercollateralized() public pure {
        uint256 hf = CollateralMath.calculateHealthFactor(0.5e18, 1e18);
        assertEq(hf, 0.5e18);
    }

    // ──────────────────────────────────────────────
    // Liquidation Check Tests
    // ──────────────────────────────────────────────

    function test_isLiquidatable_belowMargin() public pure {
        assertTrue(CollateralMath.isLiquidatable(1.1e18, 1.2e18));
    }

    function test_isLiquidatable_aboveMargin() public pure {
        assertFalse(CollateralMath.isLiquidatable(1.5e18, 1.2e18));
    }

    function test_isLiquidatable_atMargin() public pure {
        assertFalse(CollateralMath.isLiquidatable(1.2e18, 1.2e18));
    }

    // ──────────────────────────────────────────────
    // Interest Rate Tests
    // ──────────────────────────────────────────────

    function test_interestRate_belowKink() public pure {
        uint256 rate = CollateralMath.calculateInterestRate(
            0.5e18,
            0.02e18,
            0.8e18,
            0.04e18,
            0.75e18
        );
        assertEq(rate, 0.04e18);
    }

    function test_interestRate_aboveKink() public pure {
        uint256 rate = CollateralMath.calculateInterestRate(
            0.9e18,
            0.02e18,
            0.8e18,
            0.04e18,
            0.75e18
        );
        assertEq(rate, 0.127e18);
    }

    function test_interestRate_zeroUtilization() public pure {
        uint256 rate = CollateralMath.calculateInterestRate(
            0,
            0.02e18,
            0.8e18,
            0.04e18,
            0.75e18
        );
        assertEq(rate, 0.02e18);
    }

    // ──────────────────────────────────────────────
    // Max Loan Tests
    // ──────────────────────────────────────────────

    function test_calculateMaxLoan() public pure {
        uint256 maxLoan = CollateralMath.calculateMaxLoan(1e18, 0.5e18);
        assertEq(maxLoan, 0.5e18);
    }

    function test_calculateMaxLoan_zeroLTV() public pure {
        uint256 maxLoan = CollateralMath.calculateMaxLoan(1e18, 0);
        assertEq(maxLoan, 0);
    }
}
