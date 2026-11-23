// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { FlatPricer } from "./utils/WrappedPool.sol";
import { MockMetricFactory, MockMetricPool } from "./utils/metric/MockMetricPool.sol";
import { EntryPart } from "../src/arbitrage/ArbitrageEntry.sol";
import { SearchPart } from "../src/arbitrage/ArbitrageSearch.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IVenuePricer } from "../src/interfaces/IVenuePricer.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A pricer that is set but never has a price, as before Metric's pricer exists.
contract NoPricer is IVenuePricer {
    function price(PoolKey calldata)
        external
        pure
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        revert("no price");
    }
}

/// @dev Swaps through a Metric pool wrapped by `MetricVenueHook` start the arbitrage hook's
/// searches, before the fill and after it, inside the same unlock.
abstract contract MetricVenueSearchWorld is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant CAP = 12_000_000;
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    MockMetricFactory internal factory;
    MetricVenueHook internal venue;
    MockMetricPool internal metric;
    PoolKey internal metricKey;
    bytes32 internal metricId;
    PoolKey internal hookless;

    function setUp() public virtual override {
        super.setUp();
        factory = new MockMetricFactory();
        address at = address(uint160(0x4444 << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(address(this), address(factory), address(manager), address(hook)),
            at
        );
        venue = MetricVenueHook(at);
        bool backingLow = address(backing) < address(coin);
        (address low, address high) =
            backingLow ? (address(backing), address(coin)) : (address(coin), address(backing));
        metric = new MockMetricPool(address(factory), low, high, 1, 1, uint128(1 << 64));
        factory.register(address(metric));
        TestAsset(low).mint(address(metric), 1_000_000e18);
        TestAsset(high).mint(address(metric), 1_000_000e18);
        metricKey = PoolKey(Currency.wrap(low), Currency.wrap(high), 0, 1, IHooks(at));
        metricId = _id(metricKey);
        venue.bind(metricKey, address(metric));

        hook.setPricer(at, address(new NoPricer()));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        vm.prank(team);
        hook.addVenue(id, metricKey);
        _lead(address(backing), address(coin), _list(_id(first), _id(second)));
        _limits(address(backing), 1e15);
        venue.setTrigger(metricKey, id, address(backing), CAP, true);
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    /// Swaps through a Metric pool of coin and USD instead, which does not hold WETH, the
    /// token the trigger counts profit in. Such a swap starts one search from the first
    /// leader of every group, as `sweep` does; a pool that holds the trigger's token is
    /// searched from itself instead (`ArbitrageWrappedStart.t.sol`, part B of
    /// `docs/specs/hook-wrapped-start.md`).
    function _useQuotePool() internal {
        _useMetricPoolOf(address(usd));
    }

    /// The same with a Metric pool of coin and `other`.
    function _useMetricPoolOf(address other) internal {
        (address low, address high) =
            other < address(coin) ? (other, address(coin)) : (address(coin), other);
        metric = new MockMetricPool(address(factory), low, high, 1, 1, uint128(1 << 64));
        factory.register(address(metric));
        TestAsset(low).mint(address(metric), 1_000_000e18);
        TestAsset(high).mint(address(metric), 1_000_000e18);
        metricKey =
            PoolKey(Currency.wrap(low), Currency.wrap(high), 0, 1, IHooks(address(venue)));
        metricId = _id(metricKey);
        venue.bind(metricKey, address(metric));
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, metricKey);
        vm.stopPrank();
        _limits(address(backing), 1e15);
        venue.setTrigger(metricKey, id, address(backing), CAP, true);
    }

    /// The token a trader pays into the Metric pool: the one that is not coin.
    function _payToken() internal view returns (address) {
        return Currency.unwrap(metricKey.currency0) == address(coin)
            ? Currency.unwrap(metricKey.currency1)
            : Currency.unwrap(metricKey.currency0);
    }

    /// Sells coin into the first pool with the market switched off, so the gap stays open.
    function _openGap() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
    }

    function _sqrtPrice(PoolKey memory pool) internal view returns (uint256 root) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(pool.toId());
        return sqrtPrice;
    }

    /// The first log of the hook's cycles and the first one of Metric paying out.
    function _firstCycleAndFill(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 cycle, uint256 fill, uint256 cycles)
    {
        cycle = type(uint256).max;
        fill = type(uint256).max;
        bytes32 from = bytes32(uint256(uint160(address(metric))));
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter == address(hook)) {
                if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) {
                    if (cycle == type(uint256).max) cycle = index;
                    cycles++;
                }
            }
            if (logs[index].topics[0] == TRANSFER) {
                if (logs[index].topics[1] == from) {
                    if (fill == type(uint256).max) fill = index;
                }
            }
        }
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] == topic) n++;
        }
    }

    function _swapWithGas(uint256 gas) internal returns (bool ok) {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(venue));
        bool zeroForOne = Currency.unwrap(metricKey.currency0) == _payToken();
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(1e18),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (metricKey, params, settings, ""))
        );
    }

    /// What a swap of one WETH into the Metric pool did to the swapper's balances.
    function _swapperDeltas() internal returns (int256 weth, int256 other) {
        uint256 wethBefore = backing.balanceOf(address(this));
        uint256 coinBefore = coin.balanceOf(address(this));
        _trade(metricKey, address(backing), 1e18);
        weth = int256(backing.balanceOf(address(this))) - int256(wethBefore);
        other = int256(coin.balanceOf(address(this))) - int256(coinBefore);
    }
}

