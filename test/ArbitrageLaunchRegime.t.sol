// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev The launch price regime (docs/specs/hook-fund-safety-tests.md, item 1, 28-T-2): SZR's
/// pool a little above or below Core's NAV, where mainnet starts, instead of the 1e15 times
/// above it the legacy price leaves in every other world.
contract ArbitrageLaunchRegimeTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Core0 {
        uint256 cash;
        uint256 nav;
        uint256 weth;
        uint256 supply;
        uint256 inventory;
    }

    function _core() internal view returns (Core0 memory state) {
        state.cash = core.reserveCash();
        state.nav = core.NAV();
        state.weth = backing.balanceOf(address(core));
        state.supply = core.activeSupply();
        state.inventory = core.unreleasedSupply();
    }

    /// Counts what the hook logged against Core (venue zero), and everything it did.
    function _againstCore(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 failed, uint256 cycles)
    {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            bool venueZero = logs[index].topics.length > 2 && logs[index].topics[2] == 0;
            if (logs[index].topics[0] == ArbitrageLogic.CycleFailed.selector) {
                if (venueZero) failed++;
            }
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) {
                if (venueZero) cycles++;
            }
        }
    }

    function _aboveNav(uint256 ratio) internal {
        _poolAtNavRatio(ratio);
        Core0 memory before = _core();
        vm.recordLogs();
        _trade(usdPool, address(szr), 1e18);
        _trade(usdPool, address(usd), 1e18);
        _trade(usdPool, address(szr), 3e18);
        hook.arb(_id(usdPool));
        hook.sweep(1, address(szr));
        (uint256 failed, uint256 cycles) = _againstCore(vm.getRecordedLogs());
        assertEq(failed, 0, "no cycle against Core failed");
        assertEq(cycles, 0, "no cycle used Core");
        Core0 memory after_ = _core();
        assertEq(after_.cash, before.cash, "Core's cash");
        assertEq(after_.nav, before.nav, "NAV");
        assertEq(after_.weth, before.weth, "Core's WETH");
        assertEq(after_.inventory, before.inventory, "nothing retired");
        _assertHookEmpty();
    }

    /// With the pool above NAV Core is no place to buy SZR: no plan uses it, in either
    /// direction of a hooked swap, `arb` or `sweep`.
    function testPoolAboveNavAtOnePointFiveNeverUsesCore() public {
        _aboveNav(1.5e18);
    }

    function testPoolAboveNavAtOnePointOneNeverUsesCore() public {
        _aboveNav(1.1e18);
    }

    /// The pool's price in partner per SZR, WAD.
    function _perSzr(PoolKey memory pool) internal view returns (uint256) {
        (uint160 root,,,) = manager.getSlot0(pool.toId());
        uint256 square = FixedPointMathLib.fullMulDiv(uint256(root), uint256(root), 1 << 64);
        bool szrFirst = Currency.unwrap(pool.currency0) == address(szr);
        return szrFirst
            ? FixedPointMathLib.fullMulDiv(square, 1e18, 1 << 128)
            : FixedPointMathLib.fullMulDiv(1 << 128, 1e18, square);
    }

    /// With the pool 10% below NAV the hook redeems at Core and brings the pool back to about
    /// NAV, and Core and the pool manager end up with what they should.
    function testPoolBelowNavRedeemsAtCoreAndNothingLeaksFromCore() public {
        _poolAtNavRatio(0.9e18);
        Core0 memory before = _core();
        uint256 managerSzr = szr.balanceOf(address(manager));
        uint256 managerWeth = backing.balanceOf(address(manager));
        uint256 coreSzr = szr.balanceOf(address(core));
        uint256 mineSzr = szr.balanceOf(address(this));
        uint256 mineWeth = backing.balanceOf(address(this));
        uint256 priceBefore = _perSzr(usdPool);
        vm.recordLogs();
        uint256 earned = hook.arb(_id(usdPool));
        assertGt(earned, 0, "arb redeems at Core");
        _trade(usdPool, address(usd), 1e18);
        (, uint256 cycles) = _againstCore(vm.getRecordedLogs());
        assertGt(cycles, 0, "the cycle redeemed at Core");
        Core0 memory after_ = _core();
        assertGe(after_.nav, before.nav, "NAV never falls");
        uint256 retired = after_.inventory - before.inventory;
        assertGt(retired, 0, "SZR retired");
        uint256 outflow = before.weth - after_.weth;
        assertLe(
            outflow,
            retired * before.nav / 1e18 + retired / 1e18 + 1,
            "Core paid no more than NAV for what it retired"
        );
        _assertHookEmpty();
        // Between the pool manager, Core and the trader, every token went somewhere seen.
        assertEq(
            int256(szr.balanceOf(address(manager))) - int256(managerSzr)
                + int256(szr.balanceOf(address(core))) - int256(coreSzr)
                + int256(szr.balanceOf(address(this))) - int256(mineSzr),
            0,
            "SZR is conserved"
        );
        assertEq(
            int256(backing.balanceOf(address(manager))) - int256(managerWeth)
                + int256(backing.balanceOf(address(core))) - int256(before.weth)
                + int256(backing.balanceOf(address(this))) - int256(mineWeth),
            0,
            "WETH is conserved"
        );
        // The pool moves toward NAV and never past it. It does not reach it in one `arb`: the
        // hookless main pool is below NAV too, and each cycle in this pool opens a gap against
        // that one, so the rounds alternate between them (the audit's "ping-pong").
        assertGt(_perSzr(usdPool), priceBefore, "the pool moved up");
        assertLe(_perSzr(usdPool), after_.nav * 1005 / 1000, "and not past NAV");
    }

    /// A real NAV-backed loan is in place when the hook redeems: Core's backing counts the
    /// loan's principal, and redemption at that floor still succeeds and is sized right (28-W-1).
    function testRedemptionWithALoanOutstandingStillSucceeds() public {
        _poolAtNavRatio(0.9e18);
        szr.approve(address(core), type(uint256).max);
        uint256 collateral = 1_000_000e18;
        uint256 principal = core.NAV() * collateral / 1e18 / 2;
        core.borrow(collateral, principal);
        (uint256 owedCollateral, uint256 owedPrincipal,) = core.loans(address(this));
        assertEq(owedPrincipal, principal, "the loan is real");
        assertGt(core.loanPrincipal(), 0, "and counted in backing");
        Core0 memory before = _core();
        vm.recordLogs();
        uint256 earned = hook.arb(_id(usdPool));
        (uint256 failed, uint256 cycles) = _againstCore(vm.getRecordedLogs());
        assertGt(earned, 0, "arb earns");
        assertEq(failed, 0, "no redemption failed");
        assertGt(cycles, 0, "and Core was used");
        Core0 memory after_ = _core();
        assertGe(after_.nav, before.nav, "NAV never falls");
        assertEq(core.loanPrincipal(), principal, "the loan is untouched");
        (uint256 collateralAfter,,) = core.loans(address(this));
        assertEq(collateralAfter, owedCollateral, "and so is its collateral");
        _assertHookEmpty();
    }
}
