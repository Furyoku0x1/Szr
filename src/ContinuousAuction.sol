// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Constant-product purchases with a finite, non-resetting active-time decay.
/// @dev Product uses a 1e18-scaled virtual payment reserve. Actual payment rounding surplus
/// never changes the virtual invariant, so splitting fills cannot reset or pump the curve.
/// The decaying part is the exact quantity `excess * DURATION - deficit`, held as two words so
/// the product may use a whole word. Every operation reproduces single-word arithmetic on
/// that quantity bit for bit.
library ContinuousAuction {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DURATION = 2 days;
    uint256 internal constant MAX_PRODUCT = type(uint256).max;
    /// @dev Largest depth whose square times DURATION still fits one word.
    uint256 internal constant MAX_DEPTH = 818592150592861781622465154682686325;

    struct State {
        uint256 depth;
        uint256 floorWad;
        /// @dev Price excess over the floor, in product units, rounded up.
        uint256 excess;
        /// @dev How far `excess * DURATION` overstates the exact value; always below DURATION.
        uint256 deficit;
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
        state.excess = state.decayMass;
    }

    /// @notice Advance only eligible sale time, then rescale depth without resetting decay.
    /// @dev Callers supply elapsed active time; this library never reads a wall clock.
    function project(State memory state, uint256 elapsed, uint256 depth) internal pure {
        if (depth == 0) revert InvalidDepth();
        if (depth > MAX_DEPTH) revert InvalidDepth();
        if (state.depth == 0) revert InvalidDepth();
        if (state.depth > MAX_DEPTH) revert InvalidDepth();
        if (state.decayMass != 0) _decay(state, elapsed);
        if (depth == state.depth) return;
        uint256 oldSquare = state.depth * state.depth;
        uint256 newSquare = depth * depth;
        (state.excess, state.deficit) =
            _rescale(state.excess, state.deficit, newSquare, oldSquare);
        state.decayMass = FixedPointMathLib.fullMulDivUp(state.decayMass, newSquare, oldSquare);
        state.depth = depth;
        product(state);
    }

    /// @dev Subtracts `decayMass * elapsed` from the exact excess, or clears it once spent.
    /// Remaining time never exceeds DURATION (`excess <= decayMass` always holds), so a wait
    /// of DURATION or longer always finishes the decay without multiplying.
    function _decay(State memory state, uint256 elapsed) private pure {
        if (elapsed < DURATION) {
            uint256 whole = FixedPointMathLib.fullMulDiv(state.decayMass, elapsed, DURATION);
            if (whole < state.excess) {
                uint256 excess = state.excess - whole;
                uint256 deficit = state.deficit + mulmod(state.decayMass, elapsed, DURATION);
                if (deficit >= DURATION) {
                    deficit -= DURATION;
                    excess -= 1;
                }
                if (excess != 0) {
                    state.excess = excess;
                    state.deficit = deficit;
                    return;
                }
            }
        }
        state.excess = 0;
        state.deficit = 0;
        state.decayMass = 0;
    }

    /// @dev Exactly `ceil((excess * DURATION - deficit) * newSquare / oldSquare)`, re-encoded
    /// as the same two words. Both squares are at most MAX_DEPTH squared, so the plain
    /// multiplications by DURATION and by a deficit below DURATION cannot overflow.
    function _rescale(uint256 excess, uint256 deficit, uint256 newSquare, uint256 oldSquare)
        private
        pure
        returns (uint256, uint256)
    {
        if (excess == 0) return (0, 0);
        uint256 whole = FixedPointMathLib.fullMulDiv(excess, newSquare, oldSquare);
        uint256 part = mulmod(excess, newSquare, oldSquare) * DURATION;
        uint256 owed = deficit * newSquare;
        uint256 gain = part / oldSquare;
        uint256 loss = owed / oldSquare;
        if (part % oldSquare > owed % oldSquare) gain += 1;
        if (gain >= loss) {
            gain -= loss;
            if (gain == 0) return (whole, 0);
            return (whole + 1, DURATION - gain);
        }
        loss -= gain;
        return (whole - loss / DURATION, loss % DURATION);
    }

    function product(State memory state) internal pure returns (uint256 result) {
        if (state.depth == 0) revert InvalidDepth();
        if (state.depth > MAX_DEPTH) revert InvalidDepth();
        uint256 square = state.depth * state.depth;
        if (state.floorWad > MAX_PRODUCT / square) revert UnrepresentableCurve();
        result = state.floorWad * square;
        if (state.excess > MAX_PRODUCT - result) revert UnrepresentableCurve();
        result += state.excess;
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
        (uint256 baseline, uint256 shortfall) =
            _rescale(state.excess, state.deficit, square, oldSquare);
        uint256 mass = FixedPointMathLib.fullMulDivUp(state.decayMass, square, oldSquare);
        state.excess = invariant - state.floorWad * square;
        state.deficit = 0;
        uint256 bump = state.excess - baseline;
        if (shortfall != 0) bump += 1;
        if (bump > type(uint256).max - mass) revert UnrepresentableCurve();
        state.decayMass = mass + bump;
    }
}
