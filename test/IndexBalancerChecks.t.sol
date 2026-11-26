// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import {
    BalancerWorld,
    IndexRouter,
    LyingToken,
    RefusingToken
} from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev Checks the review found no test pinned (L-2, the pool-manager accounting, Metric's
/// exact-output fill, and the keeper rule when a refused venue's pair is set aside).
contract IndexBalancerChecksTest is BalancerWorld {
    address internal unit;

    function setUp() public override {
        super.setUp();
        unit = address(new IndexToken(18));
        _readyToken(unit);
    }

    /// A pool of `coin` and the unit, with `coin` at 1.05 on a deep v4 venue.
    function _pairWith(address coin) internal returns (IndexPool pool, PoolKey memory key) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        pool = _create(list, _equal(2), FEE, address(balancer), HOOK_GAS);
        IndexToken(coin).approve(address(pool), type(uint256).max);
        IndexToken(unit).approve(address(pool), type(uint256).max);
        key = _venue(coin, unit, 1.05e18, DEEP, 3000);
        // Settings before the start apply at once.
        _attach(pool, unit, coin, key, 1e15, 0);
        pool.start(_amounts(1000e18, 1000e18), 1e24, FAR);
    }

    /// L-2: with the pool manager locked and a payment waiting in a token the balancer
    /// trades, a swap whose caller cannot be paid back is refused; a keeper's call does
    /// nothing.
    function testAPaymentThatCannotBeReturnedBlocksOnlyBeforeASwap() public {
        RefusingToken coin = new RefusingToken();
        coin.mint(address(this), 1e40);
        coin.approve(address(provider), type(uint256).max);
        (IndexPool pool,) = _pairWith(address(coin));
        IndexRouter router = new IndexRouter(manager);
        coin.mint(address(router), 10e18);
        IndexToken(unit).mint(address(router), 10e18);
        router.approve(unit, address(pool));
        coin.refuse(address(router));
        bytes memory swap = abi.encode(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (unit, address(coin), 1e18, true, 0, address(router), FAR)
            )
        );
        vm.expectRevert(IndexPool.HookBlocked.selector);
        router.payLocked(address(coin), 5e18, swap);
        // The same waiting payment, and a keeper's call in the same transaction: nothing
        // happens, nothing reverts.
        bytes memory keeper = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(pool), address(coin), unit))
        );
        vm.recordLogs();
        router.payLocked(address(coin), 5e18, keeper);
        assertEq(_assertInvariants(pool), 0, "no swap");
    }

    /// The pool-manager accounting checks, inside another contract's unlock where the pool
    /// manager's own end-of-call check cannot cover for them: a token whose balance reads
    /// high after it is paid makes the pool manager credit the balancer more than it sent.
    /// The checks undo the cycle and the outer contract's unlock completes; without them the
    /// cycle stands owing nothing and owed something, and the outer unlock fails.
    function testAccountingChecksInsideAnotherUnlock() public {
        LyingToken liar = new LyingToken();
        liar.mint(address(this), 1e40);
        liar.approve(address(provider), type(uint256).max);
        liar.approve(address(swapper), type(uint256).max);
        (IndexPool pool,) = _pairWith(address(liar));
        liar.setLie(address(manager), 1e18);
        IndexRouter router = new IndexRouter(manager);
        IndexToken(unit).mint(address(router), 1e18);
        bytes memory call = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(pool), address(liar), unit))
        );
        router.run(router.OUTER(), unit, 1e18, call);
        assertEq(router.profit(), 0, "the cycle was undone");
        assertEq(router.countBefore(), router.countAfter(), "no balance left open");
    }

    /// Metric's exact output must fill in full: with the balancer holding a gift of the
    /// unit, a part-filled exact output could otherwise be paid for from the gift.
    function testMetricExactOutputMustFillInFull() public {
        address[] memory list = _two(18, 18);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool first = _metricVenue(list[0], unit, 1.05e18, 2000e18, true);
        _attachRoutes(pool, unit, list[0], _metricRoutes(address(first)), 1e15, 0);
        PoolKey memory key = _venue(list[1], unit, 1e18, DEEP, 3000);
        _attachRoutes(pool, unit, list[1], _routes(key), 1e15, 0);
        first.setMaxFill(1e18);
        IndexToken(unit).mint(address(balancer), 50e18);
        balancer.balance(address(pool), list[0], list[1]);
        assertEq(IndexToken(unit).balanceOf(address(balancer)), 50e18, "the gift untouched");
    }

    /// A keeper's call that drops a refusing Metric venue, with nothing to fall back on,
    /// sets nothing aside.
    function testKeeperSetsNothingAsideWhenAVenueRefuses() public {
        address[] memory list = new address[](2);
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool metric = _metricVenue(coin, unit, 1.05e18, 2000e18, true);
        _attachRoutes(pool, unit, coin, _metricRoutes(address(metric)), 1e15, 0);
        metric.setSwitches(0, false, true, false);
        bytes32 pair = keccak256(abi.encode(address(pool), unit, coin));
        uint256 snapshot = vm.snapshotState();
        assertEq(balancer.balance(address(pool), coin, unit), 0, "nothing");
        (uint64 until,) = settings.benched(pair);
        assertEq(until, 0, "a keeper sets nothing aside");
        vm.revertToState(snapshot);
        // The same refusal before a swap does set the pair aside: the test is not empty.
        IndexToken(unit).approve(address(pool), type(uint256).max);
        _swap(pool, unit, coin, 1e18, true);
        (until,) = settings.benched(pair);
        assertGt(until, 0, "a swap sets it aside");
    }

    /// The callback runs only the cycle the balancer itself handed Metric: a pool that hands
    /// back another (here the same cycle aimed at a second pool of the same tokens, to trade
    /// it fee-free and donate elsewhere) is refused, and nothing is traded.
    function testCallbackRunsOnlyTheCycleItHandedOver() public {
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        IndexPool own = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        IndexPool other = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool metric = _metricVenue(coin, unit, 1.05e18, 2000e18, true);
        _attachRoutes(own, unit, coin, _metricRoutes(address(metric)), 1e15, 0);
        metric.setTamper(address(other));
        vm.recordLogs();
        balancer.balance(address(own), coin, unit);
        assertEq(_assertInvariants(own), 0, "nothing traded");
        assertEq(other.owed(coin), 0, "the other pool untouched");
    }

    /// A Metric pool whose callback asks to be paid nothing, while reporting the input as
    /// taken, is refused: the balancer would otherwise keep the tokens it never paid.
    function testCallbackThatAsksNothingIsRefused() public {
        address coin = address(new IndexToken(18));
        _readyToken(coin);
        address[] memory list = new address[](2);
        (list[0], list[1]) = coin < unit ? (coin, unit) : (unit, coin);
        IndexPool pool = _hooked(list, _equal(2), _amounts(1000e18, 1000e18));
        MockBinPool metric = _metricVenue(coin, unit, 1.05e18, 2000e18, true);
        _attachRoutes(pool, unit, coin, _metricRoutes(address(metric)), 1e15, 0);
        metric.setAskNothing(true);
        vm.recordLogs();
        balancer.balance(address(pool), coin, unit);
        assertEq(_assertInvariants(pool), 0, "nothing traded, nothing kept");
    }
}
