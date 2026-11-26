// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexSizer } from "../src/index/IndexSizer.sol";
import { IIndexHook } from "../src/interfaces/IIndexHook.sol";
import { IMetricPool, IMetricSwapCallback } from "../src/interfaces/metric/IMetricPool.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev Makes one configured call when asked, as an attacker's callback would, and keeps
/// what it returned. It can also make the call as if from a given address.
contract Caller {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address public target;
    bytes public call;
    address public posing;
    bool public ok;
    bytes public result;
    bool public called;

    function set(address target_, bytes calldata call_, address posing_) external {
        (target, call, posing) = (target_, call_, posing_);
    }

    function go() external {
        called = true;
        if (posing != address(0)) VM.prank(posing);
        (ok, result) = target.call(call);
    }

    function approve(address token, address spender) external {
        IndexToken(token).approve(spender, type(uint256).max);
    }
}

/// @dev Makes a dust swap on a Metric pool and, inside its callback, the configured call:
/// the review's H-2 attack.
contract MetricLockAttacker is IMetricSwapCallback {
    Caller public immutable inner = new Caller();

    function attack(address pool, bool zeroForOne, uint256 amount) external {
        IMetricPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int128(uint128(amount)),
                zeroForOne ? 0 : type(uint128).max,
                "",
                ""
            );
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        inner.go();
        address token0 = MockBinPool(msg.sender).token0();
        address token1 = MockBinPool(msg.sender).token1();
        if (amount0 > 0) IndexToken(token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IndexToken(token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @dev The fixes from the review of 2026-11-25: nested swaps (H-1), a locked Metric venue
/// (H-2), a losing size on Metric (L-1), a payment that cannot be returned (L-2), and the
/// checks the review found unpinned.
contract IndexBalancerReviewTest is BalancerWorld {
    address internal token;
    address internal unit;
    IndexPool internal victim;
    PoolKey internal venue;
    Caller internal caller;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        victim = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        venue = _venue(token, unit, 1.05e18, DEEP, 3000);
        _attach(victim, unit, token, venue, 1e15, 0);
        caller = new Caller();
        IndexToken(unit).mint(address(caller), 1000e18);
        caller.approve(unit, address(victim));
    }

    function _victimSwap(address recipient) internal view returns (bytes memory) {
        return abi.encodeCall(
            IndexPool.swap, (unit, token, 50e18, true, 0, recipient, block.timestamp)
        );
    }

    /// The attacker's own pool: a token that calls the attacker on its next transfer and a
    /// venue that makes a small cycle pay.
    function _baitPool()
        internal
        returns (IndexPool bait, address baitToken, address baitUnit)
    {
        address[] memory list = _two(18, 18);
        (baitToken, baitUnit) = (list[0], list[1]);
        bait = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        _attach(
            bait, baitUnit, baitToken, _venue(baitToken, baitUnit, 1.05e18, DEEP, 3000), 1e15, 0
        );
        IndexToken(baitUnit).setReenter(address(caller), abi.encodeCall(Caller.go, ()));
    }

    // ------------------------------------------------------------------ H-1

    /// The review's proof of concept: a swap in the victim pool made from inside a token
    /// transfer during a cycle for the attacker's pool is refused; the attacker's cycle is
    /// unaffected; an honest swap right after is balanced as usual.
    function testNestedSwapIsBlocked() public {
        (IndexPool bait, address baitToken, address baitUnit) = _baitPool();
        caller.set(address(victim), _victimSwap(address(caller)), address(0));
        vm.recordLogs();
        uint256 profit = balancer.balance{ gas: 30_000_000 }(address(bait), baitToken, baitUnit);
        assertTrue(caller.called(), "the attacker was called mid-cycle");
        assertFalse(caller.ok(), "its swap failed");
        assertEq(bytes4(caller.result()), IndexPool.HookBlocked.selector, "blocked");
        assertGt(profit, 0, "the attacker's own cycle stands");
        assertEq(victim.owed(token), 0, "the victim untouched");
        _assertInvariants(bait);
        vm.recordLogs();
        _swap(victim, unit, token, 50e18, true);
        assertGe(_assertInvariants(victim), 1, "an honest swap after is balanced");
    }

    /// The same nesting into `afterSwap`, as the victim pool would call it, and into
    /// `balance`, returns at once without blocking.
    function testNestedAfterSwapAndBalanceReturn() public {
        for (uint256 run; run < 2; run++) {
            uint256 snapshot = vm.snapshotState();
            (IndexPool bait, address baitToken, address baitUnit) = _baitPool();
            bytes memory call = run == 0
                ? abi.encodeCall(IndexBalancer.afterSwap, (address(caller), unit, token, 1, 1))
                : abi.encodeCall(IndexBalancer.balance, (address(victim), token, unit));
            caller.set(address(balancer), call, run == 0 ? address(victim) : address(0));
            balancer.balance{ gas: 30_000_000 }(address(bait), baitToken, baitUnit);
            assertTrue(caller.called(), "called mid-cycle");
            assertTrue(caller.ok(), "returned");
            vm.revertToState(snapshot);
        }
    }

    /// The same nesting through a Metric pool's extension with honest tokens: the attacker's
    /// pool is balanced against a Metric pool whose extension swaps in the victim pool.
    function testNestedSwapThroughAMetricExtensionIsBlocked() public {
        address[] memory list = _two(18, 18);
        IndexPool own = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool metric = _metricVenue(list[0], list[1], 1.05e18, 2000e18, true);
        _attachRoutes(own, list[1], list[0], _metricRoutes(address(metric)), 1e15, 0);
        caller.set(address(victim), _victimSwap(address(caller)), address(0));
        metric.setExtension(address(caller), abi.encodeCall(Caller.go, ()));
        balancer.balance{ gas: 30_000_000 }(address(own), list[0], list[1]);
        assertTrue(caller.called(), "the extension ran mid-cycle");
        assertEq(bytes4(caller.result()), IndexPool.HookBlocked.selector, "blocked");
    }

    // ------------------------------------------------------------------ H-2

    function _metricVictim(uint256 price)
        internal
        returns (IndexPool pool, address coin, MockBinPool metric)
    {
        address[] memory list = _two(18, 18);
        coin = list[0];
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        metric = _metricVenue(coin, list[1], price, 2000e18, true);
        _attachRoutes(pool, list[1], coin, _metricRoutes(address(metric)), 1e15, 0);
    }

    /// The review's proof of concept on the mock: a swap in the index pool from inside a
    /// callback of its own Metric venue is refused.
    function testSwapInsideTheMetricVenuesCallbackIsBlocked() public {
        (IndexPool pool, address coin, MockBinPool metric) = _metricVictim(1.02e18);
        MetricLockAttacker attacker = _lockAttacker(pool, coin, metric);
        attacker.attack(address(metric), false, 10e18);
        Caller inner = attacker.inner();
        assertTrue(inner.called(), "called inside the Metric swap");
        assertEq(bytes4(inner.result()), IndexPool.HookBlocked.selector, "blocked");
    }

    function _lockAttacker(IndexPool pool, address coin, MockBinPool metric)
        internal
        returns (MetricLockAttacker attacker)
    {
        attacker = new MetricLockAttacker();
        address other = metric.token1();
        IndexToken(other).mint(address(attacker), 1000e18);
        IndexToken(other).mint(address(attacker.inner()), 1000e18);
        attacker.inner().approve(other, address(pool));
        attacker.inner()
            .set(
                address(pool),
                abi.encodeCall(
                    IndexPool.swap,
                    (other, coin, 20e18, true, 0, address(attacker.inner()), block.timestamp)
                ),
                address(0)
            );
    }

    /// From inside the callback, `balance` and `afterSwap` return without blocking.
    function testInsideTheMetricCallbackKeeperAndAfterSwapReturn() public {
        (IndexPool pool, address coin, MockBinPool metric) = _metricVictim(1.02e18);
        MetricLockAttacker attacker = _lockAttacker(pool, coin, metric);
        attacker.inner()
            .set(
                address(balancer),
                abi.encodeCall(IndexBalancer.balance, (address(pool), coin, metric.token1())),
                address(0)
            );
        attacker.attack(address(metric), false, 10e18);
        assertTrue(attacker.inner().ok(), "balance returned");
        attacker.inner()
            .set(
                address(balancer),
                abi.encodeCall(
                    IndexBalancer.afterSwap, (address(this), coin, metric.token1(), 1, 1)
                ),
                address(pool)
            );
        attacker.attack(address(metric), false, 10e18);
        assertTrue(attacker.inner().ok(), "afterSwap returned");
    }

    /// A stalled feed, a paused pool and a guard do not block a swap; nor does a locked
    /// Metric pool that is not a venue of the pair.
    function testOtherMetricFailuresAndUnrelatedLocksDoNotBlock() public {
        for (uint256 run; run < 3; run++) {
            uint256 snapshot = vm.snapshotState();
            (IndexPool pool, address coin, MockBinPool metric) = _metricVictim(1.02e18);
            if (run == 0) metric.setSwitches(0, true, false, false);
            if (run == 1) metric.setSwitches(1, false, false, false);
            if (run == 2) metric.setSwitches(0, false, true, false);
            IndexToken(metric.token1()).approve(address(pool), type(uint256).max);
            (, uint256 out) = _swap(pool, metric.token1(), coin, 1e18, true);
            assertGt(out, 0, "the swap goes on");
            vm.revertToState(snapshot);
        }
        // The victim pool's only venue is v4; a swap there from inside an unrelated Metric
        // pool's callback is balanced as usual.
        MockBinPool unrelated = _metricVenue(token, unit, 1e18, 2000e18, true);
        MetricLockAttacker attacker = new MetricLockAttacker();
        IndexToken(unit).mint(address(attacker), 1000e18);
        IndexToken(unit).mint(address(attacker.inner()), 1000e18);
        attacker.inner().approve(unit, address(victim));
        attacker.inner()
            .set(address(victim), _victimSwap(address(attacker.inner())), address(0));
        vm.recordLogs();
        attacker.attack(address(unrelated), false, 10e18);
        assertTrue(attacker.inner().ok(), "not blocked");
        assertGe(_assertInvariants(victim), 1, "and balanced");
    }

    // ------------------------------------------------------------------ L-1

    /// With the walk switched off the first size is the whole gap. Against a Metric bin wide
    /// enough to fill it and about as deep as the pool, that size loses inside Metric's
    /// callback: the smaller sizes are still tried, the venue is not dropped and nothing is
    /// set aside.
    function testALosingSizeOnMetricIsAnOrdinaryFailedTry() public {
        address[] memory list = _two(18, 18);
        address coin = list[0];
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        // A bin 6% wide holding 15 of each: deep enough to fill the whole gap, not to pay for it.
        MockBinPool metric = _metricVenue(coin, list[1], 1.03e18, 15e18, true);
        metric.setLength(60_000);
        _attachRoutes(pool, list[1], coin, _metricRoutes(address(metric)), 1e15, 0);
        address other = metric.token1();
        vm.mockCallRevert(
            address(balancer.sizer()), abi.encodeWithSelector(IndexSizer.size.selector), ""
        );
        IndexToken(other).approve(address(pool), type(uint256).max);
        (Cycle memory cycle,) = balancer.plan(address(pool), coin, other);
        uint256 whole = balancer.whole(cycle);
        vm.recordLogs();
        _swap(pool, other, coin, 1e17, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 stood;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != IndexBalancer.Balanced.selector) continue;
            if (stood == 0) (stood,) = abi.decode(logs[index].data, (uint256, uint256));
        }
        console.log("whole, stood", whole, stood);
        assertLt(stood, whole, "the whole gap lost; a smaller size stood");
        vm.recordLogs();
        (uint64 until,) = settings.benched(keccak256(abi.encode(address(pool), other, coin)));
        assertEq(until, 0, "nothing set aside");
    }
}
