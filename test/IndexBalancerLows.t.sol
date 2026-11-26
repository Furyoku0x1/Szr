// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexMetric } from "../src/index/IndexMetric.sol";
import { IndexSettings } from "../src/index/IndexSettings.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { Cycle, IndexSizer } from "../src/index/IndexSizer.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev The third fix round: a losing size in the reordered shape (Low-1), answers from
/// inside Metric's call taken only when the balancer raised them (Low-2), and test gaps.
contract IndexBalancerLowsTest is BalancerWorld {
    address internal unit;

    function setUp() public override {
        super.setUp();
        unit = address(new IndexToken(18));
        _readyToken(unit);
    }

    function _balancedAt() internal returns (uint256 first, uint256 asides) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == IndexBalancer.Balanced.selector) {
                if (first == 0) (first,) = abi.decode(logs[index].data, (uint256, uint256));
            }
            if (topic == IndexBalancer.SetAside.selector) asides++;
        }
    }

    // ------------------------------------------------------------------ Low-1

    /// The reviewer's setup: A on a Metric bin, B on a v4 venue of liquidity 3e20, no unit
    /// in the pool, the walk forced to fail. The large sizes buy more A from the index pool
    /// than the v4 trade can pay Metric for: each is the size losing, not Metric refusing.
    /// A smaller size stands and nothing is set aside.
    function testALosingSizeInTheReorderedShapeIsAnOrdinaryFailedTry() public {
        address[] memory list = _two(18, 18);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool metric = _metricVenue(list[0], unit, 1.03e18, 2000e18, true);
        _attachRoutes(pool, unit, list[0], _metricRoutes(address(metric)), 1e15, 0);
        PoolKey memory key = _venue(list[1], unit, 1e18, 3e20, 3000);
        _attachRoutes(pool, unit, list[1], _routes(key), 1e15, 0);
        vm.mockCallRevert(
            address(balancer.sizer()), abi.encodeWithSelector(IndexSizer.size.selector), ""
        );
        IndexToken(list[1]).approve(address(pool), type(uint256).max);
        vm.recordLogs();
        _swap(pool, list[1], list[0], 1e17, true);
        (uint256 stood, uint256 asides) = _balancedAt();
        console.log("size that stood", stood);
        assertGt(stood, 0, "a smaller size stood");
        assertEq(asides, 0, "nothing set aside");
    }

    // ------------------------------------------------------------------ Low-2

    /// A token on a Metric venue that prices best and a v4 venue beside it.
    function _beside(address coin) internal returns (IndexPool pool, MockBinPool metric) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        metric = _metricVenue(coin, unit, 1.06e18, 2000e18, true);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(_venue(coin, unit, 1.04e18, DEEP, 3000))[0];
        both[1] = _metricRoutes(address(metric))[0];
        _attachRoutes(pool, unit, coin, both, 1e15, 0);
    }

    /// A Metric pool whose swap reverts with the bytes of the balancer's own `Lost` is
    /// Metric failing: it is dropped and the v4 venue closes the gap.
    function testAForgedLostIsMetricFailing() public {
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        (IndexPool pool, MockBinPool metric) = _beside(coin);
        metric.setRevertData(
            abi.encodeWithSelector(IndexBalancerState.Lost.selector, bytes32(0))
        );
        IndexToken(unit).approve(address(pool), type(uint256).max);
        vm.recordLogs();
        _swap(pool, unit, coin, 1e18, true);
        (uint256 stood, uint256 asides) = _balancedAt();
        assertGt(stood, 0, "closed through v4");
        assertEq(asides, 0, "nothing set aside");
    }

    /// One that names another, honest Metric venue as the one refusing drops itself, and
    /// the honest venue closes the gap.
    function testAMetricPoolNamingAnotherDropsItself() public {
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool hostile = _metricVenue(coin, unit, 1.06e18, 2000e18, true);
        MockBinPool honest = _metricVenue(coin, unit, 1.04e18, 2000e18, true);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _metricRoutes(address(honest))[0];
        both[1] = _metricRoutes(address(hostile))[0];
        _attachRoutes(pool, unit, coin, both, 1e15, 0);
        hostile.setRevertData(
            abi.encodeWithSelector(IndexBalancerState.MetricFailed.selector, address(honest))
        );
        vm.recordLogs();
        assertGt(
            balancer.balance(address(pool), coin, unit), 0, "closed through the honest one"
        );
    }

    // ------------------------------------------------------------------ gaps

    /// A balancer given a settings module built for another reader, or another factory, is
    /// refused.
    function testWrongModuleIsRefused() public {
        IndexMetric metric = new IndexMetric(IMetricFactory(address(metricFactory)));
        IndexMetric other = new IndexMetric(IMetricFactory(address(metricFactory)));
        IndexSettings settings_ = new IndexSettings(manager, factory, other);
        vm.expectRevert(IndexBalancerState.WrongModule.selector);
        new IndexBalancer(manager, factory, metric, settings_);
        IndexPoolFactory another =
            new IndexPoolFactory(ISzrLiquidity(address(liquidity)), protocol);
        IndexSettings elsewhere = new IndexSettings(manager, another, metric);
        vm.expectRevert(IndexBalancerState.WrongModule.selector);
        new IndexBalancer(manager, factory, metric, elsewhere);
        IndexSettings ok = new IndexSettings(manager, factory, metric);
        assertGt(address(new IndexBalancer(manager, factory, metric, ok)).code.length, 0);
    }

    /// Announcing the unit, routes or limits again restarts the day's wait.
    function testReannouncingRestartsTheWait() public {
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        PoolKey memory key = _venue(coin, unit, 1.05e18, DEEP, 3000);
        settings.setUnit(address(pool), unit);
        settings.setRoutes(address(pool), coin, _routes(key));
        settings.setLimits(address(pool), 1e15, 0);
        uint256 first = block.timestamp + 1 days;
        vm.warp(block.timestamp + 12 hours);
        settings.setUnit(address(pool), unit);
        settings.setRoutes(address(pool), coin, _routes(key));
        settings.setLimits(address(pool), 2e15, 0);
        vm.warp(first);
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), address(pool));
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), coin);
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), address(0));
        vm.warp(first + 12 hours);
        settings.applyChange(address(pool), address(pool));
        settings.applyChange(address(pool), coin);
        settings.applyChange(address(pool), address(0));
        (uint128 gapLimit,) = settings.limitsOf(address(pool));
        assertEq(gapLimit, 2e15, "the later announcement");
    }

    /// Metric for both, the second Metric venue refusing: the inner refusal is passed on
    /// as that venue's, it is dropped, and the cycle falls back to the v4 venue of the
    /// second token.
    function testASecondMetricVenueRefusingFallsBack() public {
        address[] memory list = _two(18, 18);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool first = _metricVenue(list[0], unit, 1.05e18, 2000e18, true);
        _attachRoutes(pool, unit, list[0], _metricRoutes(address(first)), 1e15, 0);
        MockBinPool second = _metricVenue(list[1], unit, 0.99e18, 2000e18, true);
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(_venue(list[1], unit, 1e18, DEEP, 3000))[0];
        both[1] = _metricRoutes(address(second))[0];
        _attachRoutes(pool, unit, list[1], both, 1e15, 0);
        (Cycle memory cycle,) = balancer.plan(address(pool), list[0], list[1]);
        assertEq(cycle.buyPool, address(second), "Metric for both");
        second.setSwitches(0, false, true, false);
        vm.recordLogs();
        assertGt(balancer.balance(address(pool), list[0], list[1]), 0, "closed through v4");
    }
}
