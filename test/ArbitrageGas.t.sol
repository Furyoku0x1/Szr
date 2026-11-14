// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { TwoHopRouter } from "./utils/Routers.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev What the hook's gas rules promise: what a swap costs, what gas it needs, that more
/// gas never hurts, and that cycles which cannot work cost a bounded amount once.
contract ArbitrageGasTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// A cycle that cannot work must cost a swap a bounded amount of gas once, not make it
    /// revert, as long as the swap brought the minimum a hooked swap needs. The failure is
    /// recorded, so the next swap does not pay for it again.
    function testUnworkableCycleCostsOnceAndNeverRevertsAFundedSwap() public {
        _fakeVenue(21_960, 1e22);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 1e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        vm.recordLogs();
        assertFalse(_swapWithGas(600_000), "too little gas for a hooked swap");
        assertEq(_failures(), 0, "nothing recorded by a failed swap");
        assertTrue(_swapWithGas(6_000_000), "funded swap goes through");
        assertGt(_failures(), 0, "failure recorded");
        uint256 spent = gasleft();
        assertTrue(_swapWithGas(6_000_000), "next swap goes through");
        spent -= gasleft();
        assertEq(_failures(), 0, "and does not pay for it again");
        assertLt(spent, 500_000, "ordinary cost");
    }

    function _swapWithGas(uint256 gas) internal returns (bool filled) {
        return _sellWithGas(gas, 1e15);
    }

    function _sellWithGas(uint256 gas, uint256 amount) internal returns (bool filled) {
        return _tradeWithGas(gas, amount, true);
    }

    function _tradeWithGas(uint256 gas, uint256 amount, bool sell)
        internal
        returns (bool filled)
    {
        // Earlier steps of the test touched these contracts' storage. A real swap starts
        // with none of it touched, which costs more, so start each one that way.
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        bool zeroForOne = (Currency.unwrap(usdPool.currency0) == address(szr)) == sell;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
    }

    /// Fills every group and every leader slot of the searched pool's group, so a search
    /// prices as many venues as it ever can, each other group two connecting pools away.
    function _fillGroups() internal returns (PoolKey memory last) {
        poolUnits = 20_000e18;
        hook.setLimits(1, 0, 0, 1.0001e18);
        TestAsset partner;
        for (uint256 index; index < 6; index++) {
            partner = new TestAsset();
            last = _addPartner(partner);
        }
        _addHooked(address(partner), 500);
        _addHooked(address(partner), 100);
        assertEq(hook.market(1).groups.length, hook.MAX_GROUPS(), "every group in use");
        assertEq(hook.leadersOf(1, address(partner)).length, hook.MAX_LEADERS(), "every slot");
    }

    /// The gas floors assume reading and ranking the venues costs at most a fixed amount
    /// each. This pins that at the most venues a search can price, read for the first time.
    function testScanCostStaysWithinItsAllowanceAtTheMostVenues() public {
        PoolKey memory last = _fillGroups();
        // A gap, so that every venue is taken all the way through to the depth reads.
        _trade(last, address(szr), 3_000e18);
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), address(hook));
        // Everything above touched these contracts' storage in this same transaction. Mark
        // it untouched again, so the reads below cost what a first read costs.
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        (uint256 book, uint256 best, uint256 venues, uint256 allowance, uint256 bookAllowance) =
            ArbitrageProbe(address(hook)).scanCost(_id(last));
        // The pool, two more leaders of its group, seven other groups, and Core.
        assertEq(venues, 11, "the most venues");
        assertLt(book, bookAllowance * venues, "reading prices within its allowance");
        assertLt(best, allowance * venues, "ranking within its allowance");
    }

    /// A pool that leads nothing in a full group prices one venue more than a leader does,
    /// which is the most there can be.
    function testScanCostStaysWithinItsAllowanceForAPoolThatDoesNotLead() public {
        PoolKey memory last = _fillGroups();
        PoolKey memory fourth = _addHooked(_partnerOf(last), 10_000);
        _trade(fourth, address(szr), 3_000e18);
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), address(hook));
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        (uint256 book, uint256 best, uint256 venues, uint256 allowance, uint256 bookAllowance) =
            ArbitrageProbe(address(hook)).scanCost(_id(fourth));
        // The pool, its group's three leaders, seven other groups, and Core.
        assertEq(venues, 12, "the most venues");
        assertLt(book, bookAllowance * venues, "reading prices within its allowance");
        assertLt(best, allowance * venues, "ranking within its allowance");
    }

    /// Giving a swap more gas must never make it fail where less gas succeeded, and a swap
    /// that goes through with a gap open must always have closed some of it. How much is
    /// retired is not required to rise with gas: more gas lets the search before the swap
    /// close more first, so the swap itself trades at a better price and leaves less behind.
    /// Checked across the range of gas limits, for a small and a large swap, in three
    /// states: one open gap, several pools priced apart, and a venue that cannot be traded
    /// sitting beside a real gap.
    function testMoreGasNeverMakesASwapFail() public {
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("one gap", 1e15, 9_000_000, 100_000);
        _assertMonotonic("one gap, large swap", 20_000e18, 9_000_000, 100_000);
        vm.revertToState(snapshot);
        // Two more pools on the same partner token, so all three are compared directly.
        PoolKey memory low = _addHooked(address(usd), 500);
        PoolKey memory high = _addHooked(address(usd), 100);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(low, address(szr), 150_000e18);
        _trade(high, address(usd), 150_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("pools priced apart", 1e15, 9_000_000, 100_000);
        _assertMonotonic("pools priced apart, large swap", 20_000e18, 9_000_000, 100_000);
        vm.revertToState(snapshot);
        _fakeVenue(21_960, 1e22);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("unworkable venue beside a real gap", 1e15, 9_000_000, 100_000);
        _assertMonotonic("unworkable venue, large swap", 20_000e18, 9_000_000, 100_000);
    }

    function _assertMonotonic(string memory state, uint256 amount, uint256 top, uint256 stride)
        internal
    {
        bool filled;
        uint256 inventory = core.unreleasedSupply();
        for (uint256 gas = 200_000; gas <= top; gas += stride) {
            uint256 snapshot = vm.snapshotState();
            bool ok = _sellWithGas(gas, amount);
            uint256 earned = core.unreleasedSupply() - inventory;
            vm.revertToState(snapshot);
            if (filled) assertTrue(ok, string.concat(state, ": more gas failed"));
            if (ok) {
                assertGt(earned, 0, string.concat(state, ": filled without closing a gap"));
            }
            filled = ok;
        }
        assertTrue(filled, string.concat(state, ": never filled"));
    }

    /// What a swap costs depends on the venues a search prices, not on how many pools are
    /// tracked. With the leaders settled, tracking sixty more pools leaves the cost of a
    /// swap with no gap where it was.
    function testSwapCostDoesNotGrowWithPoolsTracked() public {
        _addHooked(address(backing), 500);
        _addHooked(address(backing), 100);
        _addHooked(address(usd), 500);
        _addHooked(address(usd), 100);
        uint256 few = _noGapCost();
        assertLt(few, 420_000, "six pools, all leaders");
        poolUnits = 1_000e18;
        for (uint256 index; index < 60; index++) {
            address partner = index % 2 == 0 ? address(backing) : address(usd);
            _addHooked(partner, uint24(1_000 + index));
        }
        assertEq(hook.market(1).poolCount, 66);
        uint256 many = _noGapCost();
        assertLt(many, few + few / 50, "sixty more pools tracked, same cost");
    }

    function _noGapCost() internal returns (uint256 spent) {
        _trade(usdPool, address(szr), 1e18);
        _trade(usdPool, address(szr), 1e15);
        spent = gasleft();
        _trade(usdPool, address(szr), 1e15);
        spent -= gasleft();
    }

    /// When the hook's own gas allowance runs out with a cycle still to try, it says so
    /// instead of going quiet. Here the smallest allowance is spent on three venues that
    /// cannot be traded, one more than it must cover, leaving too little for the real gap,
    /// which a later swap takes.
    function testSearchCutShortIsReported() public {
        _threeUnworkableLeaders();
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        _trade(usdPool, address(szr), 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 reported;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.SearchCutShort.selector) reported++;
        }
        assertGt(reported, 0, "cut short and reported");
        _trade(usdPool, address(szr), 1e15);
        assertGt(core.unreleasedSupply(), inventory, "real gap taken afterwards");
    }

    /// The same property with every group and leader slot in use, a realistic swap size,
    /// and a gap already open, where the gas a search needs is at its largest.
    function testMoreGasNeverMakesASwapFailAtTheMostVenues() public {
        _fillGroups();
        _trade(usdPool, address(szr), 5_000e18);
        hook.setLimits(1, uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        _assertMonotonic("the most venues", 2_000e18, 24_000_000, 500_000);
    }

    /// The search before a swap spends its budget on a cycle that cannot work, and the swap
    /// then opens a gap of its own for the search after it. At the smallest gas limit that
    /// lets the swap through, the failure must have been recorded and the swap's own gap
    /// closed: the first search must not have left the second one short.
    function testUnworkableCycleBeforeTheSwapDoesNotStarveTheSearchAfterIt() public {
        _fakeVenue(21_960, 1e22);
        uint256 inventory = core.unreleasedSupply();
        for (uint256 gas = 400_000; gas <= 9_000_000; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool filled = _sellWithGas(gas, 20_000e18);
            uint256 failures = _failures();
            uint256 retired = core.unreleasedSupply() - inventory;
            vm.revertToState(snapshot);
            if (!filled) continue;
            assertGt(failures, 0, "failure recorded by the first swap through");
            assertGt(retired, 0, "the swap's own gap was closed");
            return;
        }
        fail();
    }

    /// Three venues that cannot be traded rank above a real gap, and the swap is a
    /// purchase that would close that gap itself if the hook stood aside. Whatever the gas
    /// limit, more gas must not turn a swap that went through into one that fails.
    function testMoreGasNeverFailsAPurchaseBesideThreeUnworkableVenues() public {
        _threeUnworkableLeaders();
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        bool filled;
        for (uint256 gas = 400_000; gas <= 12_000_000; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            bool ok = _tradeWithGas(gas, 20_000e18, false);
            vm.revertToState(snapshot);
            if (filled) assertTrue(ok, "more gas failed");
            filled = ok;
        }
        assertTrue(filled, "never filled");
    }

    /// The same property where every cycle crosses two connecting pools: the only other
    /// venue is an SZR/EUR pool, reached from the SZR/USD pool through WETH.
    function testMoreGasNeverMakesATwoHopSwapFail() public {
        _addPartner(new TestAsset());
        _untrack(mainPool);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("two hops", 20_000e18, 9_000_000, 100_000);
    }

    /// The same property with liquidity concentrated in narrow ranges around the price, so
    /// that the user's swap and the hook's cycles both cross many ticks and cost more.
    function testMoreGasNeverMakesASwapFailAcrossDenseTicks() public {
        (, int24 tick,,) = manager.getSlot0(usdPool.toId());
        int24 base = tick / 60 * 60;
        for (int24 step = -12; step < 12; step++) {
            provider.modifyLiquidity(
                usdPool,
                IPoolManager.ModifyLiquidityParams(
                    base + step * 60, base + (step + 1) * 60, int256(3_000_000e18), 0
                ),
                ""
            );
        }
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 80_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("dense ticks", 60_000e18, 12_000_000, 100_000);
    }

    function _allowances() internal returns (uint256 swap, uint256 attempt) {
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), address(hook));
        return ArbitrageProbe(address(hook)).gasAllowances();
    }

    /// Dust liquidity in `count` narrow ranges either side of the price, which costs next to
    /// nothing and makes every swap through them cross that many initialised ticks.
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

    /// The search before a swap leaves a fixed amount of gas for the swap itself. This pins
    /// what that covers: a swap moving the price about a tenth through fifteen ranges of
    /// dust liquidity, far more initialised ticks than a pool normally has in its path.
    function testGasLeftForTheSwapCoversFifteenTickRanges() public {
        (uint256 allowance,) = _allowances();
        _dustTicks(20);
        hook.setLimits(1, 0, 0, 1.0001e18);
        vm.cool(address(manager));
        uint256 spent = gasleft();
        _trade(usdPool, address(szr), 50_000e18);
        spent -= gasleft();
        assertLt(spent, allowance, "swap fits in what is left for it");
    }

    /// When a swap costs more than that, because someone has littered its path with ticks,
    /// more gas must still never make it fail.
    function testMoreGasNeverMakesASwapFailThroughLitteredTicks() public {
        _dustTicks(60);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(mainPool, address(backing), 200_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        _assertMonotonic("littered ticks", 150_000e18, 14_000_000, 100_000);
    }

    /// One try at a cycle may use at most half the cycle's budget. This pins that the
    /// heaviest ordinary cycle, across two connecting pools, fits: the whole cost the hook
    /// adds to a swap for one such cycle, searching and retiring included, is under it.
    function testOneTryCoversACycleAcrossTwoConnectingPools() public {
        (, uint256 allowance) = _allowances();
        _addPartner(new TestAsset());
        _untrack(mainPool);
        _trade(usdPool, address(szr), 1e15);
        uint256 quiet = gasleft();
        _trade(usdPool, address(szr), 1e15);
        quiet -= gasleft();
        vm.recordLogs();
        uint256 busy = gasleft();
        _trade(usdPool, address(szr), 20_000e18);
        busy -= gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 cycles;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.Arbitraged.selector) cycles++;
        }
        assertEq(cycles, 1, "one cycle");
        assertLt(busy - quiet, allowance, "one cycle and its overheads fit in one try");
    }

    /// One transaction that swaps through two hooked pools runs four searches. With gaps
    /// open on both, more gas must never make it fail.
    function testMoreGasNeverMakesTwoHookedSwapsFail() public {
        PoolKey memory wethPool = _addHooked(address(backing), 500);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        _trade(wethPool, address(backing), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        TwoHopRouter router = new TwoHopRouter(manager);
        usd.approve(address(router), type(uint256).max);
        bytes memory trade =
            abi.encodeCall(router.trade, (usdPool, wethPool, address(usd), 20_000e18));
        uint256 inventory = core.unreleasedSupply();
        bool filled;
        for (uint256 gas = 400_000; gas <= 20_000_000; gas += 200_000) {
            uint256 snapshot = vm.snapshotState();
            vm.cool(address(manager));
            vm.cool(address(hook));
            vm.cool(address(core));
            (bool ok,) = address(router).call{ gas: gas }(trade);
            uint256 retired = core.unreleasedSupply() - inventory;
            vm.revertToState(snapshot);
            if (filled) assertTrue(ok, "more gas failed");
            if (ok) assertGt(retired, 0, "filled without closing a gap");
            filled = ok;
        }
        assertTrue(filled, "never filled");
    }

    /// Three venues that cannot be traded, as the three leaders of the searched pool's
    /// group, so that every one of them is compared with it.
    function _threeUnworkableLeaders() internal {
        bytes32[] memory fakes = new bytes32[](3);
        fakes[0] = _id(_fakeVenueWithFee(21_960, 1e22, 100));
        fakes[1] = _id(_fakeVenueWithFee(21_960, 1e22, 200));
        fakes[2] = _id(_fakeVenueWithFee(21_960, 1e22, 300));
        _setLeaders(address(usd), fakes);
    }
}
