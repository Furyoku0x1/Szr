// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev What a swap that is given a chosen amount of gas did, as the swapper sees it.
struct Outcome {
    bool ok;
    bytes reason;
    uint256 received;
    uint256 arbBefore;
    uint256 arbAfter;
    uint256 profit;
}

/// @dev The world of finding 23-M-1 (`docs/specs/hook-partial-cycle.md`): SZR's market, dust
/// liquidity at every tick of the SZR/USD pool, a gap of 400,000 WETH sold into the main
/// pool, and a swap of 20,000 USD into the dust pool.
abstract contract PartialWorld is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
    }

    function _dustTicks(int24 count) internal {
        (, int24 tick,,) = manager.getSlot0(usdPool.toId());
        int24 base = tick / 60 * 60;
        for (int24 step = -count; step < count; step++) {
            provider.modifyLiquidity(
                usdPool,
                IPoolManager.ModifyLiquidityParams(
                    base + step * 60, base + (step + 1) * 60, int256(1e12), 0
                ),
                ""
            );
        }
    }

    uint256 internal constant COSTLY_RANGES = 6;
    int24 internal constant COSTLY_AWAY = 2_400;
    uint256 internal constant COSTLY_UNITS = 1e24;

    /// Venues that each take a cycle a long way to price, as in `ArbitrageGasTest`: the most
    /// a failed cycle and the scan after it can cost.
    function _costlyLeaders() internal {
        uint24[3] memory fees = [uint24(100), 200, 300];
        bytes32[] memory fakes = new bytes32[](3);
        for (uint256 index; index < 3; index++) {
            fakes[index] = _id(_costlyVenue(address(usd), fees[index]));
        }
        _setLeaders(address(usd), fakes);
        for (uint256 index; index < 6; index++) {
            TestAsset partner = new TestAsset();
            _addPartner(partner);
            bytes32[] memory only = new bytes32[](1);
            only[0] = _id(_costlyVenue(address(partner), 100));
            _setLeaders(address(partner), only);
        }
    }

    function _costlyVenue(address partner, uint24 fee) internal returns (PoolKey memory fake) {
        fake = _register(partner, fee, uint160(1 << 96));
        bool szrFirst = Currency.unwrap(fake.currency0) == address(szr);
        int24 tick = szrFirst ? -COSTLY_AWAY : COSTLY_AWAY;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            fake,
            IPoolManager.SwapParams(szrFirst, -1e30, TickMath.getSqrtPriceAtTick(tick)),
            settings,
            ""
        );
        for (uint256 step; step < COSTLY_RANGES; step++) {
            int24 lower = szrFirst
                ? tick + int24(uint24(step)) * 60
                : tick - int24(uint24(step) + 1) * 60;
            provider.modifyLiquidity(
                fake, IPoolManager.ModifyLiquidityParams(lower, lower + 60, 1e12, 0), ""
            );
        }
        provider.modifyLiquidity(
            fake,
            IPoolManager.ModifyLiquidityParams(
                szrFirst ? tick - 60 : tick,
                szrFirst ? tick : tick + 60,
                int256(COSTLY_UNITS),
                0
            ),
            ""
        );
    }

    /// The gap is opened with the market off, then the market is switched on with
    /// `allowance` as its own gas limit.
    function _stage(int24 dust, uint32 allowance, uint256 gapWeth) internal {
        if (dust != 0) _dustTicks(dust);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(mainPool, address(backing), gapWeth * 1e18);
        uint256 least = hook.minimumGasLimit(1);
        if (allowance < least) allowance = uint32(least);
        hook.setLimits(1, address(szr), allowance, 10e18, 1.0001e18);
        vm.recordLogs();
    }

    /// One swap of 20,000 USD in the dust pool with `gas`, as one external call, and what it
    /// did. The state is put back afterwards.
    function _swap(uint256 gas) internal returns (Outcome memory out) {
        uint256 snapshot = vm.snapshotState();
        vm.getRecordedLogs();
        uint256 held = szr.balanceOf(address(this));
        _cool();
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(usd);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(20_000e18),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (out.ok, out.reason) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
        out.received = szr.balanceOf(address(this)) - held;
        _scan(out);
        vm.revertToState(snapshot);
    }

    function _scan(Outcome memory out) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fills;
        for (uint256 i; i < logs.length; i++) {
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(manager)) {
                if (topic != IPoolManager.Swap.selector) continue;
                address sender = address(uint160(uint256(logs[i].topics[2])));
                if (sender == address(swapper)) fills++;
                continue;
            }
            if (logs[i].emitter != address(hook)) continue;
            if (topic != ArbitrageLogic.Arbitraged.selector) continue;
            (, uint256 profit) = abi.decode(logs[i].data, (bool, uint256));
            if (fills == 0) out.arbBefore++;
            else out.arbAfter++;
            out.profit += profit;
        }
    }

    /// A revert as the router returns it wraps the hook's own: look for a selector in it.
    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 i; i + 4 <= data.length; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), i))
            }
            if (bytes4(word) == wanted) return true;
        }
        return false;
    }

    /// The swap failed `InsufficientGas`, in the search before it and not the one after.
    function _failedBefore(Outcome memory out) internal pure returns (bool) {
        if (out.ok) return false;
        if (!_has(out.reason, ArbitrageLogic.InsufficientGas.selector)) return false;
        return _has(out.reason, IHooks.beforeSwap.selector);
    }

    /// The lowest gas, to within 10,000, at which a swap settles: `low` must fail and `high`
    /// settle. Bisection, so the tests ask for the boundary instead of naming it.
    function _lowest(uint256 low, uint256 high) internal returns (uint256) {
        assertFalse(_swap(low).ok, "the low end of the search fails");
        assertTrue(_swap(high).ok, "the high end of the search settles");
        while (high - low > 10_000) {
            uint256 mid = (low + high) / 2;
            if (_swap(mid).ok) high = mid;
            else low = mid;
        }
        return high;
    }

    /// Steps of 20,000 from `from` to 600,000 above it: once a swap settles, none above it
    /// fails, which a coarse sweep cannot see for a window of about 50,000.
    function _fine(uint256 from) internal {
        bool passed;
        for (uint256 gas = from; gas <= from + 600_000; gas += 20_000) {
            Outcome memory out = _swap(gas);
            if (out.ok) passed = true;
            else assertFalse(passed, "a swap failed that a lower one passed");
        }
        assertTrue(passed, "the sweep reached a passing swap");
    }

    /// Every row is either a swap that failed for want of gas before the swap, or one that
    /// settled and gave the swapper no more than `most`. Counts each.
    function _checkRows(uint256[] memory rows, uint256 most)
        internal
        returns (uint256 failed, uint256 settled)
    {
        for (uint256 i; i < rows.length; i++) {
            Outcome memory out = _swap(rows[i]);
            if (out.ok) {
                settled++;
                assertLe(out.received, most + most / 1e9, "the swapper received more");
                continue;
            }
            failed++;
            assertTrue(_failedBefore(out), "a failure is InsufficientGas before the swap");
        }
    }
}

