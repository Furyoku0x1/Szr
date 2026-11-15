// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Pools whose trades are filled somewhere other than the pool manager, such as one
/// of Uniswap's aggregator hooks wrapping another exchange's pool. Liquidity's manager
/// pairs such a hook with a pricer; markets can then trade against its pools.
contract ArbitrageWrappedTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    PoolKey internal outside;

    function setUp() public override {
        super.setUp();
        // The beforeSwap permission and the one that lets it return a delta.
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        outside = _wrap(address(backing), address(coin));
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, outside);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first), _id(outside)));
        _limits(address(backing), 1e15);
    }

    /// A pool on the wrapping hook, holding a million of each token somewhere else.
    function _wrap(address one, address other) internal returns (PoolKey memory pool) {
        pool = _pair(one, other, 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        TestAsset(one).mint(address(wrapper), 1_000_000e18);
        TestAsset(other).mint(address(wrapper), 1_000_000e18);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    function _held(PoolKey memory pool) internal view returns (uint256 weth) {
        (uint256 zero, uint256 one) = wrapper.reservesOf(_id(pool));
        return Currency.unwrap(pool.currency0) == address(backing) ? zero : one;
    }

    function _swapWithGas(PoolKey memory pool, address input, uint256 amount, uint256 gas)
        internal
        returns (bool filled)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(pricer));
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (pool, params, settings, ""))
        );
    }

    /// A gap between the market's own pool and the wrapped one is closed through the pool
    /// manager like any other, in both directions, and the profit is paid as usual.
    function testWrappedPoolIsArbitragedLikeAnyOther() public {
        uint256 before = _held(outside);
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "a cycle against the wrapped pool");
        assertLt(_held(outside), before, "WETH came out of the wrapped pool");
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "team paid");
        // The other way round, the cycle ends at the wrapped pool with an exact output.
        _trade(first, address(backing), 120_000e18);
        assertGt(backing.balanceOf(treasury), kept, "team paid again");
        assertEq(coin.balanceOf(treasury), 0, "never in the team's token");
        assertGt(hook.market(id).pricerGas, 0);
        _assertNothingHeld();
    }

    /// Only Liquidity's manager pairs a hook with a pricer, a pool on any other hook is
    /// refused, and taking the pricer away stops the pool being traded at once.
    function testOnlyAPricedHooksPoolsCanJoin() public {
        vm.prank(team);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setPricer(address(wrapper), address(pricer));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setPricer(address(hook), address(pricer));
        PoolKey memory stranger = _pair(address(backing), address(coin), 500, address(0xF00D));
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.NotTrusted.selector);
        hook.addVenue(id, stranger);
        vm.expectRevert(ArbitrageHook.NotTrusted.selector);
        hook.setConnector(id, _pair(address(coin), address(usd), 500, address(0xF00D)), true);
        vm.stopPrank();
        // SZR's market takes a wrapped pool only if it holds SZR.
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.addVenue(1, outside);
        hook.setPricer(address(wrapper), address(0));
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertEq(_cycles(), 0, "not traded once its pricer is gone");
        _assertNothingHeld();
    }

    /// A pricer that reverts, burns its gas, answers at the wrong length or out of range
    /// only makes its pools disappear. The swap goes through, on little gas too.
    function testBadPricerOnlyHidesItsPools() public {
        for (uint256 mode = 1; mode < 9; mode++) {
            uint256 snapshot = vm.snapshotState();
            pricer.arm(mode);
            vm.recordLogs();
            _trade(first, address(coin), 50_000e18);
            assertEq(_cycles(), 0, "no cycle on a bad answer");
            assertEq(_failures(), 0, "and nothing tried");
            assertTrue(_swapWithGas(first, address(coin), 1e15, 900_000), "short swap fills");
            vm.revertToState(snapshot);
        }
    }

    /// While a cycle runs through a wrapped pool, that pool's hook and the tokens it moves
    /// run their own code. They cannot trade a pool of another market in the meantime: its
    /// search would be standing aside. The attempt fails the cycle and nothing else.
    function testNothingElseOnTheHookTradesWhileAWrappedLegRuns() public {
        address rivalOwner = address(0xBEEF);
        PoolKey memory theirs = _pair(address(backing), address(usd), 500, address(hook));
        vm.startPrank(rivalOwner);
        uint256 rival = hook.openMarket(rivalOwner);
        hook.createPool(rival, theirs, uint160(1 << 96));
        vm.stopPrank();
        _provide(theirs, 1_000_000e18);
        TestAsset(Currency.unwrap(theirs.currency0)).mint(address(wrapper), 10e18);
        wrapper.arm(1, theirs, address(hook), 0);
        (uint160 before,,,) = manager.getSlot0(theirs.toId());
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_failures(), 0, "the cycle through the wrapped pool failed");
        (uint160 afterwards,,,) = manager.getSlot0(theirs.toId());
        assertEq(afterwards, before, "the other market's pool was not traded");
        _assertNothingHeld();
    }

    /// Nor can a market be reconfigured in the middle of a search, by its owner or anyone.
    function testNothingIsConfiguredWhileASearchRuns() public {
        vm.prank(address(wrapper));
        uint256 owned = hook.openMarket(treasury);
        wrapper.arm(2, outside, address(hook), owned);
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_failures(), 0, "the cycle failed");
        assertEq(hook.market(owned).recipient, treasury, "recipient unchanged");
        // Outside a search the same call goes through.
        vm.prank(address(wrapper));
        hook.setRecipient(owned, address(wrapper));
        _assertNothingHeld();
    }

    /// A wrapped pool that fills an exact-output swap short leaves the cycle unable to pay
    /// what it owes, so the cycle fails and nothing is kept.
    function testInexactOutputFailsTheCycle() public {
        wrapper.arm(3, outside, address(hook), 0);
        vm.recordLogs();
        _trade(first, address(backing), 120_000e18);
        assertGt(_failures(), 0, "the cycle failed");
        assertEq(backing.balanceOf(treasury), 0, "nothing paid");
        _assertNothingHeld();
    }

    /// A wrapped pool's hook that ends a swap owing the pool manager, or that credits this
    /// hook with something on the side, would have the swapper's whole transaction refused
    /// at the end. The cycle fails instead, and the swap goes through.
    function testUnsettledWrappedLegFailsTheCycleNotTheSwap() public {
        for (uint256 mode = 4; mode < 6; mode++) {
            uint256 snapshot = vm.snapshotState();
            wrapper.arm(mode, outside, address(hook), 0);
            vm.recordLogs();
            _trade(first, address(coin), 50_000e18);
            assertGt(_failures(), 0, "the cycle failed");
            assertEq(backing.balanceOf(treasury), 0, "nothing paid");
            _assertNothingHeld();
            vm.revertToState(snapshot);
        }
    }

    /// A pricer with no code behind it gives no price, like any other bad answer.
    function testPricerWithNoCodeHidesItsPools() public {
        hook.setPricer(address(wrapper), address(0xDEAD));
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertEq(_cycles(), 0, "no cycle");
        assertEq(_failures(), 0, "and nothing tried");
    }

    /// Adding a wrapped pool raises what a market must reserve, and its owner sets how
    /// much gas its pricers get, within what one byte of units can hold.
    function testOwnerSetsPricerGas() public {
        address rivalOwner = address(0xBEEF);
        PoolKey memory theirs = _pair(address(backing), address(coin), 100, address(hook));
        vm.startPrank(rivalOwner);
        uint256 rival = hook.openMarket(rivalOwner);
        hook.createPool(rival, theirs, uint160(1 << 96));
        hook.setLeaders(rival, address(backing), address(coin), _list(_id(theirs)));
        uint256 plain = hook.minimumGasLimit(rival);
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setPricerGas(rival, 40_000);
        hook.addVenue(rival, outside);
        uint256 wrapped = hook.minimumGasLimit(rival);
        assertGt(wrapped, plain, "more is reserved once a wrapped pool is added");
        assertEq(hook.market(rival).pricerGas, 20_000, "the default");
        hook.setPricerGas(rival, 37_000);
        assertEq(hook.market(rival).pricerGas, 40_000, "rounded up to a whole unit");
        assertGt(hook.minimumGasLimit(rival), wrapped, "and more again for more gas");
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setPricerGas(rival, 0);
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setPricerGas(rival, 1_020_001);
        vm.stopPrank();
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setPricerGas(rival, 40_000);
    }

    /// SZR's market takes a wrapped pool that holds SZR, for SZR trading somewhere else.
    function testSzrMarketCanAddAWrappedSzrPool() public {
        PoolKey memory away = _pair(address(szr), address(backing), 3_000, address(wrapper));
        manager.initialize(away, uint160(1 << 96));
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        hook.addVenue(1, away);
        assertTrue(hook.tracked(1, _id(away)));
        assertGt(hook.market(1).pricerGas, 0);
        hook.setLimits(1, address(szr), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        // With nothing held behind it, it has no price and is passed over.
        uint256 inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "the market still works");
        _assertNothingHeld();
    }

    /// A market that uses wrapped pools reserves more gas, and a swap given what
    /// `gasForSwap` states never fails for gas. More gas never fails where less succeeded.
    function testGasRulesHoldWithAWrappedPool() public {
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        vm.stopPrank();
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        uint256 stated = hook.gasForSwap(id) + 200_000;
        bool filled;
        for (uint256 gas = 300_000; gas <= stated; gas += 100_000) {
            uint256 snapshot = vm.snapshotState();
            bool ok = _swapWithGas(first, address(coin), 1_000e18, gas);
            vm.revertToState(snapshot);
            if (filled) assertTrue(ok, "more gas failed");
            filled = ok;
        }
        assertTrue(_swapWithGas(first, address(coin), 1_000e18, stated), "stated gas is enough");
    }

    /// SZR's market can use a wrapped pool to convert between two partner tokens.
    function testSzrMarketConvertsThroughAWrappedPool() public {
        PoolKey memory route = _wrap(address(backing), address(usd));
        locker.registerRoute(route);
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        hook.setConnector(1, publicPool, false);
        hook.setConnector(1, route, true);
        hook.setLimits(1, address(szr), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        assertGt(hook.market(1).pricerGas, 0);
        (uint256 zero,) = wrapper.reservesOf(_id(route));
        uint256 inventory = core.unreleasedSupply();
        _trade(usdPool, address(szr), 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "profit retired");
        (uint256 later,) = wrapper.reservesOf(_id(route));
        assertTrue(later != zero, "the wrapped pool carried the conversion");
        _assertNothingHeld();
    }
}
