// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HoleWorld } from "./utils/HoleWorld.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A failed stand-in must never keep a real plan from being made
/// (docs/specs/hook-hole-edge.md, review fold-in of 2026-11-24).
contract ArbitrageHoleBenchTest is HoleWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _victim() internal returns (uint256 earned) {
        uint256 inventory = core.unreleasedSupply();
        _swapTo(false, -1e30, TickMath.getSqrtPriceAtTick(centre + 200));
        earned = core.unreleasedSupply() - inventory;
    }

    /// An LP who is the pool's only liquidity pulls it, has the hook try a stand-in far
    /// away, and puts it back. A later victim's swap must still be searched in full.
    function _attacked() internal returns (uint256 control) {
        _build(0);
        uint256 snapshot = vm.snapshotState();
        control = _victim();
        vm.revertToState(snapshot);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        _swapTo(false, -1e9, TickMath.getSqrtPriceAtTick(centre + 13_000));
        _swapTo(true, -1e9, TickMath.getSqrtPriceAtTick(centre));
        _position(centre - WIDTH, centre + WIDTH, BIG);
    }

    function testAFailedStandInDoesNotBlockTheVictimsSwap() public {
        uint256 control = _attacked();
        assertGt(control, 0, "a control gap");
        assertGe(_victim() * 100, control * 99, "the victim's swap is searched in full");
    }

    function testAFailedStandInDoesNotBlockArb() public {
        _attacked();
        // The victim's swap with the market off leaves its gap for `arb`.
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _victim();
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        vm.warp(block.timestamp + 170);
        assertGt(hook.arb(_id(focus)), 0, "arb takes the gap");
    }

    // ----- Core as the venue: the ratio never applies -----

    /// A marginal Core buyback ahead of a swap makes a stand-in that is declined. The real
    /// Core cycle after the swap must still run, and the price end at NAV.
    function testAMarginalCoreStandInDoesNotStopTheRealCycleAfterTheSwap() public {
        (int24 navTick, bool szr0) = _coreSetup(40);
        hook.setLimits(1, address(szr), 8_000_000, 0, 1.0001e18);
        uint256 snapshot = vm.snapshotState();
        uint256 small = hook.arb(_id(focus));
        assertGt(small, 0, "a marginal gap");
        vm.revertToState(snapshot);
        int24 wide = szr0 ? navTick - 64 : navTick + 64;
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _swapTo(szr0, -1e30, TickMath.getSqrtPriceAtTick(wide));
        hook.setLimits(1, address(szr), 8_000_000, 0, 1.0001e18);
        uint256 full = hook.arb(_id(focus));
        vm.revertToState(snapshot);
        hook.setLimits(1, address(szr), 8_000_000, uint128(small * 13 / 10), 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        _swapTo(szr0, -1e30, TickMath.getSqrtPriceAtTick(wide));
        assertGe(
            (core.unreleasedSupply() - inventory) * 100, full * 99, "the real cycle after ran"
        );
        int24 end = _tick();
        int24 gap = end > navTick ? end - navTick : navTick - end;
        assertLt(gap, 60, "the price is back at NAV");
    }
}
