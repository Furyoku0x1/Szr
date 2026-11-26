// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexMetric } from "../src/index/IndexMetric.sol";
import { MetricPricer } from "../src/pricers/MetricPricer.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";
import { MockWrapper } from "./MetricPricer.t.sol";

/// @dev Metric routes: accepted and refused when set and when applied, and read exactly as
/// `MetricPricer` reads a pool bound to `MetricVenueHook`.
contract IndexBalancerMetricRoutesTest is BalancerWorld {
    using PoolIdLibrary for PoolKey;

    address internal token;
    address internal unit;
    IndexPool internal pool;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
    }

    // ------------------------------------------------------------------ routes

    function testMetricRoutesAreCheckedWhenSetAndWhenApplied() public {
        settings.setUnit(address(pool), unit);
        MockBinPool good = _metricVenue(token, unit, 1e18, 2000e18, false);
        MockBinPool stray = _metricVenue(token, unit, 1e18, 2000e18, true);
        metricFactory.deregister(address(stray));
        vm.expectRevert(IndexMetric.NotMetricPool.selector);
        settings.setRoutes(address(pool), token, _metricRoutes(address(stray)));
        address other = address(new IndexToken(18));
        MockBinPool wrong = _metricVenue(other, unit, 1e18, 2000e18, true);
        vm.expectRevert(IndexMetric.WrongPair.selector);
        settings.setRoutes(address(pool), token, _metricRoutes(address(wrong)));
        // Either token order is accepted, beside a v4 venue, up to three in all.
        MockBinPool flipped = _metricVenue(token, unit, 1e18, 2000e18, true);
        IndexBalancerState.Route[] memory three = new IndexBalancerState.Route[](3);
        three[0] = _metricRoutes(address(good))[0];
        three[1] = _metricRoutes(address(flipped))[0];
        three[2] = _routes(_venue(token, unit, 1e18, DEEP, 3000))[0];
        settings.setRoutes(address(pool), token, three);
        _apply(pool, token);
        IndexBalancerState.Route[] memory live = settings.routesOf(address(pool), token);
        assertEq(live.length, 3, "all three");
        assertTrue(live[0].metric, "kept as Metric");
        assertEq(live[0].pool, address(good), "its pool");
        assertFalse(live[2].metric, "and the v4 one");
        // A later setting is checked again when it is applied.
        settings.setRoutes(address(pool), token, _metricRoutes(address(flipped)));
        metricFactory.deregister(address(flipped));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(IndexMetric.NotMetricPool.selector);
        settings.applyChange(address(pool), token);
    }

    // ------------------------------------------------------------------ reading

    /// The reader gives exactly `MetricPricer`'s answer for the same pool, in both token
    /// orders and with 6 and 18 decimals.
    function testReadingIsMetricPricers() public {
        MockWrapper wrapper = new MockWrapper();
        MetricPricer pricer = new MetricPricer(MetricVenueHook(payable(address(wrapper))));
        for (uint256 run; run < 4; run++) {
            address coin = address(new IndexToken(run < 2 ? 6 : 18));
            _readyToken(coin);
            MockBinPool venue = _metricVenue(coin, unit, 1.7e18, 500e18, run % 2 == 0);
            (address low, address high) = coin < unit ? (coin, unit) : (unit, coin);
            PoolKey memory key =
                PoolKey(Currency.wrap(low), Currency.wrap(high), 0, 1, IHooks(address(1)));
            wrapper.bind(
                key.toId(),
                MockWrapper.Binding(
                    address(venue),
                    venue.token0() != low,
                    false,
                    uint128(venue.scale0()),
                    uint128(venue.scale1())
                )
            );
            uint256[5] memory read = balancer.metric().read(address(venue), low);
            (uint160 root, uint24 fee, uint128 units, uint160 lower, uint160 upper) =
                pricer.price(key);
            assertEq(read[0], root, "price");
            assertEq(read[1], fee, "fee");
            assertEq(read[2], units, "liquidity");
            assertEq(read[3], lower, "lower");
            assertEq(read[4], upper, "upper");
        }
    }
}
