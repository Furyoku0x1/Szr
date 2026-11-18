// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { MetricVenueSearchWorld, NoPricer } from "./MetricVenueSearch.t.sol";
import { FlatPricer } from "./utils/WrappedPool.sol";
import { MockMetricPool } from "./utils/metric/MockMetricPool.sol";
import { SearchPart } from "../src/arbitrage/ArbitrageSearch.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IVenuePricer } from "../src/interfaces/IVenuePricer.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A router that pays first: it marks the input token as synced, sends it to the pool
/// manager, swaps, takes the output, and settles at the end.
contract PayFirstRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager pools) {
        manager = pools;
    }

    function swap(PoolKey calldata key, bool zeroForOne, uint256 amount) external {
        manager.unlock(abi.encode(key, zeroForOne, amount, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amount, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        manager.sync(input);
        IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount);
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        int128 got = zeroForOne ? delta.amount1() : delta.amount0();
        manager.take(output, payer, uint128(got));
        manager.settle();
        return "";
    }
}

/// @dev A pricer that burns almost all the gas it is given and then answers like a flat one,
/// so that reading and ranking venues costs what the search reserved for it.
contract BurnPricer is IVenuePricer {
    function price(PoolKey calldata)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        uint256 spin;
        while (gasleft() > 7_000) spin++;
        return (
            uint160(1 << 96),
            3_000,
            1_000_000e18,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE
        );
    }
}

/// @dev Routers that mark a token as synced in the ways the wrapper must cope with. Mode 0:
/// marks the input, swaps, then pays and settles. Mode 1: pays first and swaps, then swaps
/// again with no mark and records the synced currency. Mode 2: marks a third token the pool
/// does not hold, swaps, and records the synced currency.
contract MarkRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable manager;
    address public recorded = address(1);

    constructor(IPoolManager pools) {
        manager = pools;
    }

    function run(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amount,
        uint8 mode,
        address third
    ) external {
        manager.unlock(abi.encode(key, zeroForOne, amount, mode, third, msg.sender));
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amount)
        internal
        returns (uint128)
    {
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        return uint128(zeroForOne ? delta.amount1() : delta.amount0());
    }

    function _pay(Currency input, uint256 amount, address payer) internal {
        IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            PoolKey memory key,
            bool zeroForOne,
            uint256 amount,
            uint8 mode,
            address third,
            address payer
        ) = abi.decode(data, (PoolKey, bool, uint256, uint8, address, address));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        uint128 got;
        if (mode == 0) {
            manager.sync(input);
            got = _swap(key, zeroForOne, amount);
            _pay(input, amount, payer);
            manager.settle();
        }
        if (mode == 1) {
            manager.sync(input);
            _pay(input, amount, payer);
            uint128 first = _swap(key, zeroForOne, amount);
            manager.take(output, payer, first);
            manager.settle();
            got = _swap(key, zeroForOne, amount);
            recorded = Currency.unwrap(manager.getSyncedCurrency());
            manager.sync(input);
            _pay(input, amount, payer);
            manager.settle();
        }
        if (mode == 2) {
            manager.sync(Currency.wrap(third));
            got = _swap(key, zeroForOne, amount);
            recorded = Currency.unwrap(manager.getSyncedCurrency());
            manager.sync(input);
            _pay(input, amount, payer);
            manager.settle();
        }
        manager.take(output, payer, got);
        return "";
    }
}

/// @dev A pay-after router whose work after the swap burns a fixed amount of gas, as a
/// route with more hops would, before it pays and takes.
contract BurnAfterRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager pools) {
        manager = pools;
    }

    function swap(PoolKey calldata key, bool zeroForOne, uint256 amount, uint256 burn)
        external
    {
        manager.unlock(abi.encode(key, zeroForOne, amount, burn, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amount, uint256 burn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, uint256, address));
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        Currency output = zeroForOne ? key.currency1 : key.currency0;
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        uint256 stop = gasleft() > burn ? gasleft() - burn : 0;
        while (gasleft() > stop) { }
        manager.sync(input);
        IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), amount);
        manager.settle();
        manager.take(output, payer, uint128(zeroForOne ? delta.amount1() : delta.amount0()));
        return "";
    }
}

