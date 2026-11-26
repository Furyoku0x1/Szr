// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev Every cycle shape with a Metric venue, in both directions, each sized against the
/// best size found by real quotes, then run: the profit is in the token taken out of the
/// pool and donated, and nothing is left anywhere.
contract IndexBalancerMetricShapesTest is BalancerWorld {
    /// Metric legs are read and filled as the same one-range model, so the walk is held to
    /// 0.001% of the best size and 0.0001% of the best profit. Measured: within 1.1e-6.
    uint256 internal constant SIZE_MARGIN = 1e13;
    uint256 internal constant PROFIT_MARGIN = 1e12;
    /// Venues about as deep as the index pool, so their price impact sets the size.
    uint104 internal constant RESERVE = 2000e18;
    uint128 internal constant LEVEL = 1e21;

    address internal unit;

    function setUp() public override {
        super.setUp();
        unit = address(new IndexToken(18));
        _readyToken(unit);
    }

    /// Sizes the pair's cycle against the reference, runs it, and checks where it went.
    function _check(IndexPool pool, address tokenA, address tokenB, address take)
        internal
        returns (Cycle memory cycle)
    {
        uint256 width;
        (cycle, width) = balancer.plan(address(pool), tokenA, tokenB);
        assertGt(width, 0, "a gap");
        assertEq(cycle.take, take, "the cheap token");
        uint256 walked = balancer.sizer().size(cycle);
        (uint256 best, uint256 most) = _reference(pool, cycle, balancer.mostTaken(cycle));
        uint256 got = _cycleProfit(pool, cycle, walked);
        console.log("walk size, best size", walked, best);
        console.log("walk profit, best profit", got, most);
        assertApproxEqRel(walked, best, SIZE_MARGIN, "size");
        assertApproxEqRel(got, most, PROFIT_MARGIN, "profit");
        vm.recordLogs();
        uint256 profit = balancer.balance(address(pool), tokenA, tokenB);
        assertGt(profit, 0, "balanced");
        assertEq(pool.owed(take), profit * 3000 / 10_000, "donated in the token taken out");
        assertEq(_assertInvariants(pool), 1, "one swap");
    }

    function _withUnit(uint256 price, bool tokenFirst)
        internal
        returns (IndexPool pool, address token)
    {
        token = address(new IndexToken(18));
        _readyToken(token);
        address[] memory list = new address[](2);
        (list[0], list[1]) = token < unit ? (token, unit) : (unit, token);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool venue = _metricVenue(token, unit, price, RESERVE, tokenFirst);
        _attachRoutes(pool, unit, token, _metricRoutes(address(venue)), 1e15, 0);
    }

    /// One trade, on Metric, with no pool manager at all: the token cheap, then dear, with
    /// the token as Metric's token0 and as its token1.
    function testMetricAloneWithTheUnit() public {
        for (uint256 run; run < 4; run++) {
            bool cheap = run % 2 == 0;
            (IndexPool pool, address token) = _withUnit(cheap ? 1.05e18 : 0.95e18, run < 2);
            _check(pool, token, unit, cheap ? token : unit);
        }
    }

    /// A 6-decimal token against the 18-decimal unit on Metric, in both token orders and
    /// both directions. The 6-decimal side counts in millionths, so the profit is flat near
    /// its top: the size is held to 0.5%.
    function testSixDecimalTokenOnMetric() public {
        for (uint256 run; run < 4; run++) {
            bool cheap = run % 2 == 0;
            address coin = address(new IndexToken(6));
            _readyToken(coin);
            address[] memory list = new address[](2);
            (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
            uint256[] memory amounts =
                coin < unit ? _amounts(1000e6, 1000e18) : _amounts(1000e18, 1000e6);
            IndexPool pool = _hooked(list, _equal(2), amounts);
            MockBinPool venue =
                _metricVenue(coin, unit, cheap ? 1.05e18 : 0.95e18, RESERVE, run < 2);
            _attachRoutes(pool, unit, coin, _metricRoutes(address(venue)), 1e15, 0);
            (Cycle memory cycle,) = balancer.plan(address(pool), coin, unit);
            uint256 walked = balancer.sizer().size(cycle);
            (uint256 best, uint256 most) = _reference(pool, cycle, balancer.mostTaken(cycle));
            uint256 got = _cycleProfit(pool, cycle, walked);
            console.log("6 decimals: walk size, best size", walked, best);
            assertApproxEqRel(walked, best, 5e15, "size");
            assertApproxEqRel(got, most, 1e13, "profit");
            vm.recordLogs();
            assertGt(balancer.balance(address(pool), coin, unit), 0, "balanced");
            _assertInvariants(pool);
        }
    }

    /// A pool of two tokens neither of which is the unit, each with one venue of the kind
    /// given, the first token's at `price`.
    function _withoutUnit(bool firstOnMetric, bool secondOnMetric, uint256 price)
        internal
        returns (IndexPool pool, address first, address second)
    {
        address[] memory list = _two(18, 18);
        (first, second) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        _venueFor(pool, first, firstOnMetric, price);
        _venueFor(pool, second, secondOnMetric, 1e18);
    }

    function _venueFor(IndexPool pool, address token, bool onMetric, uint256 price) internal {
        IndexBalancerState.Route[] memory routes;
        if (onMetric) {
            routes = _metricRoutes(address(_metricVenue(token, unit, price, RESERVE, true)));
        } else {
            routes = _routes(_venue(token, unit, price, LEVEL, 3000));
        }
        _attachRoutes(pool, unit, token, routes, 1e15, 0);
    }

    /// Metric first, v4 second, run reordered: the units are sold for the second token on v4
    /// first, the index pool is traded, and only then are exactly those units bought from
    /// Metric with the first token, outside any Metric callback of the balancer's own work.
    function testMetricFirstThenUniswap() public {
        (IndexPool pool, address first, address second) = _withoutUnit(true, false, 1.05e18);
        _check(pool, first, second, first);
        (pool, first, second) = _withoutUnit(false, true, 0.95e18);
        _check(pool, first, second, second);
    }

    /// v4 first, Metric second.
    function testUniswapFirstThenMetric() public {
        (IndexPool pool, address first, address second) = _withoutUnit(false, true, 1.05e18);
        _check(pool, first, second, first);
        (pool, first, second) = _withoutUnit(true, false, 0.95e18);
        _check(pool, first, second, second);
    }

    /// Metric for both trades: no pool manager at all.
    function testMetricForBoth() public {
        (IndexPool pool, address first, address second) = _withoutUnit(true, true, 1.05e18);
        _check(pool, first, second, first);
        (pool, first, second) = _withoutUnit(true, true, 0.95e18);
        _check(pool, first, second, second);
    }
}
