// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { Vm } from "forge-std/Vm.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";

/// @dev The walk's size against the best size found by real quotes, and setting aside.
contract IndexBalancerSizingTest is BalancerWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Venue depth comparable to the pool's, so that its price impact matters to the size.
    uint128 internal constant LEVEL = 1e21;
    /// At equal weights the index leg is exact, so the walk is held to the reference within
    /// these shares (WAD) of the best size and of the best profit: 0.001% and 0.0001%. With a
    /// 6-decimal token the cycle's input or output is counted in millionths of a token, so
    /// the profit is flat near its top and many sizes earn the same: the size is held to
    /// 0.5% and the profit to 0.001%. Measured: 18/18 within 1.6e-6 of the size; 6/18
    /// within 1.1e-3 of the size at exactly the best profit.
    uint256 internal constant SIZE_MARGIN = 1e13;
    uint256 internal constant PROFIT_MARGIN = 1e12;
    uint256 internal constant MIXED_SIZE_MARGIN = 5e15;
    uint256 internal constant MIXED_PROFIT_MARGIN = 1e13;

    function _pairPool(uint8 places, uint256 weight, uint256 amount, uint256 unitAmount)
        internal
        returns (IndexPool pool, address token, address unit)
    {
        address[] memory list = _two(places, 18);
        // The 18-decimal one of a mixed pair is the unit.
        bool firstIsToken = IndexToken(list[0]).decimals() == places;
        if (places == 18) firstIsToken = true;
        (token, unit) = firstIsToken ? (list[0], list[1]) : (list[1], list[0]);
        uint256[] memory weights =
            firstIsToken ? _weights(weight, 1e18 - weight) : _weights(1e18 - weight, weight);
        uint256[] memory amounts =
            firstIsToken ? _amounts(amount, unitAmount) : _amounts(unitAmount, amount);
        pool = _hooked(list, weights, amounts);
    }

    /// Compares the walk with the reference and returns both sizes and profits.
    function _compare(IndexPool pool, address tokenA, address tokenB)
        internal
        returns (uint256 walked, uint256 best, uint256 walkedProfit, uint256 bestProfit)
    {
        (Cycle memory cycle, uint256 width) = balancer.plan(address(pool), tokenA, tokenB);
        assertGt(width, 0, "a gap");
        walked = balancer.sizer().size(cycle);
        (best, bestProfit) = _reference(pool, cycle, balancer.mostTaken(cycle));
        walkedProfit = _cycleProfit(pool, cycle, walked);
        console.log("walk size", walked);
        console.log("best size", best);
        console.log("walk profit", walkedProfit);
        console.log("best profit", bestProfit);
    }

    function _assertExact(uint256 walked, uint256 best, uint256 got, uint256 most)
        internal
        pure
    {
        assertApproxEqRel(walked, best, SIZE_MARGIN, "size");
        assertApproxEqRel(got, most, PROFIT_MARGIN, "profit");
    }

    function _assertMixed(uint256 walked, uint256 best, uint256 got, uint256 most)
        internal
        pure
    {
        assertApproxEqRel(walked, best, MIXED_SIZE_MARGIN, "size");
        assertApproxEqRel(got, most, MIXED_PROFIT_MARGIN, "profit");
    }

    function testEqualWeightsOneVenueMatchesTheReference() public {
        (IndexPool pool, address token, address unit) = _pairPool(18, 5e17, 1000e18, 1000e18);
        PoolKey memory venue = _venue(token, unit, 1.05e18, LEVEL, 3000);
        _attach(pool, unit, token, venue, 0, 0);
        (uint256 walked, uint256 best, uint256 got, uint256 most) = _compare(pool, token, unit);
        _assertExact(walked, best, got, most);
    }

    function testEqualWeightsTwoVenuesMatchesTheReference() public {
        address[] memory list = _two(18, 18);
        address unit = address(new IndexToken(18));
        _readyToken(unit);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        _attach(pool, unit, list[0], _venue(list[0], unit, 1.05e18, LEVEL, 3000), 0, 0);
        _attach(pool, unit, list[1], _venue(list[1], unit, 1e18, LEVEL, 500), 0, 0);
        (uint256 walked, uint256 best, uint256 got, uint256 most) =
            _compare(pool, list[0], list[1]);
        _assertExact(walked, best, got, most);
    }

    /// The venue has a band of extra liquidity between its price and where the cycle
    /// leaves it, so the walk crosses two initialised ticks.
    function testEqualWeightsAcrossATickBoundaryMatchesTheReference() public {
        (IndexPool pool, address token, address unit) = _pairPool(18, 5e17, 1000e18, 1000e18);
        PoolKey memory venue = _venue(token, unit, 1.05e18, LEVEL, 3000);
        (, int24 tick,,) = manager.getSlot0(venue.toId());
        int24 low = tick > 0 ? int24(300) : int24(-480);
        provider.modifyLiquidity(
            venue,
            IPoolManager.ModifyLiquidityParams(low, low + 180, int256(uint256(3e21)), 0),
            ""
        );
        _attach(pool, unit, token, venue, 0, 0);
        (uint256 walked, uint256 best, uint256 got, uint256 most) = _compare(pool, token, unit);
        _assertExact(walked, best, got, most);
        balancer.balance(address(pool), token, unit);
        // The cycle moved the venue's price into the band, across its first tick.
        (, int24 after_,,) = manager.getSlot0(venue.toId());
        if (tick > 0) assertLt(after_, low + 180, "crossed into the band");
        if (tick < 0) assertGt(after_, low, "crossed into the band");
        _assertClean(pool);
    }

    /// A 6-decimal token against an 18-decimal unit is sized as well as an 18/18 pair.
    function testSixAndEighteenDecimalsMatchesTheReference() public {
        (IndexPool pool, address token, address unit) = _pairPool(6, 5e17, 1000e6, 1000e18);
        PoolKey memory venue = _venue(token, unit, 1.05e30, LEVEL, 3000);
        _attach(pool, unit, token, venue, 0, 0);
        (uint256 walked, uint256 best, uint256 got, uint256 most) = _compare(pool, token, unit);
        _assertMixed(walked, best, got, most);
        // And the other way, the token dear in the pool.
        (pool, token, unit) = _pairPool(6, 5e17, 1000e6, 1000e18);
        venue = _venue(token, unit, 0.95e30, LEVEL, 3000);
        _attach(pool, unit, token, venue, 0, 0);
        (walked, best, got, most) = _compare(pool, unit, token);
        _assertMixed(walked, best, got, most);
    }

    /// At 80/20 the index leg is an approximation near the current price: the walk's size
    /// is recorded against the best, and the balancer still earns.
    function testEightyTwentyIsRecordedAndEarns() public {
        _unequal(8e17, 4000e18, 1000e18);
    }

    function testNinetyNineToOneIsRecordedAndEarns() public {
        _unequal(99e16, 99_000e18, 1000e18);
    }

    /// The input of the cycle that stood, from the balancer's event.
    function _stood() internal returns (uint256 spend) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != IndexBalancer.Balanced.selector) continue;
            (spend,) = abi.decode(logs[index].data, (uint256, uint256));
        }
    }

    /// Each side heavy and light, at a 5% gap against a venue of the pool's depth and at a
    /// 20% gap against a deep one, where the index pool sets the size.
    function _unequal(uint256 weight, uint256 amount, uint256 unitAmount) internal {
        for (uint256 run; run < 4; run++) {
            bool heavy = run % 2 == 0;
            bool wide = run > 1;
            // The token is the heavy side or the light one, at a price of 1.
            (IndexPool pool, address token, address unit) = heavy
                ? _pairPool(18, weight, amount, unitAmount)
                : _pairPool(18, 1e18 - weight, unitAmount, amount);
            uint256 price = _poolPrice(pool, token, unit) * (wide ? 120 : 105) / 100;
            PoolKey memory venue = _venue(token, unit, price, wide ? DEEP : LEVEL, 3000);
            _attach(pool, unit, token, venue, 0, 0);
            console.log(heavy ? "heavy token cheap, gap %" : "light token cheap, gap %");
            console.log(wide ? 20 : 5);
            (uint256 walked, uint256 best, uint256 got, uint256 most) =
                _compare(pool, token, unit);
            console.log("walk / best size (WAD)", walked * 1e18 / best);
            console.log("walk / best profit (WAD)", got * 1e18 / most);
            // A smaller try earns too: the eighth of the whole gap, the last size tried.
            (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
            uint256 eighth = balancer.whole(cycle) / 8;
            uint256 small = _cycleProfit(pool, cycle, eighth);
            console.log("profit at an eighth of the whole gap", small);
            assertGt(small, 0, "the smallest size earns");
            vm.recordLogs();
            assertGt(balancer.balance(address(pool), token, unit), 0, "earns");
            console.log("size that stood", _stood());
            _assertClean(pool);
        }
    }
}
