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

/// @dev Marked tokens and both lock states with a Metric leg, and switching the hook off
/// when a venue is on Metric.
contract IndexBalancerMetricLocksTest is BalancerWorld {
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

    // ------------------------------------------------------------------ marks, locks

    /// With a v4 first trade and a Metric second, the same cycle runs with the pool manager
    /// locked and from inside another's unlock, and a marked token still counts in full.
    function testLockStatesAndMarksWithAMetricLeg() public {
        address[] memory list = _two(18, 18);
        IndexPool mixed = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        _attachRoutes(
            mixed, unit, list[0], _routes(_venue(list[0], unit, 1.05e18, DEEP, 3000)), 1e15, 0
        );
        MockBinPool second = _metricVenue(list[1], unit, 1e18, 2000e18, true);
        _attachRoutes(mixed, unit, list[1], _metricRoutes(address(second)), 1e15, 0);
        IndexRouter router = new IndexRouter(manager);
        uint256 snapshot = vm.snapshotState();
        uint256 locked = balancer.balance(address(mixed), list[0], list[1]);
        assertGt(locked, 0, "locked");
        vm.revertToState(snapshot);
        IndexToken(unit).mint(address(router), 1e18);
        bytes memory call = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(mixed), list[0], list[1]))
        );
        router.run(router.OUTER(), unit, 1e18, call);
        assertEq(router.profit(), locked, "the same cycle inside another's unlock");
        assertEq(router.deltaBefore(), router.deltaAfter(), "its balance untouched");
        vm.revertToState(snapshot);
        IndexToken(list[1]).mint(address(router), 20e18);
        router.approve(list[1], address(mixed));
        bytes memory swap = abi.encode(
            address(mixed),
            abi.encodeCall(
                IndexPool.swap,
                (list[1], list[0], 10e18, true, 0, address(router), block.timestamp)
            )
        );
        vm.recordLogs();
        router.run(router.PAY_FIRST(), list[1], 5e18, swap);
        assertEq(router.credited(), 5e18, "the payment counts in full");
        assertEq(router.markedAfter(), list[1], "marked again");
        assertGe(_assertInvariants(mixed), 1, "balanced");
    }

    // ------------------------------------------------------------------ switching off

    /// A cycle on Metric alone needs nothing from the pool manager, which here holds none
    /// of either token: a drain cannot block it, nor make the balancer stand aside.
    function testMetricOnlyCycleIgnoresThePoolManager() public {
        _metricOnly(1.05e18);
        assertEq(IndexToken(unit).balanceOf(address(manager)), 0, "nothing to drain");
        assertEq(IndexToken(token).balanceOf(address(manager)), 0, "nothing to drain");
        vm.recordLogs();
        _swap(pool, unit, token, 1e18, true);
        assertGe(_assertInvariants(pool), 1, "balanced before and after");
    }

    /// Metric first and v4 second: the pool manager must hold the most the v4 trade could
    /// owe before Metric is called, so a drain of it blocks the swap.
    function testDrainBeforeAMetricFirstCycleBlocks() public {
        address[] memory list = _two(18, 18);
        IndexPool mixed = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool first = _metricVenue(list[0], unit, 1.05e18, 2000e18, true);
        _attachRoutes(mixed, unit, list[0], _metricRoutes(address(first)), 1e15, 0);
        _attachRoutes(
            mixed, unit, list[1], _routes(_venue(list[1], unit, 1e18, DEEP, 3000)), 1e15, 0
        );
        IndexRouter router = new IndexRouter(manager);
        IndexToken(list[1]).mint(address(router), 100e18);
        router.approve(list[1], address(mixed));
        bytes memory swap = abi.encode(
            address(mixed),
            abi.encodeCall(
                IndexPool.swap,
                (list[1], list[0], 1e18, true, 0, address(router), block.timestamp)
            )
        );
        uint256 drain = router.DRAIN();
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.run(drain, list[1], 0, swap);
        // Without the drain the same swap is balanced.
        vm.recordLogs();
        router.run(router.MARK_ONLY(), list[1], 0, swap);
        assertGe(_assertInvariants(mixed), 1, "balanced");
    }

    /// v4 first and Metric second: the units the v4 trade makes owed are taken before
    /// Metric is called, so a drain of them blocks the swap.
    function testDrainBeforeAMetricSecondCycleBlocks() public {
        address[] memory list = _two(18, 18);
        IndexPool mixed = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        PoolKey memory key = _venue(list[0], unit, 1.05e18, DEEP, 3000);
        _attachRoutes(mixed, unit, list[0], _routes(key), 1e15, 0);
        MockBinPool second = _metricVenue(list[1], unit, 1e18, 2000e18, true);
        _attachRoutes(mixed, unit, list[1], _metricRoutes(address(second)), 1e15, 0);
        IndexRouter router = new IndexRouter(manager);
        IndexToken(list[1]).mint(address(router), 100e18);
        router.approve(list[1], address(mixed));
        bytes memory swap = abi.encode(
            address(mixed),
            abi.encodeCall(
                IndexPool.swap,
                (list[1], list[0], 1e18, true, 0, address(router), block.timestamp)
            )
        );
        uint256 drain = router.DRAIN();
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.run(drain, unit, 0, swap);
    }

    /// A Metric-only cycle run from inside a router's unlock while it holds the pool
    /// manager's whole balance of the unit: balanced as usual.
    function testMetricOnlyCycleInsideADrainingRouter() public {
        _metricOnly(1.05e18);
        // An unrelated v4 pool, so the pool manager has some of the unit to drain.
        _venue(token, unit, 1e18, DEEP, 3000);
        assertGt(IndexToken(unit).balanceOf(address(manager)), 0, "something to drain");
        IndexRouter router = new IndexRouter(manager);
        router.approve(unit, address(pool));
        IndexToken(unit).mint(address(router), 10e18);
        bytes memory swap = abi.encode(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (unit, token, 1e18, true, 0, address(router), block.timestamp)
            )
        );
        vm.recordLogs();
        router.run(router.DRAIN(), unit, 0, swap);
        assertGe(_assertInvariants(pool), 1, "balanced");
    }

    /// Metric first and v4 second against a thin v4 venue: the cycle runs the v4 trade
    /// first and takes only what it leaves owed, so an honest swap is never blocked, deep
    /// venue or thin. With a minimum profit no cycle reaches, every size is tried, the
    /// whole gap included, which a thin venue could never have paid for.
    function testThinSecondVenueNeverBlocksAnHonestSwap() public {
        for (uint256 run; run < 3; run++) {
            uint256 snapshot = vm.snapshotState();
            uint256 least = run == 2 ? 1e30 : 0;
            (IndexPool mixed, address[] memory list) =
                _metricThenV4(run == 1 ? DEEP : 1e19, least);
            vm.recordLogs();
            (bool ok,) = address(mixed)
                .call(
                    abi.encodeCall(
                        IndexPool.swap, (list[1], list[0], 1e18, true, 0, address(this), FAR)
                    )
                );
            assertTrue(ok, "the swap goes through");
            if (run < 2) assertGe(_assertInvariants(mixed), 1, "and is balanced");
            if (run == 2) assertEq(_assertInvariants(mixed), 0, "nothing paid enough");
            vm.revertToState(snapshot);
        }
    }

    /// The same shape drained of the token the v4 trade leaves owed: blocked before a swap,
    /// silent after one and in a keeper's call, and nothing set aside.
    function testDrainInTheReorderedShapeBlocksOnlyBeforeASwap() public {
        (IndexPool mixed, address[] memory list) = _metricThenV4(DEEP, 0);
        IndexRouter router = new IndexRouter(manager);
        bytes memory keeper = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(mixed), list[0], list[1]))
        );
        vm.recordLogs();
        router.run(router.DRAIN(), list[1], 0, keeper);
        assertEq(router.profit(), 0, "keeper: nothing");
        assertEq(_assertInvariants(mixed), 0, "no swap");
        (uint64 until,) =
            settings.benched(keccak256(abi.encode(address(mixed), list[1], list[0])));
        assertEq(until, 0, "nothing set aside");
    }

    function _metricThenV4(uint128 depth, uint256 least)
        internal
        returns (IndexPool mixed, address[] memory list)
    {
        list = _two(18, 18);
        mixed = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool first = _metricVenue(list[0], unit, 1.05e18, 2000e18, true);
        _attachRoutes(mixed, unit, list[0], _metricRoutes(address(first)), 1e15, least);
        PoolKey memory key = _venue(list[1], unit, 1e18, depth, 3000);
        _attachRoutes(mixed, unit, list[1], _routes(key), 1e15, least);
    }

    // ------------------------------------------------------------------ gas

    function _measure(string memory label, IndexPool target, address a, address b)
        internal
        returns (uint256 profit)
    {
        vm.cool(address(manager));
        vm.cool(address(balancer));
        vm.cool(address(balancer.sizer()));
        vm.cool(address(balancer.metric()));
        vm.cool(balancer.settings());
        vm.cool(address(factory));
        vm.cool(address(target));
        vm.cool(a);
        vm.cool(b);
        uint256 before = gasleft();
        profit = balancer.balance(address(target), a, b);
        console.log(label, before - gasleft());
    }

    function testGasOfANoGapCallReadingOneMetricVenue() public {
        MockBinPool venue = _metricOnly(1e18);
        vm.cool(address(venue));
        assertEq(_measure("no gap, one Metric venue", pool, token, unit), 0, "no gap");
    }

    function testGasOfANoGapCallReadingTwoMetricVenues() public {
        address[] memory list = _two(18, 18);
        IndexPool both = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool first = _metricVenue(list[0], unit, 1e18, 2000e18, true);
        MockBinPool second = _metricVenue(list[1], unit, 1e18, 2000e18, true);
        _attachRoutes(both, unit, list[0], _metricRoutes(address(first)), 1e15, 0);
        _attachRoutes(both, unit, list[1], _metricRoutes(address(second)), 1e15, 0);
        vm.cool(address(first));
        vm.cool(address(second));
        assertEq(_measure("no gap, two Metric venues", both, list[0], list[1]), 0, "no gap");
    }

    function testGasOfAOneTryMetricCycle() public {
        MockBinPool venue = _metricOnly(1.05e18);
        vm.cool(address(venue));
        assertGt(_measure("one try, Metric", pool, token, unit), 0, "one try");
        _assertClean(pool);
    }

    function testGasOfFiveFailedTriesWithAMetricLeg() public {
        MockBinPool venue = _metricVenue(token, unit, 1.05e18, 2000e18, true);
        _attachRoutes(pool, unit, token, _metricRoutes(address(venue)), 1e15, 1e30);
        vm.cool(address(venue));
        assertEq(_measure("five failed tries, Metric", pool, token, unit), 0, "five tries");
        _assertClean(pool);
    }
}
