// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";

contract ArbitrageHookTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function testTriangleAfterSaleRetiresProfit() public {
        _assertSaleBackrun(usdPool);
    }

    function testTriangleAfterPurchaseRetiresProfit() public {
        _assertPurchaseBackrun(usdPool, address(usd));
    }

    /// The same cycles with SZR as the pool's first token instead of its second.
    function testTriangleWithSzrAsFirstToken() public {
        address high = address(uint160(address(szr)) + 1);
        deployCodeTo("TestAsset.sol:TestAsset", high);
        PoolKey memory pool = _addPartner(TestAsset(high));
        assertEq(Currency.unwrap(pool.currency0), address(szr));
        _assertSaleBackrun(pool);
        _assertPurchaseBackrun(pool, high);
        assertEq(TestAsset(high).balanceOf(address(hook)), 0, "hook partner");
    }

    /// Two pools on the same pair need no connecting pool: a second, hooked SZR/WETH pool
    /// is traded against the hookless main one in both directions.
    function testTwoPoolCycleWithoutConnector() public {
        PoolKey memory pool = _addHooked(address(backing), 500);
        _assertSaleBackrun(pool);
        _assertPurchaseBackrun(pool, address(backing));
    }

    /// Liquidity's own swaps are never backrun, even with a gap open.
    function testManagerSwapsAreLeftAlone() public {
        PoolKey memory pool = _addHooked(address(backing), 500);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(pool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 0, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(backing);
        uint256 held = locker.heldPrincipal(address(backing));
        assertGt(held, 0);
        locker.swapPrincipal(
            pool,
            zeroForOne,
            held / 2,
            1,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        assertEq(core.unreleasedSupply(), inventory, "manager swap not backrun");
        _trade(pool, address(szr), 1e18);
        assertGt(core.unreleasedSupply(), inventory, "the gap was there");
        _assertHookEmpty();
    }

    /// The main pool has no hook, so a gap against NAV is closed through `arb`: buy SZR in
    /// the pool with WETH and redeem only enough of it to repay that WETH.
    function testRedeemsWhenMainPoolTradesBelowNav() public {
        // With no other venue, the only cycle is the one through Core.
        _untrack(usdPool);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        uint256 nav = core.NAV();
        assertGt(nav, _price(mainPool), "pool below NAV");
        uint256 inventory = core.unreleasedSupply();
        uint256 profit = hook.arb(_id(mainPool));
        assertGt(profit, 0, "profit");
        // Redeemed SZR and the donated profit both return to unreleased inventory.
        assertGt(core.unreleasedSupply(), inventory + profit, "redeemed and retired");
        // Buying stops where the pool price plus its 0.3% fee meets NAV as it was. Retiring
        // the profit afterwards lifts NAV, which is a new, smaller gap for the next call.
        assertApproxEqRel(_price(mainPool), nav * 997 / 1000, 1e15, "price at NAV");
        assertGt(core.NAV(), nav, "retiring lifts NAV");
        _assertHookEmpty();
    }

    /// The triggering swap must go through whatever happens to the backrun.
    function testSwapSucceedsWhenTheBackrunCannotProfit() public {
        hook.setLimits(1, 8_000_000, type(uint128).max, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 received = usd.balanceOf(address(this));
        _trade(usdPool, address(szr), 50_000e18);
        assertGt(usd.balanceOf(address(this)), received, "swap filled");
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        assertEq(core.unreleasedSupply(), inventory, "switched off");
        _assertHookEmpty();
    }

    function testOnlyTheManagerConfigures() public {
        vm.startPrank(alice);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.track(0);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.untrack(_id(usdPool));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setConnector(1, mainPool, false);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLimits(1, 0, 0, 1.0001e18);
        vm.stopPrank();
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setLimits(1, 8_000_000, 0, 0.99e18);
        uint32 tooLittle = uint32(hook.minimumGasLimit(1) - 1);
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setLimits(1, tooLittle, 0, 1.0001e18);
        vm.startPrank(alice);
        vm.expectRevert(ArbitrageHook.NotSelf.selector);
        hook.search(_id(usdPool), true, false, alice);
        vm.stopPrank();
        _untrack(usdPool);
        assertEq(hook.market(1).poolCount, 1);
        vm.expectRevert(ArbitrageHook.UnknownPool.selector);
        hook.arb(_id(usdPool));
    }

    /// A gap opened on the hookless main pool is taken by the hook before the next swap in
    /// a hooked pool trades, so that swap cannot collect it.
    function testGapIsTakenBeforeTheSwapTrades() public {
        _trade(mainPool, address(backing), 600_000e18);
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, 0, 0, 1.0001e18);
        uint256 without = _buyOnUsdPool();
        vm.revertToState(snapshot);
        uint256 inventory = core.unreleasedSupply();
        uint256 aligned = _buyOnUsdPool();
        assertGt(core.unreleasedSupply(), inventory, "gap retired");
        assertLt(aligned, without * 97 / 100, "buyer paid the aligned price");
        _assertHookEmpty();
    }

    function _buyOnUsdPool() internal returns (uint256 received) {
        uint256 held = szr.balanceOf(address(this));
        _trade(usdPool, address(usd), 1_000e18);
        received = szr.balanceOf(address(this)) - held;
    }

    /// Two partner tokens with no pool between them are still crossed, through WETH.
    function testCrossesTwoConnectorsThroughWeth() public {
        TestAsset eur = new TestAsset();
        _addPartner(eur);
        _untrack(mainPool);
        // The only other venue is the SZR/EUR pool, two connecting pools away.
        uint256 inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 50_000e18);
        uint256 afterSale = core.unreleasedSupply();
        assertGt(afterSale, inventory, "sale backrun");
        _trade(usdPool, address(usd), 100_000e18);
        assertGt(core.unreleasedSupply(), afterSale, "purchase backrun");
        assertEq(eur.balanceOf(address(hook)), 0, "hook eur");
        _assertHookEmpty();
    }

    /// A pool whose partner token has no connecting pool cannot be part of a cycle with
    /// the others, however wide the gap looks, so nothing is attempted.
    function testUnreachablePartnerIsNeverAttempted() public {
        TestAsset island = new TestAsset();
        _approve(island);
        PoolKey memory pool = _register(address(island), 3_000, uint160(2 << 96));
        _provide(pool, 1_000_000e18);
        vm.expectCall(address(hook), abi.encodeWithSelector(hook.execute.selector), 0);
        assertEq(hook.arb(_id(pool)), 0, "nothing to trade against");
    }

    /// An empty pool sitting at a stale price shows the widest gap of all. It is skipped
    /// instead of using up the search.
    function testEmptyStalePoolDoesNotBlockOthers() public {
        _register(address(usd), 100, uint160(2 << 96));
        _assertSaleBackrun(usdPool);
        _assertPurchaseBackrun(usdPool, address(usd));
    }

    /// Closing a gap against the main pool moves the main pool, which opens a smaller gap
    /// between it and a third pool. The same search follows on and closes that too.
    function testFollowsTheVenueItJustMoved() public {
        PoolKey memory third = _addHooked(address(backing), 500);
        _trade(third, address(szr), 1e15);
        assertEq(hook.arb(_id(third)), 0, "third pool aligned");
        hook.setLimits(1, 8_000_000, 0, 1.0001e18);
        vm.recordLogs();
        _trade(usdPool, address(szr), 200_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 followed;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.Arbitraged.selector) continue;
            if (logs[index].topics[1] != _id(usdPool)) followed++;
        }
        assertGt(followed, 0, "searched from another pool");
        _assertHookEmpty();
    }

    /// A swap sent with too little gas for any backrun fails as a whole. With enough for
    /// some cycles but not all, the ones completed are kept.
    function testShortGasKeepsCompletedCycles() public {
        // Two more pools on the same partner token, so all three are compared directly.
        PoolKey memory low = _addHooked(address(usd), 500);
        PoolKey memory high = _addHooked(address(usd), 100);
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(low, address(szr), 150_000e18);
        _trade(high, address(usd), 150_000e18);
        hook.setLimits(1, 8_000_000, 0, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 snapshot = vm.snapshotState();
        assertFalse(_tradeWithGas(SHORT_GAS), "too little for any cycle");
        assertTrue(_shortGasError(), "fails with the hook's own error");
        assertTrue(_tradeWithGas(9_000_000), "full run");
        uint256 full = core.unreleasedSupply() - inventory;
        vm.revertToState(snapshot);
        assertTrue(_tradeWithGas(PARTIAL_GAS), "partial run");
        uint256 kept = core.unreleasedSupply() - inventory;
        assertGt(kept, 0, "completed cycles kept");
        assertLt(kept, full, "not every cycle fitted");
    }

    uint256 internal constant SHORT_GAS = 300_000;

    uint256 internal constant PARTIAL_GAS = 4_600_000;

    /// The pool manager wraps a hook's error, so look for its selector inside the data.
    function _shortGasError() internal returns (bool found) {
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(szr);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -1e18,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (, bytes memory data) = address(swapper).call{ gas: SHORT_GAS }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
        bytes4 wanted = ArbitrageHook.InsufficientGas.selector;
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
    }

    function _tradeWithGas(uint256 gas) internal returns (bool filled) {
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(szr);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -1e18,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
    }
}
