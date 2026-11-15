// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Sweeps and then swaps in one transaction, since the hook's transient state is
/// cleared between a test's top-level calls.
contract SweepThenSwap {
    function run(
        ArbitrageHook hook,
        uint256 id,
        address base,
        PoolSwapTest swapper,
        PoolKey calldata pool,
        address input,
        uint256 amount,
        address paid
    ) external returns (uint256 afterSweep, uint256 afterSwap) {
        TestAsset(input).approve(address(swapper), type(uint256).max);
        hook.sweep(id, base);
        afterSweep = TestAsset(base).balanceOf(paid);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        afterSwap = TestAsset(base).balanceOf(paid);
    }
}

/// @dev A sweep searches every group of a market from its first leader, without a swap.
contract ArbitrageSweepTest is MarketsWorld {
    PoolKey internal open;

    function setUp() public override {
        super.setUp();
        // A pool that runs no hook leads the coin group, so `arb` cannot name it.
        open = _pair(address(backing), address(coin), 1_000, address(0));
        manager.initialize(open, uint160(1 << 96));
        _provide(open, 1_000_000e18);
        vm.prank(team);
        hook.addVenue(id, open);
        _lead(address(backing), address(coin), _list(_id(open), _id(first), _id(second)));
    }

    function _list(bytes32 one, bytes32 two, bytes32 three)
        internal
        pure
        returns (bytes32[] memory list)
    {
        list = new bytes32[](3);
        list[0] = one;
        list[1] = two;
        list[2] = three;
    }

    /// Opens a gap by swapping while the market is off, then switches it back on.
    function _openGap(PoolKey memory pool, address input, uint256 amount) internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(pool, input, amount);
        _limits(address(backing), 1e15);
    }

    function testSweepClosesAGapOnAHooklessHead() public {
        _openGap(first, address(coin), 50_000e18);
        vm.expectRevert(ArbitrageHook.UnknownPool.selector);
        hook.arb(_id(open));
        uint256 protocol = backing.balanceOf(address(core));
        uint256 paid = backing.balanceOf(treasury);
        uint256 profit = hook.sweep(id, address(backing));
        uint256 share = backing.balanceOf(address(core)) - protocol;
        uint256 kept = backing.balanceOf(treasury) - paid;
        assertGt(profit, 0, "gap closed");
        assertEq(share + kept, profit, "all of it paid out");
        _assertThirty(share, profit);
        assertEq(share, (profit * 30 + 99) / 100, "30% rounded up");
        // A second look finds a residual: the first stopped at `MAX_ROUNDS` while still
        // converging on the head, and the other leaders may differ by a sliver.
        assertLt(hook.sweep(id, address(backing)), profit / 100, "nearly all closed");
        _assertNothingHeld();
    }

    function testSweepWithNoGapChangesNothing() public {
        uint256 protocol = backing.balanceOf(address(core));
        vm.recordLogs();
        assertEq(hook.sweep(id, address(backing)), 0);
        assertEq(vm.getRecordedLogs().length, 0, "no events");
        assertEq(backing.balanceOf(address(core)), protocol);
        assertEq(backing.balanceOf(treasury), 0);
        _assertNothingHeld();
    }

    function testSweepDoesNothingForAnOffMarketOrAnUncountableToken() public {
        _openGap(first, address(coin), 50_000e18);
        assertEq(hook.sweep(id, address(coin)), 0, "not a profit token");
        assertEq(hook.sweep(id, address(szr)), 0, "SZR is not this market's");
        assertEq(hook.sweep(1, address(backing)), 0, "WETH is not SZR's");
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        assertEq(hook.sweep(id, address(backing)), 0, "switched off");
        assertEq(backing.balanceOf(treasury), 0, "nothing paid");
        _limits(address(backing), 1e15);
        assertGt(hook.sweep(id, address(backing)), 0, "and the gap is still there");
    }

    /// A swap right after a sweep, in the same transaction, is searched as usual.
    function testSwapRightAfterASweepIsSearched() public {
        SweepThenSwap helper = new SweepThenSwap();
        coin.mint(address(helper), 50_000e18);
        _openGap(first, address(coin), 50_000e18);
        (uint256 afterSweep, uint256 afterSwap) = helper.run(
            hook, id, address(backing), swapper, first, address(coin), 50_000e18, treasury
        );
        assertGt(afterSweep, 0, "sweep paid");
        assertGt(afterSwap, afterSweep, "and the swap's own gap was closed as well");
        _assertNothingHeld();
    }
}

/// @dev A failing cycle during a sweep, and sweeping SZR's market.
contract ArbitrageSweepSzrTest is ArbitrageWorld {
    function testSweepClosesEveryGroupAndRetiresSzr() public {
        TestAsset eur = new TestAsset();
        PoolKey memory eurPool = _addPartner(eur);
        assertEq(hook.groupsOf(1, address(szr)).length, 3);
        uint32 allowance = hook.market(1).gasLimit;
        uint128 floor = hook.minimumProfit(1, address(szr));
        uint64 edge = hook.market(1).minimumEdge;
        hook.setLimits(1, address(szr), 0, floor, edge);
        _trade(usdPool, address(szr), 50_000e18);
        _trade(eurPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), allowance, floor, edge);
        uint256 inventory = core.unreleasedSupply();
        uint256 gas = gasleft();
        uint256 profit = hook.sweep(1, address(szr));
        gas -= gasleft();
        console2.log("sweep over three groups, gas", gas);
        assertGt(profit, 0, "gaps closed");
        assertEq(core.unreleasedSupply() - inventory, profit, "SZR retired");
        assertEq(hook.arb(_id(usdPool)), 0, "USD group closed");
        assertEq(hook.arb(_id(eurPool)), 0, "EUR group closed");
        _assertHookEmpty();
    }

    function testSweepLeavesAFailingCycleUnbenched() public {
        PoolKey memory fake = _fakeVenue(21_960, 1e22);
        vm.recordLogs();
        hook.sweep(1, address(szr));
        assertGt(_failures(), 0, "failure reported");
        assertEq(
            hook.benchedUntil(1, address(szr), _id(usdPool), _id(fake), false),
            0,
            "not set aside"
        );
        // A swap still tries it, and sets it aside.
        _trade(usdPool, address(usd), 1e15);
        assertGt(
            hook.benchedUntil(1, address(szr), _id(usdPool), _id(fake), false),
            block.timestamp,
            "tried by the swap"
        );
    }
}

