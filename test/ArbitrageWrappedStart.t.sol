// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { SearchPart } from "../src/arbitrage/ArbitrageSearch.sol";
import { SearchManyPart } from "../src/arbitrage/ArbitrageSearchMany.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev The hook's search with its book and ranking exposed, for the rule that an ordinary
/// plan never has the start pool as its venue and for what an exchanged plan names.
contract StartProbe is ArbitrageProbe {
    struct Ranked {
        bool exchanged;
        uint256 index;
        bytes32 venue;
        bytes32 limitEnd;
        bytes32 start;
        uint256 score;
        bool buying;
    }

    constructor(Liquidity treasury) ArbitrageProbe(treasury) { }

    /// Ranks the book of a search from `poolId` in `market`, counting in `base`.
    function rank(uint256 market, address base, bytes32 poolId, address partner)
        external
        returns (Ranked memory out)
    {
        active = market;
        home = base;
        _begin(market);
        Venue[] memory book = _book(poolId, partner, true);
        Plan memory plan = _best(book);
        out.exchanged = plan.venue == book[0].id;
        out.index = plan.index;
        out.venue = plan.venue;
        out.score = plan.score;
        out.buying = plan.buying;
        out.start = book[0].id;
        if (plan.score != 0) out.limitEnd = _limitEnd(book, plan);
        asking = 0;
        active = 0;
    }

    /// Builds two books of `market`, one from each pool, and plans from the first. The
    /// second book's entries for the pools in `look` are first given a wrong rate; after
    /// what a cycle through the plan moved is priced again in the second book, they must
    /// match the first book's reading. Returns those two readings per pool.
    function requote(
        uint256 market,
        address base,
        bytes32 one,
        address onePartner,
        bytes32 other,
        address otherPartner,
        bytes32[2] calldata look
    ) external returns (uint256[2] memory wanted, uint256[2] memory got, bool exchanged) {
        active = market;
        home = base;
        _begin(market);
        Many memory run;
        run.books = new Venue[][](2);
        run.books[0] = _book(one, onePartner, true);
        run.books[1] = _book(other, otherPartner, false);
        run.bases = new address[](2);
        run.bases[0] = base;
        run.bases[1] = base;
        for (uint256 index; index < 2; index++) {
            wanted[index] = _rateOf(run.books[0], look[index]);
            _setRate(run.books[1], look[index], 1);
        }
        Plan memory plan = _best(run.books[0]);
        exchanged = plan.venue == run.books[0][0].id;
        _requoteOthers(run, 0, _limitEnd(run.books[0], plan), plan);
        for (uint256 index; index < 2; index++) {
            got[index] = _rateOf(run.books[1], look[index]);
        }
        asking = 0;
        active = 0;
    }

    function _setRate(Venue[] memory book, bytes32 poolId, uint256 rate) internal pure {
        for (uint256 index; index < book.length; index++) {
            if (book[index].id == poolId) book[index].rate = rate;
        }
    }

    function _rateOf(Venue[] memory book, bytes32 poolId) internal pure returns (uint256) {
        for (uint256 index; index < book.length; index++) {
            if (book[index].id == poolId) return book[index].rate;
        }
        return 0;
    }
}