contract MetricVenueSearchTest is MetricVenueSearchWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------
    // gaps
    // ---------------------------------------------------------------------------------

    /// A gap between two v4 pools that was open before the trader's swap is closed by the
    /// search ahead of the fill, so the trader fills after it has been closed.
    function testGapOpenBeforeTheSwapIsClosedBeforeTheFill() public {
        _useQuotePool();
        _openGap();
        uint256 paid = backing.balanceOf(treasury);
        vm.recordLogs();
        _trade(metricKey, _payToken(), 1e18);
        (uint256 cycle, uint256 fill, uint256 cycles) = _firstCycleAndFill(vm.getRecordedLogs());
        assertGt(cycles, 0, "a cycle ran");
        assertLt(cycle, fill, "closed before Metric filled");
        assertGt(backing.balanceOf(treasury), paid, "the market was paid");
        _assertNothingHeld();
    }

    /// A gap the swap itself opens, here by Metric's pool trading in a hookless venue of
    /// the market, is closed by the search after the swap.
    function testGapTheSwapOpensIsClosedAfterIt() public {
        _useQuotePool();
        hookless = _pair(address(backing), address(coin), 3_000, address(0));
        manager.initialize(hookless, uint160(1 << 96));
        _provide(hookless, 1_000_000e18);
        vm.prank(team);
        hook.addVenue(id, hookless);
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(first);
        list[1] = _id(second);
        list[2] = _id(hookless);
        _lead(address(backing), address(coin), list);
        _limits(address(backing), 1e15);
        bool coinFirst = Currency.unwrap(hookless.currency0) == address(coin);
        metric.setMode(5, 0);
        metric.setNested(
            manager,
            hookless,
            IPoolManager.SwapParams(
                coinFirst,
                -int256(50_000e18),
                coinFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        );
        uint256 paid = backing.balanceOf(treasury);
        vm.recordLogs();
        _trade(metricKey, _payToken(), 1e18);
        (uint256 cycle, uint256 fill, uint256 cycles) = _firstCycleAndFill(vm.getRecordedLogs());
        assertGt(cycles, 0, "a cycle ran");
        assertGt(cycle, fill, "nothing was open before the fill");
        assertGt(backing.balanceOf(treasury), paid, "the market was paid");
        uint256 one = _sqrtPrice(first);
        uint256 other = _sqrtPrice(hookless);
        uint256 apart = one > other ? one - other : other - one;
        assertLt(apart * 100, one, "the gap is closed");
        _assertNothingHeld();
    }

    /// The search that runs before the fill trades the wrapped pool itself as a venue
    /// (Metric priced by a pricer that has an answer). The wrapper's own `beforeSwap`
    /// calls back into `venueSearch` while that search runs, and is ignored.
    function testSearchThatTradesTheWrapperIsNotNested() public {
        hook.setPricer(address(venue), address(new FlatPricer()));
        bytes32[] memory list = new bytes32[](2);
        list[0] = _id(first);
        list[1] = metricId;
        _lead(address(backing), address(coin), list);
        _limits(address(backing), 1e15);
        _openGap();
        uint256 paid = backing.balanceOf(treasury);
        vm.recordLogs();
        // One search before the fill and one after it, none nested inside the first.
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 2);
        _trade(metricKey, address(backing), 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 viaMetric;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] != ArbitrageLogic.Arbitraged.selector) continue;
            if (logs[index].topics[2] == metricId) viaMetric++;
        }
        assertGt(viaMetric, 0, "a cycle traded the Metric pool during the search");
        assertEq(_count(logs, ArbitrageLogic.SearchUndone.selector), 0, "nothing undone");
        assertEq(_count(logs, ArbitrageLogic.VenueSearchSkipped.selector), 0, "no nested try");
        assertGt(backing.balanceOf(treasury), paid, "the market was paid");
        _assertNothingHeld();
    }

    /// The swapper gets the same from the Metric pool whatever the searches do.
    function testSettlementDoesNotDependOnTheSearch() public {
        _useQuotePool();
        _openGap();
        uint256 snapshot = vm.snapshotState();
        (int256 withWeth, int256 withCoin) = _swapperDeltas();
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

    // ---------------------------------------------------------------------------------
    // who may call, and when it does nothing
    // ---------------------------------------------------------------------------------

    function testOnlyTheVenuesOwnHookMayCallVenueSearch() public {
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.venueSearch(metricId, true, address(this));
        // The wrapper cannot name a pool that is on some other hook.
        vm.prank(address(venue));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.venueSearch(_id(first), true, address(this));
        vm.prank(address(venue));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.venueSearch(bytes32(uint256(1)), true, address(this));
        // Without a pricer the wrapper is not trusted at all.
        hook.setPricer(address(venue), address(0));
        vm.prank(address(venue));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.venueSearch(metricId, true, address(this));
    }

    /// Outside an unlock the call does nothing, and does not revert.
    function testVenueSearchOutsideAnUnlockDoesNothing() public {
        _openGap();
        uint256 price = _sqrtPrice(first);
        vm.recordLogs();
        vm.prank(address(venue));
        hook.venueSearch(metricId, true, address(this));
        assertEq(vm.getRecordedLogs().length, 0, "nothing happened");
        assertEq(_sqrtPrice(first), price, "gap left alone");
    }

    // ---------------------------------------------------------------------------------
    // gas
    // ---------------------------------------------------------------------------------

    /// With too little gas the search is skipped and reported, and the swap settles. More
    /// gas never turns a swap that settled into one that fails.
    function testLowGasSkipsTheSearchAndTheSwapStillSettles() public {
        _useQuotePool();
        _openGap();
        bool settled;
        bool skipped;
        bool searched;
        for (uint256 gas = 300_000; gas <= 9_000_000; gas += 50_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWithGas(gas);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 cycles = _count(logs, ArbitrageLogic.Arbitraged.selector);
            uint256 skips = _count(logs, ArbitrageLogic.VenueSearchSkipped.selector);
            vm.revertToState(snapshot);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (ok) {
                settled = true;
                if (skips != 0) skipped = true;
                if (cycles != 0) searched = true;
            }
        }
        assertTrue(settled, "never settled");
        assertTrue(skipped, "never skipped");
        assertTrue(searched, "never searched");
    }

    // ---------------------------------------------------------------------------------
    // triggers
    // ---------------------------------------------------------------------------------

    /// A market's owner cannot register a trigger, whatever the market: only the wrapper
    /// can, and the wrapper's own `setTrigger` is for its owner.
    function testOnlyTheWrapperSetsTriggers() public {
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.setVenueTrigger(id, metricId, address(usd), CAP, true);
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.setVenueTrigger(id, metricId, address(usd), CAP, false);
        vm.prank(team);
        vm.expectRevert(MetricVenueHook.NotOwner.selector);
        venue.setTrigger(metricKey, id, address(usd), CAP, true);
        venue.setTrigger(metricKey, id, address(usd), CAP, true);
        assertEq(hook.triggersOf(metricId).length, 2);
        // Without a pricer the wrapper cannot register one either.
        hook.setPricer(address(venue), address(0));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        venue.setTrigger(metricKey, id, address(backing), CAP, false);
    }

    function testTriggerNeedsATrackedPoolAndAChosenToken() public {
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        venue.setTrigger(metricKey, 1, address(szr), CAP, true);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        venue.setTrigger(metricKey, id, address(coin), CAP, true);
        // A pool the wrapper never bound cannot be named.
        PoolKey memory other = metricKey;
        other.fee = 1;
        vm.expectRevert(MetricVenueHook.NotBound.selector);
        venue.setTrigger(other, id, address(backing), CAP, true);
    }

    function testAVenueHasAtMostTwoTriggersAcrossMarkets() public {
        venue.setTrigger(metricKey, id, address(usd), CAP, true);
        // A second market tracks the same venue; a third trigger is still refused.
        vm.startPrank(treasury);
        uint256 other = hook.openMarket(treasury);
        hook.addVenue(other, metricKey);
        vm.stopPrank();
        vm.expectRevert(ArbitrageLogic.TooManyTriggers.selector);
        venue.setTrigger(metricKey, other, address(backing), CAP, true);
        // Setting one that exists is not a new one, and freeing a place lets another in.
        venue.setTrigger(metricKey, id, address(usd), CAP, true);
        assertEq(hook.triggersOf(metricId).length, 2);
        venue.setTrigger(metricKey, id, address(usd), CAP, false);
        assertEq(hook.triggersOf(metricId).length, 1);
        venue.setTrigger(metricKey, other, address(backing), CAP, true);
        assertEq(hook.triggersOf(metricId).length, 2);
    }
}
