// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HoleWorld } from "./utils/HoleWorld.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The real book, ranking and ordering code with a stand-in and a real plan side by
/// side (docs/specs/hook-hole-edge.md): the real plan must win in a book and across books,
/// and only a book's start pool makes a stand-in.
contract ArbitrageHoleRankingTest is HoleWorld {
    /// A pool of SZR and WETH at tick `tick` with `units` of full-range liquidity.
    function _at(int24 tick, uint24 fee, uint256 units) internal returns (PoolKey memory pool) {
        pool = _register(address(backing), fee, TickMath.getSqrtPriceAtTick(tick));
        _provide(pool, units);
    }

    /// A smallest profit that the thin pool's own estimate misses against a gap of 5%, and
    /// a deep one's meets against 2%.
    function _gate() internal {
        _untrack(usdPool);
        hook.setLimits(1, address(szr), 8_000_000, 6e19, 1.0001e18);
    }

    function testAThinStartPoolMakesAStandIn() public {
        PoolKey memory thin = _at(1_000, 100, 1e22);
        _gate();
        ArbitrageLogic.Plan memory plan = _probeInHook().planFrom(_id(thin), address(backing));
        assertGt(plan.score, 0, "a plan");
        assertTrue(plan.standin, "made as if the thin pool were as deep as the rest");
    }

    function testARealPlanBeatsAStandInInTheSameBook() public {
        PoolKey memory thin = _at(1_000, 100, 1e22);
        PoolKey memory far = _at(5_000, 200, 1e22);
        _gate();
        ArbitrageLogic.Plan memory plan = _probeInHook().planFrom(_id(thin), address(backing));
        assertGt(plan.score, 0, "a plan");
        assertFalse(plan.standin, "the real plan wins, whatever the stand-in's score");
        assertEq(plan.venue, _id(far), "against the shallow pool far away");
    }

    function testARealPlanBeatsAStandInAcrossBooks() public {
        PoolKey memory thin = _at(1_000, 100, 1e22);
        PoolKey memory deep = _at(-400, 200, 1e24);
        _gate();
        bytes32[] memory centres = new bytes32[](2);
        centres[0] = _id(thin);
        centres[1] = _id(deep);
        ArbitrageProbe probe = _probeInHook();
        (uint256 pick, ArbitrageLogic.Plan memory best) =
            probe.pickAmong(centres, address(backing));
        ArbitrageLogic.Plan memory alone = probe.planFrom(_id(thin), address(backing));
        assertTrue(alone.standin, "the first book holds only a stand-in");
        assertGt(alone.gap, best.gap, "and its gap is wider");
        assertEq(pick, 1, "the second book's real plan is picked");
        assertFalse(best.standin, "a real plan");
    }
}
