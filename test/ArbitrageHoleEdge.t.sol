// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HoleWorld } from "./utils/HoleWorld.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev 18-M-2 (docs/specs/hook-hole-edge.md): a swap that ends on a range edge, or an LP
/// who pulls the in-range liquidity, leaves the searched pool with nothing to size a cycle
/// by, and the gap must still be closed.
contract ArbitrageHoleEdgeTest is HoleWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// What the control gap must exceed to be worth taking, in SZR. A world with SZR first
    /// in the pool turns a sale into a purchase, whose gap yields less SZR for the same
    /// price move (`test/ArbitrageTokenOrder.t.sol`).
    function controlFloor() internal pure virtual returns (uint256) {
        return 700e18;
    }

    /// Spec test 1 and 2: a swap to the exact edge, against the same swap stopped one wei
    /// short, which leaves the liquidity in range.
    function _edge(uint256 dust, bool zeroForOne, uint256 percent) internal {
        _build(dust);
        uint256 snapshot = vm.snapshotState();
        uint256 control = _retired(zeroForOne, false);
        vm.revertToState(snapshot);
        uint256 attack = _retired(zeroForOne, true);
        assertGt(control, controlFloor(), "the control gap is worth taking");
        assertGe(attack * 100, control * percent, "the edge swap's gap is taken as well");
    }

    function testNoLiquidityUnderTheEdgeLower() public {
        _edge(0, true, 95);
    }

    function testNoLiquidityUnderTheEdgeUpper() public {
        _edge(0, false, 95);
    }

    function testDustUnderTheEdgeLower() public {
        _edge(1e12, true, 95);
    }

    function testDustUnderTheEdgeUpper() public {
        _edge(1e12, false, 95);
    }

    function testOnePercentUnderTheEdgeLower() public {
        _edge(1e22, true, 95);
    }

    function testOnePercentUnderTheEdgeUpper() public {
        _edge(1e22, false, 95);
    }

    /// A regression check: with a tenth of the pool's depth underneath, the real estimate
    /// already finds most of the gap.
    function testTenPercentUnderTheEdgeStillTakesMostOfIt() public {
        _build(1e23);
        uint256 profit = _retired(true, true);
        assertGe(profit, 674e18, "at least 674 SZR");
    }

    /// Spec test 4: one wei of liquidity left over.
    function testOneWeiLeftOverStillEarnsLower() public {
        _edge(1, true, 95);
    }

    function testOneWeiLeftOverStillEarnsUpper() public {
        _edge(1, false, 95);
    }

    // ----- an LP pulls the in-range position (spec test 3) -----

    /// The in-range position is removed, which leaves the pool's price in a hole. A second
    /// range sits `offset` ticks away from it, up or down, with a thin range in each of
    /// `fillers` ticks between (each an initialised tick the walk has to cross). The main
    /// pool is then moved to the middle of the second range, so the gap can only be closed
    /// through it.
    function _pulled(bool up, int24 offset, uint256 fillers) internal {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        for (uint256 index; index < fillers; index++) {
            int24 step = int24(int256(index * 60));
            if (up) _position(centre + step + 60, centre + step + 120, 1);
            else _position(centre - step - 60, centre - step, 1);
        }
        if (up) _position(centre + offset, centre + offset + 1_200, BIG);
        else _position(centre - offset - 1_200, centre - offset, BIG);
        int24 target = up ? centre + offset + 300 : centre - offset - 300;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(!up, -1e30, TickMath.getSqrtPriceAtTick(target)),
            settings,
            ""
        );
        assertEq(manager.getLiquidity(focus.toId()), 0, "nothing to trade against");
    }

    function _pulledEarns(bool up, int24 offset, uint256 fillers) internal {
        _pulled(up, offset, fillers);
        uint256 snapshot = vm.snapshotState();
        assertGt(hook.arb(_id(focus)), 0, "arb earns");
        vm.revertToState(snapshot);
        uint256 inventory = core.unreleasedSupply();
        // A tiny swap towards the second range; the search before it closes the gap.
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            focus,
            IPoolManager.SwapParams(
                !up, -1e9, up ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            settings,
            ""
        );
        assertGt(core.unreleasedSupply(), inventory, "a hooked swap earns");
    }

    function testPulledPositionSecondRangeAbove() public {
        _pulledEarns(true, 60, 0);
    }

    function testPulledPositionSecondRangeThreeInitialisedTicksAbove() public {
        _pulledEarns(true, 240, 3);
    }

    /// Going down from the price at tick zero crosses a word boundary of the tick bitmap
    /// before it meets anything.
    function testPulledPositionSecondRangeBelowAcrossAWord() public {
        _pulledEarns(false, 0, 0);
    }

    function testPulledPositionThreeInitialisedTicksBelow() public {
        _pulledEarns(false, 180, 3);
    }
}
