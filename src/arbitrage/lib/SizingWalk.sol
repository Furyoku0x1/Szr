// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { TickBitmap } from "v4-core/libraries/TickBitmap.sol";
import { BitMath } from "v4-core/libraries/BitMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { SwapMath } from "v4-core/libraries/SwapMath.sol";
import { LiquidityMath } from "v4-core/libraries/LiquidityMath.sol";
import { ProtocolFeeLibrary } from "v4-core/libraries/ProtocolFeeLibrary.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { V4Read } from "./V4Read.sol";

/// @notice The engine of the arbitrage hook's exact-sizing walk: a cycle of legs composed into
/// one curve, solved within its ranges and walked across their boundaries. Stateless: the
/// caller loads the legs and reads the answer, and the pool manager is an argument. See
/// `docs/specs/hook-exact-sizing.md`.
/// @dev `Unsizable` shares its name and selector with the hook's own.
library SizingWalk {
    using StateLibrary for IPoolManager;

    /// @dev The most boundary events (a tick crossed, or an empty word passed) one sizing
    /// walk follows, across all its legs together. Reaching it stops the walk where it is,
    /// which under-trades.
    uint256 internal constant SIZING_STEPS = 8;
    /// @dev What one more step of the walk may cost per leg, and what is held back for the
    /// answer after the last one. Measured at about 20k for a step with two legs and 28k to 33k
    /// with three, and rounded up. The walk stops before a step it cannot afford.
    uint256 internal constant SIZING_STEP_GAS = 12_000;
    uint256 internal constant SIZING_TAIL_GAS = 5_000;
    /// @dev Every size the walk answers is held back by this share of the whole cycle input
    /// plus a few wei, so that every leg really fills whatever rounding the crossings left.
    uint256 internal constant SIZING_SHAVE = 1_000_000;
    uint256 internal constant SIZING_WEI = 16;
    uint256 internal constant MAX_CYCLE_RATE = 1 << 180;
    uint256 internal constant MAX_DEPTH = 1 << 160;
    uint256 internal constant MIN_RATE = V4Read.MIN_RATE;
    uint256 internal constant MAX_RATE = V4Read.MAX_RATE;
    uint256 internal constant WAD = V4Read.WAD;
    uint256 internal constant Q96 = V4Read.Q96;
    uint256 internal constant Q192 = V4Read.Q192;

    /// @dev One leg of a cycle as the sizing walk sees it, in the order value flows. `id` is
    /// zero for Core redemption, which has no state. `rate` is the leg's marginal rate at
    /// size zero as a Q96 square root, fee included, and `depth` its depth in input units;
    /// `depthIn` is the depth of all the legs before it, and `flowIn` the most they can ever
    /// supply. `reach` is the gross
    /// input that takes the leg to `target`, the price of tick `next`, and `beyond` the
    /// liquidity past it. `limit` is the price the real trade is given as its limit (zero for
    /// none, as for Core), and `edge` marks a `target` that is that limit or the end of the
    /// tick range: the end of the leg. `broken` marks a boundary that could not be read.
    struct Leg {
        bytes32 id;
        bool zeroForOne;
        bool initialized;
        bool edge;
        bool broken;
        bool wrapped;
        int24 spacing;
        int24 tick;
        int24 next;
        uint24 fee;
        uint128 liquidity;
        uint128 beyond;
        uint160 price;
        uint160 target;
        uint160 limit;
        uint256 keep;
        uint256 rate;
        uint256 depth;
        uint256 depthIn;
        uint256 flowIn;
        uint256 reach;
    }

    /// @dev What a sizing walk has found so far: the cycle input, the input of the focus
    /// pool, and the profit it is expected to make. Two flags say different things.
    /// `stopped` means the walk never declines what it found; it is set when the walk stops
    /// at its cap on boundary events or for want of gas, and is also preset for any cycle
    /// with a wrapped leg. `short` means the walk could not carry on to its natural end; it
    /// is set at the four places where that happens and nowhere else, and it is what makes
    /// a cycle partial.
    struct Walk {
        uint256 total;
        uint256 focusIn;
        int256 predicted;
        uint256 steps;
        bool stopped;
        bool short;
    }

    error Unsizable();

    /// @dev One round of the walk: crosses a hole, or solves the legs within their ranges and
    /// moves them to the nearest boundary. False when the walk is over. Whatever the walk
    /// could not carry on with after it has found a size is a stop, never a decline.
    function _round(
        IPoolManager manager,
        Leg[] memory legs,
        Walk memory walk,
        uint256 focus,
        uint256 round
    ) internal view returns (bool) {
        // Short of gas for another step: what has been found is an under-trade.
        if (gasleft() < legs.length * SIZING_STEP_GAS + SIZING_TAIL_GAS) {
            walk.stopped = true;
            walk.short = true;
            return false;
        }
        uint256 empty = _shapeAll(legs);
        if (empty != legs.length) return _pass(manager, legs[empty], walk, round);
        (uint256 rate, uint256 depth, bool fits) = _compose(legs);
        if (!fits) {
            walk.stopped = true;
            walk.short = true;
            return false;
        }
        if (rate <= Q96) return false;
        uint256 cycle = FixedPointMathLib.fullMulDiv(depth, rate - Q96, Q96);
        uint256 hit;
        // A best size of zero, or of no more than the few wei that rounding is worth, with the
        // rate still above break-even is a range too thin to matter, not the optimum: go to
        // its nearest boundary, and across it if that is zero too.
        bool thin = cycle <= SIZING_WEI;
        (cycle, hit) = _bounded(legs, thin ? type(uint256).max : cycle);
        bool crossing = hit != legs.length;
        if (!crossing) {
            if (thin) return false;
        }
        // The next boundary is further than the few wei that rounding is worth: this is the
        // optimum, not a range to skip.
        if (thin) {
            if (cycle > SIZING_WEI) return false;
        }
        if (crossing) {
            if (_ends(manager, legs[hit])) crossing = false;
        }
        _step(legs, walk, cycle, hit, focus, crossing);
        if (!crossing) return false;
        return _carryOn(manager, legs[hit], walk, round);
    }

    /// @dev A leg in a hole, or in a range too thin to shape, crosses to its next boundary
    /// for nothing, as in v4. The end of the leg is the only dead end.
    function _pass(IPoolManager manager, Leg memory leg, Walk memory walk, uint256 round)
        internal
        view
        returns (bool)
    {
        if (_ends(manager, leg)) return false;
        return _carryOn(manager, leg, walk, round);
    }

    function _carryOn(IPoolManager manager, Leg memory leg, Walk memory walk, uint256 round)
        internal
        view
        returns (bool)
    {
        if (round == SIZING_STEPS) {
            walk.stopped = true;
            walk.short = true;
            return false;
        }
        _cross(manager, leg);
        walk.steps++;
        if (leg.broken) {
            walk.stopped = true;
            walk.short = true;
            return false;
        }
        return true;
    }

    function _shaved(uint256 spend) internal pure returns (uint256) {
        uint256 cut = spend / SIZING_SHAVE + SIZING_WEI;
        return spend > cut ? spend - cut : 0;
    }

    /// @dev Moves every leg by `cycle` of cycle input and books the result.
    function _step(
        Leg[] memory legs,
        Walk memory walk,
        uint256 cycle,
        uint256 hit,
        uint256 focus,
        bool force
    ) internal pure {
        uint256 out;
        uint256 focusIn;
        (out, focusIn) = _advance(legs, cycle, force ? hit : legs.length, focus);
        walk.total += cycle;
        walk.focusIn += focusIn;
        walk.predicted += int256(out) - int256(cycle);
    }

    /// @dev Fills in a leg from the first word of its pool's state, as `Pool.swap` reads it:
    /// the fee is the one for the leg's direction.
    function _read(Leg memory leg, uint256 packed, uint256 units, uint256 gap) internal pure {
        leg.price = uint160(packed);
        leg.tick = int24(uint24(packed >> 160));
        uint16 levy = uint16(leg.zeroForOne ? (packed >> 184) & 0xfff : (packed >> 196) & 0xfff);
        uint24 lpFee = uint24(packed >> 208);
        leg.fee = levy == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(levy, lpFee);
        leg.liquidity = uint128(units);
        if (leg.price == 0) revert Unsizable();
        if (leg.fee >= 1e6) revert Unsizable();
        uint256 rate = leg.zeroForOne ? leg.price : Q192 / leg.price;
        if (rate < MIN_RATE) revert Unsizable();
        if (rate > MAX_RATE) revert Unsizable();
        leg.keep = V4Read._keep(leg.fee);
        // The limit the real trade is given, `_legLimit`; the focus leg's is set by the caller.
        leg.limit = V4Read._limitFrom(leg.price, leg.zeroForOne, gap);
    }

    /// @dev The next tick `Pool.swap` would stop at going the leg's way: the next
    /// initialised one within a bitmap word, or the word's edge when it has none. Reaching
    /// the end of the tick range is the end of liquidity.
    function _bound(IPoolManager manager, Leg memory leg) internal view {
        int24 compressed = TickBitmap.compress(leg.tick, leg.spacing);
        PoolId pool = PoolId.wrap(leg.id);
        int24 next;
        unchecked {
            if (leg.zeroForOne) {
                (int16 word, uint8 bit) = TickBitmap.position(compressed);
                uint256 masked =
                    manager.getTickBitmap(pool, word) & (type(uint256).max >> (255 - bit));
                leg.initialized = masked != 0;
                uint8 back = leg.initialized ? bit - BitMath.mostSignificantBit(masked) : bit;
                next = (compressed - int24(uint24(back))) * leg.spacing;
            } else {
                (int16 word, uint8 bit) = TickBitmap.position(++compressed);
                uint256 masked = manager.getTickBitmap(pool, word) & ~((uint256(1) << bit) - 1);
                leg.initialized = masked != 0;
                uint8 ahead = leg.initialized
                    ? BitMath.leastSignificantBit(masked) - bit
                    : type(uint8).max - bit;
                next = (compressed + int24(uint24(ahead))) * leg.spacing;
            }
        }
        leg.edge = next <= TickMath.MIN_TICK || next >= TickMath.MAX_TICK;
        if (next <= TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        if (next >= TickMath.MAX_TICK) next = TickMath.MAX_TICK;
        leg.next = next;
        leg.target = TickMath.getSqrtPriceAtTick(next);
        // The real trade is stopped at its limit, so that is where the leg ends if nearer.
        if (leg.zeroForOne) {
            if (leg.target <= leg.limit) (leg.target, leg.edge) = (leg.limit, true);
            if (leg.target > leg.price) leg.broken = true;
        } else {
            if (leg.target >= leg.limit) (leg.target, leg.edge) = (leg.limit, true);
            if (leg.target < leg.price) leg.broken = true;
        }
    }

    /// @dev The cycle's whole chain of legs, at their current prices, as one curve:
    /// its marginal rate at size zero (a Q96 square root) and its depth in input units. Each
    /// leg also keeps the same for the legs before it. See `docs/specs/hook-exact-sizing.md`.
    function _compose(Leg[] memory legs)
        internal
        pure
        returns (uint256 rate, uint256 depth, bool fits)
    {
        rate = Q96;
        depth = MAX_DEPTH;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            leg.depthIn = depth;
            uint256 flow = FixedPointMathLib.fullMulDiv(
                FixedPointMathLib.fullMulDiv(depth, rate, Q96), rate, Q96
            );
            leg.flowIn = flow;
            depth = FixedPointMathLib.fullMulDiv(depth, leg.depth, leg.depth + flow);
            rate = FixedPointMathLib.fullMulDiv(rate, leg.rate, Q96);
            if (rate > MAX_CYCLE_RATE) return (0, 0, false);
        }
        return (rate, depth, true);
    }

    /// @dev Shapes every leg, and says which is the first with no depth to compose: in a hole,
    /// or in a range so thin that its depth rounds to zero. Such a leg is crossed for
    /// nothing. `legs.length` if there is none.
    function _shapeAll(Leg[] memory legs) internal pure returns (uint256 empty) {
        empty = legs.length;
        for (uint256 index; index < legs.length; index++) {
            if (legs[index].id == bytes32(0)) continue;
            _shape(legs[index]);
            if (empty == legs.length) {
                if (legs[index].depth == 0) empty = index;
            }
        }
    }

    /// @dev A leg's rate and depth from its price and liquidity: the input token's side of
    /// its virtual reserves, with the fee taken from the input.
    function _shape(Leg memory leg) internal pure {
        uint256 price = leg.price;
        uint256 reserve;
        if (leg.liquidity == 0) {
            leg.depth = 0;
            return;
        }
        if (leg.zeroForOne) {
            leg.rate = FixedPointMathLib.fullMulDiv(price, leg.keep, WAD);
            reserve = FixedPointMathLib.fullMulDiv(leg.liquidity, Q96, price);
        } else {
            leg.rate = FixedPointMathLib.fullMulDiv(Q192, leg.keep, price * WAD);
            reserve = FixedPointMathLib.fullMulDiv(leg.liquidity, price, Q96);
        }
        uint256 depth = FixedPointMathLib.fullMulDiv(reserve, 1e6, 1e6 - leg.fee);
        leg.depth = depth > MAX_DEPTH ? MAX_DEPTH : depth;
    }

    /// @dev The cycle input at which the first leg to reach its boundary does, if that is
    /// less than `cycle`, and which leg it is (`legs.length` for none). A leg gets `x` of
    /// its own input from the legs before it when the cycle puts in `x * P / (M * P - x)`,
    /// `M` and `P` being their price and depth; if they can never supply `x` the leg never
    /// gets there.
    function _bounded(Leg[] memory legs, uint256 cycle)
        internal
        pure
        returns (uint256, uint256 hit)
    {
        hit = legs.length;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) continue;
            leg.reach = _reach(leg);
            uint256 input = leg.reach;
            if (index != 0) {
                if (input >= leg.flowIn) continue;
                input = FixedPointMathLib.fullMulDiv(input, leg.depthIn, leg.flowIn - input);
            }
            if (input < cycle) {
                cycle = input;
                hit = index;
            }
        }
        return (cycle, hit);
    }

    /// @dev The gross input, fee included, that takes a leg from its price to its boundary.
    function _reach(Leg memory leg) internal pure returns (uint256 amount) {
        amount = leg.zeroForOne
            ? SqrtPriceMath.getAmount0Delta(leg.target, leg.price, leg.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(leg.price, leg.target, leg.liquidity, true);
        amount += FullMath.mulDivRoundingUp(amount, leg.fee, 1e6 - leg.fee);
    }

    /// @dev Whether the leg's boundary is the end of the leg, its price limit or the end of the
    /// tick range. If not, it also finds the liquidity past it, for `_cross`. Zero liquidity
    /// past it is a hole, which is crossed, not an end.
    function _ends(IPoolManager manager, Leg memory leg) internal view returns (bool) {
        if (leg.edge) return true;
        leg.beyond = leg.liquidity;
        if (!leg.initialized) return false;
        (, int128 net) = manager.getTickLiquidity(PoolId.wrap(leg.id), leg.next);
        leg.beyond = LiquidityMath.addDelta(leg.liquidity, leg.zeroForOne ? -net : net);
        return false;
    }

    /// @dev Moves a leg across its boundary, as `Pool.swap` does, and finds the next one.
    function _cross(IPoolManager manager, Leg memory leg) internal view {
        leg.price = leg.target;
        leg.liquidity = leg.beyond;
        leg.tick = leg.zeroForOne ? leg.next - 1 : leg.next;
        _bound(manager, leg);
    }

    /// @dev Trades `cycle` through every leg in turn, as `SwapMath` would, and returns what
    /// the last one pays out and what went into the focus pool. The leg at `hit` is taken to
    /// its boundary whatever rounding says, since it is the one the walk is stopping at.
    function _advance(Leg[] memory legs, uint256 cycle, uint256 hit, uint256 focus)
        internal
        pure
        returns (uint256 amount, uint256 focusIn)
    {
        amount = cycle;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) {
                amount = FixedPointMathLib.fullMulDiv(
                    FixedPointMathLib.fullMulDiv(amount, leg.rate, Q96), leg.rate, Q96
                );
                continue;
            }
            if (index == hit) {
                if (amount < leg.reach) amount = leg.reach;
            }
            if (index == focus) focusIn = amount;
            if (amount == 0) continue;
            (leg.price,, amount,) = SwapMath.computeSwapStep(
                leg.price, leg.target, leg.liquidity, -int256(amount), leg.fee
            );
        }
    }
}
