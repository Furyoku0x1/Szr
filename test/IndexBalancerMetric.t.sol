// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld, IndexRouter } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev Metric venues: choosing between them and v4 venues, their failures, a forged
/// callback, and a false price.
contract IndexBalancerMetricTest is BalancerWorld {
    address internal token;
    address internal unit;
    IndexPool internal pool;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
    }

    function _metricOnly(uint256 price) internal returns (MockBinPool venue) {
        venue = _metricVenue(token, unit, price, 2000e18, true);
        _attachRoutes(pool, unit, token, _metricRoutes(address(venue)), 1e15, 0);
    }

    // ------------------------------------------------------------------ choosing

    /// The venue that pays more is used for each direction: Metric when it bids more for
    /// the cheap token, v4 when it does.
    function testBestVenueOfEitherKindEachWay() public {
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 1e15, 0);
        MockBinPool venue = _metricVenue(token, unit, 1.06e18, 2000e18, true);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(_venue(token, unit, 1.04e18, DEEP, 3000))[0];
        both[1] = _metricRoutes(address(venue))[0];
        settings.setRoutes(address(pool), token, both);
        _apply(pool, token);
        (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
        assertEq(cycle.take, token, "token cheap");
        assertEq(cycle.sellPool, address(venue), "sold on Metric, which bids more");
        // Now the token is dear: v4 at 0.94 sells it cheaper than Metric at 0.96.
        (IndexPool other, address coin) = _pairAt(0.94e18, 0.96e18);
        (cycle,) = balancer.plan(address(other), coin, unit);
        assertEq(cycle.take, unit, "token dear");
        assertEq(cycle.buyPool, address(0), "bought on v4, which asks less");
        // And the other way round.
        (other, coin) = _pairAt(0.96e18, 0.94e18);
        (cycle,) = balancer.plan(address(other), coin, unit);
        assertTrue(cycle.buyPool != address(0), "bought on Metric");
        vm.recordLogs();
        assertGt(balancer.balance(address(other), coin, unit), 0, "and balanced");
        _assertInvariants(other);
    }

    function _pairAt(uint256 v4Price, uint256 metricPrice)
        internal
        returns (IndexPool other, address coin)
    {
        coin = address(new IndexToken(18));
        _readyToken(coin);
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        other = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(_venue(coin, unit, v4Price, DEEP, 3000))[0];
        both[1] =
            _metricRoutes(address(_metricVenue(coin, unit, metricPrice, 2000e18, false)))[0];
        _attachRoutes(other, unit, coin, both, 1e15, 0);
    }

    // ------------------------------------------------------------------ failures

    /// A paused pool, a feed that is down, a guard that refuses, a partial fill and a pool
    /// short of what it sells: each is silent, in a keeper's call and before a swap, and
    /// never blocks the swap.
    function testMetricFailuresAreSilent() public {
        for (uint256 run; run < 5; run++) {
            uint256 snapshot = vm.snapshotState();
            MockBinPool venue = _metricOnly(1.05e18);
            if (run == 0) venue.setSwitches(1, false, false, false);
            if (run == 1) venue.setSwitches(0, true, false, false);
            if (run == 2) venue.setSwitches(0, false, true, false);
            if (run == 3) venue.setMaxFill(1e15);
            if (run == 4) venue.setSwitches(0, false, false, true);
            if (run > 1) {
                (uint256 width,) = balancer.gap(address(pool), token, unit);
                assertGt(width, 0.04e18, "the gap is open: the trade itself fails");
            }
            vm.recordLogs();
            assertEq(balancer.balance(address(pool), token, unit), 0, "keeper: nothing");
            (, uint256 out) = _swap(pool, unit, token, 1e18, true);
            assertGt(out, 0, "the swap goes on");
            assertEq(_assertInvariants(pool), 0, "no balancing swap");
            vm.revertToState(snapshot);
        }
    }

    /// A paused Metric pool has no price, so a v4 venue beside it is used.
    function testPausedMetricBesideV4UsesV4() public {
        MockBinPool venue = _besideV4();
        venue.setSwitches(1, false, false, false);
        (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
        assertEq(cycle.sellPool, address(0), "the v4 venue");
        vm.recordLogs();
        assertGt(balancer.balance(address(pool), token, unit), 0, "balanced through v4");
        _assertInvariants(pool);
    }

    /// The best-priced venue is Metric and it quotes but refuses to trade: it is dropped for
    /// the call and the next best venue closes the gap, a working v4 venue or a second
    /// Metric one, and nothing is set aside. Alone, the pair is set aside as before.
    function testRefusingMetricFallsBackToTheNextVenue() public {
        for (uint256 run; run < 3; run++) {
            uint256 snapshot = vm.snapshotState();
            MockBinPool venue;
            if (run == 0) venue = _besideV4();
            if (run == 1) venue = _besideMetric();
            if (run == 2) venue = _metricOnly(1.06e18);
            venue.setSwitches(0, false, true, false);
            (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
            assertEq(cycle.sellPool, address(venue), "the refusing venue prices best");
            vm.recordLogs();
            _swap(pool, unit, token, 1e18, true);
            uint256 swaps = _assertInvariants(pool);
            (uint64 until,) =
                settings.benched(keccak256(abi.encode(address(pool), unit, token)));
            if (run < 2) {
                assertGe(swaps, 1, "closed through the next venue");
                assertEq(until, 0, "nothing set aside");
            } else {
                assertEq(swaps, 0, "nothing to fall back on");
                assertGt(until, 0, "set aside");
            }
            vm.revertToState(snapshot);
        }
    }

    /// The cost of falling back: the same cycle through v4, with and without a refusing
    /// Metric venue priced above it.
    function testGasOfTheFallback() public {
        uint256 snapshot = vm.snapshotState();
        MockBinPool venue = _besideV4();
        venue.setSwitches(0, false, true, false);
        uint256 before = gasleft();
        assertGt(balancer.balance(address(pool), token, unit), 0, "fell back");
        uint256 fallen = before - gasleft();
        vm.revertToState(snapshot);
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 1e15, 0);
        settings.setRoutes(
            address(pool), token, _routes(_venue(token, unit, 1.04e18, DEEP, 3000))
        );
        _apply(pool, token);
        before = gasleft();
        assertGt(balancer.balance(address(pool), token, unit), 0, "v4 alone");
        uint256 direct = before - gasleft();
        console.log("with a refusing Metric venue, through v4 alone", fallen, direct);
    }

    /// A Metric venue bidding 1.06 beside a v4 venue bidding 1.04.
    function _besideV4() internal returns (MockBinPool venue) {
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 1e15, 0);
        venue = _metricVenue(token, unit, 1.06e18, 2000e18, true);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(_venue(token, unit, 1.04e18, DEEP, 3000))[0];
        both[1] = _metricRoutes(address(venue))[0];
        settings.setRoutes(address(pool), token, both);
        _apply(pool, token);
    }

    /// A Metric venue bidding 1.06 beside a second one bidding 1.04.
    function _besideMetric() internal returns (MockBinPool venue) {
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 1e15, 0);
        venue = _metricVenue(token, unit, 1.06e18, 2000e18, true);
        MockBinPool other = _metricVenue(token, unit, 1.04e18, 2000e18, false);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _metricRoutes(address(other))[0];
        both[1] = _metricRoutes(address(venue))[0];
        settings.setRoutes(address(pool), token, both);
        _apply(pool, token);
    }

    /// A callback from anyone but the Metric pool being called reverts and moves nothing:
    /// a stranger, and a real Metric pool outside a swap of the balancer's.
    function testForgedCallbackGainsNothing() public {
        MockBinPool venue = _metricOnly(1.05e18);
        // A real cycle first, in the same transaction, so the balancer's record of its last
        // Metric trade is what a forger would find.
        assertGt(balancer.balance(address(pool), token, unit), 0, "a real cycle");
        IndexToken(token).mint(address(balancer), 5e18);
        vm.expectRevert(IndexBalancerState.NotMetric.selector);
        balancer.metricOmmSwapCallback(int256(1e18), -int256(1), "");
        vm.expectRevert(IndexBalancerState.NotMetric.selector);
        venue.poke(address(balancer));
        assertEq(IndexToken(token).balanceOf(address(balancer)), 5e18, "nothing paid out");
    }

    /// A partial fill is Metric's own failure: the venue is dropped for the call, so alone
    /// nothing stands and nothing is left behind, and beside a v4 venue the gap is closed
    /// there instead.
    function testPartialFillNeverStands() public {
        for (uint256 run; run < 2; run++) {
            uint256 snapshot = vm.snapshotState();
            MockBinPool venue = run == 0 ? _metricOnly(1.25e18) : _besideV4();
            (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
            uint256 walked = balancer.sizer().size(cycle);
            // Enough that a part-filled try would still look profitable.
            venue.setMaxFill(walked * 9 / 10);
            vm.recordLogs();
            uint256 profit = balancer.balance(address(pool), token, unit);
            uint256 swaps = _assertInvariants(pool);
            if (run == 0) {
                assertEq(profit, 0, "alone: nothing stands");
                assertEq(swaps, 0, "and nothing is left");
            } else {
                assertGt(profit, 0, "beside v4: closed there");
                assertEq(swaps, 1, "one swap");
            }
            vm.revertToState(snapshot);
        }
    }

    // ------------------------------------------------------------------ a false price

    /// A Metric price moved away from the v4 venue's, as a false price source would, is
    /// traded only while each cycle pays; the index pool's distance from the v4 price is
    /// recorded, with an honest deep v4 venue beside it and with none.
    function testFalseMetricPriceIsTradedOnlyWhileItPays() public {
        for (uint256 run; run < 2; run++) {
            uint256 snapshot = vm.snapshotState();
            bool withHonest = run == 0;
            settings.setUnit(address(pool), unit);
            settings.setLimits(address(pool), 1e15, 0);
            PoolKey memory honest = _venue(token, unit, 1e18, DEEP, 3000);
            MockBinPool venue = _metricVenue(token, unit, 1e18, 300e18, true);
            IndexBalancerState.Route[] memory both =
                new IndexBalancerState.Route[](withHonest ? 2 : 1);
            both[0] = _metricRoutes(address(venue))[0];
            if (withHonest) both[1] = _routes(honest)[0];
            settings.setRoutes(address(pool), token, both);
            _apply(pool, token);
            _apply(pool, token);
            venue.setMid(venue.mid() * 120 / 100);
            uint256 cycles = _untilItStopsPaying();
            uint256 distance =
                _distance(_poolPrice(pool, token, unit), _venuePrice(honest, token));
            console.log(withHonest ? "with an honest v4 venue" : "Metric alone");
            console.log("cycles that paid", cycles);
            console.log("index pool's distance from the v4 price (WAD)", distance);
            assertGt(cycles, 0, "the false price was traded");
            assertLt(cycles, 40, "until it stopped paying");
            assertLt(distance, 0.2e18, "never past the false price");
            vm.revertToState(snapshot);
        }
    }

    /// Every call stands only if it paid; counts them until one does not.
    function _untilItStopsPaying() internal returns (uint256 cycles) {
        vm.recordLogs();
        for (uint256 call; call < 40; call++) {
            if (balancer.balance(address(pool), token, unit) == 0) break;
            cycles++;
        }
        _assertInvariants(pool);
    }
}
