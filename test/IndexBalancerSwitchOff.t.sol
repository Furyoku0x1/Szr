// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IIndexHook } from "../src/interfaces/IIndexHook.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { Cycle } from "../src/index/IndexSizer.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld, IndexRouter } from "./utils/IndexBalancerWorld.sol";

/// @dev The three ways of switching the hook off for one transaction: too little gas, a
/// marked token and a drained pool manager. None lets an arbitrageur take the gap.
contract IndexBalancerSwitchOffTest is BalancerWorld, IUnlockCallback {
    address internal token;
    address internal unit;
    IndexPool internal pool;
    PoolKey internal venue;
    IndexRouter internal router;
    bytes internal reason;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
        pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        router = new IndexRouter(manager);
        router.approve(unit, address(pool));
        router.approve(token, address(pool));
        IndexToken(unit).mint(address(router), 100e18);
    }

    function _gapped(uint256 price) internal {
        venue = _venue(token, unit, price, DEEP, 3000);
        _attach(pool, unit, token, venue, 1e15, 0);
    }

    /// The router buys `amount` of units' worth of the token in the pool.
    function _buy(uint256 amount) internal view returns (bytes memory) {
        return abi.encode(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (unit, token, amount, true, 0, address(router), block.timestamp)
            )
        );
    }

    function _keeper() internal view returns (bytes memory) {
        return abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(pool), token, unit))
        );
    }

    function _pair(address pay, address take) internal view returns (uint64 until) {
        (until,) = settings.benched(keccak256(abi.encode(address(pool), pay, take)));
    }

    /// With the pool manager's whole balance of the units the cycle is owed borrowed away,
    /// a swap into the pool with an open gap is refused, and nothing is taken.
    function testDrainedPoolManagerBlocksASwapWithAGap() public {
        _gapped(1.05e18);
        uint256 held = IndexToken(token).balanceOf(address(router));
        uint256 drainable = IndexToken(unit).balanceOf(address(manager));
        uint256 drain = router.DRAIN();
        bytes memory buy10 = _buy(10e18);
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.run(drain, unit, 0, buy10);
        assertEq(IndexToken(token).balanceOf(address(router)), held, "nothing taken");
        assertEq(IndexToken(unit).balanceOf(address(manager)), drainable, "nothing moved");
    }

    /// The same drain with no gap: the balancer takes nothing, so the swap goes through.
    function testDrainedPoolManagerWithNoGapLetsTheSwapThrough() public {
        _gapped(1e18);
        vm.recordLogs();
        router.run(router.DRAIN(), unit, 0, _buy(1e18));
        assertGt(IndexToken(token).balanceOf(address(router)), 0, "the swap went through");
        assertEq(_assertInvariants(pool), 0, "no balancing swap");
    }

    /// After a swap the same shortage only undoes the balancer's work, and sets nothing
    /// aside: the swap opens a gap that needs the drained token.
    function testShortageAfterASwapDoesNothing() public {
        _gapped(1e18);
        vm.recordLogs();
        router.run(router.DRAIN(), token, 0, _buy(50e18));
        assertGt(IndexToken(token).balanceOf(address(router)), 0, "the swap stands");
        assertEq(_assertInvariants(pool), 0, "no balancing swap");
        (uint256 width, bool cheap) = balancer.gap(address(pool), token, unit);
        assertGt(width, 0.04e18, "the swap left a gap");
        assertFalse(cheap, "which needs the drained token");
        assertEq(_pair(token, unit), 0, "nothing set aside");
    }

    /// The balancer's own answer to the same shortage, called as the pool would call it:
    /// `Blocked()` before a swap, nothing at all after one.
    function testOnlyBeforeSwapAnswersBlocked() public {
        _gapped(1.05e18);
        manager.unlock(abi.encode(true));
        assertEq(reason, abi.encodeWithSelector(IIndexHook.Blocked.selector), "before: Blocked");
        vm.recordLogs();
        manager.unlock(abi.encode(false));
        assertEq(reason.length, 0, "after: returns");
        assertEq(_assertInvariants(pool), 0, "no swap");
        assertEq(_pair(unit, token), 0, "nothing set aside");
    }

    /// Takes the pool manager's whole balance of units, calls the hook as the pool, and
    /// pays it all back.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        bool before = abi.decode(data, (bool));
        uint256 held = IndexToken(unit).balanceOf(address(manager));
        manager.take(Currency.wrap(unit), address(this), held);
        delete reason;
        vm.prank(address(pool));
        if (before) {
            try balancer.beforeSwap(address(this), token, unit) { }
            catch (bytes memory failure) {
                reason = failure;
            }
        } else {
            balancer.afterSwap(address(this), token, unit, 1, 1);
        }
        manager.sync(Currency.wrap(unit));
        IndexToken(unit).transfer(address(manager), held);
        manager.settle();
        return "";
    }

    /// A drain of the token the cycle pays in changes nothing: the balancer never borrows
    /// it, it only pays it.
    function testDrainOfTheTokenPaidBackDoesNotBlock() public {
        _gapped(1.05e18);
        vm.recordLogs();
        router.run(router.DRAIN(), token, 0, _buy(1e18));
        assertGe(_assertInvariants(pool), 1, "balanced");
    }

    /// A keeper's call into the same shortage does nothing and sets nothing aside.
    function testShortageInBalanceDoesNothing() public {
        _gapped(1.05e18);
        vm.recordLogs();
        router.run(router.DRAIN(), unit, 0, _keeper());
        assertEq(router.profit(), 0, "nothing");
        assertEq(_assertInvariants(pool), 0, "no swap");
        assertEq(_pair(unit, token), 0, "nothing set aside");
    }

    /// A router that has itself taken most of a token earlier in its unlock is blocked only
    /// when the cycle is owed more than is left: the limit the arbitrage hook accepts.
    function testRouterThatTookMostIsBlockedOnlyBeyondWhatIsLeft() public {
        _gapped(1.05e18);
        (Cycle memory cycle,) = balancer.plan(address(pool), token, unit);
        uint256 size = balancer.sizer().size(cycle);
        (PoolKey[] memory path, address[] memory inputs) = _path(cycle);
        uint256 owed = quoter.quote(path, inputs, size);
        uint256 held = IndexToken(unit).balanceOf(address(manager));
        console.log("units the first try is owed", owed);
        console.log("units the pool manager holds", held);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        router.run(router.OUTER(), unit, held - owed * 2, _buy(1e18));
        assertGe(_assertInvariants(pool), 1, "enough left: balanced");
        vm.revertToState(snapshot);
        uint256 outer = router.OUTER();
        bytes memory buy1 = _buy(1e18);
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.run(outer, unit, held - owed / 2, buy1);
    }

    /// An arbitrageur who tries each way and then sells what it bought on the venue ends
    /// with no profit: too little gas reverts, a marked token changes nothing, and a drain
    /// blocks the swap.
    function testAttackerGainsNothingByAnyWay() public {
        _gapped(1.05e18);
        bytes memory buy = abi.encodeCall(
            IndexPool.swap, (unit, token, 10e18, true, 0, address(this), block.timestamp)
        );
        IndexToken(unit).approve(address(pool), type(uint256).max);
        (bool ok, bytes memory reason) = address(pool).call{ gas: 5_000_000 }(buy);
        assertFalse(ok, "too little gas");
        assertEq(bytes4(reason), IndexPool.InsufficientGas.selector, "refused for gas");
        router.run(router.MARK_ONLY(), unit, 0, _buy(10e18));
        uint256 bought = IndexToken(token).balanceOf(address(router));
        PoolKey[] memory path = new PoolKey[](1);
        address[] memory inputs = new address[](1);
        (path[0], inputs[0]) = (venue, token);
        assertLt(quoter.quote(path, inputs, bought), 10e18, "marking: sold back at a loss");
        _push(venue, unit, 2000e18);
        uint256 drain = router.DRAIN();
        bytes memory again = _buy(10e18);
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.run(drain, unit, 0, again);
        _assertClean(pool);
    }
}
