// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { MeddlingHook } from "./utils/MeddlingHook.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

/// @dev What the audit found or suspected: hostile pool states, unusual routers, and venues
/// built to waste swappers' gas.
contract ArbitrageHardeningTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// Anyone can push an empty pool's price to either end of the range for nothing. That
    /// must not stop the hook working for every other pool.
    function testExtremePriceOnAnEmptyPoolDoesNotDisableTheHook() public {
        PoolKey memory hollow = _register(address(usd), 100, uint160(1 << 96));
        uint256 snapshot = vm.snapshotState();
        _trade(hollow, address(szr), 1e30);
        _assertSaleBackrun(usdPool);
        vm.revertToState(snapshot);
        _trade(hollow, address(usd), 1e30);
        _assertSaleBackrun(usdPool);
        _assertPurchaseBackrun(usdPool, address(usd));
        // A search centred on the empty pool itself finds nothing and does not revert.
        assertEq(hook.arb(_id(hollow)), 0);
    }

    /// Every price the scan reads is pushed to an extreme at once: an empty SZR pool, and
    /// two empty connecting pools that would be crossed one after the other. The scan must
    /// still finish, and the one sound cycle must still run.
    function testScanSurvivesExtremePricesEverywhere() public {
        TestAsset eur = new TestAsset();
        _approve(eur);
        PoolKey memory eurPool = _register(address(eur), 3_000, uint160(1 << 96));
        PoolKey memory hollow = _register(address(usd), 100, uint160(1 << 96));
        PoolKey memory eurRoute = _emptyRoute(address(eur));
        for (uint256 way; way < 4; way++) {
            uint256 snapshot = vm.snapshotState();
            _trade(hollow, way % 2 == 0 ? address(szr) : address(usd), 1e30);
            _trade(eurPool, way % 2 == 0 ? address(eur) : address(szr), 1e30);
            _trade(eurRoute, way < 2 ? address(eur) : address(backing), 1e30);
            assertEq(hook.arb(_id(eurPool)), 0, "empty pool");
            assertEq(hook.arb(_id(hollow)), 0, "empty pool");
            _assertSaleBackrun(usdPool);
            vm.revertToState(snapshot);
        }
    }

    function _emptyRoute(address partner) internal returns (PoolKey memory route) {
        bool wethFirst = address(backing) < partner;
        route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : partner),
            Currency.wrap(wethFirst ? partner : address(backing)),
            500,
            10,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        locker.registerRoute(route);
        hook.setConnector(1, route, true);
    }

    /// A dynamic-fee pool takes its fee from its hook, and this hook never sets one. Such a
    /// pool would trade for nothing for ever, so the hook refuses to track it.
    function testDynamicFeePoolOnThisHookIsRefused() public {
        Liquidity.PoolConfig memory config = _config();
        config.feePips = 0x800000;
        config.hooks = IHooks(address(hook));
        FeeCollector.AssetConfig memory unused;
        uint256 id = locker.addPool(config, unused);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.track(id);
    }

    /// Clearing a connecting pool has to name the pool that is set. Naming another pool
    /// on the same pair must not clear it.
    function testClearingAConnectorMustNameTheOneThatIsSet() public {
        PoolKey memory other = _emptyRoute(address(usd));
        // `_emptyRoute` replaced the connecting pool; put the original back.
        bool wethFirst = address(backing) < address(usd);
        PoolKey memory original = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(usd)),
            Currency.wrap(wethFirst ? address(usd) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        hook.setConnector(1, original, true);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setConnector(1, other, false);
        hook.setConnector(1, original, false);
        assertEq(
            hook.connector(
                1, Currency.unwrap(original.currency0), Currency.unwrap(original.currency1)
            ),
            bytes32(0)
        );
    }

    /// A venue priced absurdly far from every other is not a gap to close. It is never
    /// attempted, however deep it claims to be, and real cycles still run.
    function testAbsurdlyPricedVenueIsIgnored() public {
        _fakeVenue(693_120, 1e30);
        vm.recordLogs();
        _assertSaleBackrun(usdPool);
        _assertPurchaseBackrun(usdPool, address(usd));
        assertEq(_failures(), 0, "never attempted");
    }

    /// A venue that looks like a real gap but cannot be traded fails, is set aside
    /// for a while, and stops costing every later swap two failed attempts. The cycles
    /// that do work still run in the meantime.
    function testVenueThatFailsIsSetAsideNotRetried() public {
        PoolKey memory fake = _fakeVenue(21_960, 1e22);
        vm.recordLogs();
        _assertSaleBackrun(usdPool);
        // Once for each pool the search was centred on: the pool traded and the one it
        // moved on to.
        assertGt(_failures(), 0, "failed at first");
        // SZR looks cheap in the fake venue, so the failed cycle sells in the pool searched.
        assertGt(
            hook.benchedUntil(_id(usdPool), _id(fake), false), block.timestamp, "set aside"
        );
        _trade(usdPool, address(usd), 50_000e18);
        _trade(usdPool, address(szr), 50_000e18);
        assertEq(_failures(), 0, "not retried while set aside");
        vm.warp(hook.benchedUntil(_id(usdPool), _id(fake), false));
        _trade(usdPool, address(usd), 50_000e18);
        assertGt(_failures(), 0, "tried again afterwards");
    }

    /// Forcing one marginal cycle to fail must not switch that pair off for a real gap.
    /// The profit floor is set just above what a small cycle returns, so it fails and its
    /// pair is set aside; a much wider gap between the same two pools is still taken.
    function testMarginalFailureDoesNotSuppressARealGap() public {
        hook.setLimits(1, 8_000_000, 0, 1.0001e18);
        _trade(usdPool, address(szr), 1e15);
        uint256 snapshot = vm.snapshotState();
        uint256 inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 3_000e18);
        uint256 small = core.unreleasedSupply() - inventory;
        assertGt(small, 0, "small cycle earns something");
        vm.revertToState(snapshot);
        hook.setLimits(1, 8_000_000, uint128(small + 1), 1.0001e18);
        vm.recordLogs();
        _trade(usdPool, address(szr), 3_000e18);
        assertGt(_failures(), 0, "marginal cycle failed");
        assertGt(
            hook.benchedUntil(_id(usdPool), _id(mainPool), true), block.timestamp, "set aside"
        );
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 50_000e18);
        assertGt(core.unreleasedSupply() - inventory, small * 10, "real gap still taken");
    }

    /// The pool manager can charge its own fee on top of a pool's. The hook prices it in,
    /// so its cycles are still sized to succeed first time.
    function testProtocolFeeIsPricedIn() public {
        manager.setProtocolFeeController(address(this));
        // 0.1% in each direction, the most the pool manager allows.
        manager.setProtocolFee(usdPool, 1000 | (1000 << 12));
        manager.setProtocolFee(mainPool, 1000 | (1000 << 12));
        vm.recordLogs();
        uint256 inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 50_000e18);
        uint256 afterSale = core.unreleasedSupply();
        assertGt(afterSale, inventory, "sale backrun");
        _trade(usdPool, address(usd), 100_000e18);
        assertGt(core.unreleasedSupply(), afterSale, "purchase backrun");
        assertEq(_failures(), 0, "no failed cycles");
        _assertHookEmpty();
    }

    /// The size of a cycle is estimated from the liquidity in range at the current price,
    /// which anyone can inflate with a narrow position the trade leaves at once. That makes
    /// the estimate far too small. The whole gap is tried as well, so the cycle still runs
    /// instead of failing at every size and being set aside.
    function testInflatedLiquidityDoesNotGetARealPairSetAside() public {
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        // Park the price at the very end of one tick range, on the side the hook's own
        // purchase will leave, then add 200,000 times the pool's liquidity in that range.
        usd.mint(address(this), 1_000_000_000e18);
        bool szrFirst = Currency.unwrap(usdPool.currency0) == address(szr);
        (, int24 tick,,) = manager.getSlot0(usdPool.toId());
        int24 edge = szrFirst ? (tick / 60 - 1) * 60 : (tick / 60 + 1) * 60;
        uint160 parkedAt = TickMath.getSqrtPriceAtTick(edge);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            usdPool,
            IPoolManager.SwapParams(szrFirst, -1e30, szrFirst ? parkedAt - 1 : parkedAt),
            settings,
            ""
        );
        provider.modifyLiquidity(
            usdPool,
            IPoolManager.ModifyLiquidityParams(
                szrFirst ? edge - 60 : edge,
                szrFirst ? edge : edge + 60,
                int256(200_000_000_000e18),
                0
            ),
            ""
        );
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        hook.arb(_id(usdPool));
        assertGt(core.unreleasedSupply() - inventory, 1_000e18, "real gap taken");
        assertEq(_failures(), 0, "nothing set aside");
    }

    /// Core can refuse a redemption, for instance when its cash is lent out. The cycle
    /// through Core then fails and is set aside; the swap is unaffected.
    function testCoreRefusingRedemptionDoesNotAffectTheSwap() public {
        PoolKey memory pool = _addHooked(address(backing), 500);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        vm.mockCallRevert(
            address(core), abi.encodeWithSelector(core.redeem.selector), "no cash"
        );
        uint256 held = backing.balanceOf(address(this));
        vm.recordLogs();
        _trade(pool, address(szr), 1_000e18);
        assertGt(backing.balanceOf(address(this)), held, "swap filled");
        assertGt(_failures(), 0, "cycle through Core failed and was recorded");
        assertGt(hook.benchedUntil(_id(pool), bytes32(0), true), block.timestamp, "set aside");
        _assertHookEmpty();
    }

    /// If Core refuses the donation, the whole search is undone and the swap goes ahead as
    /// if the hook were not there. Nothing is left with the hook.
    function testCoreRefusingTheDonationUndoesTheSearch() public {
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        vm.mockCallRevert(
            address(core), abi.encodeWithSelector(core.donateSzr.selector), "closed"
        );
        uint256 inventory = core.unreleasedSupply();
        uint256 held = usd.balanceOf(address(this));
        vm.recordLogs();
        _trade(usdPool, address(szr), 1_000e18);
        assertGt(usd.balanceOf(address(this)), held, "swap filled");
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        _assertHookEmpty();
        // The search says it was undone, and by what.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 undone;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.SearchUndone.selector) continue;
            assertEq(bytes4(abi.decode(logs[index].data, (bytes32))), bytes4("clos"));
            undone++;
        }
        assertGt(undone, 0, "undone search reported");
        vm.clearMockedCalls();
        _trade(usdPool, address(szr), 1e15);
        assertGt(core.unreleasedSupply(), inventory, "gap closed once Core accepts again");
    }

    /// Two venues that cannot be traded outrank a real gap. The search before the swap must
    /// get past both and still close the real gap, so the swap pays the aligned price and
    /// does not collect the gap itself.
    function testUnworkableVenuesDoNotLetASwapCollectTheGap() public {
        _fakeVenueWithFee(21_960, 1e22, 100);
        _fakeVenueWithFee(21_960, 1e22, 200);
        _trade(mainPool, address(backing), 600_000e18);
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, 0, 0, 1.0001e18);
        uint256 without = _buySzr();
        vm.revertToState(snapshot);
        uint256 inventory = core.unreleasedSupply();
        uint256 aligned = _buySzr();
        assertLt(aligned, without * 97 / 100, "paid the aligned price");
        assertGt(core.unreleasedSupply(), inventory, "gap retired");
    }

    /// A partner token with six decimals against SZR's eighteen puts the pool's raw price a
    /// million million away from one, in a pool and in its connecting pool. Sizing, limits
    /// and directions must hold there as they do at a price of one.
    function testCyclesAtASkewedPrice() public {
        TestAsset small = new TestAsset();
        _approve(small);
        backing.mint(address(this), 60_000_000e18);
        bool szrFirst = address(szr) < address(small);
        // One whole SZR for a millionth of a millionth of its raw units.
        uint256 unit = 1 << 96;
        uint160 poolPrice = uint160(szrFirst ? unit / 1e6 : unit * 1e6);
        PoolKey memory pool = _register(address(small), 3_000, poolPrice);
        _provide(pool, 1e18);
        bool wethFirst = address(backing) < address(small);
        PoolKey memory route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(small)),
            Currency.wrap(wethFirst ? address(small) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(wethFirst ? unit / 1e6 : unit * 1e6));
        _provide(route, 5e19);
        locker.registerRoute(route);
        hook.setConnector(1, route, true);
        uint256 inventory = core.unreleasedSupply();
        _trade(pool, address(szr), 50_000e18);
        uint256 afterSale = core.unreleasedSupply();
        assertGt(afterSale - inventory, 100e18, "sale backrun");
        _trade(pool, address(small), 100_000e6);
        assertGt(core.unreleasedSupply() - afterSale, 100e18, "purchase backrun");
        assertEq(small.balanceOf(address(hook)), 0, "hook partner");
        _assertHookEmpty();
    }

    /// A swap that asks for an exact amount out is searched like any other.
    function testExactOutputSwapIsBackrun() public {
        uint256 inventory = core.unreleasedSupply();
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(szr);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            usdPool,
            IPoolManager.SwapParams(
                zeroForOne,
                int256(40_000e18),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        assertGt(core.unreleasedSupply(), inventory, "gap retired");
        _assertHookEmpty();
    }

    /// The search before a swap moves the pool's price. A swap whose own price limit lies
    /// between the old price and the aligned one can then no longer trade and reverts, as
    /// the README says. This pins that behaviour so a change to it is noticed.
    function testPriceLimitBetweenOldAndAlignedPriceReverts() public {
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        (uint160 stale,,,) = manager.getSlot0(usdPool.toId());
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        // A purchase of SZR moves the price the same way the hook's own purchase does.
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(usd);
        uint160 limit = zeroForOne ? stale - stale / 200 : stale + stale / 200;
        PoolSwapTest.TestSettings memory settings;
        vm.expectPartialRevert(Pool.PriceLimitAlreadyExceeded.selector);
        swapper.swap(usdPool, IPoolManager.SwapParams(zeroForOne, -1e18, limit), settings, "");
    }

    /// Switching the hook off switches the permissionless entry off too.
    function testArbDoesNothingWhileTheHookIsOff() public {
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        uint256 inventory = core.unreleasedSupply();
        assertEq(hook.arb(_id(usdPool)), 0);
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        assertGt(hook.arb(_id(usdPool)), 0, "back on");
    }

    /// A gap setting above the widest gap the hook will act on would switch it off
    /// without saying so, so it is refused.
    function testMinimumEdgeAboveTheWidestGapIsRefused() public {
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setLimits(1, 8_000_000, 10e18, 4e18 + 1);
        hook.setLimits(1, 8_000_000, 10e18, 4e18);
    }

    /// The size of a cycle is estimated from liquidity in range at the current price.
    /// Liquidity parked just beyond the price, in the direction the hook trades, is not
    /// counted, and a price limit alone would have the hook buy a large part of it at every
    /// size and fail. The first leg is bounded by amount as well, so the hook takes the gap
    /// from that liquidity instead, and nothing is set aside.
    function testLiquidityWallAheadOfThePriceDoesNotGetAPairSetAside() public {
        // A gap of a few percent, small beside what the wall holds.
        _trade(mainPool, address(backing), 200_000e18);
        bool szrFirst = Currency.unwrap(usdPool.currency0) == address(szr);
        // Park the price right at the end of a tick range, so the wall starts at once.
        hook.setLimits(1, 0, 0, 1.0001e18);
        (, int24 tick,,) = manager.getSlot0(usdPool.toId());
        int24 edge = szrFirst ? (tick / 60 + 1) * 60 : (tick / 60 - 1) * 60;
        uint160 parkedAt = TickMath.getSqrtPriceAtTick(edge);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            usdPool,
            IPoolManager.SwapParams(!szrFirst, -1e30, szrFirst ? parkedAt - 1 : parkedAt + 1),
            settings,
            ""
        );
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        // The hook buys SZR here, which moves the price up when SZR is the first token
        // and down when it is the second. The wall is the tick range it would enter.
        provider.modifyLiquidity(
            usdPool,
            IPoolManager.ModifyLiquidityParams(
                szrFirst ? edge : edge - 60,
                szrFirst ? edge + 60 : edge,
                int256(100_000_000e18),
                0
            ),
            ""
        );
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        assertGt(hook.arb(_id(usdPool)), 0, "gap taken");
        assertGt(core.unreleasedSupply(), inventory, "and retired");
        assertEq(_failures(), 0, "nothing set aside");
        _assertHookEmpty();
    }

    /// The pool manager's own fee can differ by direction. The hook prices the larger of
    /// the two for both, which can only make a cycle look a little less profitable than it
    /// is, so cycles still succeed first time whichever direction carries the fee.
    function testUnevenProtocolFeeIsPricedIn() public {
        manager.setProtocolFeeController(address(this));
        for (uint256 side; side < 2; side++) {
            uint256 snapshot = vm.snapshotState();
            uint24 fee = side == 0 ? uint24(1000) : uint24(1000 << 12);
            manager.setProtocolFee(usdPool, fee);
            manager.setProtocolFee(mainPool, fee);
            vm.recordLogs();
            uint256 inventory = core.unreleasedSupply();
            _trade(usdPool, address(szr), 50_000e18);
            uint256 afterSale = core.unreleasedSupply();
            assertGt(afterSale, inventory, "sale backrun");
            _trade(usdPool, address(usd), 100_000e18);
            assertGt(core.unreleasedSupply(), afterSale, "purchase backrun");
            assertEq(_failures(), 0, "no failed cycles");
            _assertHookEmpty();
            vm.revertToState(snapshot);
        }
    }

    /// A connecting pool can carry someone else's hook. Here that hook tries to start the
    /// arbitrage hook's search from inside every swap through it. It is refused each time,
    /// and the cycles that cross it still complete.
    function testConnectingPoolWithAMeddlingHook() public {
        TestAsset eur = new TestAsset();
        _approve(eur);
        backing.mint(address(this), 60_000_000e18);
        PoolKey memory pool = _addHooked(address(eur), 3_000);
        MeddlingHook meddler = MeddlingHook(address(uint160(0xBEEF << 24 | 1 << 6)));
        deployCodeTo(
            "MeddlingHook.sol:MeddlingHook", abi.encode(hook, _id(pool)), address(meddler)
        );
        bool wethFirst = address(backing) < address(eur);
        PoolKey memory route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(eur)),
            Currency.wrap(wethFirst ? address(eur) : address(backing)),
            3_000,
            60,
            IHooks(address(meddler))
        );
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 50_000_000e18);
        locker.registerRoute(route);
        hook.setConnector(1, route, true);
        uint256 inventory = core.unreleasedSupply();
        _trade(pool, address(szr), 50_000e18);
        uint256 afterSale = core.unreleasedSupply();
        assertGt(afterSale, inventory, "sale backrun");
        _trade(pool, address(eur), 100_000e18);
        assertGt(core.unreleasedSupply(), afterSale, "purchase backrun");
        assertGt(meddler.swaps(), 0, "cycles crossed the hooked pool");
        assertEq(meddler.refused(), meddler.swaps(), "every attempt refused");
        assertEq(eur.balanceOf(address(hook)), 0, "hook partner");
        _assertHookEmpty();
    }
}