/// @dev A market that counts in WETH only, whose WETH/coin group has the plain pool `first`
/// and a wrapped pool, with a WETH/coin pool `second` that no group lists.
abstract contract StartWorld is MarketsWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    TestAsset internal dai;
    PoolKey internal wrapped;
    PoolKey internal stable;

    struct Cycle {
        bytes32 centre;
        bytes32 venue;
        bool buying;
        uint256 profit;
        bool failed;
        bool afterSwap;
    }

    function setUp() public virtual override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        wrapped = _wrap(3_000);
        dai = new TestAsset();
        _approve(dai);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        address[] memory only = new address[](1);
        only[0] = address(backing);
        hook.setTokens(id, only);
        hook.addVenue(id, wrapped);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(wrapped), _id(first)));
        stable = _create(address(coin), address(dai), 500);
        vm.prank(team);
        hook.setConnector(id, stable, true);
    }

    /// A WETH/coin pool on the wrapping hook, holding a million of each token elsewhere.
    function _wrap(uint24 fee) internal returns (PoolKey memory pool) {
        pool = _pair(address(backing), address(coin), fee, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        backing.mint(address(wrapper), 1_000_000e18);
        coin.mint(address(wrapper), 1_000_000e18);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    function _off() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
    }

    function _on() internal {
        _limits(address(backing), 1e15);
    }

    /// Opens a gap by trading in `first` with the market switched off.
    function _gap(address input, uint256 amount) internal {
        _off();
        _trade(first, input, amount);
        _on();
    }

    function _held(PoolKey memory pool) internal view returns (uint256 weth) {
        (uint256 zero, uint256 one) = wrapper.reservesOf(_id(pool));
        return Currency.unwrap(pool.currency0) == address(backing) ? zero : one;
    }

    function _order(bytes32 one, bytes32 two) internal {
        _lead(address(backing), address(coin), _list(one, two));
        _on();
    }

    /// Every cycle and failed cycle the hook logged, in order, split at the swap in `stable`.
    function _cyclesIn(Vm.Log[] memory logs) internal view returns (Cycle[] memory found) {
        found = new Cycle[](logs.length);
        uint256 count;
        bool sawSwap;
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory log = logs[index];
            bytes32 topic = log.topics[0];
            if (log.emitter == address(manager)) {
                if (topic == IPoolManager.Swap.selector) {
                    if (log.topics[1] == _id(stable)) sawSwap = true;
                }
                continue;
            }
            if (log.emitter != address(hook)) continue;
            bool cycle = topic == ArbitrageLogic.Arbitraged.selector;
            bool failed = topic == ArbitrageLogic.CycleFailed.selector;
            if (!cycle) {
                if (!failed) continue;
            }
            Cycle memory entry = Cycle(log.topics[1], log.topics[2], false, 0, failed, sawSwap);
            if (cycle) (entry.buying, entry.profit) = abi.decode(log.data, (bool, uint256));
            found[count++] = entry;
        }
        assembly ("memory-safe") {
            mstore(found, count)
        }
    }

    function _assertSameCycles(Cycle[] memory one, Cycle[] memory two) internal pure {
        assertEq(one.length, two.length, "same number of cycles");
        for (uint256 index; index < one.length; index++) {
            assertEq(one[index].centre, two[index].centre, "same limit end");
            assertEq(one[index].venue, two[index].venue, "same venue");
            assertEq(one[index].buying, two[index].buying, "same direction");
            assertEq(one[index].profit, two[index].profit, "same profit, to the wei");
            assertEq(one[index].failed, two[index].failed, "same outcome");
            assertEq(one[index].afterSwap, two[index].afterSwap, "same side of the swap");
        }
    }

    struct Run {
        bool ok;
        bool refused;
        bool cycled;
    }

    /// Runs `swap` at each gas from `from` to `to` in a world that is put back after each
    /// run. `cycled` says that a cycle ran in the search before the swap.
    function _sweep(
        function(uint256) internal returns (bool, bytes memory) swap,
        uint256 from,
        uint256 to,
        uint256 step
    ) internal returns (Run[] memory runs) {
        runs = new Run[]((to - from) / step + 1);
        for (uint256 index; index < runs.length; index++) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            (bool ok, bytes memory data) = swap(from + index * step);
            Cycle[] memory cycles = _cyclesIn(vm.getRecordedLogs());
            vm.revertToState(snapshot);
            runs[index].ok = ok;
            runs[index].refused = _holds(data, ArbitrageLogic.InsufficientGas.selector);
            if (cycles.length != 0) runs[index].cycled = !cycles[0].afterSwap;
        }
    }

    /// The required rule, told apart from the low-gas floor. With no gap open the swap fails
    /// at low gas only: it settles from some gas up and never fails again above it. With a
    /// gap open, every gas at which it settles ran a cycle in the search before the swap, and
    /// some gas at which it settles with no gap is refused `InsufficientGas`, which only the
    /// gap can cause.
    function _assertRule(Run[] memory idle, Run[] memory open) internal pure {
        bool settledIdle;
        bool settledOpen;
        bool onlyTheGap;
        for (uint256 index; index < idle.length; index++) {
            if (settledIdle) assertTrue(idle[index].ok, "more gas failed with no gap");
            if (settledOpen) assertTrue(open[index].ok, "more gas failed with a gap");
            if (idle[index].ok) settledIdle = true;
            if (open[index].ok) {
                settledOpen = true;
                assertTrue(open[index].cycled, "settled without closing the gap first");
                assertTrue(idle[index].ok, "settled with a gap but not without");
            }
            if (idle[index].ok) {
                if (open[index].refused) onlyTheGap = true;
            }
        }
        assertTrue(settledIdle, "never settled with no gap");
        assertTrue(settledOpen, "never settled with a gap");
        assertTrue(onlyTheGap, "no gas was refused for the gap alone");
    }

    /// Whether `data`, a revert wrapped by the pool manager's routers, carries `selector`.
    function _holds(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), index))
            }
            if (word == selector) return true;
        }
        return false;
    }
}

