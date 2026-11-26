// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld, IndexRouter } from "./utils/IndexBalancerWorld.sol";
import { HostileToken } from "./utils/Routers.sol";

/// @dev The balancer's cycles in both directions and shapes, before and after swaps, in both
/// pool-manager lock states, with a marked token, and against re-entry.
contract IndexBalancerTest is BalancerWorld {
    /// A pair with the unit: `token` and `unit`, 1,000 of each, at 1:1.
    address internal token;
    address internal unit;
    IndexPool internal pool;
    PoolKey internal venue;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
    }

    /// The venue values `token` at `price` units; the pool still says 1.
    function _withUnit(uint256 price) internal {
        venue = _venue(token, unit, price, DEEP, 3000);
        _attach(pool, unit, token, venue, 1e15, 0);
    }

    /// The token is cheap in the pool: the balancer sells it on the venue first, pays the
    /// units it is owed into the pool, and takes the token out, with one outside trade. The
    /// profit is in the token taken out.
    function testCheapTokenWithTheUnitIsBoughtAndTheProfitDonated() public {
        _withUnit(1.05e18);
        vm.recordLogs();
        uint256 profit = balancer.balance(address(pool), token, unit);
        assertGt(profit, 0, "profit");
        assertEq(pool.owed(token), profit * 3000 / 10_000, "30% to the protocol");
        assertEq(pool.unreleased(token), profit - profit * 3000 / 10_000, "the rest released");
        assertEq(pool.owed(unit), 0, "nothing in the token paid in");
        assertLt(_distance(_poolPrice(pool, token, unit), 1.05e18), 0.01e18, "pool near venue");
        assertEq(_assertInvariants(pool), 1, "one swap");
    }

    /// The token is dear in the pool: the balancer buys it on the venue with units, pays it
    /// into the pool and takes units out. The profit is in units.
    function testDearTokenWithTheUnitIsSoldAndTheProfitDonated() public {
        _withUnit(0.95e18);
        vm.recordLogs();
        uint256 profit = balancer.balance(address(pool), unit, token);
        assertGt(profit, 0, "profit");
        assertEq(pool.owed(unit), profit * 3000 / 10_000, "30% to the protocol");
        assertLt(_distance(_poolPrice(pool, token, unit), 0.95e18), 0.01e18, "pool near venue");
        assertEq(_assertInvariants(pool), 1, "one swap");
    }

    /// The profit goes to the pool that was balanced, not to another pool of the same
    /// token.
    function testProfitGoesToThePoolBalanced() public {
        address[] memory list = new address[](2);
        address stranger = address(new IndexToken(18));
        _readyToken(stranger);
        (list[0], list[1]) = stranger < token ? (stranger, token) : (token, stranger);
        IndexPool neighbour = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        _withUnit(1.05e18);
        vm.recordLogs();
        uint256 profit = balancer.balance(address(pool), token, unit);
        assertGt(profit, 0, "profit");
        assertEq(pool.owed(token), profit * 3000 / 10_000, "to the pool balanced");
        assertEq(neighbour.owed(token), 0, "not to its neighbour");
        assertEq(neighbour.unreleased(token), 0, "not to its neighbour");
        _assertInvariants(pool);
    }

    /// Without the unit in the pool there are two outside trades, both ways.
    function testPairWithoutTheUnitBalancesBothWays() public {
        (IndexPool other, address first, address second, PoolKey memory one,) =
            _withoutUnit(1.05e18, 1e18);
        vm.recordLogs();
        uint256 profit = balancer.balance(address(other), first, second);
        assertGt(profit, 0, "first cheap");
        assertGt(other.owed(first), 0, "profit in the cheap token");
        assertLt(_distance(_poolPrice(other, first, second), 1.05e18), 0.01e18, "near venues");
        _assertInvariants(other);
        // The venue for the first token falls below the pool: the first is now dear.
        _push(one, first, 30_000e18);
        vm.recordLogs();
        profit = balancer.balance(address(other), first, second);
        assertGt(profit, 0, "first dear");
        assertGt(other.owed(second), 0, "profit in the cheap token");
        _assertInvariants(other);
    }

    /// A pool of two tokens neither of which is the unit, with a venue each.
    function _withoutUnit(uint256 firstPrice, uint256 secondPrice)
        internal
        returns (
            IndexPool other,
            address first,
            address second,
            PoolKey memory one,
            PoolKey memory two
        )
    {
        address[] memory list = _two(18, 18);
        (first, second) = (list[0], list[1]);
        other = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        one = _venue(first, unit, firstPrice, DEEP, 3000);
        two = _venue(second, unit, secondPrice, DEEP, 3000);
        _attach(other, unit, first, one, 1e15, 0);
        _attach(other, unit, second, two, 1e15, 0);
    }

    /// A gap under `minimumGap` does nothing.
    function testGapUnderTheMinimumDoesNothing() public {
        venue = _venue(token, unit, 1.05e18, DEEP, 3000);
        _attach(pool, unit, token, venue, 0.2e18, 0);
        (uint256 width, bool cheap) = balancer.gap(address(pool), token, unit);
        assertGt(width, 0.04e18, "a gap after the venue fee");
        assertLt(width, 0.2e18, "under the minimum");
        assertTrue(cheap, "token cheap");
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// A cycle that cannot clear `minimumProfit` is undone at every size and leaves nothing.
    function testLosingCycleIsUndoneWithoutTrace() public {
        venue = _venue(token, unit, 1.05e18, DEEP, 3000);
        _attach(pool, unit, token, venue, 0, 1e30);
        uint256[] memory held = pool.balances();
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
        assertEq(pool.balances()[0], held[0], "balances unchanged");
        assertEq(pool.balances()[1], held[1], "balances unchanged");
        assertEq(pool.owed(unit), 0, "no donation");
        assertEq(pool.owed(token), 0, "no donation");
        (uint64 until,) = settings.benched(keccak256(abi.encode(address(pool), unit, token)));
        assertEq(until, 0, "a keeper call sets nothing aside");
    }

    /// An arbitrageur's swap into a stale pool finds the gap closed before it is priced, so
    /// buying the cheap token and selling it on the venue loses.
    function testArbitrageurFindsTheGapClosed() public {
        _withUnit(1.05e18);
        address trader = makeAddr("trader");
        IndexToken(unit).mint(trader, 100e18);
        vm.startPrank(trader);
        IndexToken(unit).approve(address(pool), type(uint256).max);
        IndexToken(token).approve(address(swapper), type(uint256).max);
        vm.recordLogs();
        (, uint256 bought) = pool.swap(unit, token, 20e18, true, 0, trader, block.timestamp);
        _push(venue, token, bought);
        vm.stopPrank();
        assertLt(IndexToken(unit).balanceOf(trader), 100e18, "the round trip loses");
        assertGe(_assertInvariants(pool), 1, "the balancer traded first");
    }

    /// An ordinary swap opens a gap and `afterSwap` closes it.
    function testOrdinarySwapsGapIsClosedAfterIt() public {
        _withUnit(1e18);
        (uint256 width,) = balancer.gap(address(pool), token, unit);
        assertEq(width, 0, "no gap before");
        vm.recordLogs();
        _swap(pool, token, unit, 50e18, true);
        assertEq(_assertInvariants(pool), 1, "closed after the swap");
        (width,) = balancer.gap(address(pool), token, unit);
        assertLt(width, 0.01e18, "closed");
    }

    /// The same cycle with the pool manager locked and from inside another contract's
    /// unlock, whose own balance there is untouched.
    function testBothLockStatesRunTheSameCycle() public {
        _withUnit(1.05e18);
        IndexRouter router = new IndexRouter(manager);
        uint256 snapshot = vm.snapshotState();
        uint256 locked = balancer.balance(address(pool), token, unit);
        assertGt(locked, 0, "locked");
        vm.revertToState(snapshot);
        IndexToken(unit).mint(address(router), 1e18);
        vm.recordLogs();
        router.run(
            router.OUTER(),
            unit,
            1e18,
            abi.encode(
                address(balancer),
                abi.encodeCall(IndexBalancer.balance, (address(pool), token, unit))
            )
        );
        assertEq(router.profit(), locked, "the same cycle");
        assertEq(router.deltaBefore(), router.deltaAfter(), "outer balance untouched");
        assertEq(router.countBefore(), router.countAfter(), "no balance left open");
        assertEq(_assertInvariants(pool), 1, "one swap");
    }

    /// A router that marks a token the balancer trades and pays only after the swap: the
    /// pool is balanced as usual, the mark is there again afterwards, and the payment then
    /// counts in full.
    function testMarkedTokenWithNothingPaidIsBalancedAndMarkedAgain() public {
        IndexRouter router = _markRouter();
        vm.recordLogs();
        router.run(router.MARK_FIRST(), unit, 5e18, _routerSwap(router));
        assertEq(router.markedAfter(), unit, "marked again");
        assertEq(router.credited(), 5e18, "the later payment counts in full");
        assertGe(_assertInvariants(pool), 1, "balanced");
    }

    /// A pay-first router with the pool manager open: its payment is credited to it in
    /// full and the pool is still balanced.
    function testPaidInTokenIsCreditedToTheCallerAndThePoolBalanced() public {
        IndexRouter router = _markRouter();
        vm.recordLogs();
        router.run(router.PAY_FIRST(), unit, 5e18, _routerSwap(router));
        assertEq(router.credited(), 5e18, "payment credited in full");
        assertEq(router.markedAfter(), unit, "marked again");
        assertGe(_assertInvariants(pool), 1, "balanced");
    }

    /// The same with the pool manager locked: the balancer settles the waiting payment in
    /// its own unlock and sends it back to the swap's caller.
    function testPaidInTokenWhileLockedIsSentBackToTheCaller() public {
        IndexRouter router = _markRouter();
        uint256 before = IndexToken(unit).balanceOf(address(router));
        vm.recordLogs();
        router.payLocked(unit, 5e18, _swapCall(router));
        assertEq(
            before - IndexToken(unit).balanceOf(address(router)), 10e18, "only the swap's input"
        );
        assertEq(router.markedAfter(), unit, "marked again");
        assertGe(_assertInvariants(pool), 1, "balanced");
    }

    /// A keeper's call while a payment is waiting has nobody to credit, so it does nothing,
    /// and the payer's own settle still counts it.
    function testKeeperDoesNothingWhileAPaymentIsWaiting() public {
        IndexRouter router = _markRouter();
        bytes memory call = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(pool), token, unit))
        );
        vm.recordLogs();
        router.run(router.PAY_FIRST(), unit, 5e18, call);
        assertEq(router.credited(), 5e18, "payment credited in full");
        assertEq(_assertInvariants(pool), 0, "nothing done");
    }

    /// A marked token the balancer does not trade is never called, whether its balance
    /// read reverts or burns all gas, and the gap is still closed.
    function testUntradedMarkedTokenIsNeverCalled() public {
        for (uint256 arm = 2; arm < 4; arm++) {
            uint256 snapshot = vm.snapshotState();
            IndexRouter router = _markRouter();
            HostileToken hostile = new HostileToken();
            vm.recordLogs();
            router.run(router.HOSTILE(), address(hostile), arm, _routerSwap(router));
            assertGe(_assertInvariants(pool), 1, "balanced");
            vm.revertToState(snapshot);
        }
    }

    function _markRouter() internal returns (IndexRouter router) {
        _withUnit(1.05e18);
        router = new IndexRouter(manager);
        IndexToken(unit).mint(address(router), 15e18);
        router.approve(unit, address(pool));
    }

    function _swapCall(IndexRouter router) internal view returns (bytes memory) {
        return abi.encode(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (unit, token, 10e18, true, 0, address(router), block.timestamp)
            )
        );
    }

    function _routerSwap(IndexRouter router) internal view returns (bytes memory) {
        return _swapCall(router);
    }

    /// A token that calls back into the balancer mid-cycle gets nothing, and the cycle goes
    /// on.
    function testReentryMidCycleGetsNothing() public {
        _withUnit(1.05e18);
        // A second pool with its own unit and an open gap, which a call back would balance
        // if it got through. The pool manager's balances of the first cycle's tokens are
        // open while it calls back, so the call is made about this one.
        (IndexPool second, address secondToken, address secondUnit) = _separatePool();
        IndexToken(unit)
            .setReenter(
                address(balancer),
                abi.encodeCall(
                    IndexBalancer.balance, (address(second), secondToken, secondUnit)
                )
            );
        vm.recordLogs();
        uint256 profit = balancer.balance(address(pool), token, unit);
        assertTrue(IndexToken(unit).reentered(), "called back");
        assertTrue(IndexToken(unit).reenterOk(), "the call back returned");
        assertEq(abi.decode(IndexToken(unit).reenterResult(), (uint256)), 0, "and got nothing");
        assertGt(profit, 0, "the outer cycle stands");
        assertEq(_assertInvariants(pool), 1, "one swap");
        _assertClean(second);
        assertGt(
            balancer.balance(address(second), secondToken, secondUnit), 0, "its gap was open"
        );
    }

    function _separatePool() internal returns (IndexPool second, address first, address other) {
        address[] memory list = _two(18, 18);
        (first, other) = (list[0], list[1]);
        second = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        PoolKey memory key = _venue(first, other, 1.05e18, DEEP, 3000);
        _attach(second, other, first, key, 1e15, 0);
    }

    /// The first try that clears the minimum stands: one cycle, at the walk's size.
    function testFirstTryThatPaysStands() public {
        _withUnit(1.05e18);
        (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
        uint256 walked = balancer.sizer().size(cycle);
        assertGt(walked, 0, "the walk sizes it");
        vm.recordLogs();
        balancer.balance(address(pool), token, unit);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != IndexBalancer.Balanced.selector) continue;
            (uint256 spend,) = abi.decode(logs[index].data, (uint256, uint256));
            assertEq(spend, walked, "the walk's size");
            found++;
        }
        assertEq(found, 1, "one cycle");
        _assertClean(pool);
    }
}
