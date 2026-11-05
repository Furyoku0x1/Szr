// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Continuous exponential release with full unsold carry and a fixed minimum rate.
/// @dev Absolute cumulative release preserves every fraction across checkpoints and purchases.
library ReleaseSchedule {
    uint256 internal constant DAY = 1 days;
    uint256 internal constant HALF_LIFE = 365 days;
    uint256 internal constant INITIAL_RATE = 500_000e18;
    uint256 internal constant MINIMUM_RATE = 100_000e18;
    uint256 internal constant LN_2_WAD = 693147180559945309;
    uint256 internal constant WAD = 1e18;

    struct State {
        uint256 scaledCredit;
        uint256 updatedAt;
    }

    function tailAt() internal pure returns (uint256) {
        uint256 logarithm =
            uint256(FixedPointMathLib.lnWad(int256(INITIAL_RATE * WAD / MINIMUM_RATE)));
        return FixedPointMathLib.fullMulDiv(HALF_LIFE, logarithm, LN_2_WAD);
    }

    function ratePerDay(uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= tailAt()) return MINIMUM_RATE;
        uint256 exponent = FixedPointMathLib.fullMulDiv(elapsed, LN_2_WAD, HALF_LIFE);
        uint256 factor = uint256(FixedPointMathLib.expWad(-int256(exponent)));
        return FixedPointMathLib.fullMulDiv(INITIAL_RATE, factor, WAD);
    }

    /// @notice Integrated allowance in token-wei * day units, not newly minted supply.
    function cumulativeScaled(uint256 elapsed) internal pure returns (uint256 result) {
        uint256 tail = tailAt();
        uint256 decayElapsed = elapsed < tail ? elapsed : tail;
        uint256 exponent = FixedPointMathLib.fullMulDiv(decayElapsed, LN_2_WAD, HALF_LIFE);
        uint256 factor = uint256(FixedPointMathLib.expWad(-int256(exponent)));
        uint256 mass = FixedPointMathLib.fullMulDiv(INITIAL_RATE, HALF_LIFE * WAD, LN_2_WAD);
        result = FixedPointMathLib.fullMulDiv(mass, WAD - factor, WAD);
        if (elapsed > tail) result += MINIMUM_RATE * (elapsed - tail);
    }

    function projected(State memory state, uint256 opening, uint256 nowAt)
        internal
        pure
        returns (uint256)
    {
        if (opening == 0) return 0;
        uint256 start = state.updatedAt > opening ? state.updatedAt : opening;
        if (nowAt <= start) return state.scaledCredit;
        uint256 accrued = cumulativeScaled(nowAt - opening) - cumulativeScaled(start - opening);
        return state.scaledCredit + accrued;
    }

    function checkpoint(State storage state, uint256 opening) internal {
        state.scaledCredit = projected(state, opening, block.timestamp);
        state.updatedAt = block.timestamp > opening ? block.timestamp : opening;
    }

    function readyAt(State memory state, uint256 opening) internal pure returns (uint256) {
        if (opening == 0) return type(uint256).max;
        if (state.scaledCredit >= DAY) return 0;
        uint256 start = state.updatedAt > opening ? state.updatedAt : opening;
        // The minimum rate exceeds one token-wei per second throughout the schedule.
        return start + 1;
    }

    function decayStartsAt(State memory state, uint256 opening)
        internal
        pure
        returns (uint256)
    {
        if (opening == 0) return type(uint256).max;
        if (state.scaledCredit >= DAY) return 0;
        return state.updatedAt > opening ? state.updatedAt : opening;
    }
}
