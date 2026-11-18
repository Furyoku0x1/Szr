// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPricer } from "./utils/WrappedPool.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev The baseline for exact cycle sizing (`docs/specs/hook-exact-sizing.md`): how today's
/// first-try estimate and fallback sizes do against the best cycle found independently, and
/// what a swap costs. Each test builds a scenario with the market off, opens a gap, runs the
/// hook with the market on and logs one row. Nothing here fixes a threshold yet. In every
/// scenario but S7, SZR is made cheap in the focus pool and the other pools are at one.
abstract contract SizingScenarios is SizingWorld {
    /// How far a wrapped venue's short range holds, in parts per million of its price.
    uint256 internal constant REACH = 3_000;

    function testS0Constants() public {
        _on();
        _trade(usdPool, address(szr), 1e18);
        _cool();
        uint256 spent = gasleft();
        _trade(usdPool, address(szr), 1e15);
        spent -= gasleft();
        console.log("S0 no-gap swap gas (cooled)", spent);
        console.log("S0 minimumGasLimit(1)", hook.minimumGasLimit(1));
        console.log("S0 gasForSwap(1)", hook.gasForSwap(1));
    }

    /// The acceptance line of `docs/specs/hook-exact-sizing.md` for rows the walk should
    /// size: the first try fills, and its profit is within half a percent of the best
    /// cycle found independently. Checked at the tiny minimum profit only, where every
    /// profitable cycle counts.
    function _accept(Result memory result) internal view {
        if (minProfit != MIN_PROFIT) return;
        assertFalse(result.firstTryFailed, "the first try succeeded");
        assertGt(result.cycles, 0, "and earned");
        assertGe(result.first * 1000, result.optimum * 995, "within 0.5% of the optimum");
    }

    // ----- S1, S2: one range each -----

    function testS1HalfPercentGap() public {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, 5_000);
        _accept(_measure(_direct("S1   two pools, 0.5% gap", venue, usdPool)));
    }

    function testS2TenPercentGap() public {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, 100_000);
        _accept(_measure(_direct("S2   two pools, 10% gap", venue, usdPool)));
    }

    // ----- S3: the cycle crosses initialised ticks of real liquidity -----

    /// Ranges of the pool's own depth, one per tick crossed, in the focus pool.
    function _crossFocus(string memory name, uint256 count, uint256 gap) internal {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        int24 dir = _push(usdPool, address(usd));
        int24 base = _bands(usdPool, dir, _alternating(count, poolUnits, poolUnits * 2));
        Spec memory spec = _direct(name, venue, usdPool);
        _expect(spec, usdPool, dir, base, count);
        _accept(_measure(spec));
    }

    function testS3aOneTickInTheFocusPool() public {
        _crossFocus("S3a1 focus, 1 tick, 3% gap", 1, 30_000);
    }

    function testS3aThreeTicksInTheFocusPool() public {
        _crossFocus("S3a3 focus, 3 ticks, 6.5% gap", 3, 65_000);
    }

    function _crossVenue(string memory name, uint256 count, uint256 gap) internal {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        int24 dir = _push(venue, address(szr));
        int24 base = _bands(venue, dir, _alternating(count, poolUnits, poolUnits * 2));
        Spec memory spec = _direct(name, venue, usdPool);
        _expect(spec, venue, dir, base, count);
        _accept(_measure(spec));
    }

    function testS3bOneTickInTheVenue() public {
        _crossVenue("S3b1 venue, 1 tick, 3% gap", 1, 30_000);
    }

    function testS3bThreeTicksInTheVenue() public {
        _crossVenue("S3b3 venue, 3 ticks, 7% gap", 3, 70_000);
    }

    /// The venue is an SZR/EUR pool, reached from the SZR/USD pool through one connecting
    /// pool of USD and EUR. The ranges are in that connecting pool.
    function _crossLink(string memory name, uint256 count, uint256 gap) internal {
        TestAsset eur = new TestAsset();
        _approve(eur);
        PoolKey memory venue = _addHooked(address(eur), 500);
        PoolKey memory link = _pair(address(usd), address(eur), 3_000, address(0));
        manager.initialize(link, uint160(1 << 96));
        _provide(link, poolUnits);
        locker.registerRoute(link);
        hook.setConnector(1, link, true);
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        int24 dir = _push(link, address(eur));
        int24 base = _bands(link, dir, _alternating(count, poolUnits, poolUnits * 2));
        Spec memory spec;
        spec.name = name;
        spec.focus = usdPool;
        spec.path = _keys(venue, link, usdPool);
        spec.inputs = _tokens(address(szr), address(eur), address(usd));
        spec.ceiling = 1e24;
        _expect(spec, link, dir, base, count);
        _accept(_measure(spec));
    }

    function testS3cOneTickInAConnectingPool() public {
        _crossLink("S3c1 link, 1 tick, 5% gap", 1, 50_000);
    }

    function testS3cThreeTicksInAConnectingPool() public {
        _crossLink("S3c3 link, 3 ticks, 14% gap", 3, 140_000);
    }

    // ----- S5: dust at every tick -----

    function _dusty(string memory name, int24 count, uint256 gap)
        internal
        returns (Result memory)
    {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        _dust(usdPool, count);
        return _measure(_direct(name, venue, usdPool));
    }

    /// The walk stops at its cap of eight boundary events. Its gas is not asserted here: at
    /// the cap it needs more than `SIZING_GAS` allows (see `ArbitrageGasTest`), so it falls
    /// back to the estimate and the walk's gas comes out of the budget, not the stipend.
    function testS5aDustSixty() public {
        Result memory result = _dusty("S5a  dust 60 ranges each side, 12%", 60, 120_000);
        assertFalse(result.firstTryFailed, "the first try succeeded");
        assertEq(result.walkSteps, 8, "the walk stopped at its cap");
    }

    function testS5bDustOneHundredFifty() public {
        Result memory result = _dusty("S5b  dust 150 ranges each side, 12%", 150, 120_000);
        assertEq(result.walkSteps, 8, "the walk stopped at its cap");
    }

    /// The same row as S5c with the walk on, for the table.
    function testS5cWithTheWalk() public {
        Result memory result =
            _dusty("S5c' dust 60 ranges each side, 20%, walk on", 60, 200_000);
        assertEq(result.walkSteps, 8, "the walk stopped at its cap");
    }

    /// A gap so wide that one try uses up its whole stipend crossing the dust. The walk is
    /// switched off, since its size could keep the first try inside its stipend; this pins
    /// what the hook does when a try at the estimate's size runs out of gas.
    function testS5cDustSixtyWideGap() public {
        _declineSizing();
        Result memory result = _dusty("S5c  dust 60 ranges each side, 20%", 60, 200_000);
        _assertRanOutThenEighth(result);
        // The eighth earns, so the pair is not benched for a failed cycle.
        assertGt(result.total, 0, "the smallest size earned");
        ArbitrageLogic.Plan memory plan = result.plans[0];
        uint256 until =
            hook.benchedUntil(1, address(szr), _id(usdPool), plan.venue, plan.buying);
        assertEq(until, 0, "and the pair was not benched");
    }

    /// The first try ran out of gas inside a nested call, which leaves a little of its
    /// stipend unspent, and the hook noticed: it logged `TryRanOut` once and went straight
    /// to an eighth of the whole size.
    function _assertRanOutThenEighth(Result memory result) internal pure {
        assertEq(result.ranOut, 1, "the try that ran out of gas was noticed, once");
        assertGe(result.tries, 2, "another try followed");
        if (result.tries < 2) return;
        ArbitrageLogic.Plan memory next = result.plans[1];
        uint256 eighth = next.fullSpend;
        for (uint256 halving; halving < 3; halving++) {
            eighth = eighth / 2 + 1;
        }
        assertEq(next.spend, eighth, "the try after it was the smallest size");
        assertLt(
            next.spend, result.plans[0].spend, "which is smaller than the one that ran out"
        );
    }

    // ----- S6: two connecting pools -----

    function testS6TwoHopRoute() public {
        TestAsset eur = new TestAsset();
        PoolKey memory venue = _addPartner(eur);
        _untrack(mainPool);
        _cheapen(usdPool, 20_000);
        Spec memory spec;
        spec.name = "S6   two connecting pools, 2%";
        spec.focus = usdPool;
        spec.path = _keys(
            venue,
            _pair(address(backing), address(eur), 3_000, address(0)),
            _pair(address(backing), address(usd), 3_000, address(0)),
            usdPool
        );
        spec.inputs = _tokens(address(szr), address(eur), address(backing), address(usd));
        spec.ceiling = 1e24;
        _accept(_measure(spec));
    }

    // ----- S7: SZR's main pool against Core redemption -----

    /// Raises NAV to 2.3% above the main pool's price, so Core pays more than the pool.
    function testS7CoreRedemption() public {
        _untrack(usdPool);
        uint160 root = _priceOf(mainPool);
        uint160 wethPerSzr = _szrFirst(mainPool) ? root : uint160(Q192 / root);
        uint256 price = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(wethPerSzr, wethPerSzr, Q96), 1e18, Q96
        );
        uint256 target = price * 1_023_000 / 1_000_000;
        uint256 extra = (target - core.NAV()) * core.activeSupply() / 1e18;
        backing.mint(address(this), extra);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(extra);
        Spec memory spec;
        spec.name = "S7   main pool vs Core, NAV 2.3% over";
        spec.focus = mainPool;
        spec.viaArb = true;
        Result memory result = _measure(spec);
        assertLt(result.left, 100, "the main pool is within an edge of NAV");
    }

    // ----- S8: a route through the wrap link -----

    function testS8WrapLink() public {
        _szrThroughEthPool();
        _cheapen(usdPool, 20_000);
        Spec memory spec;
        spec.name = "S8   route through the wrap link, 2%";
        spec.focus = usdPool;
        spec.path = _keys(
            mainPool, _wrapLeg(), _pair(address(usd), address(0), 3_000, address(0)), usdPool
        );
        spec.inputs = _tokens(address(szr), address(0), address(0), address(usd));
        spec.ceiling = 1e24;
        _accept(_measure(spec));
    }

    // ----- S9: a wrapped constant-product venue, by what its pricer says of its range -----

    /// A wrapped venue 7.5% dearer in SZR than the pools at one, against a focus pool whose
    /// path crosses three initialised ticks.
    function _wrappedSpec(string memory name) internal returns (Spec memory spec) {
        PoolKey memory venue = _wrappedVenue(75_000);
        _untrack(mainPool);
        int24 dir = _push(usdPool, address(usd));
        int24 base = _bands(usdPool, dir, _alternating(3, poolUnits, poolUnits * 2));
        spec = _direct(name, venue, usdPool);
        _expect(spec, usdPool, dir, base, 3);
    }

    /// The pricer reports one range over every price, as a v2-style venue's is, so the walk
    /// sizes the wrapped leg exactly.
    function testS9aWrappedVenueAgainstCrossedTicks() public {
        Spec memory spec = _wrappedSpec("S9a  wrapped v2 venue, focus 3 ticks, 7.5%");
        Result memory result = _measure(spec);
        assertTrue(result.sized, "the walk sized it");
        _accept(result);
    }

    /// The pricer cannot say how far its answer holds: the walk gives up and the estimate is
    /// used, with the profit it made before the walk could read a wrapped leg.
    function testS9bWrappedVenueWithNoRange() public {
        Spec memory spec = _wrappedSpec("S9b  wrapped venue, no range, 7.5%");
        WrappedPricer(wrappedPricer).arm(9);
        uint256 snapshot = vm.snapshotState();
        Result memory asked = _measure(spec);
        vm.revertToState(snapshot);
        _declineSizing();
        spec.name = "S9b  the same with the walk switched off";
        Result memory estimate = _measure(spec);
        assertFalse(asked.sized, "the estimate was used");
        assertEq(asked.first, estimate.first, "same first cycle");
        assertEq(asked.total, estimate.total, "same search");
        assertEq(asked.tries, estimate.tries, "same tries");
    }

    /// The pricer's range ends short of the optimum: the first try fills, and the wrapped leg
    /// stops at the end of the range, as far as its price may go.
    function testS9cWrappedVenueWithAShortRange() public {
        Spec memory spec = _wrappedSpec("S9c  wrapped venue, short range, 7.5%");
        WrappedPricer pricer = WrappedPricer(wrappedPricer);
        pricer.arm(10);
        pricer.setReach(REACH);
        (uint160 start,,,,) = pricer.price(spec.path[0]);
        uint256 snapshot = vm.snapshotState();
        Result memory result = _measure(spec);
        vm.revertToState(snapshot);
        assertTrue(result.sized, "the walk sized it");
        assertFalse(result.firstTryFailed, "the first try filled");
        ArbitrageLogic.Plan[] memory first = new ArbitrageLogic.Plan[](1);
        first[0] = result.plans[0];
        (, bytes4[] memory reasons) = _retry(_id(spec.focus), first);
        assertEq(reasons[0], bytes4(0), "and earned");
        (uint160 end,,,,) = pricer.price(spec.path[0]);
        uint256 moved = end < start ? start - end : end - start;
        // A constant-product pool keeps its fees in its reserves, so it ends a few parts in a
        // million of its price beyond where the range's own arithmetic stops.
        uint256 reach = uint256(start) * REACH / 1e6;
        assertApproxEqRel(moved, reach, 5e15, "stopped at the range's end");
    }

    // ----- S10: pairs far from a price of one -----

    /// The square-root price, token1 per token0, of SZR worth `num / den` of `partner`.
    function _rawPrice(address partner, uint256 num, uint256 den)
        internal
        view
        returns (uint160)
    {
        bool szrFirst = address(szr) < partner;
        return uint160(
            FixedPointMathLib.sqrt(
                FixedPointMathLib.fullMulDiv(szrFirst ? num : den, Q192, szrFirst ? den : num)
            )
        );
    }

    /// Two pools of SZR and a token that is raw `num / den` of SZR, with a million SZR in
    /// each, the focus pool 2% cheaper in SZR.
    function _odd(string memory name, uint256 num, uint256 den) internal {
        TestAsset coinX = new TestAsset();
        _approve(coinX);
        _untrack(mainPool);
        uint160 fair = _rawPrice(address(coinX), num, den);
        uint256 units = FixedPointMathLib.sqrt(1_000_000e18 * (1_000_000e18 * num / den));
        PoolKey memory venue = _register(address(coinX), 500, fair);
        bool szrFirst = address(szr) < address(coinX);
        PoolKey memory focus = _register(address(coinX), 3_000, _scaled(fair, 20_000, szrFirst));
        _provide(venue, units);
        _provide(focus, units);
        _accept(_measure(_direct(name, venue, focus)));
    }

    /// 18 and 6 decimals: a token of 0.65e-12 raw SZR.
    function testS10aSixDecimalPartner() public {
        _odd("S10a 18/6 decimals, 0.65e-12, 2%", 65, 1e14);
    }

    /// SZR worth 1e-9 of its partner.
    function testS10bCheapToken() public {
        _odd("S10b SZR worth 1e-9 of partner, 2%", 1, 1e9);
    }
}

/// @dev The table at the tiny minimum profit, where every profitable cycle counts.
contract ArbitrageSizingTest is SizingScenarios { }