/// @dev A group whose head is a wrapped pool is skipped; the others are still searched.
contract ArbitrageSweepWrappedTest is MarketsWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    PoolKey internal outside;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        outside = _pair(address(backing), address(coin), 3_000, address(wrapper));
        manager.initialize(outside, uint160(1 << 96));
        backing.mint(address(wrapper), 1_000_000e18);
        coin.mint(address(wrapper), 1_000_000e18);
        wrapper.seed(outside, 1_000_000e18, 1_000_000e18);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, outside);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(outside), _id(first)));
        _limits(address(backing), 1e15);
    }

    function _held() internal view returns (uint256 weth) {
        (uint256 zero, uint256 one) = wrapper.reservesOf(_id(outside));
        return Currency.unwrap(outside.currency0) == address(backing) ? zero : one;
    }

    function testWrappedHeadIsSkippedAndOtherGroupsAreSearched() public {
        PoolKey memory one = _create(address(backing), address(usd), 3_000);
        PoolKey memory two = _create(address(backing), address(usd), 500);
        _lead(address(backing), address(usd), _list(_id(one), _id(two)));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        // A gap in each group.
        _trade(first, address(coin), 50_000e18);
        _trade(one, address(usd), 50_000e18);
        _limits(address(backing), 1e15);
        uint256 held = _held();
        uint256 profit = hook.sweep(id, address(backing));
        assertGt(profit, 0, "the USD group was searched");
        assertEq(_held(), held, "the wrapped head was not a centre");
        assertEq(hook.sweep(id, address(backing)), 0, "and the skipped gap stays");
        _assertNothingHeld();
    }

    /// A sweep started from inside a search, here from a wrapped pool's hook in the middle
    /// of a cycle, is refused.
    function testSweepInsideASearchIsBusy() public {
        _lead(address(backing), address(coin), _list(_id(first), _id(outside)));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        wrapper.arm(6, outside, address(hook), id);
        assertGt(hook.sweep(id, address(backing)), 0, "the cycle went through");
        assertEq(wrapper.seen(), ArbitrageHook.Busy.selector, "refused");
        _assertNothingHeld();
    }
}

/// @dev A sweep that runs short of gas between heads keeps what the earlier heads earned.
contract ArbitrageSweepGasTest is MarketsWorld {
    PoolKey internal open;

    function setUp() public override {
        super.setUp();
        open = _pair(address(backing), address(coin), 1_000, address(0));
        manager.initialize(open, uint160(1 << 96));
        _provide(open, 1_000_000e18);
        vm.prank(team);
        hook.addVenue(id, open);
        bytes32[] memory coins = new bytes32[](2);
        coins[0] = _id(open);
        coins[1] = _id(first);
        _lead(address(backing), address(coin), coins);
        PoolKey memory one = _create(address(backing), address(usd), 3_000);
        PoolKey memory two = _create(address(backing), address(usd), 500);
        bytes32[] memory dollars = new bytes32[](2);
        dollars[0] = _id(one);
        dollars[1] = _id(two);
        _lead(address(backing), address(usd), dollars);
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _trade(one, address(usd), 50_000e18);
        _limits(address(backing), 1e15);
    }

    function _swept(uint256 gas) internal returns (uint256 profit, uint256 paid) {
        uint256 core0 = backing.balanceOf(address(core)) + backing.balanceOf(treasury);
        profit = hook.sweep{ gas: gas }(id, address(backing));
        paid = backing.balanceOf(address(core)) + backing.balanceOf(treasury) - core0;
    }

    /// Gas for a head's search to start but not to trade. It reverted before the check
    /// between heads existed.
    function testSweepWithGasOnlyToEnterReturnsZero() public {
        (uint256 profit, uint256 paid) = _swept(120_000);
        assertEq(profit, 0);
        assertEq(paid, 0);
        _assertNothingHeld();
    }

    /// Enough for the first head to trade and not for the second to finish. No gas limit
    /// was found at which the gap between the heads made the sweep revert before the check
    /// (a head stops itself well before that), so this pins the behaviour rather than
    /// failing without the check.
    function testSweepShortOfGasKeepsTheFirstHeadsProfit() public {
        uint256 snapshot = vm.snapshotState();
        (uint256 full,) = _swept(30_000_000);
        vm.revertToState(snapshot);
        (uint256 profit, uint256 paid) = _swept(1_650_000);
        assertGt(profit, 0, "the first head traded");
        assertLt(profit, full, "the second did not finish");
        assertEq(paid, profit, "and what it earned was paid");
        _assertNothingHeld();
    }
}
