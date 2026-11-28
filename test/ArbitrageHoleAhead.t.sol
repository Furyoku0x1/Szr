// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HoleWorld } from "./utils/HoleWorld.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A stand-in needs liquidity ahead (27-M-1, 27-M-2, docs/specs/hook-standin-ahead.md):
/// a thin pool with nothing deeper in its way makes none, so it costs a swap no gas and
/// benches nothing, and a stand-in's bench gives way to a gap twice as wide.
abstract contract ArbitrageHoleAheadBase is HoleWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant STANDIN_MARK = 1 << 191;
    uint256 internal constant TWO64 = 1 << 64;

    /// The bench of the pair in SZR's market, as the hook stores it: `until` in the low 64
    /// bits and the gap above. `benched` is storage slot 15.
    function _slot(bytes32 venue, bool buying) internal view returns (bytes32) {
        bytes32 key = keccak256(abi.encode(uint256(1), address(szr), _id(focus), venue, buying));
        return keccak256(abi.encode(key, uint256(15)));
    }

    function _bench(bytes32 venue, bool buying) internal view returns (uint256) {
        return uint256(vm.load(address(hook), _slot(venue, buying)));
    }

    function _benchedAny(bytes32 venue) internal view returns (bool) {
        return _bench(venue, true) != 0 || _bench(venue, false) != 0;
    }

    function _setBench(bytes32 venue, bool buying, uint256 gap) internal {
        uint256 word = (block.timestamp + hook.BENCH_TIME()) | (gap << 64);
        vm.store(address(hook), _slot(venue, buying), bytes32(word));
    }

    function _data(bool zeroForOne, int256 amount) internal view returns (bytes memory) {
        PoolSwapTest.TestSettings memory settings;
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams(zeroForOne, amount, limit);
        return abi.encodeCall(swapper.swap, (focus, params, settings, new bytes(0)));
    }

    /// A swap with exactly `gas`, every account cold as it is at the top of a transaction.
    function _swap(bool zeroForOne, int256 amount, uint256 gas) internal returns (bool ok) {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        (ok,) = address(swapper).call{ gas: gas }(_data(zeroForOne, amount));
    }

    /// The least gas, in steps of 50k, at which the swap passes. State is left as it was.
    function _lowest(bool zeroForOne, int256 amount) internal returns (uint256) {
        for (uint256 gas = 300_000; gas != 12_050_000; gas += 50_000) {
            uint256 snapshot = vm.snapshotState();
            bool ok = _swap(zeroForOne, amount, gas);
            vm.revertToState(snapshot);
            if (ok) return gas;
        }
        return 0;
    }
}

