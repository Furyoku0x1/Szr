// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexMetric } from "../src/index/IndexMetric.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";

/// @dev The creator's settings: everything at once before the pool has started and a day
/// after announcement once it has, the unit once, removal at once, the venue checks, and the
/// gap never below the pool's own fee.
contract IndexBalancerSettingsTest is BalancerWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal token;
    address internal unit;
    IndexPool internal pool;
    PoolKey internal venue;
    PoolKey internal second;
    IndexPool internal fresh;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        venue = _venue(token, unit, 1.05e18, DEEP, 3000);
        second = _venue(token, unit, 1.05e18, DEEP, 500);
        // The same tokens in a pool that has not started yet.
        fresh = _create(list, _equal(2), FEE, address(balancer), HOOK_GAS);
        IndexToken(token).approve(address(fresh), type(uint256).max);
        IndexToken(unit).approve(address(fresh), type(uint256).max);
    }

    function testOnlyTheCreatorSetsAnything() public {
        vm.startPrank(stranger);
        vm.expectRevert(IndexBalancerState.NotCreator.selector);
        settings.setUnit(address(pool), unit);
        vm.expectRevert(IndexBalancerState.NotCreator.selector);
        settings.setRoutes(address(pool), token, _routes(venue));
        vm.expectRevert(IndexBalancerState.NotCreator.selector);
        settings.setLimits(address(pool), 0, 0);
        vm.expectRevert(IndexBalancerState.NotCreator.selector);
        settings.removeRoute(address(pool), token, 0);
        vm.stopPrank();
        vm.expectRevert(IndexBalancerState.UnknownPool.selector);
        settings.setUnit(address(this), unit);
    }

    /// Before the pool has started every setting applies at once, again and again.
    function testBeforeStartEverythingAppliesAtOnce() public {
        vm.expectRevert(IndexBalancerState.UnitNotSet.selector);
        settings.setRoutes(address(fresh), token, _routes(venue));
        settings.setUnit(address(fresh), unit);
        assertEq(settings.unitOf(address(fresh)), unit, "unit at once");
        settings.setLimits(address(fresh), 1e15, 7);
        settings.setRoutes(address(fresh), token, _routes(venue));
        settings.setRoutes(address(fresh), token, _routes(second));
        settings.setLimits(address(fresh), 2e15, 9);
        IndexBalancerState.Route[] memory live = settings.routesOf(address(fresh), token);
        assertEq(live.length, 1, "routes at once");
        assertEq(live[0].venue.fee, 500, "the second setting, at once");
        (uint128 gapLimit, uint128 profitLimit) = settings.limitsOf(address(fresh));
        assertEq(gapLimit, 2e15, "limits at once");
        assertEq(profitLimit, 9, "limits at once");
        vm.expectRevert(IndexBalancerState.UnitAlreadySet.selector);
        settings.setUnit(address(fresh), token);
        fresh.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        vm.recordLogs();
        assertGt(balancer.balance(address(fresh), token, unit), 0, "balanced from the start");
        _assertInvariants(fresh);
    }

    /// Once the pool has started the unit waits a day too, is checked against by routes
    /// announced meanwhile, and once in effect never changes.
    function testUnitWaitsOnceStartedAndThenNeverChanges() public {
        vm.expectRevert(IndexBalancerState.UnitNotSet.selector);
        settings.setRoutes(address(pool), token, _routes(venue));
        vm.expectRevert(IndexBalancerState.ZeroAddress.selector);
        settings.setUnit(address(pool), address(0));
        settings.setUnit(address(pool), unit);
        assertEq(settings.unitOf(address(pool)), address(0), "waits");
        (address announced, uint256 readyAt) = settings.pendingUnit(address(pool));
        assertEq(announced, unit, "announced");
        assertEq(readyAt, block.timestamp + 1 days, "in a day");
        settings.setRoutes(address(pool), token, _routes(venue));
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), address(pool));
        vm.warp(block.timestamp + 1);
        // Routes cannot apply ahead of the unit they were checked against.
        vm.expectRevert(IndexBalancerState.UnitNotSet.selector);
        settings.applyChange(address(pool), token);
        vm.prank(stranger);
        settings.applyChange(address(pool), address(pool));
        settings.applyChange(address(pool), token);
        assertEq(settings.unitOf(address(pool)), unit, "applied");
        assertEq(settings.routesOf(address(pool), token).length, 1, "and the routes");
        vm.expectRevert(IndexBalancerState.UnitAlreadySet.selector);
        settings.setUnit(address(pool), token);
        vm.expectRevert(IndexBalancerState.NothingPending.selector);
        settings.applyChange(address(pool), address(pool));
    }

    /// Once the pool has started, every setting waits a day, a first one included, and only
    /// the announced values apply (M-1: no venues set months later in the same transaction
    /// as a trade).
    function testAfterStartEveryChangeWaitsADay() public {
        _attach(pool, unit, token, venue, 1e15, 7);
        vm.recordLogs();
        assertGt(balancer.balance(address(pool), token, unit), 0, "balances");
        assertEq(_assertInvariants(pool), 1, "one swap");
        IndexBalancerState.Route[] memory both = new IndexBalancerState.Route[](2);
        both[0] = _routes(venue)[0];
        both[1] = _routes(second)[0];
        settings.setRoutes(address(pool), token, both);
        settings.setLimits(address(pool), 2e15, 9);
        assertEq(settings.routesOf(address(pool), token).length, 1, "routes wait");
        (uint128 gapLimit, uint128 profitLimit) = settings.limitsOf(address(pool));
        assertEq(gapLimit, 1e15, "limits wait");
        (IndexBalancerState.Route[] memory announced, uint256 readyAt) =
            settings.pendingRoutes(address(pool), token);
        assertEq(announced.length, 2, "announced");
        assertEq(announced[1].venue.fee, 500, "announced venue");
        assertEq(readyAt, block.timestamp + 1 days, "ready in a day");
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), token);
        vm.expectRevert(IndexBalancerState.NotReady.selector);
        settings.applyChange(address(pool), address(0));
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        settings.applyChange(address(pool), token);
        vm.prank(stranger);
        settings.applyChange(address(pool), address(0));
        IndexBalancerState.Route[] memory live = settings.routesOf(address(pool), token);
        assertEq(live.length, 2, "applied");
        assertEq(live[1].venue.fee, 500, "the announced venue");
        (gapLimit, profitLimit) = settings.limitsOf(address(pool));
        assertEq(gapLimit, 2e15, "the announced limits");
        assertEq(profitLimit, 9, "the announced limits");
        vm.expectRevert(IndexBalancerState.NothingPending.selector);
        settings.applyChange(address(pool), token);
    }

    /// A first setting made once the pool has started waits like any other.
    function testFirstSettingsAfterStartWait() public {
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 0, 0);
        assertEq(settings.unitOf(address(pool)), address(0), "unit waits");
        assertEq(settings.limitsReadyAt(address(pool)), block.timestamp + 1 days, "limits wait");
        settings.setRoutes(address(pool), token, _routes(venue));
        assertEq(settings.routesOf(address(pool), token).length, 0, "routes wait");
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing in effect");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// Removing a route is immediate, and routes set again afterwards still wait a day.
    function testRemovalIsImmediateAndDoesNotResetTheWait() public {
        _attach(pool, unit, token, venue, 1e15, 0);
        settings.removeRoute(address(pool), token, 0);
        assertEq(settings.routesOf(address(pool), token).length, 0, "removed at once");
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "no venues, nothing done");
        assertEq(_assertInvariants(pool), 0, "no swap");
        vm.expectRevert(IndexBalancerState.InvalidIndex.selector);
        settings.removeRoute(address(pool), token, 0);
        settings.setRoutes(address(pool), token, _routes(venue));
        assertEq(settings.routesOf(address(pool), token).length, 0, "still waits");
        settings.setLimits(address(pool), 0, 0);
        (uint128 gapLimit,) = settings.limitsOf(address(pool));
        assertEq(gapLimit, 1e15, "limits set to zero still wait");
    }

    /// The gap acted on is never smaller than twice the pool's own swap fee (0.3%),
    /// whatever the minimum: a 0.45% gap through a 0.01% venue, over the fee but under twice
    /// it, is left; one over 0.6% is closed.
    function testGapNeverBelowTwiceThePoolsFee() public {
        settings.setUnit(address(fresh), unit);
        settings.setLimits(address(fresh), 0, 0);
        PoolKey memory cheap = _venue(token, unit, 1.0046e18, DEEP, 100);
        settings.setRoutes(address(fresh), token, _routes(cheap));
        fresh.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        (uint256 width,) = balancer.gap(address(fresh), token, unit);
        assertGt(width, fresh.swapFee(), "over the pool's fee");
        assertLt(width, 2 * fresh.swapFee(), "under twice it");
        vm.recordLogs();
        assertEq(balancer.balance(address(fresh), token, unit), 0, "left");
        assertEq(_assertInvariants(fresh), 0, "no swap");
        _push(cheap, unit, 400e18);
        (width,) = balancer.gap(address(fresh), token, unit);
        assertGt(width, 2 * fresh.swapFee(), "over twice the pool's fee");
        assertGt(balancer.balance(address(fresh), token, unit), 0, "closed");
    }

    /// A venue with a hook, of the wrong tokens, not yet initialised, or on Metric is refused;
    /// so are too many venues and tokens the pool does not hold.
    function testVenuesThatFailTheChecksAreRefused() public {
        pool = fresh;
        settings.setUnit(address(pool), unit);
        PoolKey memory hooked = venue;
        hooked.hooks = IHooks(address(0x1234));
        vm.expectRevert(IndexBalancerState.HookedVenue.selector);
        settings.setRoutes(address(pool), token, _routes(hooked));
        address stray = address(new IndexToken(18));
        PoolKey memory wrong = _venue(stray, unit, 1e18, 0, 3000);
        vm.expectRevert(IndexBalancerState.WrongPair.selector);
        settings.setRoutes(address(pool), token, _routes(wrong));
        PoolKey memory fresh = venue;
        fresh.fee = 10_000;
        fresh.tickSpacing = 200;
        vm.expectRevert(IndexBalancerState.NotInitialised.selector);
        settings.setRoutes(address(pool), token, _routes(fresh));
        IndexBalancerState.Route[] memory metric = _routes(venue);
        metric[0].metric = true;
        metric[0].pool = address(0xBEEF);
        vm.expectRevert(IndexMetric.NotMetricPool.selector);
        settings.setRoutes(address(pool), token, metric);
        IndexBalancerState.Route[] memory many = new IndexBalancerState.Route[](4);
        for (uint256 index; index < 4; index++) {
            many[index] = _routes(venue)[0];
        }
        vm.expectRevert(IndexBalancerState.TooManyVenues.selector);
        settings.setRoutes(address(pool), token, many);
        vm.expectRevert(IndexBalancerState.UnknownToken.selector);
        settings.setRoutes(address(pool), stray, _routes(wrong));
        vm.expectRevert(IndexBalancerState.UnknownToken.selector);
        settings.setRoutes(address(pool), unit, _routes(venue));
        // A refused setting leaves nothing behind; a good one before the start is immediate.
        assertEq(settings.routesOf(address(pool), token).length, 0, "nothing set");
        settings.setRoutes(address(pool), token, _routes(venue));
        assertEq(settings.routesOf(address(pool), token).length, 1, "set at once");
        assertEq(
            Currency.unwrap(settings.routesOf(address(pool), token)[0].venue.currency0),
            Currency.unwrap(venue.currency0),
            "stored as given"
        );
    }

    /// Limits too large to store are refused.
    function testLimitsTooLargeAreRefused() public {
        vm.expectRevert(IndexBalancerState.TooLarge.selector);
        settings.setLimits(address(pool), uint256(type(uint128).max) + 1, 0);
        vm.expectRevert(IndexBalancerState.TooLarge.selector);
        settings.setLimits(address(pool), 0, uint256(type(uint128).max) + 1);
    }

    /// The calls the balancer makes to itself and the pool manager's callback refuse anyone
    /// else.
    function testInternalEntryPointsRefuseOutsiders() public {
        _attach(pool, unit, token, venue, 1e15, 0);
        vm.expectRevert(IndexBalancerState.NotSelf.selector);
        balancer.run(address(pool), token, unit, 1, address(this));
        vm.expectRevert(IndexBalancerState.NotPoolManager.selector);
        balancer.unlockCallback("");
        Cycle memory cycle;
        vm.expectRevert(IndexBalancerState.NotSelf.selector);
        balancer.attempt(cycle);
    }

    /// The review's walk-up (M-1), made adversarial: the creator's own fee-free venue, set
    /// before the start at the pool's price, is pushed each step to just over the gap in
    /// force (`FEE_FLOOR` times the pool's fee), and a keeper call follows, until the venue
    /// reaches the market at 1.05. The last gap, under the floor, is traded by nobody, so the
    /// walk-up is compared with a fee-paying swap to the same end price: the pool is given no
    /// less than that swap's fee.
    function testWalkUpGivesThePoolNoLessThanItsFee() public {
        settings.setUnit(address(fresh), unit);
        settings.setLimits(address(fresh), 0, 0);
        PoolKey memory own = _venue(token, unit, 1e18, DEEP, 0);
        settings.setRoutes(address(fresh), token, _routes(own));
        fresh.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        uint256 snapshot = vm.snapshotState();
        uint256 floor = fresh.swapFee() * balancer.FEE_FLOOR() / 1e18;
        uint256 steps;
        while (_venuePrice(own, token) < 1.05e18) {
            uint256 target = _poolPrice(fresh, token, unit) * (1e18 + floor) / 1e18;
            target = target * (1e18 + 1e12) / 1e18;
            if (target > 1.05e18) target = 1.05e18;
            if (!_pushExact(own, target)) break;
            balancer.balance(address(fresh), token, unit);
            steps++;
            if (steps == 400) break;
        }
        uint256 given = _given(fresh);
        uint256 end = _poolPrice(fresh, token, unit);
        vm.revertToState(snapshot);
        uint256 fee = _feeToReach(end);
        console.log("steps", steps);
        console.log("pool price at the end of the walk-up (WAD)", end);
        console.log("fee a swap to that price pays (units)", fee);
        console.log("given to the pool by the walk-up (units at 1.05)", given);
        console.log("given / fee (WAD)", given * 1e18 / fee);
        assertGe(given, fee, "no less than the fee");
    }

    /// The fee a fee-paying swap pays to take the equal-weight pool from its start to `price`
    /// units per token. The amount is computed: the units in, net of the fee, that leave the
    /// pool's product unchanged at that price, `sqrt(price * bUnit * bToken) - bUnit`.
    function _feeToReach(uint256 price) internal returns (uint256) {
        uint256[] memory held = fresh.balances();
        (uint256 tokenHeld, uint256 unitHeld) =
            token < unit ? (held[0], held[1]) : (held[1], held[0]);
        uint256 after_ = FixedPointMathLib.sqrt(price * unitHeld / 1e18 * tokenHeld);
        uint256 net = after_ - unitHeld;
        uint256 gross = FixedPointMathLib.fullMulDivUp(net, 1e18, 1e18 - fresh.swapFee());
        (uint256 paidIn,) = _swap(fresh, unit, token, gross, true);
        return paidIn * fresh.swapFee() / 1e18;
    }

    /// Buys the token on `key` up to exactly `target` units per token.
    /// False if the venue is already there.
    function _pushExact(PoolKey memory key, uint256 target) internal returns (bool) {
        bool tokenFirst = Currency.unwrap(key.currency0) == token;
        uint256 ratio = tokenFirst ? target : 1e36 / target;
        uint160 limit = uint160(
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(ratio, 1 << 192, 1e18))
        );
        bool zeroForOne = !tokenFirst;
        (uint160 now_,,,) = manager.getSlot0(key.toId());
        if (zeroForOne ? limit >= now_ : limit <= now_) return false;
        swapper.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, -int256(1e30), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        return true;
    }

    /// Everything donated to the pool, the protocol's share included, in units at 1.05.
    function _given(IndexPool target) internal view returns (uint256) {
        uint256 tokens = target.owed(token) + target.unreleased(token);
        uint256 units = target.owed(unit) + target.unreleased(unit);
        return units + tokens * 105 / 100;
    }
}