/// @dev The checks around the wrapper's searches: who is paid, what gas they may use, who
/// may register one, and when one is skipped.
contract MetricVenueGuardsTest is MetricVenueSearchWorld {
    uint256 internal constant BURN_CYCLE = 800_000;
    uint256 internal constant FILL_BURN = 3_000_000;
    uint256 internal constant BURN_AFTER = 1_500_000;
    uint256 internal constant BURN_FILL = 3_500_000;

    PayFirstRouter internal payFirst;

    function setUp() public override {
        super.setUp();
        payFirst = new PayFirstRouter(manager);
        backing.approve(address(payFirst), type(uint256).max);
        coin.approve(address(payFirst), type(uint256).max);
    }

    /// Another wrapped Metric pool of the same two tokens, priced by a pricer that always has
    /// an answer, and made a leader of the coin group, so that cycles trade through it.
    /// `burn` is the gas its fill burns.
    function _addVenue(uint160 salt, uint256 burn, uint256 maxFill, address pricer)
        internal
        returns (PoolKey memory key, MockMetricPool pool)
    {
        address at = address(uint160(salt << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(address(this), address(factory), address(manager), address(hook)),
            at
        );
        (address low, address high) =
            (Currency.unwrap(metricKey.currency0), Currency.unwrap(metricKey.currency1));
        pool = new MockMetricPool(address(factory), low, high, 1, 1, uint128(1 << 64));
        factory.register(address(pool));
        TestAsset(low).mint(address(pool), 1_000_000e18);
        TestAsset(high).mint(address(pool), 1_000_000e18);
        pool.setMode(6, burn);
        pool.setMaxFill(maxFill);
        key = PoolKey(metricKey.currency0, metricKey.currency1, 0, 1, IHooks(at));
        MetricVenueHook(at).bind(key, address(pool));
        hook.setPricer(at, pricer);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, key);
        vm.stopPrank();
    }

    function _leadList(bytes32[] memory list) internal {
        _lead(address(backing), address(coin), list);
        _limits(address(backing), 1e15);
    }

    function _payFirstDeltas() internal returns (int256 weth, int256 other) {
        uint256 wethBefore = backing.balanceOf(address(this));
        uint256 coinBefore = coin.balanceOf(address(this));
        payFirst.swap(metricKey, Currency.unwrap(metricKey.currency0) == address(backing), 1e18);
        weth = int256(backing.balanceOf(address(this))) - int256(wethBefore);
        other = int256(coin.balanceOf(address(this))) - int256(coinBefore);
    }

    // ---------------------------------------------------------------------------------
    // a router that pays first
    // ---------------------------------------------------------------------------------

    /// With no gap and no trigger the router's payment must still be credited to it: the
    /// wrapper's own settlement of the output replaces the mark the router left.
    function testPayFirstRouterIsCreditedWithNoSearch() public {
        venue.setTrigger(metricKey, id, address(backing), CAP, false);
        (int256 weth, int256 other) = _payFirstDeltas();
        assertEq(weth, -1e18, "paid");
        assertEq(other, 1e18, "received");
    }

    /// Whatever the search does, with a gap or without, the swapper pays and receives the
    /// same, and with the trigger on and a gap the gap is closed before the fill with the
    /// router's payment waiting (which only works if the swapper is named as the payer).
    function testPayFirstSettlementDoesNotDependOnTheSearch() public {
        (int256 plainWeth, int256 plainCoin) = _payFirstDeltas();
        uint256 snapshot = vm.snapshotState();
        _openGap();
        vm.recordLogs();
        (int256 weth, int256 other) = _payFirstDeltas();
        (uint256 cycle, uint256 fill, uint256 cycles) = _firstCycleAndFill(vm.getRecordedLogs());
        assertGt(cycles, 0, "the gap was closed");
        assertLt(cycle, fill, "before the fill, with the payment waiting");
        assertEq(weth, plainWeth, "paid, gap, trigger on");
        assertEq(other, plainCoin, "received, gap, trigger on");
        vm.revertToState(snapshot);
        venue.setTrigger(metricKey, id, address(backing), CAP, false);
        _openGap();
        (weth, other) = _payFirstDeltas();
        assertEq(weth, plainWeth, "paid, gap, trigger off");
        assertEq(other, plainCoin, "received, gap, trigger off");
        assertEq(plainWeth, -1e18, "paid one");
    }

    // ---------------------------------------------------------------------------------
    // who may register
    // ---------------------------------------------------------------------------------

    /// Another hook that has a pricer is still refused: only the hook of the pool itself
    /// may register a trigger for it.
    function testAnotherHookWithAPricerCannotRegister() public {
        address other = address(0xB0B0);
        hook.setPricer(other, address(new NoPricer()));
        vm.prank(other);
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.setVenueTrigger(id, metricId, address(usd), CAP, true);
        vm.prank(other);
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.setVenueTrigger(id, metricId, address(backing), CAP, false);
        assertEq(hook.triggersOf(metricId).length, 1, "untouched");
    }

    function testTriggerCapIsBounded() public {
        uint32 over = uint32(hook.MAX_TRIGGER_GAS() + 1);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        venue.setTrigger(metricKey, id, address(usd), 0, true);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        venue.setTrigger(metricKey, id, address(usd), over, true);
        venue.setTrigger(metricKey, id, address(backing), 5_000_000, true);
        assertEq(hook.triggersOf(metricId)[0].gasCap, 5_000_000, "cap changed in place");
        assertEq(hook.triggersOf(metricId).length, 1);
    }

    // ---------------------------------------------------------------------------------
    // skips
    // ---------------------------------------------------------------------------------

    function testTriggerIsSkippedAfterTheMarketUntracksThePool() public {
        _openGap();
        vm.prank(team);
        hook.untrack(id, metricId);
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 0);
        _trade(metricKey, address(backing), 1e18);
        assertEq(hook.triggersOf(metricId).length, 1, "still registered");
    }

    function testTriggerIsSkippedWhenItsTokenLeavesTheList() public {
        _openGap();
        address[] memory list = new address[](1);
        list[0] = address(usd);
        vm.prank(team);
        hook.setTokens(id, list);
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 0);
        _trade(metricKey, address(backing), 1e18);
        assertEq(hook.triggersOf(metricId).length, 1, "still registered");
    }

    // ---------------------------------------------------------------------------------
    // gas
    // ---------------------------------------------------------------------------------

    /// A cycle through a second wrapped pool is costly (its fill burns gas), and so is the
    /// fill of the pool being swapped, with a gap open, so the search before the fill has
    /// a gas-heavy cycle to close. More gas must never fail the swap: the search leaves
    /// what the fill needs, which only the search before a swap, with its larger floor, does.
    function testMoreGasNeverFailsASwapWhenCyclesAndTheFillAreCostly() public {
        (PoolKey memory costly,) =
            _addVenue(0x4445, BURN_CYCLE, type(uint256).max, address(new FlatPricer()));
        bytes32[] memory list = new bytes32[](2);
        list[0] = _id(first);
        list[1] = _id(costly);
        _leadList(list);
        metric.setMode(6, BURN_FILL);
        _openGap();
        bool settled;
        bool searched;
        for (uint256 gas = 500_000; gas <= 16_000_000; gas += 250_000) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWithGas(gas);
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

    /// The plan budget (`_plan`, two million in a market with wrapped pools, and no try may
    /// use more than half of it) covers a cycle through a Metric leg: the M1 fork measured
    /// about 400k for a Metric swap. The venue's fill here burns that, then twice that, with
    /// the cycle's own legs on top. Neither cycle fails or runs a try out of gas.
    function testPlanBudgetCoversACycleThroughAMetricLeg() public {
        (PoolKey memory costly, MockMetricPool pool) =
            _addVenue(0x4445, 400_000, type(uint256).max, address(new FlatPricer()));
        bytes32[] memory list = new bytes32[](2);
        list[0] = _id(first);
        list[1] = _id(costly);
        _leadList(list);
        for (uint256 burn = 400_000; burn <= 800_000; burn += 400_000) {
            uint256 snapshot = vm.snapshotState();
            pool.setMode(6, burn);
            _openGap();
            vm.recordLogs();
            _trade(first, address(coin), 1e15);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertGt(_count(logs, ArbitrageLogic.Arbitraged.selector), 0, "the cycle ran");
            assertEq(_count(logs, ArbitrageLogic.CycleFailed.selector), 0, "and did not fail");
            assertEq(_count(logs, ArbitrageLogic.TryRanOut.selector), 0, "or run a try out");
            vm.revertToState(snapshot);
        }
    }

    /// A triggered search never ends `Starved`, which would fail the swap: it only has its
    /// own allowance, so lacking the gas for a cycle just ends it. Two venues whose fills
    /// fail make cycles fail one after the other, and the trigger's cap is swept, finely,
    /// across where the search before the fill can start, so that some search runs out just
    /// after a failure while another cycle is due.
    function testATriggeredSearchIsNeverStarved() public {
        (PoolKey memory one,) = _addVenue(0x4445, 0, 1e17, address(new FlatPricer()));
        (PoolKey memory two,) = _addVenue(0x4446, 0, 1e17, address(new FlatPricer()));
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(first);
        list[1] = _id(one);
        list[2] = _id(two);
        _leadList(list);
        _openGap();
        for (uint256 cap = 9_400_000; cap <= 10_600_000; cap += 10_000) {
            uint256 snapshot = vm.snapshotState();
            venue.setTrigger(metricKey, id, address(backing), uint32(cap), true);
            vm.recordLogs();
            _trade(metricKey, address(backing), 1e16);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 index; index < logs.length; index++) {
                if (logs[index].emitter != address(hook)) continue;
                bytes32 topic = logs[index].topics[0];
                if (topic != ArbitrageLogic.SearchUndone.selector) continue;
                bytes4 reason = abi.decode(logs[index].data, (bytes4));
                assertTrue(reason != ArbitrageLogic.Starved.selector, "starved");
            }
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------
    // two triggers, one head
    // ---------------------------------------------------------------------------------

    /// Two triggers of one market, in WETH and in USD, whose groups are headed by the same
    /// WETH/USD pool. The search before the swap for the first leaves that pool's prices
    /// remembered when it trades nothing; the second must not read them, since they are in
    /// the first's terms. A gap between the two WETH/USD pools is only worth closing in USD.
    function testTwoTriggersWithTheSameHeadDoNotShareRememberedPrices() public {
        PoolKey memory one = _create(address(backing), address(usd), 3_000);
        PoolKey memory two = _create(address(backing), address(usd), 500);
        bytes32[] memory both = new bytes32[](2);
        both[0] = _id(one);
        both[1] = _id(two);
        _lead(address(backing), address(usd), both);
        _lead(address(usd), address(backing), both);
        // Only USD is worth closing a gap for.
        _limits(address(backing), 1e30);
        _limits(address(usd), 1);
        venue.setTrigger(metricKey, id, address(usd), CAP, true);
        vm.prank(team);
        hook.setLimits(id, address(usd), 0, 1, 1.0001e18);
        _trade(one, address(usd), 50_000e18);
        _limits(address(usd), 1);
        vm.recordLogs();
        _trade(metricKey, address(backing), 1e18);
        (uint256 cycle, uint256 fill, uint256 cycles) = _firstCycleAndFill(vm.getRecordedLogs());
        assertGt(cycles, 0, "the gap was closed");
        assertLt(cycle, fill, "before the fill");
    }

    /// A route's work after the swap burns 1.5M gas: more than a search leaves of its own
    /// floor, less than that and the reserve together (the burn is hardcoded; it was found
    /// by scanning, and below about 1.85M the real code passes and a budget without the
    /// reserve fails; the floor is far lower since live pricers, see
    /// `docs/specs/hook-live-pricers.md`, which is why the scan starts at 2.5M). Scanning the
    /// gas the swap is given upward across where the search after it starts, the swap must
    /// never fail once it has succeeded. The search is made
    /// to use nearly its whole floor: the pricers of two more wrapped pools burn what they
    /// are allowed, and those pools' fills burn past every try's share, so each cycle fails
    /// after using the whole plan.
    function testReserveLeavesRoomForALaterRoute() public {
        (PoolKey memory costly,) =
            _addVenue(0x4445, FILL_BURN, type(uint256).max, address(new BurnPricer()));
        (PoolKey memory dear,) =
            _addVenue(0x4446, FILL_BURN, type(uint256).max, address(new BurnPricer()));
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(first);
        list[1] = _id(costly);
        list[2] = _id(dear);
        _leadList(list);
        _openGap();
        BurnAfterRouter router = new BurnAfterRouter(manager);
        backing.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(metricKey.currency0) == address(backing);
        bool settled;
        bool searched;
        for (uint256 gas = 2_500_000; gas <= 7_000_000; gas += 50_000) {
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
    // the trigger's cap
    // ---------------------------------------------------------------------------------

    /// A cap below what a search needs makes the trigger skip, however large the market's
    /// own allowance is.
    function testTriggerCapBelowTheSearchNeedsSkips() public {
        _openGap();
        venue.setTrigger(metricKey, id, address(backing), 2_000_000, true);
        assertGt(hook.market(id).gasLimit, 2_000_000, "the allowance is larger");
        vm.recordLogs();
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 0);
        _trade(metricKey, address(backing), 1e18);
        assertGt(_count(vm.getRecordedLogs(), ArbitrageLogic.VenueSearchSkipped.selector), 0);
    }

    // ---------------------------------------------------------------------------------
    // the swapper's mark
    // ---------------------------------------------------------------------------------

    function _markRun(uint8 mode, address third) internal returns (MarkRouter router) {
        router = new MarkRouter(manager);
        backing.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(metricKey.currency0) == address(backing);
        router.run(metricKey, zeroForOne, 1e18, mode, third);
    }

    /// A router that marks the input, swaps, and only then pays is credited exactly: the
    /// wrapper puts the mark back after settling its own output.
    function testMarkFirstPayAfterRouterIsCreditedExactly() public {
        uint256 wethBefore = backing.balanceOf(address(this));
        uint256 coinBefore = coin.balanceOf(address(this));
        _markRun(0, address(0));
        assertEq(backing.balanceOf(address(this)), wethBefore - 1e18, "paid");
        assertEq(coin.balanceOf(address(this)), coinBefore + 1e18, "received");
    }

    /// Two wrapper swaps in one unlock, the first with a mark and the second without: the
    /// second leaves the synced currency as if no mark had ever been set.
    function testNoStaleMarkSurvivesIntoALaterSwap() public {
        MarkRouter router = _markRun(1, address(0));
        assertEq(router.recorded(), address(0), "no mark after the second swap");
    }

    /// A token the pool does not hold, marked by the swapper, is never called by the wrapper
    /// and its mark is not restored. Only the pool manager's own `sync` reads its balance.
    function testAnUnrelatedMarkedTokenIsNeverCalled() public {
        TestAsset third = new TestAsset();
        vm.expectCall(address(third), abi.encodeWithSelector(IERC20.balanceOf.selector), 1);
        MarkRouter router = _markRun(2, address(third));
        assertEq(router.recorded(), address(0), "the mark was replaced, not restored");
    }
}
