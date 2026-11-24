// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./ArbitrageWorld.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev A hooked SZR/WETH pool next to the main pool, with its in-range liquidity at a
/// chosen depth, for tests of a swap that leaves the pool with nothing to trade against
/// (docs/specs/hook-hole-edge.md). The main pool is the venue; only the focus pool is thin.
abstract contract HoleWorld is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey internal focus;
    /// The tick the focus pool's position is centred on, and its half width.
    int24 internal centre;
    int24 internal constant WIDTH = 600;
    uint256 internal constant BIG = 1_000_000e18;

    function _build(uint256 dust) internal {
        (uint160 price,,,) = manager.getSlot0(mainPool.toId());
        focus = _register(address(backing), 500, price);
        centre = TickMath.getTickAtSqrtPrice(price) / 60 * 60;
        _position(centre - WIDTH, centre + WIDTH, BIG);
        if (dust > 0) _provide(focus, dust);
    }

    function _position(int24 lower, int24 upper, uint256 units) internal {
        provider.modifyLiquidity(
            focus, IPoolManager.ModifyLiquidityParams(lower, upper, int256(units), 0), ""
        );
    }

    function _unposition(int24 lower, int24 upper, uint256 units) internal {
        provider.modifyLiquidity(
            focus, IPoolManager.ModifyLiquidityParams(lower, upper, -int256(units), 0), ""
        );
    }

    /// Zero-for-one lowers the price, so it runs to the lower edge.
    function _edgeTick(bool zeroForOne) internal view returns (int24) {
        return zeroForOne ? centre - WIDTH : centre + WIDTH;
    }

    function _swapTo(bool zeroForOne, int256 amount, uint160 limit) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(focus, IPoolManager.SwapParams(zeroForOne, amount, limit), settings, "");
    }

    /// Runs the focus pool to the end of its range: on the edge itself when `exact`, and
    /// otherwise one wei short of it, which leaves the liquidity in range.
    function _toEdge(bool zeroForOne, bool exact) internal {
        uint160 limit = TickMath.getSqrtPriceAtTick(_edgeTick(zeroForOne));
        if (!exact) limit = zeroForOne ? limit + 1 : limit - 1;
        _swapTo(zeroForOne, -1e30, limit);
    }

    function _count(bytes32 selector) internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == selector) count++;
        }
    }

    function _sqrt(PoolKey memory pool) internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(pool.toId());
    }

    function _retired(bool zeroForOne, bool exact) internal returns (uint256 profit) {
        uint256 inventory = core.unreleasedSupply();
        _toEdge(zeroForOne, exact);
        profit = core.unreleasedSupply() - inventory;
    }

    // ----- Core as the venue -----

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(focus.toId());
    }

    /// The focus pool emptied and a range of 12,000 ticks put around NAV's price; Core's NAV
    /// raised well above the pools; and the pool moved to `below` ticks from NAV, with the
    /// market off. Returns NAV's tick and whether SZR is the pool's first token.
    function _coreSetup(int24 below) internal returns (int24 navTick, bool szr0) {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        _untrack(mainPool);
        _untrack(usdPool);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        uint256 nav = core.NAV();
        szr0 = Currency.unwrap(focus.currency0) == address(szr);
        uint256 ratio = szr0
            ? FixedPointMathLib.fullMulDiv(nav, 1 << 192, 1e18)
            : FixedPointMathLib.fullMulDiv(1e18, 1 << 192, nav);
        navTick = TickMath.getTickAtSqrtPrice(uint160(FixedPointMathLib.sqrt(ratio))) / 60 * 60;
        _position(navTick - 6_000, navTick + 6_000, BIG);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        int24 at = szr0 ? navTick - below : navTick + below;
        (, int24 now_,,) = manager.getSlot0(focus.toId());
        _swapTo(at < now_, -1e30, TickMath.getSqrtPriceAtTick(at));
    }
}