contract ArbitrageHoleAheadTest is ArbitrageHoleAheadBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ----- 27-M-1: no required attempt for a gap that is declined -----

    /// A marginal gap against Core at the defaults. The pool's liquidity is representative
    /// (the range around NAV is 12,000 ticks wide), so no stand-in is made and the swap
    /// needs no more gas than one with no plan possible at all.
    function testCoreMarginalGapNeedsNoStandInGas() public {
        _coreSetup(20);
        bool zeroForOne = Currency.unwrap(focus.currency0) != address(szr);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        uint256 start = vm.snapshotState();
        assertEq(hook.arb(_id(focus)), 0, "arb earns nothing");
        vm.revertToState(start);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.05e18);
        uint256 floor = _lowest(zeroForOne, -1e12);
        vm.revertToState(start);
        assertLe(_lowest(zeroForOne, -1e12), floor + 100_000, "before");
        assertTrue(_swap(zeroForOne, -1e12, 20_000_000), "the swap passes");
        assertFalse(_benchedAny(bytes32(0)), "no bench is written");
        assertLe(_lowest(zeroForOne, -1e12), floor + 100_000, "after a swap");
        vm.warp(block.timestamp + hook.BENCH_TIME() + 1);
        assertLe(_lowest(zeroForOne, -1e12), floor + 100_000, "after the bench time");
    }

    /// The focus pool left with 2% of its liquidity, in one range, with nothing deeper in
    /// either direction.
    function _thin(int256 amount) internal {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG - BIG / 50);
        uint256 start = vm.snapshotState();
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.05e18);
        uint256 floor = _lowest(true, amount);
        vm.revertToState(start);
        assertTrue(_swap(true, amount, 20_000_000), "the swap passes");
        assertEq(
            hook.benchedUntil(1, address(szr), _id(focus), _id(mainPool), false), 0, "main"
        );
        assertEq(hook.benchedUntil(1, address(szr), _id(focus), _id(usdPool), false), 0, "usd");
        assertFalse(_benchedAny(_id(mainPool)), "no bench on main");
        assertFalse(_benchedAny(_id(usdPool)), "no bench on usd");
        vm.revertToState(start);
        assertLe(_lowest(true, amount), floor + 100_000, "the gas needed");
    }

    function testThinFocusAt81NeedsNoStandInGas() public {
        _thin(-81e18);
    }

    function testThinFocusAt243NeedsNoStandInGas() public {
        _thin(-243e18);
    }

    // ----- 27-M-2: a swapper cannot switch the hole-edge fix off -----

    function _three(bool expire) internal returns (uint256) {
        _unposition(centre - WIDTH, centre + WIDTH, BIG - BIG / 50);
        uint160 start = _sqrt(focus);
        _swap(true, -81e18, 20_000_000);
        _swapTo(false, -1e30, start);
        if (expire) vm.warp(block.timestamp + 181);
        assertEq(_sqrt(focus), start, "the price is restored");
        assertFalse(_benchedAny(_id(mainPool)), "no bench on main");
        return _retired(true, true);
    }

    function testThinThreeSwapAttackDoesNotSwitchTheFixOff() public {
        _build(0);
        uint256 start = vm.snapshotState();
        uint256 attack = _three(false);
        vm.revertToState(start);
        uint256 control = _three(true);
        assertGt(control, 15e18, "a control gap worth taking");
        assertGe(attack * 100, control * 99, "the edge swap is searched in full");
    }

    function testFullWorldSingleSwapDoesNotBenchTheFix() public {
        _build(0);
        uint256 start = vm.snapshotState();
        uint256 control = _retired(true, true);
        vm.revertToState(start);
        assertTrue(_swap(true, -290e19, 20_000_000), "the swap passes");
        assertFalse(_benchedAny(_id(mainPool)), "no bench on main");
        assertGt(control, 700e18, "a control gap worth taking");
        assertGe(_retired(true, true) * 100, control * 95, "the edge swap is searched");
    }

    // ----- the bench of a stand-in -----

    /// The focus pool emptied, and the main pool 3% above it.
    function _emptyWorld() internal {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(false, -1e30, TickMath.getSqrtPriceAtTick(centre + 300)),
            settings,
            ""
        );
    }

    /// A truly empty pool makes a stand-in that fails, and its bench carries the marker and
    /// the gap it was made at.
    function testAFailedStandInBenchCarriesTheMarkerAndItsGap() public {
        _emptyWorld();
        _swapTo(false, -1e9, TickMath.getSqrtPriceAtTick(centre + 60));
        uint256 word = _bench(_id(mainPool), true) | _bench(_id(mainPool), false);
        assertGt(word, 0, "benched");
        uint256 gap = word >> 64;
        assertTrue(gap & STANDIN_MARK != 0, "marked as a stand-in's");
        assertGt(gap & ~STANDIN_MARK, 0, "with the gap it was made at");
        assertLt(gap & ~STANDIN_MARK, 4e18, "a real gap, under the edge limit");
    }

    /// 27-M-5: a real bench that is active, at a gap the stand-in is more than twice as wide
    /// as, lets the stand-in run. It fails once, and it is benched as a stand-in again, so it
    /// is not chosen again in every round.
    function testAStandInThatEscapesARealBenchFailsOnceAndIsBenched() public {
        _emptyWorld();
        uint256 start = vm.snapshotState();
        _swapTo(false, -1e9, TickMath.getSqrtPriceAtTick(centre + 60));
        bool buying = _bench(_id(mainPool), true) != 0;
        uint256 gap = (_bench(_id(mainPool), buying) >> 64) & ~STANDIN_MARK;
        vm.revertToState(start);
        _setBench(_id(mainPool), buying, gap / 3);
        vm.recordLogs();
        _swapTo(false, -1e9, TickMath.getSqrtPriceAtTick(centre + 60));
        assertEq(_count(ArbitrageLogic.CycleFailed.selector), 1, "one stand-in failed");
        uint256 word = _bench(_id(mainPool), buying);
        assertTrue((word >> 64) & STANDIN_MARK != 0, "now a stand-in's bench");
        assertEq((word >> 64) & ~STANDIN_MARK, gap, "at the stand-in's gap");
        _swapTo(false, -1e9, TickMath.getSqrtPriceAtTick(centre + 120));
        assertLe(_count(ArbitrageLogic.CycleFailed.selector), 1, "at most one in the next swap");
    }

    /// 27-M-4: a deep range far past NAV, beyond where the cycle would trade, does not make a
    /// stand-in that costs the swap a required attempt.
    function testAFarRangePastNavMakesNoStandIn() public {
        (int24 navTick, bool szr0) = _coreSetup(20);
        bool zeroForOne = Currency.unwrap(focus.currency0) != address(szr);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        if (szr0) _position(navTick + 2_400, navTick + 3_000, 20 * BIG);
        else _position(navTick - 3_000, navTick - 2_400, 20 * BIG);
        uint256 start = vm.snapshotState();
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.05e18);
        uint256 floor = _lowest(zeroForOne, -1e12);
        vm.revertToState(start);
        assertLe(_lowest(zeroForOne, -1e12), floor + 100_000, "before");
        assertTrue(_swap(zeroForOne, -1e12, 20_000_000), "the swap passes");
        assertFalse(_benchedAny(bytes32(0)), "no bench is written");
        assertLe(_lowest(zeroForOne, -1e12), floor + 100_000, "after a swap");
    }

    /// The focus pool pulled, its second range above, and the main pool in the middle of it:
    /// only a stand-in can close the gap, which is a little over 1.8%.
    function _pulled() internal {
        _build(0);
        _untrack(usdPool);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        _position(centre + 60, centre + 1_260, BIG);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(false, -1e30, TickMath.getSqrtPriceAtTick(centre + 360)),
            settings,
            ""
        );
        assertEq(manager.getLiquidity(focus.toId()), 0, "nothing to trade against");
    }

    /// A bench at a gap the candidate's is twice as wide as does not stop a stand-in.
    function testAStandInBenchGivesWayToAWiderGap() public {
        _pulled();
        _setBench(_id(mainPool), true, STANDIN_MARK | 0.001e18);
        _setBench(_id(mainPool), false, STANDIN_MARK | 0.001e18);
        assertGt(hook.arb(_id(focus)), 0, "a gap twice as wide as the bench's is taken");
    }

    /// A bench at a gap more than half the candidate's still does, of either kind.
    function testAStandInBenchStopsANarrowerGap() public {
        _pulled();
        uint256 start = vm.snapshotState();
        _setBench(_id(mainPool), true, STANDIN_MARK | 0.1e18);
        _setBench(_id(mainPool), false, STANDIN_MARK | 0.1e18);
        assertEq(hook.arb(_id(focus)), 0, "blocked by a stand-in's bench");
        vm.revertToState(start);
        _setBench(_id(mainPool), true, 0.1e18);
        _setBench(_id(mainPool), false, 0.1e18);
        assertEq(hook.arb(_id(focus)), 0, "blocked by a real bench");
    }
}

