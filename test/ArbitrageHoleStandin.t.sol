// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { HoleWorld } from "./utils/HoleWorld.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { CyclePart } from "../src/arbitrage/ArbitrageCycle.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Vm } from "forge-std/Vm.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The stand-in plan of 18-M-2 (docs/specs/hook-hole-edge.md): when it is made, how it
/// ranks, and what the walk does with a pool that is truly empty.
contract ArbitrageHoleStandinTest is HoleWorld {
    bytes32 internal constant SZR_DONATED = keccak256("SzrDonated(address,uint256)");

    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// The focus pool with nothing in it at all and the main pool 1.5% away, so the gap
    /// can only be closed by trading in a pool that has no liquidity anywhere.
    function _empty() internal {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(false, -1e30, TickMath.getSqrtPriceAtTick(centre + 300)),
            settings,
            ""
        );
        assertEq(manager.getLiquidity(focus.toId()), 0, "empty");
    }

    function _tinySwap() internal returns (bool ok, bytes memory data) {
        PoolSwapTest.TestSettings memory settings;
        (ok, data) = address(swapper).call{ gas: hook.gasForSwap(1) }(
            abi.encodeCall(
                swapper.swap,
                (
                    focus,
                    IPoolManager.SwapParams(
                        false, -1e9, TickMath.getSqrtPriceAtTick(centre + 60)
                    ),
                    settings,
                    ""
                )
            )
        );
    }

    function _benched() internal view returns (bool) {
        bytes32 venue = _id(mainPool);
        if (hook.benchedUntil(1, address(szr), _id(focus), venue, true) != 0) return true;
        return hook.benchedUntil(1, address(szr), _id(focus), venue, false) != 0;
    }

    // ----- spec test 5: a truly empty pool -----

    function testEmptyPoolSwapPassesFailsOneCycleAndBenchesWithNoTries() public {
        _empty();
        vm.expectCall(address(hook), abi.encodeWithSelector(CyclePart.execute.selector), 0);
        vm.recordLogs();
        (bool ok,) = _tinySwap();
        assertTrue(ok, "the swap passes at gasForSwap");
        assertEq(_count(ArbitrageLogic.CycleFailed.selector), 1, "exactly one failed cycle");
        assertTrue(_benched(), "and the pair is benched");
    }

    function testArbOnAnEmptyPoolBenchesNothing() public {
        _empty();
        assertEq(hook.arb(_id(focus)), 0, "nothing earned");
        assertFalse(_benched(), "nothing benched");
    }

    /// A stand-in whose cycle is not sized (the walk is off) tries the whole gap first, so
    /// the second size, which is the same, is skipped. In an empty pool every try fails fast,
    /// so the tries run are the count: of the five sizes, the first, third, fourth and fifth.
    /// The search after the swap finds the pair benched.
    function testAStandInWithNoWalkDoesNotRepeatTheWholeGap() public {
        _empty();
        _probeInHook().setDeclineSizing(true);
        vm.startStateDiffRecording();
        (bool ok,) = _tinySwap();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, "the swap passes");
        uint256 tries;
        for (uint256 index; index < accesses.length; index++) {
            if (accesses[index].account != address(hook)) continue;
            if (accesses[index].data.length < 4) continue;
            if (bytes4(accesses[index].data) == CyclePart.execute.selector) tries++;
        }
        assertEq(tries, 4, "four tries, not five");
    }

    // ----- spec test 6: more gas never fails one swap -----

    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 found = bytes4(
                bytes.concat(data[index], data[index + 1], data[index + 2], data[index + 3])
            );
            if (found == wanted) return true;
        }
        return false;
    }

    /// Runs the swap at every gas from 300k to 12M. Once one passes every larger one must,
    /// each earns what the most gas earns, and each failure is `InsufficientGas`.
    function _monotone(bool up, uint160 limit) internal {
        PoolSwapTest.TestSettings memory settings;
        bytes memory trade = abi.encodeCall(
            swapper.swap, (focus, IPoolManager.SwapParams(up, -1e9, limit), settings, "")
        );
        uint256 snapshot = vm.snapshotState();
        uint256 inventory = core.unreleasedSupply();
        (bool top,) = address(swapper).call{ gas: 12_000_000 }(trade);
        assertTrue(top, "the most gas passes");
        uint256 full = core.unreleasedSupply() - inventory;
        vm.revertToState(snapshot);
        bool passed;
        for (uint256 gas = 300_000; gas <= 12_000_000; gas += 100_000) {
            vm.cool(address(manager));
            vm.cool(address(hook));
            vm.cool(address(core));
            (bool ok, bytes memory data) = address(swapper).call{ gas: gas }(trade);
            uint256 earned = core.unreleasedSupply() - inventory;
            vm.revertToState(snapshot);
            if (passed) assertTrue(ok, "more gas failed");
            if (ok) assertEq(earned, full, "less than the full-gas profit");
            if (!ok) {
                assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "for gas");
            }
            passed = ok;
        }
        assertTrue(passed, "never passed");
    }

    function testMoreGasNeverFailsOneSwapInTheEdgeState() public {
        _build(0);
        // With the market off, so that the hook does not close the gap the swap opens.
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _toEdge(true, true);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        _monotone(false, TickMath.MAX_SQRT_PRICE - 1);
    }

    function testMoreGasNeverFailsOneSwapInTheEmptyState() public {
        _empty();
        _monotone(false, TickMath.getSqrtPriceAtTick(centre + 60));
    }

    // ----- spec test 7: a venue with no depth never plans -----

    function testAVenueWithNoDepthIsNeverPlannedAgainst() public {
        _build(0);
        _untrack(mainPool);
        // A venue priced 5% away from the focus pool with no liquidity at all.
        _register(address(backing), 100, TickMath.getSqrtPriceAtTick(centre + 1_000));
        vm.expectCall(address(hook), abi.encodeWithSelector(CyclePart.execute.selector), 0);
        vm.recordLogs();
        _swapTo(false, -1e15, TickMath.getSqrtPriceAtTick(centre + 60));
        assertEq(_count(ArbitrageLogic.Arbitraged.selector), 0, "no cycle");
    }

    // ----- spec test 9: Core as the venue -----

    /// Core's NAV is above every pool's price and the focus pool has nothing at its price:
    /// the stand-in buys SZR in the range around NAV and redeems it at Core, and the pool's
    /// price ends at NAV.
    function testStandInAgainstCoreBuysBackToNav() public {
        _coreSetup(600);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        vm.recordLogs();
        uint256 earned = hook.arb(_id(focus));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 redeemed;
        uint256 donated;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == SZR_DONATED) {
                donated += abi.decode(logs[index].data, (uint256));
            }
            if (logs[index].topics[0] != ArbitrageLogic.Arbitraged.selector) continue;
            if (logs[index].topics[2] == bytes32(0)) redeemed++;
        }
        assertGt(earned, 0, "arb earns");
        assertEq(donated, earned, "what Core was given is the figure arb returns");
        assertGt(redeemed, 0, "the cycle redeemed at Core");
        assertApproxEqRel(_price(focus), core.NAV(), 1e16, "the price is back at NAV");
    }

    // ----- spec test 8: a real plan comes before a stand-in -----

    function _plan(uint256 gap, uint256 score, bool standin)
        internal
        pure
        returns (ArbitrageLogic.Plan memory plan)
    {
        plan.gap = gap;
        plan.score = score;
        plan.standin = standin;
    }

    function testARealPlanOutranksAStandInWithinABook() public {
        ArbitrageProbe probe = _probeInHook();
        ArbitrageLogic.Plan memory real = _plan(0.01e18, 1e18, false);
        ArbitrageLogic.Plan memory stand = _plan(0.5e18, 1e30, true);
        assertFalse(probe.outranks(real, true, stand.score), "a stand-in never replaces real");
        assertTrue(probe.outranks(stand, false, real.score), "a real plan replaces a stand-in");
        assertTrue(probe.outranks(real, false, 2e18), "a better real plan wins");
        assertFalse(probe.outranks(real, false, 5e17), "a worse one does not");
        assertTrue(probe.outranks(stand, true, 2e30), "a better stand-in beats a stand-in");
        assertTrue(probe.outranks(_plan(0, 0, false), true, 1), "anything beats nothing");
    }

    function testARealPlanOutranksAStandInAcrossBooks() public {
        ArbitrageProbe probe = _probeInHook();
        ArbitrageLogic.Plan memory real = _plan(0.01e18, 1e18, false);
        ArbitrageLogic.Plan memory stand = _plan(0.5e18, 1e30, true);
        assertFalse(probe.wider(real, stand), "a wider stand-in does not replace real");
        assertTrue(probe.wider(stand, real), "a narrower real plan replaces a stand-in");
        assertTrue(probe.wider(real, _plan(0.02e18, 1e18, false)), "the wider gap wins");
        assertFalse(probe.wider(real, _plan(0.005e18, 1e18, false)), "and the narrower not");
    }

    // ----- the ratio of the focus to the rest of the cycle -----

    function testAStandInNeedsAThinFocus() public {
        // An empty focus pool, so its shape never decides: only the ratio does.
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        ArbitrageProbe probe = _probeInHook();
        bytes32 venue = _id(mainPool);
        bytes32 pool = _id(focus);
        uint256 others = probe.othersOf(venue);
        uint256 rate = 1 << 96;
        assertTrue(probe.standInMade(venue, pool, 0, rate, true, true, 0), "an empty focus");
        assertTrue(
            probe.standInMade(venue, pool, others / 10 - 1, rate, true, true, 0), "just under"
        );
        assertFalse(
            probe.standInMade(venue, pool, others / 10 + 1, rate, true, true, 0), "just over"
        );
        assertFalse(probe.standInMade(venue, pool, others, rate, true, true, 0), "as deep");
    }

    function testNoStandInOffTheStartPool() public {
        _build(0);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        ArbitrageProbe probe = _probeInHook();
        bytes32 venue = _id(mainPool);
        assertFalse(
            probe.standInMade(venue, _id(focus), 0, 1 << 96, false, true, 0),
            "not the start pool"
        );
    }
}
