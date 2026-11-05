// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Constant-product purchases with a finite, non-resetting active-time decay.
/// @dev Product uses a 1e18-scaled virtual payment reserve. Actual payment rounding surplus
/// never changes the virtual invariant, so splitting fills cannot reset or pump the curve.
library ContinuousAuction {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DURATION = 2 days;
    uint256 internal constant MAX_PRODUCT = type(uint256).max / DURATION;
    uint256 internal constant MAX_DEPTH = 818592150592861781622465154682686325;

    struct State {
        uint256 depth;
        uint256 floorWad;
        uint256 excessTime;
        uint256 decayMass;
    }

    error InvalidDepth();
    error InvalidPrice();
    error InvalidQuantity();
    error UnrepresentableCurve();

    /// @dev Price is payment atoms per sale atom, scaled by 1e18; depth is virtual sale atoms.
    function create(uint256 depth, uint256 priceWad, uint256 floorWad)
        internal
        pure
        returns (State memory state)
    {
        if (depth == 0) revert InvalidDepth();
        if (depth > MAX_DEPTH) revert InvalidDepth();
        if (floorWad == 0) revert InvalidPrice();
        if (priceWad <= floorWad) revert InvalidPrice();
        uint256 square = depth * depth;
        if (priceWad > MAX_PRODUCT / square) revert UnrepresentableCurve();
        state.depth = depth;
        state.floorWad = floorWad;
        state.decayMass = (priceWad - floorWad) * square;
        state.excessTime = state.decayMass * DURATION;
    }

    /// @notice Advance only eligible sale time, then rescale depth without resetting decay.
    /// @dev Callers supply elapsed active time; this library never reads a wall clock.
    function project(State memory state, uint256 elapsed, uint256 depth) internal pure {
        if (depth == 0) revert InvalidDepth();
        if (depth > MAX_DEPTH) revert InvalidDepth();
        if (state.depth == 0) revert InvalidDepth();
        if (state.decayMass != 0) {
            uint256 finish = FixedPointMathLib.divUp(state.excessTime, state.decayMass);
            if (elapsed >= finish) {
                state.excessTime = 0;
                state.decayMass = 0;
            } else {
                state.excessTime -= state.decayMass * elapsed;
            }
        }
        if (depth == state.depth) return;
        uint256 oldSquare = state.depth * state.depth;
        uint256 newSquare = depth * depth;
        state.excessTime =
            FixedPointMathLib.fullMulDivUp(state.excessTime, newSquare, oldSquare);
        state.decayMass = FixedPointMathLib.fullMulDivUp(state.decayMass, newSquare, oldSquare);
        state.depth = depth;
        product(state);
    }

    function product(State memory state) internal pure returns (uint256 result) {
        if (state.depth == 0) revert InvalidDepth();
        if (state.depth > MAX_DEPTH) revert InvalidDepth();
        uint256 square = state.depth * state.depth;
        if (state.floorWad > MAX_PRODUCT / square) revert UnrepresentableCurve();
        result = state.floorWad * square;
        uint256 excess = FixedPointMathLib.divUp(state.excessTime, DURATION);
        if (excess > MAX_PRODUCT - result) revert UnrepresentableCurve();
        result += excess;
    }

    function price(State memory state) internal pure returns (uint256) {
        return FixedPointMathLib.divUp(product(state), state.depth * state.depth);
    }

    /// @notice Integrated constant-product cost, rounded up once to actual payment atoms.
    function quote(State memory state, uint256 quantity) internal pure returns (uint256) {
        if (quantity == 0) revert InvalidQuantity();
        if (quantity >= state.depth) revert InvalidQuantity();
        uint256 denominator = state.depth * (state.depth - quantity);
        uint256 scaled = FixedPointMathLib.fullMulDivUp(product(state), quantity, denominator);
        return FixedPointMathLib.divUp(scaled, WAD);
    }

    /// @dev Existing pressure keeps its progress. Only the purchase's price increase adds
    /// decay mass; a tiny fill cannot restart the entire two-day period.
    function buy(State memory state, uint256 quantity) internal pure returns (uint256 payment) {
        payment = quote(state, quantity);
        uint256 invariant = product(state);
        uint256 oldSquare = state.depth * state.depth;
        state.depth -= quantity;
        uint256 square = state.depth * state.depth;
        uint256 baseline = FixedPointMathLib.fullMulDivUp(state.excessTime, square, oldSquare);
        uint256 mass = FixedPointMathLib.fullMulDivUp(state.decayMass, square, oldSquare);
        state.excessTime = (invariant - state.floorWad * square) * DURATION;
        uint256 bump = FixedPointMathLib.divUp(state.excessTime - baseline, DURATION);
        if (bump > type(uint256).max - mass) revert UnrepresentableCurve();
        state.decayMass = mass + bump;
    }
}