/// @dev The shape the focus pool must show, and what it costs (spec items 6 and 8).
contract ArbitrageHoleShapeTest is ArbitrageHoleAheadBase {
    /// Whether the focus pool, thin next to the venue, would make a stand-in trading it
    /// downwards (the price falls) or upwards, with the venue `away` ticks beyond the focus's
    /// centre in that direction, which puts the candidate's limit there.
    function _madeAt(bool down, int24 away) internal returns (bool made) {
        return _madeAim(down, away, 0);
    }

    /// `_madeAt` with the candidate's target set directly when `far` is nonzero (a square-root
    /// price in the probe's terms), for limits too far to move the venue to.
    function _madeAim(bool down, int24 away, uint256 far) internal returns (bool made) {
        uint256 start = vm.snapshotState();
        PoolSwapTest.TestSettings memory settings;
        int24 to = down ? centre - away : centre + away;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(down, -1e30, TickMath.getSqrtPriceAtTick(to)),
            settings,
            ""
        );
        bool szr0 = Currency.unwrap(focus.currency0) == address(szr);
        // Selling SZR into the pool lowers the price when SZR is its first token.
        bool buying = down ? !szr0 : szr0;
        // The venue pays more than the focus pool charges when buying and less when selling,
        // which the plan's limit arithmetic needs; the focus's own price is not read.
        uint256 rate = buying ? 1 << 96 : 2 << 96;
        made = _probeInHook().standInMade(_id(mainPool), _id(focus), 0, rate, true, buying, far);
        vm.revertToState(start);
    }

    /// With the venue well past the deeper range's first tick.
    function _made(bool down) internal returns (bool) {
        return _madeAt(down, 1_000);
    }

    function testAMidRangeFocusWithADeeperRangeAheadMakesAStandIn() public {
        _build(0);
        _position(centre - WIDTH - 1_200, centre - WIDTH, 20 * BIG);
        assertTrue(_made(true), "a deeper range starts at the next tick down");
        assertFalse(_made(false), "nothing deeper up");
        _position(centre + WIDTH, centre + WIDTH + 1_200, 20 * BIG);
        assertTrue(_made(false), "and up when there is one");
    }

    /// A range of at least ten times whose first tick lies before the candidate's limit makes a
    /// stand-in; with the limit before that tick it makes none (27-M-4).
    function testARangeBeyondTheCandidatesLimitMakesNone() public {
        _build(0);
        _position(centre - WIDTH - 1_200, centre - WIDTH, 20 * BIG);
        assertTrue(_madeAt(true, 1_000), "the limit is past the range's first tick");
        assertFalse(_madeAt(true, 300), "the limit is before it");
    }

    function testAMidRangeFocusWithNothingDeeperMakesNone() public {
        _build(0);
        assertFalse(_made(true), "not down");
        assertFalse(_made(false), "not up");
    }

    function testARangeUnderTenTimesAsDeepMakesNone() public {
        _build(0);
        _position(centre - WIDTH - 1_200, centre - WIDTH, 9 * BIG);
        assertFalse(_made(true), "nine times is not enough");
        _position(centre - WIDTH - 1_200, centre - WIDTH, BIG);
        assertTrue(_made(true), "ten times is");
    }

    /// The focus's next boundary is the edge of a bitmap word (15,360 ticks), with the venue
    /// beyond it so that the candidate's limit lies past the edge: nothing is seen, however
    /// deep the range beyond it, unless the pool's liquidity is zero.
    function testAWordEdgeBeforeTheLimitMakesNoneUnlessTheFocusIsEmpty() public {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        _provide(focus, BIG / 10);
        _position(centre + 16_020, centre + 17_220, BIG);
        _position(centre - 17_220, centre - 16_020, BIG);
        assertFalse(_madeAim(true, 1_000, 8 << 96), "not down");
        assertFalse(_madeAim(false, 1_000, (1 << 96) / 8), "not up");
        _unposition(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), BIG / 10);
        assertTrue(_madeAim(true, 1_000, 8 << 96), "empty, down");
        assertTrue(_madeAim(false, 1_000, (1 << 96) / 8), "empty, up");
    }
}

