// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    SD59x18,
    sd,
    intoUint256,
    exp,
    mul,
    UNIT as SD_UNIT
} from "@prb/math/SD59x18.sol";
import {
    UD60x18,
    ud,
    intoUint256 as udIntoUint256,
    mul as udMul,
    div as udDiv
} from "@prb/math/UD60x18.sol";

/**
 * @title CollateralMath
 * @notice Pure math library implementing the Probability-Weighted Expected Return Method (PWERM)
 *         with exponential time-decay for prediction market collateral valuation.
 *
 * @dev Formula: Value = P_implied × α(t) × (1 - MRP_category) × e^(-λ × T_remaining)
 *
 *      All values use 18-decimal fixed-point (1e18 = 1.0)
 */
library CollateralMath {
    /// @notice 1.0 in 18-decimal fixed-point
    uint256 internal constant WAD = 1e18;

    /// @notice Maximum allowed alpha haircut (1.0)
    uint256 internal constant MAX_ALPHA = WAD;

    /// @notice Maximum allowed implied probability (1.0)
    uint256 internal constant MAX_PROBABILITY = WAD;

    /// @notice Maximum allowed MRP (100% = protocol takes all value)
    uint256 internal constant MAX_MRP = WAD;

    // ──────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────

    error InvalidProbability(uint256 probability);
    error InvalidAlpha(uint256 alpha);
    error InvalidMRP(uint256 mrp);

    // ──────────────────────────────────────────────
    // Core Valuation
    // ──────────────────────────────────────────────

    /**
     * @notice Calculate the collateral value of a prediction market position
     * @param pImplied The implied probability (18 decimals, e.g., 0.65e18)
     * @param alpha The AI-controlled haircut modifier (18 decimals, e.g., 0.85e18)
     * @param mrpCategory The market risk premium for this category (18 decimals, e.g., 0.05e18)
     * @param tRemaining Time remaining until resolution in seconds
     * @param lambda The time-decay constant (18 decimals)
     * @return value The calculated collateral value (18 decimals)
     */
    function calculateCollateralValue(
        uint256 pImplied,
        uint256 alpha,
        uint256 mrpCategory,
        uint256 tRemaining,
        uint256 lambda
    ) internal pure returns (uint256 value) {
        if (pImplied > MAX_PROBABILITY) revert InvalidProbability(pImplied);
        if (alpha > MAX_ALPHA) revert InvalidAlpha(alpha);
        if (mrpCategory > MAX_MRP) revert InvalidMRP(mrpCategory);

        // If probability or alpha is zero, value is zero
        if (pImplied == 0 || alpha == 0) return 0;

        // Step 1: P_implied × α(t)
        UD60x18 pAlpha = udMul(ud(pImplied), ud(alpha));

        // Step 2: × (1 - MRP_category)
        UD60x18 afterMrp = udMul(pAlpha, ud(WAD - mrpCategory));

        // Step 3: × e^(-λ × T_remaining)
        // Convert to signed for exp calculation
        // casting to int256 is safe: lambda and tRemaining are protocol-bounded values << int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        SD59x18 negLambdaT = mul(sd(-int256(lambda)), sd(int256(tRemaining)));
        SD59x18 decayFactor = exp(negLambdaT);

        // Convert decay factor back to unsigned (it's always positive since e^x > 0)
        uint256 decayUint = intoUint256(decayFactor);

        // Step 4: Multiply everything together
        value = udIntoUint256(udMul(afterMrp, ud(decayUint)));
    }

    // ──────────────────────────────────────────────
    // Health Factor
    // ──────────────────────────────────────────────

    /**
     * @notice Calculate the health factor of a vault
     * @param collateralValue The current collateral value (18 decimals)
     * @param debtValue The outstanding loan amount (18 decimals)
     * @return healthFactor The health factor (18 decimals, 1.0e18 = break-even)
     */
    function calculateHealthFactor(
        uint256 collateralValue,
        uint256 debtValue
    ) internal pure returns (uint256 healthFactor) {
        if (debtValue == 0) return type(uint256).max;
        healthFactor = udIntoUint256(udDiv(ud(collateralValue), ud(debtValue)));
    }

    /**
     * @notice Check whether a vault should be liquidated
     * @param healthFactor Current health factor (18 decimals)
     * @param maintenanceMargin Minimum required health factor (18 decimals)
     * @return shouldLiquidate True if health factor is below maintenance margin
     */
    function isLiquidatable(
        uint256 healthFactor,
        uint256 maintenanceMargin
    ) internal pure returns (bool shouldLiquidate) {
        shouldLiquidate = healthFactor < maintenanceMargin;
    }

    // ──────────────────────────────────────────────
    // Interest Rate Model (Kink / Jump Rate)
    // ──────────────────────────────────────────────

    /**
     * @notice Calculate the borrow interest rate based on pool utilization
     * @param utilization Current pool utilization rate (18 decimals)
     * @param baseRate Base interest rate (18 decimals)
     * @param kink The utilization inflection point (18 decimals)
     * @param slope1 Rate slope below kink (18 decimals)
     * @param slope2 Rate slope above kink (18 decimals)
     * @return rate The annualized borrow rate (18 decimals)
     */
    function calculateInterestRate(
        uint256 utilization,
        uint256 baseRate,
        uint256 kink,
        uint256 slope1,
        uint256 slope2
    ) internal pure returns (uint256 rate) {
        if (utilization <= kink) {
            // rate = baseRate + utilization × slope1
            rate = baseRate + udIntoUint256(udMul(ud(utilization), ud(slope1)));
        } else {
            // rate = baseRate + kink × slope1 + (utilization - kink) × slope2
            uint256 normalRate = udIntoUint256(udMul(ud(kink), ud(slope1)));
            uint256 excessRate = udIntoUint256(
                udMul(ud(utilization - kink), ud(slope2))
            );
            rate = baseRate + normalRate + excessRate;
        }
    }

    /**
     * @notice Calculate the maximum loan amount for given collateral value and LTV
     * @param collateralValue The collateral value (18 decimals)
     * @param maxLTV The maximum Loan-to-Value ratio (18 decimals, e.g., 0.5e18 = 50%)
     * @return maxLoan The maximum loan amount
     */
    function calculateMaxLoan(
        uint256 collateralValue,
        uint256 maxLTV
    ) internal pure returns (uint256 maxLoan) {
        maxLoan = udIntoUint256(udMul(ud(collateralValue), ud(maxLTV)));
    }
}