/// @dev A search that starts from a wrapped pool compares it with plain pools only, and the
/// plain pool carries the price limit in each cycle (`docs/specs/hook-wrapped-start.md`).
contract ArbitrageWrappedStartTest is StartWorld {
    StartProbe internal probe;

    function _equivalence(address input) internal returns (bool buying) {
        _gap(input, 50_000e18);
        uint256 snapshot = vm.snapshotState();
        // The search starts from the wrapped pool, the head of the group.
        uint256 paid = backing.balanceOf(treasury);
        vm.recordLogs();
        uint256 viaWrapped = hook.sweep(id, address(backing));
        Cycle[] memory fromWrapped = _cyclesIn(vm.getRecordedLogs());
        uint256 keptWrapped = backing.balanceOf(treasury) - paid;
        uint256 heldWrapped = _held(wrapped);
        assertGt(viaWrapped, 0, "the wrapped head closed the gap");
        buying = fromWrapped[0].buying;
        vm.revertToState(snapshot);
        // The search starts from the plain pool.
        _order(_id(first), _id(wrapped));
        paid = backing.balanceOf(treasury);
        vm.recordLogs();
        uint256 viaPlain = hook.sweep(id, address(backing));
        Cycle[] memory fromPlain = _cyclesIn(vm.getRecordedLogs());
        assertEq(viaWrapped, viaPlain, "the same profit, to the wei");
        assertEq(keptWrapped, backing.balanceOf(treasury) - paid, "the same paid out");
        assertEq(heldWrapped, _held(wrapped), "the wrapped pool ends the same");
        _assertSameCycles(fromWrapped, fromPlain);
        // Every cycle trades the plain pool first.
        for (uint256 index; index < fromWrapped.length; index++) {
            assertEq(fromWrapped[index].centre, _id(first), "the limit end is the plain pool");
            assertEq(fromWrapped[index].venue, _id(wrapped), "the venue is the wrapped pool");
        }
        _assertNothingHeld();
    }

    /// One world, one gap between the plain pool and the wrapped one: a search started from
    /// either earns the same, to the wei, selling and buying.
    function testEquivalenceInBothDirections() public {
        uint256 snapshot = vm.snapshotState();
        bool selling = _equivalence(address(coin));
        vm.revertToState(snapshot);
        bool other = _equivalence(address(backing));
        assertTrue(selling != other, "the two gaps run opposite cycles");
    }

    // ---------------------------------------------------------------------------------
    // a swap in the connecting pool (the wrapped-centre PoC, turned round)
    // ---------------------------------------------------------------------------------

    function _swapInStable() internal returns (Cycle[] memory) {
        vm.recordLogs();
        _trade(stable, address(coin), 1e15);
        return _cyclesIn(vm.getRecordedLogs());
    }

    function _benched(bytes32 centre, bytes32 venue) internal view returns (uint256 until) {
        uint256 selling = hook.benchedUntil(id, address(backing), centre, venue, false);
        uint256 buying = hook.benchedUntil(id, address(backing), centre, venue, true);
        // A cycle is set aside in one direction only.
        assertTrue(selling == 0 || buying == 0, "one direction");
        return selling + buying;
    }

    /// A swap in a pool that connects two tokens searches from the group's head, here a
    /// wrapped pool. The gap is closed by one cycle before the swap, which is the cycle a
    /// search from the plain pool runs, and nothing is tried, failed or benched after it.
    function testSwapInTheConnectingPoolClosesTheGapFromAWrappedHead() public {
        for (uint256 round; round < 2; round++) {
            address input = round == 0 ? address(coin) : address(backing);
            uint256 snapshot = vm.snapshotState();
            _gap(input, 50_000e18);
            Cycle[] memory fromWrapped = _swapInStable();
            assertGt(fromWrapped.length, 0, "a cycle");
            for (uint256 index; index < fromWrapped.length; index++) {
                assertFalse(fromWrapped[index].failed, "no cycle failed");
                assertFalse(fromWrapped[index].afterSwap, "nothing left for after the swap");
            }
            assertEq(_benched(_id(first), _id(wrapped)), 0, "nothing benched");
            assertEq(_benched(_id(wrapped), _id(first)), 0, "nothing benched, reversed");
            assertEq(hook.sweep(id, address(backing)), 0, "the gap is closed");
            _assertNothingHeld();
            vm.revertToState(snapshot);
            // The same swap with the plain pool at the head gives the same cycles.
            _gap(input, 50_000e18);
            uint256 closed = backing.balanceOf(treasury);
            _order(_id(first), _id(wrapped));
            Cycle[] memory fromPlain = _swapInStable();
            _assertSameCycles(fromWrapped, fromPlain);
            assertGt(backing.balanceOf(treasury), closed, "paid");
            vm.revertToState(snapshot);
        }
    }

    /// A cycle between the two pools that fails is set aside under the same key whichever of
    /// them the search started from: the plain pool, then the wrapped one.
    function testAFailedCycleIsBenchedUnderTheSameKeyFromEitherEnd() public {
        for (uint256 round; round < 2; round++) {
            address input = round == 0 ? address(coin) : address(backing);
            uint256 snapshot = vm.snapshotState();
            _gap(input, 50_000e18);
            wrapper.arm(4, wrapped, address(hook), id);
            Cycle[] memory fromWrapped = _swapInStable();
            uint256 benchedWrapped = _benched(_id(first), _id(wrapped));
            assertGt(fromWrapped.length, 0, "a cycle was tried");
            assertTrue(fromWrapped[0].failed, "and failed");
            assertEq(fromWrapped[0].centre, _id(first), "naming the plain pool first");
            assertEq(fromWrapped[0].venue, _id(wrapped), "and the wrapped pool second");
            assertGt(benchedWrapped, 0, "set aside");
            assertEq(_benched(_id(wrapped), _id(first)), 0, "not under the reversed key");
            vm.revertToState(snapshot);
            _gap(input, 50_000e18);
            wrapper.arm(4, wrapped, address(hook), id);
            _order(_id(first), _id(wrapped));
            Cycle[] memory fromPlain = _swapInStable();
            _assertSameCycles(fromWrapped, fromPlain);
            assertEq(_benched(_id(first), _id(wrapped)), benchedWrapped, "the same bench");
            assertEq(_benched(_id(wrapped), _id(first)), 0, "not reversed from the plain end");
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------
    // the look after a cycle, and books that hold wrapped pools twice
    // ---------------------------------------------------------------------------------

    /// After a cycle against a wrapped venue the search looks again from that venue. The
    /// head `top` has a high fee, so it is closed against both pools while the wrapped pool
    /// and `second` are left apart. The last venue traded is the wrapped one, so the look
    /// starts from it and closes that gap with a cycle that has `second` as its limit end.
    function testTheLookAfterACycleStartsFromTheWrappedVenue() public {
        PoolKey memory top = _create(address(backing), address(coin), 10_000);
        _lead(address(backing), address(coin), _list3(_id(top), _id(wrapped), _id(second)));
        _on();
        _off();
        _trade(top, address(coin), 50_000e18);
        _on();
        vm.recordLogs();
        uint256 profit = hook.sweep(id, address(backing));
        Cycle[] memory cycles = _cyclesIn(vm.getRecordedLogs());
        assertGt(profit, 0, "earned");
        assertEq(cycles.length, 3, "three cycles");
        for (uint256 index; index < 3; index++) {
            assertFalse(cycles[index].failed, "no cycle failed");
        }
        assertEq(cycles[1].centre, _id(top), "the head is closed against W");
        assertEq(cycles[1].venue, _id(wrapped), "the last venue of the head's search is W");
        assertEq(cycles[2].centre, _id(second), "the look from W has `second` as limit end");
        assertEq(cycles[2].venue, _id(wrapped), "and W as venue");
        assertEq(hook.sweep(id, address(backing)), 0, "nothing is left");
        _assertNothingHeld();
    }

    function _list3(bytes32 one, bytes32 two, bytes32 three)
        internal
        pure
        returns (bytes32[] memory list)
    {
        list = new bytes32[](3);
        list[0] = one;
        list[1] = two;
        list[2] = three;
    }

    /// Two wrapped pools with a gap between them are never traded together: no cycle, no
    /// revert, nothing undone.
    function testTwoWrappedPoolsAreNeverComparedWithEachOther() public {
        PoolKey memory other = _wrap(500);
        _off();
        vm.prank(team);
        hook.addVenue(id, other);
        _lead(address(backing), address(coin), _list(_id(wrapped), _id(other)));
        _on();
        // Skew the second wrapped pool's reserves.
        wrapper.seed(other, 1_000_000e18, 600_000e18);
        vm.recordLogs();
        assertEq(hook.sweep(id, address(backing)), 0, "no profit");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_cyclesIn(logs).length, 0, "no cycle, none failed");
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            assertTrue(logs[index].topics[0] != ArbitrageLogic.SearchUndone.selector, "undone");
        }
        _assertNothingHeld();
    }

    /// A pool with no price beside a wrapped start pool is passed over, and the pool after it
    /// is still searched.
    function testACandidateWithNoPriceIsPassedOver() public {
        PoolKey memory blank = _pair(address(backing), address(coin), 1_000, address(0));
        _off();
        vm.prank(team);
        hook.addVenue(id, blank);
        _lead(address(backing), address(coin), _list3(_id(wrapped), _id(blank), _id(first)));
        _on();
        _gap(address(coin), 50_000e18);
        vm.recordLogs();
        assertGt(hook.sweep(id, address(backing)), 0, "the priced candidate was searched");
        Cycle[] memory cycles = _cyclesIn(vm.getRecordedLogs());
        for (uint256 index; index < cycles.length; index++) {
            assertEq(cycles[index].centre, _id(first), "never the pool with no price");
            assertFalse(cycles[index].failed, "nothing failed");
        }
    }

    /// An ordinary plan never has the start pool as its venue; an exchanged one does, and
    /// names the plain pool at `index` as its limit end.
    function testOrdinaryPlansNeverHaveTheStartPoolAsVenue() public {
        probe = _probe();
        _gap(address(coin), 50_000e18);
        StartProbe.Ranked memory plain =
            probe.rank(id, address(backing), _id(first), address(coin));
        assertGt(plain.score, 0, "a plan from the plain pool");
        assertFalse(plain.exchanged, "an ordinary plan");
        assertTrue(plain.venue != plain.start, "its venue is not the start pool");
        assertEq(plain.limitEnd, _id(first), "the start pool is its limit end");
        StartProbe.Ranked memory swapped =
            probe.rank(id, address(backing), _id(wrapped), address(coin));
        assertGt(swapped.score, 0, "a plan from the wrapped pool");
        assertTrue(swapped.exchanged, "an exchanged plan");
        assertEq(swapped.venue, _id(wrapped), "its venue is the start pool");
        assertEq(swapped.limitEnd, _id(first), "its limit end is the plain pool");
        assertEq(swapped.buying, plain.buying, "the same direction");
        // A start pool that is no leader of any group is an ordinary start too.
        StartProbe.Ranked memory loose =
            probe.rank(id, address(backing), _id(second), address(coin));
        assertGt(loose.score, 0, "a plan from a pool that leads nothing");
        assertFalse(loose.exchanged, "an ordinary plan");
        assertTrue(loose.venue != loose.start, "its venue is not the start pool");
        assertEq(loose.limitEnd, _id(second), "the start pool is its limit end");
    }

    /// A swap in the connecting pool whose book starts from a wrapped head is a required
    /// search: with a gap open and too little gas it fails `InsufficientGas`, and given what
    /// `gasForSwap` states it passes and closes the gap. More gas never fails a swap that
    /// passed with less.
    function testTheRequiredRuleHoldsForABookFromAWrappedHead() public {
        uint256 stated = hook.gasForSwap(id);
        Run[] memory idle = _sweep(_swapInStableWith, 200_000, stated, 100_000);
        _gap(address(coin), 50_000e18);
        Run[] memory open = _sweep(_swapInStableWith, 200_000, stated, 100_000);
        _assertRule(idle, open);
        vm.recordLogs();
        (bool passed,) = _swapInStableWith(stated);
        assertTrue(passed, "the stated gas is enough");
        Cycle[] memory cycles = _cyclesIn(vm.getRecordedLogs());
        assertGt(cycles.length, 0, "and closes the gap");
        assertFalse(cycles[0].afterSwap, "before the swap, from the wrapped head");
        assertEq(hook.sweep(id, address(backing)), 0, "nothing is left");
    }

    function _swapInStableWith(uint256 gas) internal returns (bool ok, bytes memory data) {
        bool zeroForOne = Currency.unwrap(stable.currency0) == address(coin);
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(pricer));
        (ok, data) = address(swapper).call{ gas: gas }(
            abi.encodeCall(
                swapper.swap,
                (
                    stable,
                    IPoolManager.SwapParams(
                        zeroForOne,
                        -int256(1_000e18),
                        zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
    }

    /// The gas floors assume ranking the book costs at most `SCAN_GAS_PER_VENUE` (and five
    /// cache reads) per venue. From a wrapped start each candidate gets a focus of its own,
    /// so this pins the worst book: the wrapped head, two more leaders, seven other groups,
    /// each with a connecting pool and a gap, ranked cold.
    function testRankingFromAWrappedHeadFitsItsAllowanceAtTheMostVenues() public {
        _off();
        for (uint256 index; index < 7; index++) {
            TestAsset partner = new TestAsset();
            _approve(partner);
            PoolKey memory pool = _pair(address(backing), address(partner), 3_000, address(0));
            manager.initialize(pool, uint160(1 << 96));
            _provide(pool, 1_000_000e18);
            PoolKey memory link = _pair(address(coin), address(partner), 3_000, address(0));
            manager.initialize(link, uint160(1 << 96));
            _provide(link, 1_000_000e18);
            vm.startPrank(team);
            hook.addVenue(id, pool);
            hook.setConnector(id, link, true);
            vm.stopPrank();
            _lead(address(backing), address(partner), _list(_id(pool)));
            _trade(pool, address(partner), 100_000e18);
        }
        _lead(address(backing), address(coin), _list3(_id(wrapped), _id(first), _id(second)));
        _trade(first, address(coin), 50_000e18);
        _on();
        StartProbe measured = _probe();
        vm.cool(address(manager));
        vm.cool(address(hook));
        (uint256 book, uint256 best, uint256 venues, uint256 allowance, uint256 bookAllowance) =
            measured.scanCostIn(id, address(backing), _id(wrapped));
        emit log_named_uint("venues", venues);
        emit log_named_uint("ranking from the wrapped head", best);
        emit log_named_uint("allowance for the ranking", venues * allowance);
        emit log_named_uint("reading", book);
        assertEq(venues, 10, "the most venues the book holds");
        assertLt(book, bookAllowance * venues, "reading within its allowance");
        assertLt(best, allowance * venues, "ranking within its allowance");
        // The same book ranked from a plain head, for comparison.
        vm.cool(address(manager));
        vm.cool(address(hook));
        (, uint256 plain,,,) = measured.scanCostIn(id, address(backing), _id(first));
        emit log_named_uint("ranking from a plain head", plain);
    }

    function _probe() internal returns (StartProbe) {
        address at = address(uint160(0xA4B3 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageWrappedStart.t.sol:StartProbe", abi.encode(locker), at);
        vm.etch(address(hook), at.code);
        return StartProbe(payable(address(hook)));
    }

    /// After an exchanged cycle another book's entries for both pools it moved, the limit
    /// end and the venue, are priced again.
    function testAnExchangedCycleRequotesBothMovedPoolsInOtherBooks() public {
        probe = _probe();
        _off();
        _lead(address(backing), address(coin), _list3(_id(wrapped), _id(first), _id(second)));
        _on();
        _gap(address(coin), 50_000e18);
        bytes32[2] memory look = [_id(first), _id(wrapped)];
        (uint256[2] memory wanted, uint256[2] memory got, bool exchanged) = probe.requote(
            id, address(backing), _id(wrapped), address(coin), _id(second), address(coin), look
        );
        assertTrue(exchanged, "the plan is an exchanged one");
        assertGt(wanted[0], 1, "the limit end has a price");
        assertGt(wanted[1], 1, "the venue has a price");
        assertEq(got[0], wanted[0], "the limit end is priced again");
        assertEq(got[1], wanted[1], "the venue is priced again");
    }
}

/// @dev Calls `venueSearch` as the wrapping hook from inside an unlock, as a swap through it
/// would, without needing the wrapped pool to trade.
contract VenueUnlocker {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IPoolManager internal immutable manager;
    address internal immutable wrapper;
    address internal immutable hook;
    bytes32 internal poolId;

    constructor(IPoolManager manager_, address wrapper_, address hook_) {
        manager = manager_;
        wrapper = wrapper_;
        hook = hook_;
    }

    function run(bytes32 id) external {
        poolId = id;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        VM.prank(wrapper);
        ArbitrageApi(payable(hook)).venueSearch(poolId, false, address(this));
        return "";
    }
}

/// @dev A swap through a wrapped pool that holds the trigger's token is searched once, from
/// that pool, before the fill and after it. The pool is no leader of its group.
contract ArbitrageWrappedTriggerTest is StartWorld {
    uint32 internal constant CAP = 12_000_000;

    PoolKey internal pairOne;
    PoolKey internal pairTwo;
    PoolKey internal dollars;

    function setUp() public override {
        super.setUp();
        // The wrapped pool is no leader: the groups are headed by plain pools only.
        _lead(address(backing), address(coin), _list(_id(first), _id(second)));
        pairOne = _create(address(backing), address(usd), 3_000);
        pairTwo = _create(address(backing), address(usd), 500);
        _lead(address(backing), address(usd), _list(_id(pairOne), _id(pairTwo)));
        dollars = _create(address(usd), address(coin), 3_000);
        address[] memory both = new address[](2);
        both[0] = address(backing);
        both[1] = address(usd);
        vm.prank(team);
        hook.setTokens(id, both);
        _lead(address(usd), address(coin), _list(_id(dollars)));
        _lead(address(usd), address(backing), _list(_id(pairOne), _id(pairTwo)));
        _limits(address(backing), 1e15);
        _limits(address(usd), 1e15);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] == topic) n++;
        }
    }

    /// The swap in the wrapped pool opens a gap between it and a plain leader. Today nothing
    /// finds it, since the pool is in no book; the search after the fill, started from the
    /// pool, closes it with the plain pool as the limit end. One search per side of the fill.
    function testTheSwapIsSearchedOnceFromTheWrappedPool() public {
        wrapper.watch(wrapped, address(hook), id, address(backing), CAP);
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 2);
        vm.recordLogs();
        _trade(wrapped, address(coin), 50_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, ArbitrageLogic.SearchUndone.selector), 0, "nothing undone");
        assertEq(_count(logs, ArbitrageLogic.VenueSearchSkipped.selector), 0, "none skipped");
        Cycle[] memory cycles = _cyclesIn(logs);
        assertGt(cycles.length, 0, "the gap the swap opened was closed");
        for (uint256 index; index < cycles.length; index++) {
            assertFalse(cycles[index].failed, "no cycle failed");
            assertEq(cycles[index].venue, _id(wrapped), "the wrapped pool is the venue");
            assertTrue(cycles[index].centre != _id(wrapped), "never the first trade");
        }
        _assertNothingHeld();
    }

    /// A trigger in a token the pool does not hold still searches from the first leader of
    /// every group of that token: two groups, two searches either side of the fill.
    function testATokenThePoolDoesNotHoldSearchesEveryGroup() public {
        wrapper.watch(wrapped, address(hook), id, address(usd), CAP);
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 4);
        _trade(wrapped, address(coin), 1e15);
    }

    /// The pool's own token, with two groups, is one search either side, not two.
    function testATokenThePoolHoldsIsSearchedOnce() public {
        wrapper.watch(wrapped, address(hook), id, address(backing), CAP);
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 2);
        _trade(wrapped, address(coin), 1e15);
    }

    /// Makes `pool` a venue of the market, watched for a trigger counting in `base`, and runs
    /// one `venueSearch` on it as the wrapper would; `searches` is how many `search` calls
    /// that makes.
    function _ethPoolSearches(PoolKey memory pool, address base, uint64 searches) internal {
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, pool);
        vm.stopPrank();
        _on();
        wrapper.watch(pool, address(hook), id, base, CAP);
        VenueUnlocker unlocker =
            new VenueUnlocker(IPoolManager(address(manager)), address(wrapper), address(hook));
        vm.expectCall(
            address(hook), abi.encodeWithSelector(SearchPart.search.selector), searches
        );
        vm.recordLogs();
        unlocker.run(_id(pool));
        assertEq(_count(vm.getRecordedLogs(), ArbitrageLogic.CycleFailed.selector), 0, "failed");
    }

    /// A wrapped pool of native ETH and a token T below WETH's address, priced far from 1:1,
    /// with the trigger counting in WETH, is not "held": it holds WETH's twin, and starting a
    /// search from it would price it as WETH with the pair the wrong way round. It keeps the
    /// old route of one search per group head (two groups), and nothing fails.
    function testAnEtherWrappedPoolInWethKeepsOneSearchPerGroup() public {
        address low = address(0x1234);
        deployCodeTo("TestAsset.sol:TestAsset", low);
        PoolKey memory pool = _pair(address(0), low, 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        wrapper.seed(pool, 1_000_000e18, 4_000_000e18);
        _ethPoolSearches(pool, address(backing), 2);
    }

    /// The pool's partner is native ETH, address zero, which is a real partner and not "none"
    /// (23-L-3 as the review found it): triggered in USD it is still one search.
    function testAnEtherPartnerOfTheTriggerTokenIsSearchedOnce() public {
        PoolKey memory pool = _pair(address(0), address(usd), 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
        _ethPoolSearches(pool, address(usd), 1);
    }

    /// With too little gas the search is skipped and reported, and the swap still settles;
    /// more gas never turns a swap that settled into one that fails.
    function testShortGasSkipsTheSearchAndNeverFailsTheSwap() public {
        wrapper.watch(wrapped, address(hook), id, address(backing), CAP);
        // A gap against a plain leader, so that the search before the fill trades the pool
        // that is about to be filled.
        _gap(address(coin), 50_000e18);
        bool settled;
        bool skipped;
        bool traded;
        for (uint256 gas = 300_000; gas <= 9_000_000; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWithGas(gas);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 skips = _count(logs, ArbitrageLogic.VenueSearchSkipped.selector);
            uint256 cycles = _cyclesIn(logs).length;
            vm.revertToState(snapshot);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (!ok) continue;
            settled = true;
            if (skips != 0) skipped = true;
            if (cycles != 0) traded = true;
        }
        assertTrue(settled, "never settled");
        assertTrue(skipped, "never skipped");
        assertTrue(traded, "never searched");
    }

    function _swapWithGas(uint256 gas) internal returns (bool ok) {
        bool zeroForOne = Currency.unwrap(wrapped.currency0) == address(coin);
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(pricer));
        (ok,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(
                swapper.swap,
                (
                    wrapped,
                    IPoolManager.SwapParams(
                        zeroForOne,
                        -int256(1_000e18),
                        zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
    }
}

/// @dev SZR's market: a wrapped pool that holds SZR can be named in `arb`, and the search from
/// it compares it with the plain pools. Core is passed over as a limit end.
contract ArbitrageWrappedStartSzrTest is MarketsWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    PoolKey internal away;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        away = _pair(address(szr), address(backing), 3_000, address(wrapper));
        manager.initialize(away, uint160(1 << 96));
        szr.transfer(address(wrapper), 1_000_000e18);
        backing.mint(address(wrapper), 1_000_000e18);
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        hook.addVenue(1, away);
        hook.setLimits(1, address(szr), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
    }

    function _held() internal view returns (uint256 coins) {
        (uint256 zero, uint256 one) = wrapper.reservesOf(_id(away));
        return Currency.unwrap(away.currency0) == address(szr) ? zero : one;
    }

    /// The wrapped SZR pool is dearer than the main pool, so SZR is bought in the main pool
    /// (the limit end) and sold in the wrapped pool, and the profit is retired at Core.
    function testArbFromAWrappedSzrPoolClosesTheGapAgainstThePlainPool() public {
        wrapper.seed(away, 400_000e18, 1_000_000e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 held = _held();
        vm.recordLogs();
        uint256 profit = hook.arb(_id(away));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(profit, 0, "the wrapped pool was searched");
        assertGt(core.unreleasedSupply(), inventory, "profit retired at Core");
        assertTrue(_held() != held, "the wrapped pool traded");
        bool venue;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] != ArbitrageLogic.Arbitraged.selector) continue;
            if (logs[index].topics[2] == _id(away)) venue = true;
            assertTrue(logs[index].topics[1] != _id(away), "never the first trade");
            assertTrue(logs[index].topics[1] != bytes32(0), "Core is never a limit end");
        }
        assertTrue(venue, "a cycle traded the wrapped pool as the venue");
        _assertNothingHeld();
    }

    /// Core is never the pool a cycle starts in, whichever way the wrapped pool is priced
    /// against it: no cycle names Core as its limit end, and none fails.
    function testCoreIsNeverTheLimitEnd() public {
        uint256[2][3] memory reserves = [
            [uint256(400_000e18), 1_000_000e18],
            [uint256(1_000_000e18), 400_000e18],
            [uint256(2_000_000e18), 100_000e18]
        ];
        for (uint256 round; round < reserves.length; round++) {
            uint256 snapshot = vm.snapshotState();
            bool szrFirst = Currency.unwrap(away.currency0) == address(szr);
            wrapper.seed(
                away,
                szrFirst ? reserves[round][0] : reserves[round][1],
                szrFirst ? reserves[round][1] : reserves[round][0]
            );
            vm.recordLogs();
            hook.arb(_id(away));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 index; index < logs.length; index++) {
                if (logs[index].emitter != address(hook)) continue;
                bytes32 topic = logs[index].topics[0];
                assertTrue(topic != ArbitrageLogic.CycleFailed.selector, "a cycle failed");
                if (topic != ArbitrageLogic.Arbitraged.selector) continue;
                assertTrue(logs[index].topics[1] != bytes32(0), "Core as the limit end");
            }
            vm.revertToState(snapshot);
        }
    }
}