/// @dev Finding 23-M-1 and its fix (`docs/specs/hook-partial-cycle.md`): before a swap, a
/// cycle that closes only part of a gap does not release the rule that closing it is required.
contract ArbitragePartialTest is PartialWorld {
    /// The proof of concept turned round. With dust in the pool, the first cycle is a partial
    /// one. A swap given just enough gas for it used to settle against the rest of the gap
    /// and gave the swapper 3.63% more than at ample gas, between 4.38M and 4.96M gas.
    function testDustNeverLetsASwapSettleAgainstTheGap() public {
        _stage(150, 8_000_000, 400_000);
        Outcome memory ample = _swap(30_000_000);
        assertTrue(ample.ok, "ample gas settles");
        uint256[] memory rows = new uint256[](10);
        rows[0] = 4_400_000;
        rows[1] = 4_600_000;
        rows[2] = 4_900_000;
        rows[3] = 5_100_000;
        rows[4] = 5_300_000;
        rows[5] = 5_650_000;
        rows[6] = 5_800_000;
        rows[7] = 6_400_000;
        rows[8] = hook.gasForSwap(1);
        rows[9] = hook.gasForSwap(1) + 400_000;
        (uint256 failed, uint256 settled) = _checkRows(rows, ample.received);
        assertGt(failed, 4, "the old window now fails for gas");
        assertGt(settled, 3, "and the rest settle");
    }

    /// The same world with no dust: the first cycle is full, so nothing changes. It fails below
    /// 4.4M and settles with the same result from there up, as before the change.
    function testWithoutDustNothingChanges() public {
        _stage(0, 8_000_000, 400_000);
        Outcome memory ample = _swap(30_000_000);
        assertTrue(ample.ok, "ample gas settles");
        assertTrue(_failedBefore(_swap(4_300_000)), "short of the floor still fails");
        uint256[] memory rows = new uint256[](5);
        rows[0] = 4_400_000;
        rows[1] = 4_700_000;
        rows[2] = 5_500_000;
        rows[3] = hook.gasForSwap(1);
        rows[4] = hook.gasForSwap(1) + 400_000;
        for (uint256 i; i < rows.length; i++) {
            Outcome memory out = _swap(rows[i]);
            assertTrue(out.ok, "settles");
            assertEq(out.received, ample.received, "with the same result");
        }
    }

    /// A gap too wide for three cycles: the rule ends after the third partial cycle, and a
    /// swap whose gas runs short there settles with the gap still open. With gas for two it
    /// reverts. This is the bound the design accepts. The boundary is found, not named.
    function testRuleEndsAfterThreePartialCycles() public {
        _stage(150, 8_000_000, 1_600_000);
        Outcome memory ample = _swap(30_000_000);
        assertTrue(ample.ok, "ample gas settles");
        assertTrue(_failedBefore(_swap(5_000_000)), "gas for one cycle fails");
        uint256 lowest = _lowest(5_000_000, 6_500_000);
        assertTrue(_failedBefore(_swap(lowest - 100_000)), "gas for two cycles fails");
        uint256[3] memory rows = [lowest, lowest + 100_000, lowest + 300_000];
        for (uint256 i; i < rows.length; i++) {
            Outcome memory out = _swap(rows[i]);
            assertTrue(out.ok, "gas for three cycles settles");
            assertEq(out.arbBefore, 3, "after three partial cycles");
            assertGt(out.received, ample.received, "with the gap still open");
        }
    }

    /// After a partial cycle that leaves nothing more to try, the rule ends before the search
    /// reads a new book, so a swap that cannot afford that read still settles. Without the
    /// empty round ending the rule it needs about 50,000 more gas. The lowest gas that
    /// settles is found, and the swap there and above it ends after two cycles.
    function testEmptyRoundEndsTheRule() public {
        _stage(150, 8_000_000, 400_000);
        uint256 lowest = _lowest(5_000_000, 6_500_000);
        assertTrue(_failedBefore(_swap(lowest - 100_000)), "less gas fails for gas");
        uint256[2] memory rows = [lowest, lowest + 100_000];
        for (uint256 i; i < rows.length; i++) {
            Outcome memory out = _swap(rows[i]);
            assertTrue(out.ok, "settles");
            assertEq(out.arbBefore, 2, "after two cycles and an empty round");
        }
    }

    /// More gas never fails a swap that less passed, in two dust worlds, from below the
    /// lowest passing gas to above `gasForSwap`.
    function testMoreGasNeverFailsInTheDustWorld() public {
        _stage(150, 8_000_000, 400_000);
        _ascending(5_200_000, 8_000_000, 400_000);
    }

    function testMoreGasNeverFailsWithAWideGap() public {
        _stage(150, 8_000_000, 1_600_000);
        _ascending(5_000_000, 9_000_000, 500_000);
    }

    /// The same two worlds in steps of 20,000 from the lowest passing gas to 600,000 above.
    function testFinePassInTheDustWorld() public {
        _stage(150, 8_000_000, 400_000);
        _fine(_lowest(5_000_000, 6_500_000));
    }

    function testFinePassWithAWideGap() public {
        _stage(150, 8_000_000, 1_600_000);
        _fine(_lowest(5_000_000, 6_500_000));
    }

    function _ascending(uint256 from, uint256 to, uint256 step) internal {
        bool passed;
        for (uint256 gas = from; gas <= to; gas += step) {
            Outcome memory out = _swap(gas);
            if (out.ok) passed = true;
            else assertFalse(passed, "a swap failed that a lower one passed");
        }
        assertTrue(passed, "the sweep reached a passing swap");
    }

    /// After the swap the rule is unchanged: only the first attempt is required, so a search
    /// that makes a partial first cycle and then runs short of gas stops quietly. Every row
    /// settles, with the search after the swap closing what it can.
    function testAfterTheSwapAPartialCycleNeverReverts() public {
        _stage(150, 8_000_000, 1_600_000);
        uint256[4] memory rows = [uint256(5_750_000), 6_250_000, 6_750_000, 7_250_000];
        for (uint256 i; i < rows.length; i++) {
            Outcome memory out = _swap(rows[i]);
            assertTrue(out.ok, "settles");
            assertGt(out.arbAfter, 0, "and the search after the swap closed what it could");
        }
    }

    /// `arb` and `sweep` are bounded by the hook's own allowance, never by the caller's gas,
    /// so they stop quietly where a swap would fail: never `Starved`, whatever the dust.
    function testArbAndSweepNeverRevertForGas() public {
        _stage(150, 8_000_000, 1_600_000);
        uint256[3] memory rows = [uint256(3_000_000), 4_500_000, 6_000_000];
        for (uint256 i; i < rows.length; i++) {
            uint256 snapshot = vm.snapshotState();
            _cool();
            (bool ok, bytes memory reason) =
                address(hook).call{ gas: rows[i] }(abi.encodeCall(hook.arb, (_id(usdPool))));
            assertTrue(ok, string(reason));
            vm.revertToState(snapshot);
            _cool();
            (ok, reason) = address(hook).call{ gas: rows[i] }(
                abi.encodeCall(hook.sweep, (1, address(szr)))
            );
            assertTrue(ok, string(reason));
            vm.revertToState(snapshot);
        }
    }

    /// `gasForSwap` is still enough with the new rule: a swap that brings it settles, with
    /// the hook's own allowance at the least it may be and far above.
    function testGasForSwapIsEnoughWithThreePartialCycles() public {
        _stage(150, 0, 1_600_000);
        Outcome memory out = _swap(hook.gasForSwap(1));
        assertTrue(out.ok, "settles with the allowance at the minimum");
        assertGe(out.arbBefore, 3, "after three cycles");
        hook.setLimits(1, address(szr), 30_000_000, 10e18, 1.0001e18);
        out = _swap(hook.gasForSwap(1));
        assertTrue(out.ok, "settles with the allowance far above");
        assertGe(out.arbBefore, 3, "after three cycles");
    }

    /// With costly leaders the world reaches two cycles before the swap, not three, so this
    /// shows that `gasForSwap` is enough for two costly cycles. Three near-budget cycles are
    /// covered by the arithmetic of `gasForSwap` alone, not by a test.
    function testGasForSwapIsEnoughWithTwoCostlyCycles() public {
        _costlyLeaders();
        _stage(150, 0, 1_600_000);
        Outcome memory out = _swap(hook.gasForSwap(1));
        assertTrue(out.ok, "settles with the allowance at the minimum");
        assertEq(out.arbBefore, 2, "after two costly cycles");
        hook.setLimits(1, address(szr), 30_000_000, 10e18, 1.0001e18);
        out = _swap(hook.gasForSwap(1));
        assertTrue(out.ok, "settles with the allowance far above");
        assertEq(out.arbBefore, 2, "after two costly cycles");
    }
}