/// @dev Fable's L-2: the ranking's worst case, every venue of a book of eleven making a
/// stand-in, now also pays for the focus's shape in both directions. It must fit what a
/// search reserves for scanning, forty thousand gas a venue.
contract ArbitrageHoleReserveTest is ArbitrageHoleAheadBase {
    uint256 internal constant VENUES = 10;
    /// What the hook reserves to price each venue (`SCAN_GAS_PER_VENUE`, internal).
    uint256 internal constant SCAN_GAS_PER_VENUE = 40_000;

    /// A focus pool with a hundredth of the venues' depth and a deep range on either side of
    /// its own, and ten deep venues, the gaps widening and alternating in direction so that
    /// each one's stand-in outranks the last.
    function _crowd() internal returns (bytes32[] memory ids) {
        _build(0);
        _untrack(usdPool);
        _unposition(centre - WIDTH, centre + WIDTH, BIG - BIG / 100);
        _position(centre - WIDTH - 1_200, centre - WIDTH, 20 * BIG);
        _position(centre + WIDTH, centre + WIDTH + 1_200, 20 * BIG);
        hook.setLimits(1, address(szr), 8_000_000, 1e20, 1.0001e18);
        ids = new bytes32[](VENUES);
        for (uint256 index; index < VENUES; index++) {
            int24 away = int24(int256(700 + 100 * index));
            int24 at = centre + (index % 2 == 0 ? away : -away);
            PoolKey memory venue = _register(
                address(backing), uint24(101 + index), TickMath.getSqrtPriceAtTick(at)
            );
            _provide(venue, BIG / 4);
            ids[index] = _id(venue);
        }
    }

    function testTheRankingReserveFitsEveryVenueMakingAStandIn() public {
        bytes32[] memory ids = _crowd();
        ArbitrageProbe probe = _probeInHook();
        vm.cool(address(manager));
        (uint256 used, ArbitrageLogic.Plan memory plan) = probe.rankGas(_id(focus), ids);
        emit log_named_uint("ranking gas, eleven venues, every one a stand-in", used);
        assertTrue(plan.standin, "a stand-in");
        assertLe(used, SCAN_GAS_PER_VENUE * (VENUES + 1), "it fits the scan reserve");
    }
}
