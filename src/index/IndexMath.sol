// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Weighted-pool swap maths for the index pool, written from the formulas in
/// `docs/specs/index-pool.md` (after Balancer v3's weighted pool). All amounts are 18-decimal.
library IndexMath {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_IN_RATIO = 30e16;
    uint256 internal constant MAX_OUT_RATIO = 30e16;
    /// Relative margin on every power that goes through `powWad`. Measured by
    /// `tools/index_vectors.py` over 23,991 points (bases 0.76 to 1.43, exponents 1/99 to 99,
    /// edges and values next to 1 included): the worst raw `powWad` error beyond one wei was
    /// 1.009e-16 relative. 1e-14 is about 99 times that and is Balancer's own floor. The
    /// extra wei added with it covers truncation, which dominates on very small results.
    uint256 internal constant POW_MAX_RELATIVE_ERROR = 1e4;

    error MaxInRatio();
    error MaxOutRatio();

    /// `x ^ y` rounded up. Exponents of 1, 2 and 4 are exact, so they carry no margin.
    function powUp(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == WAD) return x;
        if (y == 2 * WAD) return x.mulWadUp(x);
        if (y == 4 * WAD) {
            uint256 square = x.mulWadUp(x);
            return square.mulWadUp(square);
        }
        uint256 raw = uint256(FixedPointMathLib.powWad(int256(x), int256(y)));
        return raw + raw.mulWadUp(POW_MAX_RELATIVE_ERROR) + 1;
    }

    /// `x ^ y` rounded down.
    function powDown(uint256 x, uint256 y) internal pure returns (uint256) {
        if (y == WAD) return x;
        if (y == 2 * WAD) return x.mulWad(x);
        if (y == 4 * WAD) {
            uint256 square = x.mulWad(x);
            return square.mulWad(square);
        }
        uint256 raw = uint256(FixedPointMathLib.powWad(int256(x), int256(y)));
        uint256 error = raw.mulWadUp(POW_MAX_RELATIVE_ERROR) + 1;
        if (raw < error) return 0;
        return raw - error;
    }

    /// What the pool pays for exactly `amountIn`. Every step rounds against the swapper: the
    /// base up and the exponent down make the power larger, so the amount out is smaller.
    function outGivenExactIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn
    ) internal pure returns (uint256) {
        // The limit keeps the base at or above 1 / 1.3, inside the range the margin was
        // measured on.
        if (amountIn > balanceIn.mulWad(MAX_IN_RATIO)) revert MaxInRatio();
        uint256 base = balanceIn.divWadUp(balanceIn + amountIn);
        uint256 power = powUp(base, weightIn.divWad(weightOut));
        if (power >= WAD) return 0;
        return balanceOut.mulWad(WAD - power);
    }

    /// What the pool is paid to give exactly `amountOut`. Every step rounds up.
    function inGivenExactOut(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountOut
    ) internal pure returns (uint256) {
        // The limit keeps the base at or below 1 / 0.7, inside the range the margin was
        // measured on.
        if (amountOut > balanceOut.mulWad(MAX_OUT_RATIO)) revert MaxOutRatio();
        uint256 base = balanceOut.divWadUp(balanceOut - amountOut);
        uint256 power = powUp(base, weightOut.divWadUp(weightIn));
        return balanceIn.mulWadUp(power - WAD);
    }

    /// Whether `a * b >= c * d`, compared at 512 bits so no product can overflow or round.
    function productAtLeast(uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (bool)
    {
        (uint256 highLeft, uint256 lowLeft) = _product(a, b);
        (uint256 highRight, uint256 lowRight) = _product(c, d);
        if (highLeft != highRight) return highLeft > highRight;
        return lowLeft >= lowRight;
    }

    function _product(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            let full := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(full, low), lt(full, low))
        }
    }

    /// A token amount in 18 decimals. `scale` is `10 ^ (18 - decimals)`, so this is exact.
    function toWad(uint256 amount, uint256 scale) internal pure returns (uint256) {
        return amount * scale;
    }

    /// Back to token decimals for what the pool pays: rounded down.
    function fromWadDown(uint256 amount, uint256 scale) internal pure returns (uint256) {
        return amount / scale;
    }

    /// Back to token decimals for what the pool is paid: rounded up.
    function fromWadUp(uint256 amount, uint256 scale) internal pure returns (uint256) {
        return amount.divUp(scale);
    }
}