/// @dev A pool that holds the twin ether token is not compared with a wrapped start pool: the
/// limit end must hold the token profit is counted in.
contract ArbitrageWrappedStartTwinTest is WrapWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    PoolKey internal wrapped;
    PoolKey internal ethCoin;
    StartProbe internal probe;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        wrapped = _pair(address(backing), address(coin), 3_000, address(wrapper));
        manager.initialize(wrapped, uint160(1 << 96));
        backing.mint(address(wrapper), 1_000_000e18);
        coin.mint(address(wrapper), 1_000_000e18);
        wrapper.seed(wrapped, 1_000_000e18, 1_000_000e18);
        ethCoin = _make(address(0), address(coin), 3_000, address(hook));
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(0);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.setTokens(id, tokens);
        hook.addVenue(id, wrapped);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(wrapped), _id(first)));
        _lead(address(0), address(coin), _list(_id(ethCoin)));
        _limits(address(backing), 1e15);
        probe = _probeInHook2();
    }

    function _probeInHook2() internal returns (StartProbe) {
        address at = address(uint160(0xA4B3 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageWrappedStart.t.sol:StartProbe", abi.encode(locker), at);
        vm.etch(address(hook), at.code);
        return StartProbe(payable(address(hook)));
    }

    function _off() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
    }

    /// A book that counts in ether holds the twin lists: a plain start pool of it has the
    /// wrapped pool and the plain pool of the WETH group as candidates, and its plan is an
    /// ordinary one whose venue is never the start pool.
    function testOrdinaryPlansOfAnEtherBookNeverHaveTheStartPoolAsVenue() public {
        _off();
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        StartProbe.Ranked memory plan = probe.rank(id, address(0), _id(ethCoin), address(coin));
        assertGt(plan.score, 0, "a plan from the ether pool");
        assertFalse(plan.exchanged, "an ordinary plan");
        assertTrue(plan.venue != plan.start, "its venue is not the start pool");
        assertEq(plan.limitEnd, _id(ethCoin), "the start pool is its limit end");
    }

    /// A gap only against the twin's pool is not searched from the wrapped pool; a gap against
    /// a pool that holds the searched token still is, in the same book.
    function testATwinPoolIsPassedOverAndTheOthersAreSearched() public {
        _off();
        _trade(ethCoin, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        StartProbe.Ranked memory twin =
            probe.rank(id, address(backing), _id(wrapped), address(coin));
        assertEq(twin.score, 0, "no cycle with the twin's pool");
        _off();
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        StartProbe.Ranked memory plain =
            probe.rank(id, address(backing), _id(wrapped), address(coin));
        assertGt(plain.score, 0, "the other candidate is still searched");
        assertEq(plain.limitEnd, _id(first), "and is the limit end");
    }
}

/// @dev A connecting-pool swap that opens books from wrapped heads for both of the market's
/// profit tokens: the several-books search (`searchMany`) runs exchanged plans.
contract ArbitrageWrappedStartManyTest is StartWorld {
    PoolKey internal dollarsWrapped;
    PoolKey internal dollars;

    function setUp() public override {
        super.setUp();
        dollarsWrapped = _pair(address(usd), address(coin), 3_000, address(wrapper));
        manager.initialize(dollarsWrapped, uint160(1 << 96));
        usd.mint(address(wrapper), 1_000_000e18);
        coin.mint(address(wrapper), 1_000_000e18);
        wrapper.seed(dollarsWrapped, 1_000_000e18, 1_000_000e18);
        dollars = _create(address(usd), address(coin), 3_000);
        address[] memory both = new address[](2);
        both[0] = address(backing);
        both[1] = address(usd);
        vm.startPrank(team);
        hook.setTokens(id, both);
        hook.addVenue(id, dollarsWrapped);
        vm.stopPrank();
        _lead(address(usd), address(coin), _list(_id(dollarsWrapped), _id(dollars)));
        _limits(address(backing), 1e15);
        _limits(address(usd), 1e15);
    }

    function _gaps() internal {
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.setLimits(id, address(usd), 0, 1e15, 1.0001e18);
        vm.stopPrank();
        _trade(first, address(coin), 50_000e18);
        _trade(dollars, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        _limits(address(usd), 1e15);
    }

    function _swapIn(uint256 gas) internal returns (bool ok, bytes memory data) {
        bool zeroForOne = Currency.unwrap(stable.currency0) == address(coin);
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(pricer));
        (ok, data) = address(swapper).call{ gas: gas }(
            abi.encodeCall(
                swapper.swap,
                (
                    stable,
                    IPoolManager.SwapParams(
                        zeroForOne,
                        -int256(1_000e18),
                        zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                    ),
                    PoolSwapTest.TestSettings(false, false),
                    ""
                )
            )
        );
    }

    /// Both gaps are closed by one swap in the connecting pool, each from a wrapped head, and
    /// no cycle's first trade is in a wrapped pool. At the stated gas it passes; with less and
    /// a gap open it fails `InsufficientGas`; more gas never fails what less passed.
    function testBothBooksFromWrappedHeadsCloseTheirGaps() public {
        uint256 stated = hook.gasForSwap(id);
        Run[] memory idle = _sweep(_swapIn, 400_000, stated, 200_000);
        _gaps();
        Run[] memory open = _sweep(_swapIn, 400_000, stated, 200_000);
        _assertRule(idle, open);
        vm.recordLogs();
        // Two books, so the several-books search runs, before the swap and after it.
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchManyPart.searchMany.selector));
        (bool passed,) = _swapIn(stated);
        assertTrue(passed, "the stated gas is enough");
        Cycle[] memory cycles = _cyclesIn(vm.getRecordedLogs());
        bool weth;
        bool dollar;
        for (uint256 index; index < cycles.length; index++) {
            assertFalse(cycles[index].failed, "no cycle failed");
            bytes32 end = cycles[index].centre;
            assertTrue(end != _id(wrapped), "the first trade is never in a wrapped pool");
            assertTrue(end != _id(dollarsWrapped), "nor in the other wrapped pool");
            if (end == _id(first)) weth = true;
            if (end == _id(dollars)) dollar = true;
        }
        assertTrue(weth, "the WETH gap was closed");
        assertTrue(dollar, "the USD gap was closed");
        assertFalse(cycles[0].afterSwap, "before the swap");
        assertEq(hook.sweep(id, address(backing)), 0, "nothing left in WETH");
        assertEq(hook.sweep(id, address(usd)), 0, "nothing left in USD");
    }
}

