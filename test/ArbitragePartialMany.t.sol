// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";

contract ArbitragePartialManyTest is MultiWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _dustIn(PoolKey memory pool, int24 count) internal {
        (, int24 tick,,) = manager.getSlot0(pool.toId());
        int24 base = tick / 60 * 60;
        for (int24 step = -count; step < count; step++) {
            provider.modifyLiquidity(
                pool,
                IPoolManager.ModifyLiquidityParams(
                    base + step * 60, base + (step + 1) * 60, int256(1e12), 0
                ),
                ""
            );
        }
    }

    function _stage(uint256 gap) internal {
        _dustIn(first, 150);
        _dustIn(second, 150);
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), gap);
        _limits(address(backing), 1e15);
        vm.recordLogs();
    }

    function _row(uint256 gas) internal returns (bool ok, bytes memory reason, uint256 before) {
        uint256 snapshot = vm.snapshotState();
        vm.getRecordedLogs();
        vm.cool(address(manager));
        vm.cool(address(hook));
        (ok, reason) = _tradeWithGas(stable, address(coin), gas);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fills;
        for (uint256 i; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(manager)) {
                if (topic != IPoolManager.Swap.selector) continue;
                if (address(uint160(uint256(logs[i].topics[2]))) == address(swapper)) fills++;
                continue;
            }
            if (logs[i].emitter != address(hook)) continue;
            if (topic != ArbitrageLogic.Arbitraged.selector) continue;
            if (fills == 0) before++;
        }
        vm.revertToState(snapshot);
    }

    /// The lowest gas, to within 10,000, at which a swap settles; `low` must fail and `high`
    /// settle.
    function _lowest(uint256 low, uint256 high) internal returns (uint256) {
        (bool ok,,) = _row(low);
        assertFalse(ok, "the low end of the search fails");
        (ok,,) = _row(high);
        assertTrue(ok, "the high end of the search settles");
        while (high - low > 10_000) {
            uint256 mid = (low + high) / 2;
            (ok,,) = _row(mid);
            if (ok) high = mid;
            else low = mid;
        }
        return high;
    }

    /// A swap in the connecting pool of a market with two profit tokens searches two books in
    /// one search, with dust at every tick of both venues so that each cycle is partial. The
    /// rule is shared across the books: a swap with gas for fewer than three cycles in all
    /// reverts `InsufficientGas`, where it used to settle after one; with gas for three it
    /// settles, and at `gasForSwap` it does too. The boundary is found, not named.
    function testBooksShareTheRuleAcrossThreePartialCycles() public {
        _stage(100_000e18);
        uint256 lowest = _lowest(5_000_000, 7_500_000);
        uint256[3] memory short = [lowest - 100_000, lowest - 300_000, lowest - 500_000];
        for (uint256 i; i < short.length; i++) {
            (bool ok, bytes memory reason,) = _row(short[i]);
            assertFalse(ok, "gas for fewer than three cycles fails");
            assertTrue(_has(reason, ArbitrageLogic.InsufficientGas.selector), "for gas");
        }
        (bool settled,, uint256 before) = _row(lowest + 100_000);
        assertTrue(settled, "gas for three cycles settles");
        assertEq(before, 3, "after three partial cycles");
        (settled,, before) = _row(hook.gasForSwap(id));
        assertTrue(settled, "and so does a swap that brings gasForSwap");
        assertGe(before, 3, "after at least three");
    }

    /// Steps of 20,000 from the lowest passing gas to 600,000 above: once a swap settles,
    /// none above it fails.
    function testFinePassAcrossBooks() public {
        _stage(100_000e18);
        uint256 lowest = _lowest(5_000_000, 7_500_000);
        bool passed;
        for (uint256 gas = lowest; gas <= lowest + 600_000; gas += 20_000) {
            (bool ok,,) = _row(gas);
            if (ok) passed = true;
            else assertFalse(passed, "a swap failed that a lower one passed");
        }
        assertTrue(passed, "the sweep reached a passing swap");
    }
}
