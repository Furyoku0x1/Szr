// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken, MockIndexHook } from "./utils/IndexWorld.sol";
import {
    BalancerWorld,
    FakeIndexPool,
    IndexRouter,
    LyingToken
} from "./utils/IndexBalancerWorld.sol";

/// @dev Who the balancer acts for, failure as silence, setting a pair aside, fee-free access,
/// hostile tokens, and the gas of the three kinds of call.
contract IndexBalancerSafetyTest is BalancerWorld {
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

    function _gapped(uint256 price, uint128 units, uint256 minimumProfit) internal {
        venue = _venue(token, unit, price, units, 3000);
        _attach(pool, unit, token, venue, 1e15, minimumProfit);
    }

    /// The tests of silence would pass for nothing without a gap that pays.
    function _assertGapOpen() internal {
        (uint256 width, bool cheap) = balancer.gap(address(pool), token, unit);
        assertGt(width, 0.04e18, "a gap that pays");
        assertTrue(cheap, "the token is cheap");
    }

    /// Tries that run out of gas in a swap set nothing aside, since more gas might have
    /// worked: a pool whose hook is given enough to try, but not enough to finish a cycle.
    function testTriesThatRunOutSetNothingAside() public {
        address[] memory list = _two(18, 18);
        factory.setHookApproved(address(balancer), 700_000);
        IndexPool thin =
            IndexPool(factory.create("T", "T", list, _equal(2), FEE, address(balancer), 0));
        IndexToken(list[0]).approve(address(thin), type(uint256).max);
        IndexToken(list[1]).approve(address(thin), type(uint256).max);
        thin.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        _attach(thin, list[1], list[0], _venue(list[0], list[1], 1.05e18, DEEP, 3000), 1e15, 0);
        vm.recordLogs();
        _swap(thin, list[1], list[0], 1e18, true);
        assertEq(_assertInvariants(thin), 0, "every try ran out");
        (uint64 until,) =
            settings.benched(keccak256(abi.encode(address(thin), list[1], list[0])));
        assertEq(until, 0, "nothing set aside");
        assertGt(balancer.balance(address(thin), list[0], list[1]), 0, "more gas works");
    }

    /// A pool from the factory whose hook is another contract does nothing, though its
    /// creator gave it routes and its gap pays even with the swap fee.
    function testPoolOnAnotherHookIsIgnored() public {
        MockIndexHook other = new MockIndexHook();
        other.setMode(MockIndexHook.Mode.Idle);
        address[] memory list = _two(18, 18);
        IndexPool elsewhere = _create(list, _equal(2), FEE, address(other), HOOK_GAS);
        IndexToken(list[0]).approve(address(elsewhere), type(uint256).max);
        IndexToken(list[1]).approve(address(elsewhere), type(uint256).max);
        elsewhere.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        PoolKey memory key = _venue(list[0], list[1], 1.05e18, DEEP, 3000);
        _attach(elsewhere, list[1], list[0], key, 1e15, 0);
        (uint256 width,) = balancer.gap(address(elsewhere), list[0], list[1]);
        assertGt(width, 0.04e18, "a gap that pays");
        vm.recordLogs();
        assertEq(balancer.balance(address(elsewhere), list[0], list[1]), 0, "ignored");
        assertEq(_assertInvariants(elsewhere), 0, "no swap");
    }

    /// A pool not from the factory, and a plain call, do nothing.
    function testFakePoolAndPlainCallAreIgnored() public {
        _gapped(1.05e18, DEEP, 0);
        FakeIndexPool fake = new FakeIndexPool(address(balancer));
        vm.recordLogs();
        fake.poke(token, unit);
        balancer.beforeSwap(address(this), token, unit);
        balancer.afterSwap(address(this), token, unit, 1, 1);
        assertEq(balancer.balance(address(fake), token, unit), 0, "fake ignored");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// A paused token: no swap, no revert.
    function testPausedTokenIsSilent() public {
        _gapped(1.05e18, DEEP, 0);
        IndexToken(token).setPaused(true);
        _assertGapOpen();
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// The outflow limit reached for the token the cycle takes out: the balancer's own
    /// cycles take it down to the floor while the gap is still open, and the next call is
    /// silent.
    function testOutflowLimitIsSilent() public {
        // At three times the pool's price the pool would have to give up 42% of the token.
        _gapped(3e18, DEEP, 0);
        for (uint256 call; call < 40; call++) {
            if (balancer.balance(address(pool), token, unit) == 0) break;
        }
        (uint256 width, bool cheap) = balancer.gap(address(pool), token, unit);
        assertGt(width, 0.1e18, "a wide gap left");
        assertTrue(cheap, "the cycle would take the token out");
        assertLt(pool.balances()[0], 720e18, "the token is near its 70% floor");
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// A venue with a price and no liquidity.
    function testEmptyVenueIsSilent() public {
        _gapped(1.05e18, 0, 0);
        _assertGapOpen();
        vm.recordLogs();
        assertEq(balancer.balance(address(pool), token, unit), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// Too little gas, whether for anything at all or for a whole try: no swap, no revert.
    /// A pool whose hook is given too little gas still swaps.
    function testTooLittleGasIsSilent() public {
        _gapped(1.05e18, DEEP, 0);
        _assertGapOpen();
        vm.recordLogs();
        assertEq(balancer.balance{ gas: 60_000 }(address(pool), token, unit), 0, "starved");
        assertEq(balancer.balance{ gas: 400_000 }(address(pool), token, unit), 0, "short");
        assertEq(_assertInvariants(pool), 0, "no swap");
        address[] memory list = _two(18, 18);
        factory.setHookApproved(address(balancer), 300_000);
        IndexPool thin =
            IndexPool(factory.create("T", "T", list, _equal(2), FEE, address(balancer), 0));
        IndexToken(list[0]).approve(address(thin), type(uint256).max);
        IndexToken(list[1]).approve(address(thin), type(uint256).max);
        thin.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        _attach(thin, list[1], list[0], _venue(list[0], list[1], 1.05e18, DEEP, 3000), 1e15, 0);
        vm.recordLogs();
        (, uint256 out) = _swap(thin, list[1], list[0], 1e18, true);
        assertGt(out, 0, "the swap goes on");
        assertEq(_assertInvariants(thin), 0, "no balancing swap");
    }

    /// A token whose balance of the pool manager reads high after it is paid: the pool
    /// manager credits more than was sent, and the cycle is refused.
    function testLyingBalanceCannotMakeACycleStand() public {
        LyingToken liar = new LyingToken();
        liar.mint(address(this), 1e40);
        liar.approve(address(provider), type(uint256).max);
        liar.approve(address(swapper), type(uint256).max);
        address[] memory list = new address[](2);
        (list[0], list[1]) =
            address(liar) < unit ? (address(liar), unit) : (unit, address(liar));
        liar.approve(address(factory), type(uint256).max);
        IndexPool lied = _create(list, _equal(2), FEE, address(balancer), HOOK_GAS);
        liar.approve(address(lied), type(uint256).max);
        IndexToken(unit).approve(address(lied), type(uint256).max);
        lied.start(_amounts(1000e18, 1000e18), 1e24, FAR);
        PoolKey memory key = _venue(address(liar), unit, 1.05e18, DEEP, 3000);
        _attach(lied, unit, address(liar), key, 1e15, 0);
        liar.setLie(address(manager), 1e18);
        vm.recordLogs();
        assertEq(balancer.balance(address(lied), address(liar), unit), 0, "refused");
        assertEq(_assertInvariants(lied), 0, "no swap");
        assertEq(liar.balanceOf(address(balancer)), 0, "holds none");
    }

    /// A pair whose tries all fail in a swap is set aside: skipped for 3 minutes at less than
    /// one try's cost, tried again when the gap doubles, and again after the time.
    function testPairWhoseTriesFailIsSetAside() public {
        _gapped(1.02e18, 1e22, 0);
        // A fee on transfer makes every cycle fail: the balancer is paid less than the pool
        // sent. The trader's own swap goes on.
        IndexToken(token).setFee(100);
        vm.recordLogs();
        _swap(pool, unit, token, 1e18, true);
        assertEq(_assertInvariants(pool), 0, "every try failed");
        bytes32 pair = keccak256(abi.encode(address(pool), unit, token));
        (uint64 until, uint192 failed) = settings.benched(pair);
        assertEq(until, block.timestamp + 3 minutes, "set aside");
        IndexToken(token).setFee(0);
        uint256 snapshot = vm.snapshotState();
        uint256 before = gasleft();
        assertEq(balancer.balance(address(pool), token, unit), 0, "skipped");
        uint256 spent = before - gasleft();
        console.log("a skipped call", spent);
        assertLt(spent, 150_000, "less than one try");
        // The gap more than doubles: tried at once.
        _push(venue, unit, 300e18);
        (uint256 width,) = balancer.gap(address(pool), token, unit);
        assertGt(width, 2 * uint256(failed), "doubled");
        assertGt(balancer.balance(address(pool), token, unit), 0, "tried again");
        vm.revertToState(snapshot);
        vm.warp(block.timestamp + 3 minutes);
        assertGt(balancer.balance(address(pool), token, unit), 0, "tried after the time");
        _assertClean(pool);
    }

    /// No sequence lets a trader use the balancer to trade fee-free: it trades only its own
    /// sizes, for profit donated to the pool, and pays nobody. A trader who pushes the pool
    /// and asks the balancer to correct it, then trades back, ends worse off.
    function testNobodyTradesFeeFreeThroughTheBalancer() public {
        _gapped(1e18, DEEP, 0);
        address trader = makeAddr("trader");
        IndexToken(token).mint(trader, 100e18);
        vm.startPrank(trader);
        IndexToken(token).approve(address(pool), type(uint256).max);
        IndexToken(unit).approve(address(pool), type(uint256).max);
        vm.recordLogs();
        (, uint256 got) = pool.swap(token, unit, 100e18, true, 0, trader, block.timestamp);
        assertEq(balancer.balance(address(pool), token, unit), 0, "closed already");
        pool.swap(unit, token, got, true, 0, trader, block.timestamp);
        balancer.balance(address(pool), unit, token);
        vm.stopPrank();
        assertLt(IndexToken(token).balanceOf(trader), 100e18, "worse off");
        assertEq(IndexToken(unit).balanceOf(trader), 0, "no units kept");
        assertGt(_assertInvariants(pool), 0, "the balancer traded for the pool");
    }

    /// Every contract a call touches marked cold, as at the start of a transaction.
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(balancer));
        vm.cool(address(balancer.sizer()));
        vm.cool(address(factory));
        vm.cool(address(pool));
        vm.cool(token);
        vm.cool(unit);
    }

    function _measure(string memory label) internal returns (uint256 profit) {
        _cool();
        uint256 before = gasleft();
        profit = balancer.balance(address(pool), token, unit);
        console.log(label, before - gasleft());
    }

    /// The gas of a call that finds no gap, a cycle that pays at its first try, and a cycle
    /// whose five tries all fail, each with everything cold.
    function testGasOfACallWithNoGap() public {
        _gapped(1e18, DEEP, 0);
        assertEq(_measure("no gap"), 0, "no gap");
    }

    function testGasOfAOneTryCycle() public {
        _gapped(1.05e18, DEEP, 0);
        assertGt(_measure("one try"), 0, "one try");
        _assertClean(pool);
    }

    /// Five tries that each run the whole cycle and fail only at the profit check.
    function testGasOfFiveFailedTries() public {
        _gapped(1.05e18, DEEP, 1e30);
        assertEq(_measure("five tries failing the profit check"), 0, "five tries");
        _assertClean(pool);
    }

    /// Five tries that fail early, at the first transfer to the pool manager.
    function testGasOfFiveEarlyFailures() public {
        _gapped(1.05e18, DEEP, 0);
        IndexToken(token).setFee(100);
        assertEq(_measure("five tries failing at the first transfer"), 0, "five tries");
        _assertClean(pool);
    }

    /// The no-gap cost as the pool's own `beforeSwap` call.
    function testGasOfAHookCallWithNoGap() public {
        _gapped(1e18, DEEP, 0);
        _cool();
        vm.prank(address(pool));
        uint256 before = gasleft();
        balancer.beforeSwap(address(this), token, unit);
        console.log("no gap, beforeSwap", before - gasleft());
    }
}
