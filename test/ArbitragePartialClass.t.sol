// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Vm } from "forge-std/Vm.sol";
import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { WrappedPricer } from "./utils/WrappedPool.sol";
import { CyclePart } from "../src/arbitrage/ArbitrageCycle.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Runs the probe's `attempt` inside a pool-manager unlock, as a search would.
contract Attempter is IUnlockCallback {
    IPoolManager internal immutable manager;
    ArbitrageProbe internal immutable probe;
    uint256 public won;
    bool public piece;

    constructor(IPoolManager poolManager, ArbitrageProbe tried) {
        manager = poolManager;
        probe = tried;
    }

    function run(bytes32 poolId, ArbitrageLogic.Plan memory plan, bool filled) external {
        manager.unlock(abi.encode(poolId, plan, filled));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (bytes32 poolId, ArbitrageLogic.Plan memory plan, bool fill) =
            abi.decode(data, (bytes32, ArbitrageLogic.Plan, bool));
        (won, piece) = probe.attemptPiece(1, probe.token(), poolId, plan, fill);
        return "";
    }
}

/// @dev `_attempt` says whether the size that worked was a full one or a partial one
/// (`docs/specs/hook-partial-cycle.md`, "Which cycles are full and which are partial").
/// Each test runs a search once to record the first plan it tries, puts the state back, and
/// runs `_attempt` on that plan alone.
contract ArbitragePartialClassTest is SizingWorld {
    /// The plan `_attempt` gets for the first cycle of a search, with the pool it is tried in.
    function _firstPlan(Spec memory spec, ArbitrageProbe probe)
        internal
        returns (bytes32 poolId, ArbitrageLogic.Plan memory plan)
    {
        _cool();
        vm.startStateDiffRecording();
        _start(spec);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        if (probe.sizingCalls() != 0) {
            return abi.decode(probe.walkInput(), (bytes32, ArbitrageLogic.Plan));
        }
        for (uint256 index; index < accesses.length; index++) {
            if (accesses[index].account != address(hook)) continue;
            if (accesses[index].data.length < 4) continue;
            if (bytes4(accesses[index].data) != CyclePart.execute.selector) continue;
            bytes memory body = new bytes(accesses[index].data.length - 4);
            for (uint256 at; at < body.length; at++) {
                body[at] = accesses[index].data[at + 4];
            }
            return abi.decode(body, (bytes32, ArbitrageLogic.Plan));
        }
        revert("no cycle was tried");
    }

    uint256 internal tries;

    /// Whether the cycle `_attempt` ran for the spec's first plan worked, and in part.
    /// `tamper` gives it an estimate that cannot earn (one wei of input) and the real
    /// estimate as its whole-gap size, so that the second size is the first to work.
    function _classify(Spec memory spec, bool tamper)
        internal
        returns (uint256 won, bool piece)
    {
        return _classify(spec, tamper, true);
    }

    function _classify(Spec memory spec, bool tamper, bool filled)
        internal
        returns (uint256 won, bool piece)
    {
        _on();
        uint256 open = vm.snapshotState();
        ArbitrageProbe probe = _probeInHook();
        (bytes32 poolId, ArbitrageLogic.Plan memory plan) = _firstPlan(spec, probe);
        vm.revertToState(open);
        probe = _probeInHook();
        if (tamper) {
            plan.full = plan.limit;
            plan.fullSpend = plan.spend;
            plan.spend = 1;
        }
        Attempter attempter = new Attempter(manager, probe);
        _cool();
        vm.startStateDiffRecording();
        attempter.run(poolId, plan, filled);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        for (uint256 index; index < accesses.length; index++) {
            if (accesses[index].account != address(hook)) continue;
            if (accesses[index].data.length < 4) continue;
            if (bytes4(accesses[index].data) == CyclePart.execute.selector) tries++;
        }
        return (attempter.won(), attempter.piece());
    }

    function _oneRange() internal returns (Spec memory) {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, 100_000);
        return _direct("one range", venue, usdPool);
    }

    function _dusted(int24 count, uint256 gap) internal returns (Spec memory) {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        _dust(usdPool, count);
        return _direct("dust", venue, usdPool);
    }

    /// A venue of one thick range and dust beyond it, with the walk off: the estimate assumes
    /// the thick range's depth and so overshoots, and so does the whole gap; a half (gap 16,000)
    /// or a quarter (20,000) of it stays inside the range.
    function _overshoot(uint256 gap) internal returns (Spec memory spec) {
        _declineSizing();
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        PoolKey memory venue = _register(address(usd), 2_000, start);
        uint256[] memory units = _stepped(1, 1_500_000e18, 4, 1e12);
        _bands(venue, _push(venue, address(szr)), units);
        spec = _direct("overshoot", venue, usdPool);
        spec.probe = venue;
    }

    /// The walk ran to the optimum inside one range, and its size worked first time.
    function testWalkToItsNaturalEndIsFull() public {
        (uint256 won, bool piece) = _classify(_oneRange(), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 1, "on the first try");
        assertFalse(piece, "and it closed all there was to close");
    }

    /// Dust at every tick: the walk runs short of gas for another step (or fails), so the
    /// size it found, which worked, is partial.
    function testWalkStoppedShortIsPartial() public {
        (uint256 won, bool piece) = _classify(_dusted(150, 120_000), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 1, "on the first try");
        assertTrue(piece, "but only part of the gap");
    }

    /// A plan that is not sized at all keeps the estimate, which counts as full.
    function testUnsizedEstimateIsFull() public {
        _declineSizing();
        (uint256 won, bool piece) = _classify(_oneRange(), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 1, "on the first try");
        assertFalse(piece, "and the estimate counts as full");
    }

    /// The first size fails and the whole gap, the second, works: full.
    function testWholeGapTryIsFull() public {
        _declineSizing();
        (uint256 won, bool piece) = _classify(_oneRange(), true);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 2, "on the second try");
        assertFalse(piece, "the whole-gap size is full");
    }

    /// The first two sizes fail and a half of the gap, the third, works: partial.
    function testHalfTheGapIsPartial() public {
        (uint256 won, bool piece) = _classify(_overshoot(16_000), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 3, "on the third try");
        assertTrue(piece, "a half is partial");
    }

    /// The first three sizes fail and a quarter, the fourth, works, with no try running out
    /// of gas: partial.
    function testQuarterOfTheGapIsPartial() public {
        (uint256 won, bool piece) = _classify(_overshoot(20_000), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 4, "on the fourth try");
        assertTrue(piece, "a quarter is partial");
    }

    /// A try that ran out of gas leaves only the eighth of the gap to try (S5c): partial.
    function testStrainedEighthIsPartial() public {
        _declineSizing();
        (uint256 won, bool piece) = _classify(_dusted(60, 200_000), false);
        assertGt(won, 0, "the smallest size earned");
        assertTrue(piece, "and it is partial");
    }

    /// A walk that ends because a wrapped leg's reported range ended has reached that leg's
    /// end: its size is full, whatever the wrapped venue holds past the range. `walk.stopped`
    /// is preset for such a cycle and is not what counts.
    function testWrappedRangeEndIsFull() public {
        minProfit = 300e18;
        PoolKey memory venue = _wrappedVenue(75_000);
        _untrack(mainPool);
        int24 dir = _push(usdPool, address(usd));
        _bands(usdPool, dir, _alternating(3, poolUnits, poolUnits * 2));
        WrappedPricer pricer = WrappedPricer(wrappedPricer);
        pricer.arm(10);
        pricer.setReach(3_000);
        (uint256 won, bool piece) = _classify(_direct("wrapped", venue, usdPool), false);
        assertGt(won, 0, "the cycle earned");
        assertFalse(piece, "and the end of the wrapped range is the end of the leg");
    }

    /// A walk that reverts leaves the first try the estimate, and the size is partial. Here it
    /// reverts because the wrapped pool's answers were never asked for.
    function testWalkThatRevertsIsPartial() public {
        minProfit = 300e18;
        PoolKey memory venue = _wrappedVenue(75_000);
        _untrack(mainPool);
        int24 dir = _push(usdPool, address(usd));
        _bands(usdPool, dir, _alternating(3, poolUnits, poolUnits * 2));
        WrappedPricer pricer = WrappedPricer(wrappedPricer);
        pricer.arm(10);
        pricer.setReach(3_000);
        Spec memory spec = _direct("wrapped", venue, usdPool);
        (uint256 won, bool piece) = _classify(spec, false, false);
        assertGt(won, 0, "the estimate earned");
        assertEq(tries, 1, "on the first try");
        assertTrue(piece, "and a walk that failed is partial");
    }

    /// A walk that stops for want of gas across real ranges, not dust, is partial too.
    function testWalkStoppedAcrossRealRangesIsPartial() public {
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, 300_000);
        int24 dir = _push(usdPool, address(usd));
        _bands(usdPool, dir, _alternating(30, poolUnits, poolUnits * 2));
        (uint256 won, bool piece) = _classify(_direct("capped", venue, usdPool), false);
        assertGt(won, 0, "the cycle earned");
        assertEq(tries, 1, "on the first try");
        assertTrue(piece, "a walk stopped short is partial");
    }
}
