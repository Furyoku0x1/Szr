// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import {
    WrappingAsset,
    BrokenWrapAsset,
    HookShunningAsset,
    PayoutMeter
} from "./utils/ArbitrageNative.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { PresyncRouter, SyncEarlyRouter } from "./utils/Routers.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { Vm } from "forge-std/Vm.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";

/// @dev Native ETH is a token like any other, with currency zero. A market may count profit
/// in it; the profit is then paid out as WETH. `id` is a market that counts in ETH and
/// `wethMarket` the one MarketsWorld opens, which counts in WETH and USD.
contract ArbitrageNativeTest is MarketsWorld {
    address internal ethDesk = address(0x7EA6);
    uint256 internal wethMarket;

    receive() external payable { }

    function setUp() public override {
        super.setUp();
        // The world's WETH has no `deposit()`; the real one does.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(this), 1e30);
        hook.setProfitToken(address(0), ethDesk);
        wethMarket = id;
        vm.startPrank(team);
        id = hook.openMarket(treasury);
        hook.setTokens(id, _only(address(0)));
        vm.stopPrank();
    }

    function _only(address one) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = one;
    }

    /// A pool of the current market holding `one` and `other`. A hooked one is created; a
    /// hookless one is added as a venue or connecting pool by the caller.
    function _make(address one, address other, uint24 fee, address hooks)
        internal
        returns (PoolKey memory pool)
    {
        pool = _pair(one, other, fee, hooks);
        if (hooks == address(hook)) {
            vm.prank(team);
            hook.createPool(id, pool, uint160(1 << 96));
        } else {
            manager.initialize(pool, uint160(1 << 96));
        }
        uint256 units = 1_000_000e18;
        uint256 value = Currency.unwrap(pool.currency0) == address(0) ? units * 2 : 0;
        provider.modifyLiquidity{ value: value }(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(units), 0
            ),
            ""
        );
    }

    function _venue(PoolKey memory pool) internal {
        vm.prank(team);
        hook.addVenue(id, pool);
    }

    function _params(PoolKey memory pool, address input, uint256 amount)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        return IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// A swap that pays native ETH when `input` is zero. The router refunds what it did not
    /// need.
    function _in(PoolKey memory pool, address input, uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap{ value: input == address(0) ? amount : 0 }(
            pool, _params(pool, input, amount), settings, ""
        );
    }

    function _inWithGas(PoolKey memory pool, address input, uint256 amount, uint256 gas)
        internal
        returns (bool filled)
    {
        PoolSwapTest.TestSettings memory settings;
        vm.cool(address(manager));
        vm.cool(address(hook));
        (filled,) = address(swapper).call{ gas: gas, value: input == address(0) ? amount : 0 }(
            abi.encodeCall(swapper.swap, (pool, _params(pool, input, amount), settings, ""))
        );
    }

    function _assertClean() internal {
        _assertNothingHeld();
        assertEq(address(hook).balance, 0, "hook ether");
        assertEq(ethDesk.balance, 0, "protocol paid ether");
        assertEq(treasury.balance, 0, "market paid ether");
    }

    /// A hooked TEAM/ETH pool and a hookless one, both led by ETH's group of TEAM.
    function _ethPools() internal returns (PoolKey memory hooked, PoolKey memory open) {
        hooked = _make(address(0), address(coin), 3_000, address(hook));
        open = _make(address(0), address(coin), 500, address(0));
        _venue(open);
        _lead(address(0), address(coin), _list(_id(hooked), _id(open)));
        _limits(address(0), 1e15);
    }

    function testEthProfitIsPaidAsWethAndSplit() public {
        (PoolKey memory hooked, PoolKey memory open) = _ethPools();
        assertEq(hook.partnerOf(_id(hooked)), address(coin), "TEAM is the partner");
        _in(open, address(coin), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "gap closed by a swap");
        uint256 share = backing.balanceOf(ethDesk);
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "market paid in WETH");
        _assertThirty(share, kept + share);
        assertEq(share, ((kept + share) * 30 + 99) / 100, "30% rounded up");
        _assertClean();
    }

    /// Focus pool ETH/TEAM, venue ETH/USD, and TEAM/USD to cross between them. The
    /// connecting pool holds no ETH.
    function testEthTriangleThroughATeamUsdConnectingPool() public {
        PoolKey memory hooked = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory dollars = _make(address(0), address(usd), 500, address(0));
        PoolKey memory cross = _make(address(coin), address(usd), 500, address(0));
        _venue(dollars);
        vm.prank(team);
        hook.setConnector(id, cross, true);
        _lead(address(0), address(coin), _list(_id(hooked)));
        _lead(address(0), address(usd), _list(_id(dollars)));
        _limits(address(0), 1e15);
        _in(dollars, address(usd), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "triangle closed");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    /// Profit is counted in USD. Focus pool USD/TEAM, venue USD/ETH, and the connecting pool
    /// ETH/TEAM, which holds native ETH.
    function testTriangleThroughANativeConnectingPool() public {
        id = wethMarket;
        PoolKey memory hooked = _make(address(usd), address(coin), 3_000, address(hook));
        PoolKey memory venue = _make(address(0), address(usd), 500, address(0));
        PoolKey memory cross = _make(address(0), address(coin), 500, address(0));
        _venue(venue);
        vm.prank(team);
        hook.setConnector(id, cross, true);
        _lead(address(usd), address(coin), _list(_id(hooked)));
        _lead(address(usd), address(0), _list(_id(venue)));
        _limits(address(usd), 1e15);
        _in(venue, address(0), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "triangle closed");
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        _assertClean();
    }

    /// Profit counted in ETH, with the venue's partner reached from the focus pool's
    /// through two pools that meet at WETH.
    function testTwoPoolRouteThroughWethWhenHomeIsEth() public {
        PoolKey memory hooked = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory dollars = _make(address(0), address(usd), 500, address(0));
        PoolKey memory near = _make(address(backing), address(coin), 100, address(0));
        PoolKey memory far = _make(address(backing), address(usd), 100, address(0));
        _venue(dollars);
        vm.startPrank(team);
        hook.setConnector(id, near, true);
        hook.setConnector(id, far, true);
        vm.stopPrank();
        _lead(address(0), address(coin), _list(_id(hooked)));
        _lead(address(0), address(usd), _list(_id(dollars)));
        _limits(address(0), 1e15);
        _in(dollars, address(usd), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "closed through WETH");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    function testEthSwappedInWithAGapOpenLeavesTheHookClean() public {
        (PoolKey memory hooked, PoolKey memory open) = _ethPools();
        _in(open, address(coin), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(0), 1_000e18);
        assertGt(_cycles(), 0, "gap closed");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    function testRetrackedEthPoolIsSearchedAgain() public {
        (PoolKey memory hooked, PoolKey memory open) = _ethPools();
        _lead(address(0), address(coin), _list(_id(open)));
        vm.startPrank(team);
        hook.untrack(id, _id(hooked));
        hook.retrack(_id(hooked));
        vm.stopPrank();
        assertEq(hook.partnerOf(_id(hooked)), address(coin), "searched again");
        _lead(address(0), address(coin), _list(_id(hooked), _id(open)));
        _in(open, address(coin), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "gap closed");
        assertGt(backing.balanceOf(treasury), 0, "profit paid");
        _assertClean();
    }

    /// A hooked pool of two other tokens in a market that chose only ETH has no profit
    /// token, so its home is zero, the same as ETH's. Its swaps must not be searched as if
    /// it were ETH's.
    function testPoolWithNoChosenTokenIsNotSearchedAsEth() public {
        (, PoolKey memory open) = _ethPools();
        // TEAM sorts first, so it is the partner a search would take for the stray pool.
        TestAsset other = new TestAsset();
        while (address(other) < address(coin)) other = new TestAsset();
        _approve(other);
        PoolKey memory stray = _make(address(coin), address(other), 3_000, address(hook));
        _in(open, address(coin), 50_000e18);
        vm.recordLogs();
        _in(stray, address(coin), 1_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            assertTrue(topic != ArbitrageLogic.CycleFailed.selector, "cycle tried");
            assertTrue(topic != ArbitrageLogic.Arbitraged.selector, "arbitraged");
            assertTrue(topic != ArbitrageLogic.SearchUndone.selector, "searched");
        }
    }

    /// An ETH market with a hooked pool and a wrapped outside pool in a gap against it, led
    /// together.
    function _wrappedGap() internal returns (PoolKey memory hooked, PoolKey memory outside) {
        WrappedPool wrapper =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        hook.setPricer(address(wrapper), address(new WrappedPricer(wrapper)));
        hooked = _make(address(0), address(coin), 3_000, address(hook));
        outside = _pair(address(0), address(coin), 3_000, address(wrapper));
        manager.initialize(outside, uint160(1 << 96));
        coin.mint(address(wrapper), 1_000_000e18);
        vm.deal(address(wrapper), 1_000_000e18);
        wrapper.seed(outside, 1_000_000e18, 1_000_000e18);
        wrapper.arm(7, outside, address(hook), id);
        vm.startPrank(team);
        hook.setLimits(id, address(0), 0, 1e15, 1.0001e18);
        hook.addVenue(id, outside);
        vm.stopPrank();
        _lead(address(0), address(coin), _list(_id(hooked), _id(outside)));
        _limits(address(0), 1e15);
    }

    /// A wrapped pool's hook pays ETH with `settle{ value }`, which the pool manager refuses
    /// while its sync slot holds a token. The swapper marks WETH first, as anyone may.
    function testMarkedWethDoesNotStopAWrappedPoolPayingEth() public {
        (PoolKey memory hooked,) = _wrappedGap();
        PresyncRouter router = new PresyncRouter(manager);
        coin.approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.trade(hooked, address(coin), 50_000e18, address(backing));
        assertGt(_cycles(), 0, "the wrapped pool paid its ETH");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    /// The same for a token the market does not trade, which must not be called at all: this
    /// one reverts when the hook asks for its balance.
    function testMarkedUntradedTokenDoesNotStopAWrappedPoolPayingEth() public {
        (PoolKey memory hooked,) = _wrappedGap();
        HookShunningAsset stranger = new HookShunningAsset(address(hook));
        PresyncRouter router = new PresyncRouter(manager);
        coin.approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.trade(hooked, address(coin), 50_000e18, address(stranger));
        assertGt(_cycles(), 0, "the wrapped pool paid its ETH");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    /// A router that marked its token early has it marked again after the hook cleared the
    /// slot for a wrapped pool, so its late payment still settles.
    function testEarlyMarkIsRestoredAfterAWrappedMarketClearedIt() public {
        (PoolKey memory hooked,) = _wrappedGap();
        SyncEarlyRouter router = new SyncEarlyRouter(manager);
        coin.approve(address(router), type(uint256).max);
        vm.recordLogs();
        assertGt(router.trade(hooked, address(coin), 50_000e18), 0, "trade completes");
        assertGt(_cycles(), 0, "the gap was closed");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    /// A WETH whose `deposit` fails with no data must end only the search, as `Unsettled`:
    /// an empty revert would be read as too little gas and fail a swap that brought plenty.
    function testBrokenWrapEndsTheSearchNotTheSwap() public {
        (PoolKey memory hooked, PoolKey memory open) = _ethPools();
        _in(open, address(coin), 50_000e18);
        vm.etch(address(backing), address(new BrokenWrapAsset()).code);
        vm.recordLogs();
        assertTrue(_inWithGas(hooked, address(coin), 1_000e18, 5_000_000), "swap fills");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool undone;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageLogic.SearchUndone.selector) continue;
            undone = true;
            (bytes4 reason) = abi.decode(logs[index].data, (bytes4));
            assertEq(reason, V4Read.Unsettled.selector, "named error");
        }
        assertTrue(undone, "the search was undone");
        _assertClean();
    }

    /// A market counting in WETH takes a hookless WETH/USD pool as a venue and a hookless
    /// TEAM/USD pool as the way across to it. (A pool of WETH and ETH is never searched.)
    function testWethMarketUsesHooklessPools() public {
        id = wethMarket;
        PoolKey memory venue = _make(address(usd), address(backing), 500, address(0));
        PoolKey memory cross = _make(address(usd), address(coin), 100, address(0));
        _venue(venue);
        vm.prank(team);
        hook.setConnector(id, cross, true);
        _lead(address(backing), address(usd), _list(_id(venue)));
        _in(venue, address(backing), 50_000e18);
        uint256 before = backing.balanceOf(treasury);
        vm.recordLogs();
        _in(first, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "closed through the hookless pools");
        assertGt(backing.balanceOf(treasury), before, "paid in WETH");
        _assertClean();
    }

    function testSweepClosesAGapBetweenHooklessEthPools() public {
        PoolKey memory deep = _make(address(0), address(coin), 3_000, address(0));
        PoolKey memory cheap = _make(address(0), address(coin), 500, address(0));
        _venue(deep);
        _venue(cheap);
        _lead(address(0), address(coin), _list(_id(deep), _id(cheap)));
        _limits(address(0), 1e15);
        _in(cheap, address(coin), 50_000e18);
        uint256 profit = hook.sweep(id, address(0));
        assertGt(profit, 0, "gap closed");
        assertEq(backing.balanceOf(ethDesk) + backing.balanceOf(treasury), profit, "all paid");
        _assertClean();
    }

    function testPoolOfAMarketThatChoseNeitherTokenIsNeverSearched() public {
        id = wethMarket;
        PoolKey memory stray = _make(address(0), address(coin), 3_000, address(hook));
        assertEq(hook.partnerOf(_id(stray)), address(0), "none");
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        hook.arb(_id(stray));
        vm.recordLogs();
        assertTrue(_inWithGas(stray, address(coin), 1_000e18, 700_000), "swap goes through");
        assertEq(_cycles(), 0, "not searched");
    }

    function testTakingEthOffStopsItsPoolsAndShortGasDoesNotFail() public {
        (PoolKey memory hooked, PoolKey memory open) = _ethPools();
        _in(open, address(coin), 50_000e18);
        hook.setProfitToken(address(0), address(0));
        vm.recordLogs();
        assertTrue(_inWithGas(hooked, address(coin), 1_000e18, 700_000), "short gas is fine");
        assertEq(_cycles(), 0, "nothing arbitraged");
        assertEq(backing.balanceOf(treasury), 0, "nothing paid");
        hook.setProfitToken(address(0), ethDesk);
        vm.recordLogs();
        _in(hooked, address(coin), 1_000e18);
        assertGt(_cycles(), 0, "resumed once approved");
        assertGt(backing.balanceOf(treasury), 0, "paid again");
        _assertClean();
    }

    function testOnlyThePoolManagerMaySendEtherToTheHook() public {
        (bool ok, bytes memory reason) = address(hook).call{ value: 1 }("");
        assertFalse(ok, "sent by a test");
        assertEq(bytes4(reason), ArbitrageLogic.NotPoolManager.selector);
        vm.deal(team, 1);
        vm.prank(team);
        (ok, reason) = address(hook).call{ value: 1 }("");
        assertFalse(ok, "sent by an owner");
        assertEq(bytes4(reason), ArbitrageLogic.NotPoolManager.selector);
        assertEq(address(hook).balance, 0);
    }

    function testLeadersAcceptEthAsBaseAndAsPartner() public {
        PoolKey memory asBase = _make(address(0), address(coin), 3_000, address(hook));
        _lead(address(0), address(coin), _list(_id(asBase)));
        assertEq(hook.leadersOf(id, address(0), address(coin))[0], _id(asBase));
        assertEq(hook.groupsOf(id, address(0))[0], address(coin));
        id = wethMarket;
        PoolKey memory asPartner = _make(address(0), address(usd), 3_000, address(0));
        _venue(asPartner);
        _lead(address(usd), address(0), _list(_id(asPartner)));
        assertEq(hook.leadersOf(id, address(usd), address(0))[0], _id(asPartner));
        address[] memory groups = hook.groupsOf(id, address(usd));
        assertEq(groups[groups.length - 1], address(0));
        // A pool of the wrong pair is refused whichever side is zero.
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(id, address(usd), address(0), _list(_id(first)));
    }

    /// Paying the profit out costs less than the gas a search holds back for retiring, with
    /// a recipient that has never been touched.
    function testEthPayoutFitsInTheRetireReserve() public {
        address probeAt = address(uint160(0xA4B2 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), probeAt);
        ArbitrageProbe probe = ArbitrageProbe(payable(probeAt));
        address protocol = address(0xC01D1);
        address owner = address(0xC01D2);
        probe.setProfitToken(address(0), protocol);
        vm.prank(team);
        uint256 market = probe.openMarket(owner);
        uint256 profit = 1e18;
        PayoutMeter meter = new PayoutMeter{ value: profit }(manager, probe);
        vm.cool(protocol);
        vm.cool(owner);
        vm.cool(address(backing));
        (uint256 used, uint256 reserved) = meter.measure(market, profit);
        emit log_named_uint("ETH payout gas", used);
        emit log_named_uint("RETIRE_GAS", reserved);
        assertLt(used, reserved, "fits");
        assertEq(backing.balanceOf(protocol), (profit * 30 + 99) / 100);
        assertEq(backing.balanceOf(owner), profit - (profit * 30 + 99) / 100);
        assertEq(probeAt.balance, 0, "no ether kept");
    }
}