/// @dev A swap in a connecting pool that itself opens the gap. The book starts from a wrapped
/// head and nothing is traded before the swap, so the book is remembered; after the swap
/// `_open` recalls it and an exchanged cycle closes the gap. All of it is one call, since
/// transient storage is cleared between a test's top-level calls.
contract ArbitrageWrappedStartRememberedTest is StartWorld {
    TestAsset internal other;
    PoolKey internal otherPool;
    PoolKey internal link;

    function setUp() public override {
        super.setUp();
        // `_centreFor` takes the lower token of the connector first, so it must be the coin.
        other = new TestAsset();
        while (address(other) < address(coin)) other = new TestAsset();
        _approve(other);
        otherPool = _create(address(backing), address(other), 3_000);
        link = _create(address(coin), address(other), 500);
        vm.prank(team);
        hook.setConnector(id, link, true);
        _lead(address(backing), address(other), _list(_id(otherPool)));
        _on();
        // `_cyclesIn` splits the logs at the swap in `stable`; here that is the link.
        stable = link;
    }

    /// The second group's first leader is the limit end of the cycle; the wrapped pool is
    /// the venue.
    function testAnExchangedCycleFromARememberedBookClosesTheGap() public {
        uint256 snapshot = vm.snapshotState();
        uint256 paid = backing.balanceOf(treasury);
        vm.recordLogs();
        _trade(link, address(coin), 50_000e18);
        Cycle[] memory fromSwap = _cyclesIn(vm.getRecordedLogs());
        assertGt(backing.balanceOf(treasury), paid, "the market was paid");
        assertGt(fromSwap.length, 0, "the gap the swap opened was closed");
        for (uint256 index; index < fromSwap.length; index++) {
            assertTrue(fromSwap[index].afterSwap, "nothing was traded before the swap");
            assertFalse(fromSwap[index].failed, "no cycle failed");
            assertEq(fromSwap[index].venue, _id(wrapped), "the wrapped pool is the venue");
        }
        assertEq(fromSwap[0].centre, _id(otherPool), "the limit end is the other group's pool");
        assertEq(_benched(_id(otherPool), _id(wrapped)), 0, "nothing benched");
        assertEq(_benched(_id(wrapped), _id(otherPool)), 0, "nothing benched, reversed");
        _assertNothingHeld();
        vm.revertToState(snapshot);
        // The same end state with no swap search, closed by `sweep`, which reads every price.
        _off();
        _trade(link, address(coin), 50_000e18);
        _on();
        vm.recordLogs();
        assertGt(hook.sweep(id, address(backing)), 0, "sweep closes it");
        Cycle[] memory fromSweep = _cyclesIn(vm.getRecordedLogs());
        // The swap's search stops at `MAX_ROUNDS`, as `sweep` does for one book; `sweep`
        // then goes on to the other group's book. Every cycle the swap ran, `sweep` ran too.
        assertGe(fromSweep.length, fromSwap.length, "sweep ran at least those cycles");
        uint256 total;
        for (uint256 index; index < fromSwap.length; index++) {
            assertEq(fromSweep[index].centre, fromSwap[index].centre, "same limit end");
            assertEq(fromSweep[index].venue, fromSwap[index].venue, "same venue");
            assertEq(fromSweep[index].buying, fromSwap[index].buying, "same direction");
            assertEq(fromSweep[index].profit, fromSwap[index].profit, "same profit, to the wei");
            total += fromSwap[index].profit;
        }
        // What the rounds cap left behind is a small remainder of the gap.
        for (uint256 index = fromSwap.length; index < fromSweep.length; index++) {
            assertLt(fromSweep[index].profit * 1_000, total, "the swap closed nearly all of it");
        }
    }

    function _benched(bytes32 centre, bytes32 venue) internal view returns (uint256) {
        uint256 selling = hook.benchedUntil(id, address(backing), centre, venue, false);
        return selling + hook.benchedUntil(id, address(backing), centre, venue, true);
    }
}
