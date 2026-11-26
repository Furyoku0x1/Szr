// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { SizingWalk } from "../src/arbitrage/lib/SizingWalk.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { LibraryWorld, SizingWalkHarness } from "./utils/ArbitrageLibraries.sol";
import { SizingQuoter } from "./utils/ArbitrageSizing.sol";

/// @dev The sizing walk's engine on its own, against a real pool manager. The walk's sizes
/// are checked against real swaps through `SizingQuoter`, which shares none of its maths.
contract ArbitrageSizingWalkTest is LibraryWorld {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint128 internal constant UNITS = 1e24;

    SizingWalkHarness internal walker;
    SizingQuoter internal quoter;

    function setUp() public override {
        super.setUp();
        walker = new SizingWalkHarness(manager);
        quoter = new SizingQuoter(manager);
    }

    function _legs(SizingWalk.Leg memory a, SizingWalk.Leg memory b)
        internal
        pure
        returns (SizingWalk.Leg[] memory legs)
    {
        legs = new SizingWalk.Leg[](2);
        legs[0] = a;
        legs[1] = b;
    }

    /// A plain pool reads as it is stored, and the input that takes it to its boundary is
    /// exactly what a real swap to that price pays.
    function testPlainLegReadsThePoolAndReachesItsBoundary() public {
        PoolKey memory key = _pool(3000, 60, uint160(Q96 * 11 / 10), UNITS);
        bytes32 id = _id(key);
        SizingWalk.Leg memory leg = walker.plainLeg(id, true, 60, 0.1e18);
        (uint160 price, int24 tick,, uint24 fee) = manager.getSlot0(PoolId.wrap(id));
        assertEq(leg.price, price, "price");
        assertEq(leg.tick, tick, "tick");
        assertEq(leg.fee, fee, "fee");
        assertEq(leg.liquidity, manager.getLiquidity(PoolId.wrap(id)), "liquidity");
        assertEq(leg.keep, V4Read._keep(3000), "keep");
        assertEq(leg.limit, V4Read._limitFrom(price, true, 0.1e18), "limit");
        // No initialised tick in the word below: the boundary is the word's edge, tick 0.
        assertEq(leg.next, 0, "next");
        assertEq(leg.target, TickMath.getSqrtPriceAtTick(0), "target");
        assertFalse(leg.edge, "not the end of the leg");
        assertEq(walker.reach(leg), _swapTo(key, true, leg.target), "reach is what a swap pays");
    }

    /// The same the other way round, where the reach is an amount of token1.
    function testPlainLegReachesItsBoundaryBuyingToken0() public {
        PoolKey memory key = _pool(3000, 60, uint160(Q96 * 11 / 10), UNITS);
        SizingWalk.Leg memory leg = walker.plainLeg(_id(key), false, 60, 0.1e18);
        assertGt(leg.target, leg.price, "the boundary is above");
        assertEq(
            walker.reach(leg), _swapTo(key, false, leg.target), "reach is what a swap pays"
        );
    }

    /// A leg's boundary at an initialised tick, crossed as `Pool.swap` crosses it: the same
    /// liquidity and tick after it.
    function testLegCrossesATickAsThePoolDoes() public {
        PoolKey memory key = _pool(500, 10, uint160(Q96 * 11 / 10), UNITS);
        _position(key, 1800, 2000, UNITS / 2);
        bytes32 id = _id(key);
        SizingWalk.Leg memory leg = walker.plainLeg(id, true, 10, 0.5e18);
        assertEq(leg.next, 1800, "the narrow position's lower tick");
        assertTrue(leg.initialized, "initialised");
        assertEq(leg.liquidity, UNITS + UNITS / 2, "both positions in range");
        _swapTo(key, true, leg.target);
        (bool ends, SizingWalk.Leg memory after_) = walker.crossed(leg);
        assertFalse(ends, "a tick is not the end of the leg");
        (uint160 price, int24 tick,,) = manager.getSlot0(PoolId.wrap(id));
        assertEq(after_.price, price, "price at the tick");
        assertEq(after_.tick, tick, "tick past it");
        assertEq(after_.liquidity, manager.getLiquidity(PoolId.wrap(id)), "liquidity past it");
        assertEq(after_.liquidity, UNITS, "the narrow position left");
    }

    /// A leg with no state trades at its rate, squared since the rate is a square root.
    function testFixedRateLegTradesAtItsRate() public view {
        SizingWalk.Leg[] memory legs = new SizingWalk.Leg[](1);
        legs[0] = walker.fixedLeg(Q96 * 3 / 2);
        (uint256 out, uint256 focusIn) = walker.advance(legs, 4e18, 0);
        assertEq(out, 9e18, "2.25 times the input");
        assertEq(focusIn, 0, "a fixed leg takes no focus input");
    }

    /// Two legs compose into one curve: their rates multiply, and the depth is what the first
    /// leg's depth leaves after the second.
    function testTwoLegsCompose() public view {
        SizingWalk.Leg[] memory legs =
            _legs(walker.fixedLeg(Q96 * 3 / 2), walker.fixedLeg(Q96 * 4 / 5));
        (uint256 rate, uint256 depth, bool fits) = walker.compose(legs);
        assertTrue(fits, "fits");
        assertEq(rate, (Q96 * 3 / 2) * (Q96 * 4 / 5) / Q96, "the rates multiply");
        // The first leg passes on half its depth: what it could supply equals its own.
        uint256 half = SizingWalk.MAX_DEPTH / 2;
        uint256 flow = half * 9 / 4;
        uint256 expected = FixedPointMathLib.fullMulDiv(
            half, SizingWalk.MAX_DEPTH, SizingWalk.MAX_DEPTH + flow
        );
        assertEq(depth, expected, "depth");
    }

    /// Selling where token0 is dear and buying where it is cheap, the walk's predicted
    /// profit is what real swaps of its size return, and no nearby size earns more.
    function testTwoPoolWalkMatchesRealSwaps() public {
        _checkWalk(1100, 0);
    }

    /// The same with a narrow position the optimum moves across.
    function testTwoPoolWalkAcrossATickMatchesRealSwaps() public {
        uint256 steps = _checkWalk(1100, UNITS / 2);
        assertGt(steps, 0, "the walk crossed a tick");
    }

    function testFuzzTwoPoolWalkMatchesRealSwaps(uint256 dear, uint128 narrow) public {
        dear = bound(dear, 1015, 1300);
        narrow = uint128(bound(narrow, 0, UNITS * 4));
        _checkWalk(dear, narrow);
    }

    /// `dear` is the first pool's square-root price in thousandths; the second is at 1.01.
    function _checkWalk(uint256 dear, uint128 narrow) internal returns (uint256) {
        PoolKey[] memory path = new PoolKey[](2);
        path[0] = _pool(3000, 60, uint160(Q96 * dear / 1000), UNITS);
        path[1] = _pool(3001, 60, uint160(Q96 * 101 / 100), UNITS);
        if (narrow != 0) _position(path[0], 120, 1500, narrow);
        address[] memory inputs = new address[](2);
        inputs[0] = token0;
        inputs[1] = token1;
        SizingWalk.Leg[] memory legs = _legs(
            walker.plainLeg(_id(path[0]), true, 60, 1e18),
            walker.plainLeg(_id(path[1]), false, 60, 1e18)
        );
        (SizingWalk.Walk memory found,) = walker.walk(legs, 0);
        if (found.total == 0) return found.steps;
        assertFalse(found.short, "the walk ran to its end");
        int256 real = int256(quoter.quote(path, inputs, found.total)) - int256(found.total);
        assertApproxEqAbs(real, found.predicted, 8 * (found.steps + 1), "predicted profit");
        _assertBest(path, inputs, found.total, real);
        return found.steps;
    }

    function _assertBest(
        PoolKey[] memory path,
        address[] memory inputs,
        uint256 total,
        int256 profit
    ) internal {
        uint256 near = total / 100;
        int256 less = int256(quoter.quote(path, inputs, total - near)) - int256(total - near);
        int256 more = int256(quoter.quote(path, inputs, total + near)) - int256(total + near);
        assertLe(less, profit, "a smaller size earns no more");
        assertLe(more, profit, "a larger size earns no more");
    }

    /// A wrapped leg ends at the end of the range its pricer reports: a walk whose optimum
    /// is beyond it stops there, having taken the leg exactly to the end, and never
    /// declines.
    function testWrappedLegStopsAtTheEndOfItsRange() public view {
        uint256 packed = uint256(Q96) | uint256(3000) << 208;
        SizingWalk.Leg memory wrapped = walker.wrappedLeg(
            bytes32(uint256(7)), true, packed, 1e21, uint160(Q96 * 99 / 100), 0.1e18
        );
        SizingWalk.Leg[] memory legs = _legs(wrapped, walker.fixedLeg(Q96 * 6 / 5));
        (SizingWalk.Walk memory found, SizingWalk.Leg[] memory walked) = walker.walk(legs, 0);
        assertEq(found.total, walker.reach(wrapped), "exactly to the end of the range");
        assertEq(found.total, walked[0].reach, "the reach the walk found");
        assertEq(found.steps, 0, "nothing crossed");
        assertTrue(found.stopped, "never declined");
        assertFalse(found.short, "it ran to its end");
    }

    /// A walk that cannot afford another step stops where it is, as an under-trade.
    function testWalkStopsWhenGasIsShort() public view {
        SizingWalk.Leg[] memory legs = new SizingWalk.Leg[](3);
        legs[0] = walker.fixedLeg(Q96 * 6 / 5);
        legs[1] = walker.fixedLeg(Q96);
        legs[2] = walker.fixedLeg(Q96);
        // Three legs need 41,000 for a step.
        (bool more, SizingWalk.Walk memory found) = walker.round{ gas: 40_000 }(legs, 0);
        assertFalse(more, "over");
        assertTrue(found.short, "short");
        assertTrue(found.stopped, "stopped");
        assertEq(found.total, 0, "nothing found");
        (more, found) = walker.round(legs, 0);
        assertFalse(more, "over at the optimum");
        assertFalse(found.short, "not short with gas");
        assertGt(found.total, 0, "a size found");
    }

    /// What cannot be read reverts `Unsizable`, the hook's own error.
    function testUnreadableLegIsUnsizable() public {
        assertEq(SizingWalk.Unsizable.selector, bytes4(keccak256("Unsizable()")));
        vm.expectRevert(SizingWalk.Unsizable.selector);
        walker.read(0, 1, true, 0);
        vm.expectRevert(SizingWalk.Unsizable.selector);
        walker.read(uint256(Q96) | uint256(1e6) << 208, 1, true, 0);
        vm.expectRevert(SizingWalk.Unsizable.selector);
        walker.read(uint256(1) << 39, 1, true, 0);
    }

    function testShavedHoldsBackAMillionthAndSixteenWei() public view {
        assertEq(walker.shaved(1e18), 1e18 - 1e12 - 16);
        // The millionth rounds down.
        assertEq(walker.shaved(1e18 + 999_999), 1e18 + 999_999 - 1e12 - 16);
        assertEq(walker.shaved(16), 0);
    }

    /// Each division below is inexact, so every pin says which way the walk rounds: down,
    /// everywhere but `_reach`, which rounds up as v4 does.
    function _inexact(uint256 a, uint256 b, uint256 c) internal pure {
        assertTrue(mulmod(a, b, c) != 0, "a pin needs an inexact division");
    }

    function _floor(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        _inexact(a, b, c);
        return FixedPointMathLib.fullMulDiv(a, b, c);
    }

    /// A leg's rate, virtual reserve and depth all round down, both ways round.
    function testShapeRoundsDown() public view {
        SizingWalk.Leg memory leg;
        leg.id = bytes32(uint256(1));
        leg.price = uint160(Q96 * 7 / 5 + 12_345);
        leg.liquidity = 1e24 + 7;
        leg.fee = 3000;
        leg.keep = V4Read._keep(3000);
        uint256 price = leg.price;
        for (uint256 turn; turn < 2; turn++) {
            leg.zeroForOne = turn == 0;
            SizingWalk.Leg memory shaped = walker.shape(leg);
            uint256 rate = leg.zeroForOne
                ? _floor(price, leg.keep, 1e18)
                : _floor(1 << 192, leg.keep, price * 1e18);
            uint256 reserve = leg.zeroForOne
                ? _floor(leg.liquidity, Q96, price)
                : _floor(leg.liquidity, price, Q96);
            assertEq(shaped.rate, rate, "rate");
            assertEq(shaped.depth, _floor(reserve, 1e6, 1e6 - 3000), "depth");
        }
    }

    function _chain() internal pure returns (SizingWalk.Leg[] memory legs) {
        legs = new SizingWalk.Leg[](2);
        legs[0].rate = Q96 * 6 / 5 + 11;
        legs[0].depth = 1e24 + 3;
        legs[1].rate = Q96 * 9 / 10 + 5;
        legs[1].depth = 3e23 + 1;
    }

    /// Composing two legs rounds every step down: the flow each leg can be given, the depth
    /// that leaves, and the rates multiplied.
    function testComposeRoundsDown() public view {
        SizingWalk.Leg[] memory legs = _chain();
        (uint256 rate, uint256 depth,, SizingWalk.Leg[] memory out) = walker.composed(legs);
        uint256 max = SizingWalk.MAX_DEPTH;
        uint256 depthIn = _floor(max, legs[0].depth, legs[0].depth + max);
        assertEq(out[1].depthIn, depthIn, "depth after the first leg");
        uint256 half = _floor(depthIn, legs[0].rate, Q96);
        uint256 flow = _floor(half, legs[0].rate, Q96);
        assertEq(out[1].flowIn, flow, "flow into the second leg");
        assertEq(depth, _floor(depthIn, legs[1].depth, legs[1].depth + flow), "depth");
        assertEq(rate, _floor(legs[0].rate, legs[1].rate, Q96), "rate");
    }

    /// The best size within a range, and what fixed legs pay for it, round down.
    function testRoundSizeAndFixedLegsRoundDown() public view {
        SizingWalk.Leg[] memory legs = _chain();
        (uint256 rate, uint256 depth,,) = walker.composed(_chain());
        (bool more, SizingWalk.Walk memory found) = walker.round(legs, 0);
        assertFalse(more, "the optimum");
        uint256 cycle = _floor(depth, rate - Q96, Q96);
        assertEq(found.total, cycle, "the size");
        uint256 amount = cycle;
        for (uint256 index; index < 2; index++) {
            amount = _floor(amount, legs[index].rate, Q96);
            amount = _floor(amount, legs[index].rate, Q96);
        }
        assertEq(found.predicted, int256(amount) - int256(cycle), "what the legs pay");
    }

    /// The cycle input that takes a later leg to its boundary rounds down.
    function testBoundedRoundsDown() public view {
        SizingWalk.Leg[] memory legs = new SizingWalk.Leg[](2);
        legs[0].rate = Q96;
        legs[0].depth = SizingWalk.MAX_DEPTH;
        SizingWalk.Leg memory leg = legs[1];
        leg.id = bytes32(uint256(1));
        leg.zeroForOne = true;
        leg.price = uint160(Q96);
        leg.target = uint160(Q96 * 9 / 10);
        leg.liquidity = 1e21 + 1;
        leg.fee = 3000;
        leg.depthIn = 5e21 + 3;
        leg.flowIn = 4e21 + 1;
        uint256 reach = walker.reach(leg);
        (uint256 at, uint256 hit,) = walker.bounded(legs, type(uint256).max);
        assertEq(hit, 1, "the second leg");
        assertEq(at, _floor(reach, leg.depthIn, leg.flowIn - reach), "its input");
    }

    /// The band check reads the price down: a price whose rate is just under the lowest
    /// allowed is refused, not rounded up into the band.
    function testReadRoundsTheRateDown() public {
        _inexact(1 << 192, 1, (1 << 152) + 1);
        vm.expectRevert(SizingWalk.Unsizable.selector);
        walker.read((1 << 152) + 1, 1, false, 0);
        walker.read(1 << 152, 1, false, 0);
    }
}
