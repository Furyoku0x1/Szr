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

/// @dev The rest of the sizing table (S9, S10), in a file of its own because the first
/// was at the test size limit.
abstract contract SizingScenariosTail is SizingWorld {
    /// How far a wrapped venue's short range holds, in parts per million of its price.
    uint256 internal constant REACH = 3_000;

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

/// @dev At the tiny minimum profit.
contract ArbitrageSizingTailTest is SizingScenariosTail { }
