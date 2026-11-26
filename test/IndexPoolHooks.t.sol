// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexToken, IndexWorld, MockIndexHook } from "./utils/IndexWorld.sol";

contract IndexPoolHooksTest is IndexWorld {
    address internal alice = makeAddr("alice");
    uint32 internal constant GAS = 1_000_000;

    // ---------------------------------------------------------------- factory

    function testSwitchOffAcceptsOnlyApprovedHooksOrNone() public {
        address[] memory list = _tokens(_same(18, 2));
        address hook = address(new MockIndexHook());
        vm.expectRevert(IndexPoolFactory.HookNotApproved.selector);
        factory.create("I", "I", list, _equal(2), FEE, hook, GAS);
        IndexPool none =
            IndexPool(factory.create("I", "I", list, _equal(2), FEE, address(0), 5));
        assertEq(none.hook(), address(0));
        assertEq(none.hookGas(), 0);
        assertFalse(none.hookApproved());
        factory.setHookApproved(hook, GAS);
        IndexPool pool = IndexPool(factory.create("I", "I", list, _equal(2), FEE, hook, 7));
        assertEq(pool.hook(), hook);
        assertTrue(pool.hookApproved());
        assertTrue(factory.isPool(address(pool)));
        assertTrue(factory.isPool(address(none)));
        assertFalse(factory.isPool(hook));
    }

    function testSwitchOnAcceptsAnyHook() public {
        address[] memory list = _tokens(_same(18, 2));
        address hook = makeAddr("any hook");
        factory.setOpenHooks(true);
        assertTrue(factory.openHooks());
        IndexPool pool =
            IndexPool(factory.create("I", "I", list, _equal(2), FEE, hook, 123_456));
        assertEq(pool.hook(), hook);
        assertEq(pool.hookGas(), 123_456);
        assertFalse(pool.hookApproved());
        assertEq(pool.creator(), address(this));
        factory.setOpenHooks(false);
        vm.expectRevert(IndexPoolFactory.HookNotApproved.selector);
        factory.create("I", "I", list, _equal(2), FEE, hook, 123_456);
    }

    function testApprovedHookAlwaysGetsTheFactoryGas() public {
        address[] memory list = _tokens(_same(18, 2));
        address hook = makeAddr("approved");
        factory.setHookApproved(hook, 777_777);
        assertEq(factory.approvedHookGas(hook), 777_777);
        assertEq(
            IndexPool(factory.create("I", "I", list, _equal(2), FEE, hook, 1)).hookGas(),
            777_777
        );
        factory.setOpenHooks(true);
        assertEq(
            IndexPool(factory.create("I", "I", list, _equal(2), FEE, hook, 8_000_000))
                .hookGas(),
            777_777
        );
    }

    function testHookGasLimits() public {
        address[] memory list = _tokens(_same(18, 2));
        address hook = makeAddr("hook");
        vm.expectRevert(IndexPoolFactory.InvalidHookGas.selector);
        factory.setHookApproved(hook, 8_000_001);
        factory.setHookApproved(hook, 8_000_000);
        factory.setHookApproved(hook, 0);
        factory.setOpenHooks(true);
        vm.expectRevert(IndexPool.InvalidHookGas.selector);
        factory.create("I", "I", list, _equal(2), FEE, hook, 8_000_001);
        vm.expectRevert(IndexPool.InvalidHookGas.selector);
        factory.create("I", "I", list, _equal(2), FEE, hook, 0);
        factory.create("I", "I", list, _equal(2), FEE, hook, 8_000_000);
    }

    function testOnlyTheLiveManagerSetsHooks() public {
        address hook = makeAddr("hook");
        vm.startPrank(alice);
        vm.expectRevert(IndexPoolFactory.NotManager.selector);
        factory.setHookApproved(hook, GAS);
        vm.expectRevert(IndexPoolFactory.NotManager.selector);
        factory.setOpenHooks(true);
        vm.stopPrank();
        liquidity.setManager(alice);
        vm.expectRevert(IndexPoolFactory.NotManager.selector);
        factory.setHookApproved(hook, GAS);
        vm.prank(alice);
        factory.setHookApproved(hook, GAS);
        vm.prank(alice);
        factory.setOpenHooks(true);
        assertEq(factory.approvedHookGas(hook), GAS);
        assertTrue(factory.openHooks());
    }

    function testFactoryChangesLeaveExistingPoolsAlone() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Record);
        factory.setHookApproved(address(hook), 0);
        factory.setOpenHooks(true);
        factory.setOpenHooks(false);
        assertEq(pool.hookGas(), GAS);
        assertTrue(pool.hookApproved());
        address[] memory list = pool.tokens();
        _swap(pool, list[0], list[1], 1e18, true);
        assertEq(hook.callCount(), 2);
    }

    // ---------------------------------------------------------------- hook calls

    function testBothCallsInOrderWithTheirArguments() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        _fundAll(alice, pool, 1e30);
        vm.prank(alice);
        (uint256 paid, uint256 got) = pool.swap(list[1], list[0], 5e18, false, FAR, alice, FAR);
        assertEq(hook.callCount(), 2);
        (bool before, address sender, address tokenIn, address tokenOut,,,) = hook.calls(0);
        assertTrue(before);
        assertEq(sender, alice);
        assertEq(tokenIn, list[1]);
        assertEq(tokenOut, list[0]);
        uint256 amountIn;
        uint256 amountOut;
        (before, sender, tokenIn, tokenOut, amountIn, amountOut,) = hook.calls(1);
        assertFalse(before);
        assertEq(sender, alice);
        assertEq(amountIn, paid);
        assertEq(amountOut, got);
        assertEq(got, 5e18);
    }

    function testSwapIsPricedAfterTheHookTrades() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 snapshot = vm.snapshotState();
        hook.swapAsHook(list[0], list[1], 1e22, true, 0);
        (, uint256 expected) = pool.quoteSwap(list[0], list[1], 1e20, true);
        vm.revertToState(snapshot);
        (, uint256 untouched) = pool.quoteSwap(list[0], list[1], 1e20, true);
        hook.setMode(MockIndexHook.Mode.Honest);
        hook.setAction(list[0], list[1], 1e22);
        (, uint256 got) = _swap(pool, list[0], list[1], 1e20, true);
        assertEq(got, expected);
        assertLt(got, untouched);
    }

    function testBrokenHooksNeverBlockASwap() public {
        MockIndexHook.Mode[3] memory modes =
            [MockIndexHook.Mode.Revert, MockIndexHook.Mode.Burn, MockIndexHook.Mode.Huge];
        for (uint256 index; index < modes.length; index++) {
            (IndexPool pool,) = _hooked(modes[index]);
            address[] memory list = pool.tokens();
            (, uint256 quoted) = pool.quoteSwap(list[0], list[1], 1e18, true);
            (, uint256 got) = _swap(pool, list[0], list[1], 1e18, true);
            assertEq(got, quoted);
            _assertSolvent(pool, _none());
        }
    }

    /// A hook that returns a huge blob or burns its gas costs the swap at most its allowance.
    function testHookCostsAtMostItsGas() public {
        uint256 idle = _swapGas(MockIndexHook.Mode.Idle);
        uint256 record = _swapGas(MockIndexHook.Mode.Record);
        uint256 burn = _swapGas(MockIndexHook.Mode.Burn);
        uint256 huge = _swapGas(MockIndexHook.Mode.Huge);
        assertLe(burn, idle + 2 * uint256(GAS));
        // Returning 100 KB costs the hook about 28k of memory each time. A pool that copied
        // it would pay about as much again for each call, and this bound would fail.
        // Both modes record each call, so the recording hook is the baseline.
        assertLe(huge, record + 70_000);
        console2.log("swap gas: idle, recording, burning, huge-return hook");
        console2.log(idle, record, burn, huge);
    }

    function testReenteringHookLeavesTheSwapWorking() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Reenter);
        address[] memory list = pool.tokens();
        pool.transfer(address(hook), 1e21);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(
            IndexPool.swap, (list[1], list[0], 1e18, true, 0, address(hook), FAR)
        );
        calls[1] = abi.encodeCall(IndexPool.join, (1e18, _maxes(2), FAR));
        calls[2] = abi.encodeCall(IndexPool.exit, (1e18, _zeros(2), _none(), FAR));
        calls[3] = abi.encodeCall(IndexPool.donate, (list[0], 1e18));
        for (uint256 index; index < calls.length; index++) {
            hook.setReenter(calls[index]);
            uint256 count = hook.callCount();
            _swap(pool, list[0], list[1], 1e18, true);
            assertEq(hook.callCount(), count + 2, "both hook calls ran");
            assertTrue(hook.reenterOk(), "hook call ran");
            _assertSolvent(pool, _none());
        }
    }

    function testHookSwapsPayNoFeeAndCallNothing() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        vm.prank(address(hook));
        (, uint256 freeQuote) = pool.quoteSwap(list[0], list[1], 1e20, true);
        (, uint256 got) = hook.swapAsHook(list[0], list[1], 1e20, true, 0);
        assertEq(got, freeQuote);
        assertEq(hook.callCount(), 0);
        assertEq(pool.owed(list[0]), 0);
        (, uint256 paidQuote) = pool.quoteSwap(list[0], list[1], 1e20, true);
        _swap(pool, list[0], list[1], 1e20, true);
        assertGt(pool.owed(list[0]), 0);
        assertEq(hook.callCount(), 2);
        assertLt(paidQuote, freeQuote);
    }

    /// The hook's fee-free trades, there and back in every combination of kinds.
    function testFuzzFeeFreeRoundTripsNeverProfit(uint256 amount, bool sixDecimals) public {
        (IndexPool pool, MockIndexHook hook) =
            _hookedPair(sixDecimals ? 6 : 18, _weights(8e17, 2e17));
        address[] memory list = pool.tokens();
        uint256 given = _given(amount, pool.balances()[0]);
        _roundTrip(pool, hook, list[0], list[1], given, true, true);
        _roundTrip(pool, hook, list[0], list[1], given, true, false);
        _roundTrip(pool, hook, list[1], list[0], given, false, true);
        _roundTrip(pool, hook, list[1], list[0], given, false, false);
        given = _given(amount, pool.balances()[1]);
        _roundTrip(pool, hook, list[1], list[0], given, true, true);
        _roundTrip(pool, hook, list[1], list[0], given, true, false);
        _roundTrip(pool, hook, list[0], list[1], given, false, true);
        _roundTrip(pool, hook, list[0], list[1], given, false, false);
    }

    function testFeeFreeDustSwapsNeverProfit() public {
        // Small balances: at 1e24 a `MIN_TRADE` move is below the base's 18 decimals.
        (IndexPool pool, MockIndexHook hook) = _hookedPair(18, _equal(2), 1000, 3000);
        address[] memory list = pool.tokens();
        uint256 a = _balanceOf(list[0], address(hook));
        uint256 b = _balanceOf(list[1], address(hook));
        for (uint256 index; index < 500; index++) {
            hook.swapAsHook(list[0], list[1], 1e6, true, 0);
            hook.swapAsHook(list[1], list[0], 1e6, false, FAR);
        }
        assertEq(_balanceOf(list[0], address(hook)), a);
        assertLe(_balanceOf(list[1], address(hook)), b);
    }

    function testFeeFreeRawUnitSwapsNeverProfit() public {
        (IndexPool pool, MockIndexHook hook) = _hookedPair(6, _equal(2));
        address[] memory list = pool.tokens();
        address usdg = IndexToken(list[0]).decimals() == 6 ? list[0] : list[1];
        address stock = usdg == list[0] ? list[1] : list[0];
        uint256 dollars = _balanceOf(usdg, address(hook));
        uint256 shares = _balanceOf(stock, address(hook));
        for (uint256 index; index < 500; index++) {
            // One raw unit in, then the same unit bought back: selling `got` back exact-in
            // could price to zero raw units, which the pool now refuses.
            hook.swapAsHook(usdg, stock, 1, true, 0);
            hook.swapAsHook(stock, usdg, 1, false, FAR);
        }
        assertLe(_balanceOf(usdg, address(hook)), dollars);
        assertLe(_balanceOf(stock, address(hook)), shares);
    }

    // ---------------------------------------------------------------- hostile hooks

    function testLimitIsCheckedAfterTheHookTraded() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Sandwich);
        address[] memory list = pool.tokens();
        hook.setAction(address(0), address(0), 3e21);
        (, uint256 quoted) = pool.quoteSwap(list[0], list[1], 1e21, true);
        vm.expectRevert(IndexPool.Slippage.selector);
        pool.swap(list[0], list[1], 1e21, true, quoted, address(this), FAR);
        uint256 limit = quoted * 99 / 100;
        (, uint256 got) = pool.swap(list[0], list[1], 1e21, true, limit, address(this), FAR);
        assertGe(got, limit);
        assertLt(got, quoted);
        _assertSolvent(pool, _none());
    }

    // ---------------------------------------------------------------- gas rule

    /// Below the threshold the swap reverts `InsufficientGas`; at it the hook runs with its
    /// full allowance, both times; and more gas never fails.
    function testGasRuleBoundary() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        bytes memory data = abi.encodeCall(
            IndexPool.swap, (list[0], list[1], 1e18, true, 0, address(this), FAR)
        );
        _probe(pool, data, 30_000_000);
        uint256 low = 100_000;
        uint256 high = 30_000_000;
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            (bool ok,) = _probe(pool, data, middle);
            if (ok) high = middle;
            else low = middle;
        }
        (bool okLow, bytes memory reason) = _probe(pool, data, high - 1);
        assertFalse(okLow);
        assertEq(bytes4(reason), IndexPool.InsufficientGas.selector);
        uint256 count = hook.callCount();
        (bool okHigh,) = address(pool).call{ gas: high }(data);
        assertTrue(okHigh);
        assertEq(hook.callCount(), count + 2);
        (,,,,,, uint256 first) = hook.calls(count);
        (,,,,,, uint256 second) = hook.calls(count + 1);
        assertGe(first, GAS - 1000);
        assertGe(second, GAS - 1000);
        console2.log("least gas a hooked swap may be sent", high);
        for (uint256 extra = 1; extra < 4_000_000; extra = extra * 7 + 1) {
            (bool more,) = _probe(pool, data, high + extra);
            assertTrue(more);
        }
    }

    /// The second check decides (review, finding 3): the hook burns its whole allowance in
    /// `beforeSwap` and both tokens' transfers are dear, so the locked step costs more than
    /// `SWAP_GAS`. One wei under the threshold reverts `InsufficientGas`; at it `afterSwap`
    /// still gets its full allowance.
    function testGasRuleWhenTheCheckBeforeAfterSwapDecides() public {
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.BurnBefore);
        address[] memory list = pool.tokens();
        IndexToken(list[0]).setTransferBurn(250_000);
        IndexToken(list[1]).setTransferBurn(250_000);
        bytes memory data = abi.encodeCall(
            IndexPool.swap, (list[0], list[1], 1e18, true, 0, address(this), FAR)
        );
        uint256 low = 100_000;
        uint256 high = 30_000_000;
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            (bool ok,) = _probe(pool, data, middle);
            if (ok) high = middle;
            else low = middle;
        }
        (bool okLow, bytes memory reason) = _probe(pool, data, high - 1);
        assertFalse(okLow);
        assertEq(bytes4(reason), IndexPool.InsufficientGas.selector);
        // Far above what the first check asks, so the first check is not what decided.
        uint256 callGas = uint256(GAS) * 64 / 63 + pool.HOOK_CALL_GAS();
        assertGt(high, 2 * callGas + pool.SWAP_GAS() + 100_000);
        (bool okHigh,) = address(pool).call{ gas: high }(data);
        assertTrue(okHigh);
        assertEq(hook.callCount(), 1);
        (bool before,,,,,, uint256 entry) = hook.calls(0);
        assertFalse(before);
        assertGe(entry, GAS - 1000);
        console2.log("least gas, burning hook and dear transfers", high);
    }

    // ---------------------------------------------------------------- donations

    function testDonateTakesThirtyPercentAndMintsNothing() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 supply = pool.totalSupply();
        uint256 before = pool.balances()[0];
        uint256 donated = 1000e18 + 7;
        pool.donate(list[0], donated);
        assertEq(pool.owed(list[0]), donated * 3000 / 10_000);
        uint256 kept = donated - donated * 3000 / 10_000;
        assertEq(pool.unreleased(list[0]), kept);
        assertEq(pool.totalSupply(), supply);
        assertEq(pool.balances()[0], before);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.balances()[0] - before, kept / 3, 1);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqAbs(pool.balances()[0] - before, kept * 2 / 3, 1);
        vm.warp(block.timestamp + 1 days);
        assertEq(pool.balances()[0] - before, kept);
        assertEq(pool.unreleased(list[0]), 0);
    }

    /// Two equal donations a day apart. The first has 140 of its 210 left with 2 days to
    /// run; adding 210 more at 3 days makes (140 × 2 + 210 × 3) / 350 = 2.6 days left.
    function testSecondDonationMovesTheEndByWeight() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 before = pool.balances()[0];
        pool.donate(list[0], 300e18);
        vm.warp(block.timestamp + 1 days);
        pool.donate(list[0], 300e18);
        uint256 end = block.timestamp + 224_640;
        assertApproxEqAbs(pool.balances()[0] - before, 70e18, 1);
        assertApproxEqAbs(pool.unreleased(list[0]), 350e18, 1);
        vm.warp(block.timestamp + 1.3 days);
        assertApproxEqAbs(pool.unreleased(list[0]), 175e18, 1);
        vm.warp(end - 1);
        assertGt(pool.unreleased(list[0]), 0);
        vm.warp(end);
        assertEq(pool.unreleased(list[0]), 0);
        assertApproxEqAbs(pool.balances()[0] - before, 420e18, 1);
    }

    /// A first donation takes the full 3 days.
    function testFirstDonationTakesThreeDays() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 end = block.timestamp + 3 days;
        pool.donate(list[0], 1000e18);
        vm.warp(end - 1);
        assertGt(pool.unreleased(list[0]), 0);
        vm.warp(end);
        assertEq(pool.unreleased(list[0]), 0);
    }

    /// One wei on top of a large donation does not move its end at all (review, finding
    /// 2): the weighted average rises by far less than a second and is rounded down.
    function testOneWeiDonationDoesNotMoveTheEnd() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 end = block.timestamp + 3 days;
        pool.donate(list[0], 1000e18);
        vm.warp(block.timestamp + 1 days);
        pool.donate(list[0], 1);
        vm.warp(end - 1);
        assertGt(pool.unreleased(list[0]), 0);
        vm.warp(end);
        assertEq(pool.unreleased(list[0]), 0);
    }

    /// The review's second proof of concept: 600 one-wei donations a day into a large one
    /// no longer hold anything back at the original 3-day mark.
    function testDustDonationsDoNotDelayTheRelease() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 end = block.timestamp + 3 days;
        pool.donate(list[0], 1000e18);
        vm.warp(block.timestamp + 1 days);
        for (uint256 index; index < 600; index++) {
            pool.donate(list[0], 1);
        }
        vm.warp(end);
        assertEq(pool.unreleased(list[0]), 0);
    }

    /// A donation never brings the end forward: the time left is never below what was left.
    function testFuzzTimeLeftNeverShrinks(uint256 first, uint256 second, uint256 wait) public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        first = bound(first, 10, 1e24);
        second = bound(second, 1, 1e24);
        wait = bound(wait, 0, 3 days - 2);
        uint256 end = block.timestamp + 3 days;
        pool.donate(list[0], first);
        vm.warp(block.timestamp + wait);
        pool.donate(list[0], second);
        vm.warp(end - 1);
        assertGt(pool.unreleased(list[0]), 0);
    }

    /// What the views report is what the next call applies.
    function testViewsMatchTheNextCall() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        pool.donate(list[0], 300e18);
        vm.warp(block.timestamp + 17 hours);
        uint256[] memory preview = pool.previewJoin(1e21);
        uint256 a = _balanceOf(list[0], address(this));
        pool.join(1e21, preview, FAR);
        assertEq(a - _balanceOf(list[0], address(this)), preview[0]);
        vm.warp(block.timestamp + 5 hours);
        (, uint256 quoted) = pool.quoteSwap(list[1], list[0], 1e18, true);
        (, uint256 got) = _swap(pool, list[1], list[0], 1e18, true);
        assertEq(got, quoted);
    }

    function testDonationThenSwapBackNeverProfitsTheDonor() public {
        (IndexPool pool,) = _hooked(MockIndexHook.Mode.Record);
        address[] memory list = pool.tokens();
        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + 3 days);
        (, uint256 plain) = _swap(pool, list[1], list[0], 1e20, true);
        vm.revertToState(snapshot);
        pool.donate(list[0], 1e21);
        (, uint256 now_) = pool.quoteSwap(list[1], list[0], 1e20, true);
        vm.warp(block.timestamp + 3 days);
        (, uint256 later) = _swap(pool, list[1], list[0], 1e20, true);
        assertLe(later, plain + 1e21);
        assertLe(now_, plain);
    }

    /// Deposit, set off a donation, withdraw: in one transaction nothing is gained, and
    /// over time only what was released while holding.
    function testDepositDonateWithdraw() public {
        assertLe(_depositDonateWithdraw(0), 0);
        int256 bound1 = int256(_releasedShare(12 seconds));
        assertLe(_depositDonateWithdraw(12 seconds), bound1);
        int256 bound2 = int256(_releasedShare(1 hours));
        assertLe(_depositDonateWithdraw(1 hours), bound2);
    }

    // ---------------------------------------------------------------- gas report

    function testGasReport() public {
        IndexPool plain = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        (IndexPool hooked,) = _hooked(MockIndexHook.Mode.Idle);
        _report("no hook", plain);
        _report("idle hook", hooked);
    }

    // ---------------------------------------------------------------- helpers

    function _hooked(MockIndexHook.Mode mode)
        internal
        returns (IndexPool pool, MockIndexHook hook)
    {
        hook = new MockIndexHook();
        pool = _create(_tokens(_same(18, 2)), _equal(2), FEE, address(hook), GAS);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e6;
        units[1] = 1e6;
        _start(pool, units, 1e24);
        _fundAll(address(this), pool, 1e40);
        _fundAll(address(hook), pool, 1e40);
        hook.setPool(pool);
        hook.setMode(mode);
    }

    /// A pool whose hook only trades when told to, with one token of `places` decimals.
    function _hookedPair(uint8 places, uint256[] memory weights)
        internal
        returns (IndexPool pool, MockIndexHook hook)
    {
        return _hookedPair(places, weights, 1e6, 3e6);
    }

    function _hookedPair(uint8 places, uint256[] memory weights, uint256 first, uint256 second)
        internal
        returns (IndexPool pool, MockIndexHook hook)
    {
        hook = new MockIndexHook();
        pool = _create(_tokens(_pair(places, 18)), weights, FEE, address(hook), GAS);
        uint256[] memory units = new uint256[](2);
        units[0] = first;
        units[1] = second;
        _start(pool, units, 1e24);
        _fundAll(address(this), pool, 1e40);
        _fundAll(address(hook), pool, 1e40);
        hook.setPool(pool);
    }

    function _roundTrip(
        IndexPool pool,
        MockIndexHook hook,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool firstExactIn,
        bool backExactIn
    ) internal {
        uint256 snapshot = vm.snapshotState();
        uint256 a = _balanceOf(tokenIn, address(hook));
        uint256 b = _balanceOf(tokenOut, address(hook));
        (uint256 paid, uint256 got) =
            hook.swapAsHook(tokenIn, tokenOut, amount, firstExactIn, firstExactIn ? 0 : FAR);
        // Selling back all that was got leaves that token even, so the other must not gain;
        // buying back all that was paid works the same way the other way round.
        if (backExactIn) {
            hook.swapAsHook(tokenOut, tokenIn, got, true, 0);
            assertLe(_balanceOf(tokenIn, address(hook)), a, "profit");
        } else {
            hook.swapAsHook(tokenOut, tokenIn, paid, false, FAR);
            assertLe(_balanceOf(tokenOut, address(hook)), b, "profit");
        }
        vm.revertToState(snapshot);
    }

    /// Between a billionth and a twentieth of the given token's balance: inside every
    /// limit for both legs at the weights used, so no run is skipped.
    function _given(uint256 amount, uint256 balance) internal pure returns (uint256) {
        return bound(amount, balance / 1e9, balance / 20);
    }

    function _swapGas(MockIndexHook.Mode mode) internal returns (uint256 used) {
        (IndexPool pool,) = _hooked(mode);
        address[] memory list = pool.tokens();
        _swap(pool, list[1], list[0], 1e18, true);
        uint256 start = gasleft();
        _swap(pool, list[0], list[1], 1e18, true);
        used = start - gasleft();
    }

    function _probe(IndexPool pool, bytes memory data, uint256 gas)
        internal
        returns (bool ok, bytes memory reason)
    {
        uint256 snapshot = vm.snapshotState();
        (ok, reason) = address(pool).call{ gas: gas }(data);
        vm.revertToState(snapshot);
    }

    /// The depositor's gain, valued 1:1, from joining nine times the supply, swapping once
    /// (which makes the hook donate 1,000 of token 0), waiting `wait`, and exiting.
    function _depositDonateWithdraw(uint256 wait) internal returns (int256 gain) {
        uint256 snapshot = vm.snapshotState();
        (IndexPool pool, MockIndexHook hook) = _hooked(MockIndexHook.Mode.Honest);
        address[] memory list = pool.tokens();
        hook.setDonation(list[0], 1000e18);
        uint256 a = _balanceOf(list[0], address(this));
        uint256 b = _balanceOf(list[1], address(this));
        uint256 shares = pool.totalSupply() * 9;
        pool.join(shares, _maxes(2), FAR);
        _swap(pool, list[0], list[1], 1e18, true);
        assertGe(pool.owed(list[0]), 300e18, "the hook donated");
        vm.warp(block.timestamp + wait);
        pool.exit(shares, _zeros(2), _none(), FAR);
        gain = int256(_balanceOf(list[0], address(this))) - int256(a);
        gain += int256(_balanceOf(list[1], address(this))) - int256(b);
        vm.revertToState(snapshot);
    }

    /// Nine tenths of what 700 released over `wait` out of 3 days.
    function _releasedShare(uint256 wait) internal pure returns (uint256) {
        return 700e18 * wait / 3 days * 9 / 10 + 1;
    }

    function _report(string memory label, IndexPool pool) internal {
        address[] memory list = pool.tokens();
        _swap(pool, list[1], list[0], 1e18, true);
        uint256 start = gasleft();
        _swap(pool, list[0], list[1], 1e18, true);
        console2.log(label, "swap exact in", start - gasleft());
        start = gasleft();
        _swap(pool, list[0], list[1], 1e18, false);
        console2.log(label, "swap exact out", start - gasleft());
        start = gasleft();
        pool.join(1e21, _maxes(2), FAR);
        console2.log(label, "join", start - gasleft());
        start = gasleft();
        pool.exit(1e21, _zeros(2), _none(), FAR);
        console2.log(label, "exit", start - gasleft());
        start = gasleft();
        pool.donate(list[0], 1e18);
        console2.log(label, "donate", start - gasleft());
    }
}
