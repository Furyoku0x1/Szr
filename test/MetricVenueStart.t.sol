// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { MetricVenueSearchWorld } from "./MetricVenueSearch.t.sol";
import { PayFirstRouter, BurnAfterRouter, BurnPricer } from "./MetricVenueGuards.t.sol";
import { FlatPricer } from "./utils/WrappedPool.sol";
import { EntryPart } from "../src/arbitrage/ArbitrageEntry.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The guards of `MetricVenueGuards.t.sol` and the settlement tests of
/// `MetricVenueSearch.t.sol`, on the route where the swapped Metric pool holds the trigger's
/// token. The wrapper is the real `MetricVenueHook` and its pricer answers, so the trigger
/// runs one search from the swapped pool and plans with the ends exchanged
/// (`docs/specs/hook-wrapped-start.md`, part B).
contract MetricVenueStartTest is MetricVenueSearchWorld {
    uint256 internal constant FILL_BURN = 800_000;
    uint256 internal constant HEAVY_BURN = 3_000_000;
    uint256 internal constant BURN_AFTER = 1_500_000;

    PayFirstRouter internal payFirst;
    PoolKey internal third;
    PoolKey internal fourth;

    function setUp() public override {
        super.setUp();
        // The wrapper's pricer answers, so the swapped pool is a wrapped pool the hook can
        // search from, and it holds WETH, the token the trigger counts in.
        hook.setPricer(address(venue), address(new FlatPricer()));
        payFirst = new PayFirstRouter(manager);
        backing.approve(address(payFirst), type(uint256).max);
        coin.approve(address(payFirst), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// Two more plain WETH/coin pools, so that three leaders can each have a gap.
    function _moreLeaders() internal {
        third = _create(address(backing), address(coin), 100);
        fourth = _create(address(backing), address(coin), 10_000);
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(first);
        list[1] = _id(third);
        list[2] = _id(fourth);
        _lead(address(backing), address(coin), list);
        _limits(address(backing), 1e15);
    }

    function _openGaps() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _trade(third, address(coin), 50_000e18);
        _trade(fourth, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
    }

    /// The last payment out of the Metric pool is the swapper's own fill; the cycles' fills
    /// come before it.
    function _lastFill(Vm.Log[] memory logs) internal view returns (uint256 at) {
        bytes32 from = bytes32(uint256(uint160(address(metric))));
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics.length < 2) continue;
            if (logs[index].topics[0] != TRANSFER) continue;
            if (logs[index].topics[1] == from) at = index;
        }
    }

    function _swapWith(uint256 gas, uint256 amount) internal returns (bool ok) {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(venue));
        bool zeroForOne = Currency.unwrap(metricKey.currency0) == address(backing);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (metricKey, params, settings, ""))
        );
    }

    function _payFirstDeltas() internal returns (int256 weth, int256 other) {
        uint256 wethBefore = backing.balanceOf(address(this));
        uint256 coinBefore = coin.balanceOf(address(this));
        payFirst.swap(metricKey, Currency.unwrap(metricKey.currency0) == address(backing), 1e18);
        weth = int256(backing.balanceOf(address(this))) - int256(wethBefore);
        other = int256(coin.balanceOf(address(this))) - int256(coinBefore);
    }

    function _assertNotStarved(Vm.Log[] memory logs) internal view {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] != ArbitrageLogic.SearchUndone.selector) continue;
            bytes4 reason = abi.decode(logs[index].data, (bytes4));
            assertTrue(reason != ArbitrageLogic.Starved.selector, "starved");
        }
    }

    // ---------------------------------------------------------------------------------
    // a router that pays first
    // ---------------------------------------------------------------------------------

    /// With a gap open and the router's payment waiting, `_release` credits the payer and a
    /// cycle trades the pool about to be filled, from a plain limit end. The swap settles,
    /// the swapper pays and receives what it would with no gap, and the gap is closed before
    /// the fill. A later look from the plain pool may trade it against another plain pool
    /// in the search after the fill; that is not checked here.
    function testPayFirstSettlementWithAGapClosesItBeforeTheFill() public {
        uint256 snapshot = vm.snapshotState();
        (int256 plainWeth, int256 plainCoin) = _payFirstDeltas();
        assertEq(plainWeth, -1e18, "paid one");
        vm.revertToState(snapshot);
        _openGap();
        vm.recordLogs();
        (int256 weth, int256 other) = _payFirstDeltas();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fill = _lastFill(logs);
        uint256 cycles;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            bytes32 topic = logs[index].topics[0];
            assertTrue(topic != ArbitrageLogic.CycleFailed.selector, "a cycle failed");
            assertTrue(topic != ArbitrageLogic.SearchUndone.selector, "a search undone");
            if (topic != ArbitrageLogic.Arbitraged.selector) continue;
            // What the search after the fill finds is not this test's business.
            if (index > fill) continue;
            cycles++;
            assertEq(logs[index].topics[1], _id(first), "the first trade is in the plain pool");
            assertEq(logs[index].topics[2], metricId, "the Metric pool is the venue");
        }
        assertGt(cycles, 0, "the gap was closed");
        assertEq(weth, plainWeth, "paid, gap, trigger on");
        assertEq(other, plainCoin, "received, gap, trigger on");
        uint256 one = _sqrtPrice(first);
        uint256 two = _sqrtPrice(second);
        uint256 apart = one > two ? one - two : two - one;
        assertLt(apart * 100, one, "the gap is closed");
        _assertNothingHeld();
    }

    // ---------------------------------------------------------------------------------
    // gas
    // ---------------------------------------------------------------------------------

    /// A triggered search is never `Starved`, which would fail the swap. Three plain
    /// leaders have a gap against the Metric pool, whose fills are capped so that every
    /// cycle fails, one after the other. The trigger's cap is swept across where the search
    /// can start, and then the swap's own gas.
    function testATriggeredSearchIsNeverStarved() public {
        _moreLeaders();
        metric.setMaxFill(1e17);
        _openGaps();
        bool failedSome;
        for (uint256 cap = 3_000_000; cap <= 12_000_000; cap += 100_000) {
            uint256 snapshot = vm.snapshotState();
            venue.setTrigger(metricKey, id, address(backing), uint32(cap), true);
            vm.recordLogs();
            assertTrue(_swapWith(30_000_000, 1e16), "the swap never fails for the search");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertNotStarved(logs);
            if (_count(logs, ArbitrageLogic.CycleFailed.selector) != 0) failedSome = true;
            vm.revertToState(snapshot);
        }
        assertTrue(failedSome, "failing cycles were staged");
        bool settled;
        failedSome = false;
        for (uint256 gas = 600_000; gas <= 14_000_000; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWith(gas, 1e16);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            _assertNotStarved(logs);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (ok) settled = true;
            if (ok) {
                if (_count(logs, ArbitrageLogic.CycleFailed.selector) != 0) failedSome = true;
            }
            vm.revertToState(snapshot);
        }
        assertTrue(settled, "never settled");
        assertTrue(failedSome, "a swap settled with a failed cycle");
    }

    /// The fill of the swapped pool is costly, and so is each cycle through it: the search
    /// before the fill has a gas-heavy cycle to close. More gas must never fail the swap
    /// once it has settled.
    function testMoreGasNeverFailsASwapWhenTheFillIsCostly() public {
        metric.setMode(6, FILL_BURN);
        _openGap();
        bool settled;
        bool searched;
        for (uint256 gas = 500_000; gas <= 16_000_000; gas += 250_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWith(gas, 1e18);
            uint256 cycles = _count(vm.getRecordedLogs(), ArbitrageLogic.Arbitraged.selector);
            vm.revertToState(snapshot);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (ok) settled = true;
            if (ok) {
                if (cycles != 0) searched = true;
            }
        }
        assertTrue(settled, "never settled");
        assertTrue(searched, "never searched");
    }

    /// A later step of the route burns gas after the swap. The search before the fill uses
    /// nearly its whole floor (the pricer burns what it is allowed and each cycle through
    /// the heavy fill fails after the whole plan), and the swap must still complete once it
    /// has with less gas.
    function testReserveLeavesRoomForALaterRoute() public {
        hook.setPricer(address(venue), address(new BurnPricer()));
        metric.setMode(6, HEAVY_BURN);
        _openGap();
        BurnAfterRouter router = new BurnAfterRouter(manager);
        backing.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(metricKey.currency0) == address(backing);
        bool settled;
        bool searched;
        for (uint256 gas = 4_000_000; gas <= 16_000_000; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            (bool ok,) = address(router).call{ gas: gas }(
                abi.encodeCall(router.swap, (metricKey, zeroForOne, 1e18, BURN_AFTER))
            );
            uint256 failed = _count(vm.getRecordedLogs(), ArbitrageLogic.CycleFailed.selector);
            vm.revertToState(snapshot);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (ok) settled = true;
            if (ok) {
                if (failed != 0) searched = true;
            }
        }
        assertTrue(settled, "never settled");
        assertTrue(searched, "never searched");
    }

    // ---------------------------------------------------------------------------------
    // settlement
    // ---------------------------------------------------------------------------------

    /// The swapper gets the same from the Metric pool whatever the search does, and the
    /// search with the trigger on really does close the gap first.
    function testSettlementDoesNotDependOnTheSearch() public {
        _openGap();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        (int256 withWeth, int256 withCoin) = _swapperDeltas();
        uint256 cycles = _count(vm.getRecordedLogs(), ArbitrageLogic.Arbitraged.selector);
        assertGt(cycles, 0, "the search ran");
        vm.revertToState(snapshot);
        venue.setTrigger(metricKey, id, address(backing), CAP, false);
        (int256 plainWeth, int256 plainCoin) = _swapperDeltas();
        assertEq(withWeth, plainWeth, "paid");
        assertEq(withCoin, plainCoin, "received");
        vm.revertToState(snapshot);
        // A search that reverts outright changes nothing either.
        vm.mockCallRevert(address(hook), EntryPart.venueSearch.selector, "boom");
        (int256 brokenWeth, int256 brokenCoin) = _swapperDeltas();
        assertEq(brokenWeth, plainWeth, "paid, search reverting");
        assertEq(brokenCoin, plainCoin, "received, search reverting");
    }
}
