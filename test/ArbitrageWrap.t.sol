// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import {
    WrappingAsset,
    BrokenUnwrapAsset,
    HookShunningAsset,
    ConvertMeter
} from "./utils/ArbitrageNative.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { PresyncRouter } from "./utils/Routers.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev ETH and WETH are one asset in two forms. A cycle may convert between them through
/// the wrap link, so a pool pairing a token with ETH is compared with one pairing it with
/// WETH, and a connecting pool that holds ETH can stand in for one that holds WETH. `id` is
/// the market MarketsWorld opens, which counts profit in USD (and WETH).
abstract contract WrapWorld is MarketsWorld {
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");

    address internal ethDesk = address(0x7EA6);

    receive() external payable { }

    function setUp() public virtual override {
        super.setUp();
        // The world's WETH has neither `deposit()` nor `withdraw()`; the real one has both.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(this), 1e30);
        vm.deal(address(backing), 1e27);
        hook.setProfitToken(address(0), ethDesk);
        // Profit is counted in USD only, so a pool of USD and WETH is searched with USD
        // as its profit token and WETH as its partner.
        address[] memory tokens = new address[](1);
        tokens[0] = address(usd);
        vm.prank(team);
        hook.setTokens(id, tokens);
    }

    // ----- helpers -----

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

    function _in(PoolKey memory pool, address input, uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap{ value: input == address(0) ? amount : 0 }(
            pool, _params(pool, input, amount), settings, ""
        );
    }

    function _assertClean() internal {
        _assertNothingHeld();
        assertEq(address(hook).balance, 0, "hook ether");
        assertEq(backing.balanceOf(address(hook)), 0, "hook weth");
    }

    /// How many cycles bought and sold in the pool searched, and how many times the hook
    /// wrapped and unwrapped, from the logs of everything since `recordLogs`.
    function _tally()
        internal
        returns (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps)
    {
        return _tallyOf(vm.getRecordedLogs());
    }

    function _tallyOf(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps)
    {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.Arbitraged.selector) {
                (bool buying,) = abi.decode(logs[index].data, (bool, uint256));
                if (buying) bought++;
                else sold++;
            }
            if (logs[index].emitter != address(backing)) continue;
            if (logs[index].topics[0] != TRANSFER) continue;
            if (logs[index].topics[1] == bytes32(0)) wraps++;
            if (logs[index].topics[2] == bytes32(0)) unwraps++;
        }
    }

    // ----- the wrap link between ETH and WETH pools -----

    /// Focus USD/ETH (hooked), venue USD/WETH, in different groups. A swap in the venue
    /// opens a gap; the hook closes it through the wrap link.
    function _usdEtherAndWeth() internal returns (PoolKey memory hooked, PoolKey memory venue) {
        hooked = _make(address(0), address(usd), 3_000, address(hook));
        venue = _make(address(backing), address(usd), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(0), _list(_id(hooked)));
        _lead(address(usd), address(backing), _list(_id(venue)));
        _limits(address(usd), 1e15);
    }

    /// SZR's market: the SZR/USD pool against the SZR/WETH pool, with a USD/ETH pool
    /// registered with Liquidity as the only way across and the wrap link for the rest.
    function _szrThroughEthPool() internal {
        hook.setConnector(1, publicPool, false);
        PoolKey memory cross = _pair(address(usd), address(0), 3_000, address(0));
        manager.initialize(cross, uint160(1 << 96));
        provider.modifyLiquidity{ value: 50_000_000e18 }(
            cross,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(20_000_000e18), 0
            ),
            ""
        );
        locker.registerRoute(cross);
        hook.setConnector(1, cross, true);
    }
}

contract ArbitrageWrapTest is WrapWorld {
    /// The venue's USD is bought: the hook sells USD there and buys it back in the ETH
    /// pool. WETH is what it holds after the venue, so it unwraps it.
    function testEtherPoolAgainstWethPoolUnwrapsInABuyCycle() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(backing), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(bought + sold, 0, "gap closed");
        assertGt(unwraps, 0, "WETH unwrapped");
        assertEq(wraps, 0, "no wrap");
        assertEq(sold, 0, "one direction");
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        _assertClean();
    }

    /// The other direction of the same pair: ETH is wrapped.
    function testEtherPoolAgainstWethPoolWrapsInASellCycle() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(usd), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(bought + sold, 0, "gap closed");
        assertGt(wraps, 0, "ETH wrapped");
        assertEq(unwraps, 0, "no unwrap");
        assertEq(bought, 0, "one direction");
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        _assertClean();
    }

    /// With the focus pool on WETH and the venue on ETH the conversions swap places.
    function testWethPoolAgainstEtherPoolInBothDirections() public {
        PoolKey memory hooked = _make(address(backing), address(usd), 3_000, address(hook));
        PoolKey memory venue = _make(address(0), address(usd), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(backing), _list(_id(hooked)));
        _lead(address(usd), address(0), _list(_id(venue)));
        _limits(address(usd), 1e15);
        _in(venue, address(usd), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(sold, 0, "sold in the WETH pool");
        assertEq(bought, 0, "one direction");
        assertGt(unwraps, 0, "the WETH it got became the ETH the venue wants");
        assertEq(wraps, 0, "no wrap");
        _in(venue, address(0), 100_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (bought, sold, wraps, unwraps) = _tally();
        assertGt(bought, 0, "bought in the WETH pool");
        assertEq(sold, 0, "the other direction");
        assertGt(wraps, 0, "the ETH it got became the WETH the pool wants");
        assertEq(unwraps, 0, "no unwrap");
        _assertClean();
    }

    // ----- a connecting pool and the wrap link -----

    /// Focus USD/<focus partner>, venue USD/<venue partner>, and TEAM/<twin> to cross. One
    /// of the two partners is TEAM and the other the ether token `kind`; the connecting
    /// pool holds the ether token's twin, so the route needs the wrap link as well.
    /// `buy` makes the venue's USD dear, so the hook buys USD in the focus pool and sells it
    /// at the venue; otherwise the other way.
    function _twoLinks(address kind, bool etherAtFocus, bool buy) internal {
        address twin = kind == address(0) ? address(backing) : address(0);
        PoolKey memory hooked =
            _make(address(usd), etherAtFocus ? kind : address(coin), 3_000, address(hook));
        PoolKey memory venue =
            _make(address(usd), etherAtFocus ? address(coin) : kind, 500, address(0));
        PoolKey memory cross = _make(address(coin), twin, 500, address(0));
        _venue(venue);
        vm.prank(team);
        hook.setConnector(id, cross, true);
        _lead(address(usd), etherAtFocus ? kind : address(coin), _list(_id(hooked)));
        _lead(address(usd), etherAtFocus ? address(coin) : kind, _list(_id(venue)));
        _limits(address(usd), 1e15);
        address venuePartner = etherAtFocus ? address(coin) : kind;
        _in(venue, buy ? venuePartner : address(usd), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        if (buy) assertGt(bought, 0, "bought in the focus pool");
        else assertGt(sold, 0, "sold in the focus pool");
        assertGt(bought + sold, 0, "gap closed through the pool and the link");
        assertGt(wraps + unwraps, 0, "converted");
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        _assertClean();
    }

    /// The ether end is the venue's partner: the route is the connecting pool, then the link.
    function testRouteFromEthVenueThroughWethConnector() public {
        _twoLinks(address(0), false, false);
    }

    function testRouteFromWethVenueThroughEthConnector() public {
        _twoLinks(address(backing), false, false);
    }

    /// The ether end is the focus pool's partner: the route is the link, then the pool.
    function testRouteToEthFocusThroughWethConnector() public {
        _twoLinks(address(0), true, false);
    }

    function testRouteToWethFocusThroughEthConnector() public {
        _twoLinks(address(backing), true, false);
    }

    /// The same four routes in the buying direction, where the conversion waits for the
    /// venue to supply the token it needs.
    function testBuyRouteFromEthVenueThroughWethConnector() public {
        _twoLinks(address(0), false, true);
    }

    function testBuyRouteFromWethVenueThroughEthConnector() public {
        _twoLinks(address(backing), false, true);
    }

    function testBuyRouteToEthFocusThroughWethConnector() public {
        _twoLinks(address(0), true, true);
    }

    function testBuyRouteToWethFocusThroughEthConnector() public {
        _twoLinks(address(backing), true, true);
    }

    // ----- SZR's market -----

    function testSzrMarketCrossesThroughAnEthPoolAfterASale() public {
        _szrThroughEthPool();
        vm.recordLogs();
        _assertSaleBackrun(usdPool);
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(bought + sold, 0, "cycle ran");
        assertGt(wraps + unwraps, 0, "converted");
    }

    function testSzrMarketCrossesThroughAnEthPoolAfterAPurchase() public {
        _szrThroughEthPool();
        vm.recordLogs();
        _assertPurchaseBackrun(usdPool, address(usd));
        (uint256 bought, uint256 sold, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(bought + sold, 0, "cycle ran");
        assertGt(wraps + unwraps, 0, "converted");
    }

    /// The same against Core, which pays NAV in WETH: the other end of the route is WETH.
    function testSzrMarketRedeemsAtCoreThroughAnEthPool() public {
        _szrThroughEthPool();
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        uint256 profit = hook.arb(_id(usdPool));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.CycleFailed.selector) continue;
            assertTrue(logs[index].topics[2] != bytes32(0), "a try at Core failed");
        }
        (uint256 bought,,, uint256 unwraps) = _tallyOf(logs);
        assertGt(profit, 0, "profit");
        assertGt(bought, 0, "bought in the SZR/USD pool");
        assertGt(unwraps, 0, "WETH unwrapped to repay the ETH pool");
        assertGt(core.unreleasedSupply(), inventory + profit, "redeemed and retired");
        _assertHookEmpty();
    }

    // ----- the pool manager's sync slot -----

    /// The swapper marks WETH as synced before swapping, as anyone may. The unwrapping cycle
    /// must clear the slot before it settles ETH.
    function testMarkedWethDoesNotStopACycleThatUnwraps() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(backing), 50_000e18);
        PresyncRouter router = new PresyncRouter(manager);
        usd.approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.trade(hooked, address(usd), 1e18, address(backing));
        (uint256 bought,,, uint256 unwraps) = _tally();
        assertGt(bought, 0, "cycle ran");
        assertGt(unwraps, 0, "and unwrapped");
        _assertClean();
    }

    /// The same with a token the market does not trade, which must not be called either.
    function testMarkedUntradedTokenDoesNotStopACycleThatUnwraps() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(backing), 50_000e18);
        HookShunningAsset stranger = new HookShunningAsset(address(hook));
        PresyncRouter router = new PresyncRouter(manager);
        usd.approve(address(router), type(uint256).max);
        vm.recordLogs();
        router.trade(hooked, address(usd), 1e18, address(stranger));
        (uint256 bought,,, uint256 unwraps) = _tally();
        assertGt(bought, 0, "cycle ran");
        assertGt(unwraps, 0, "and unwrapped");
        _assertClean();
    }

    // ----- failures -----

    ArbitrageProbe internal probe;
    ConvertMeter internal meter;

    function _probe() internal {
        address probeAt = address(uint160(0xA4B2 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), probeAt);
        probe = ArbitrageProbe(payable(probeAt));
        meter = new ConvertMeter{ value: 10e18 }(manager, probe, address(backing));
        backing.mint(address(meter), 10e18);
    }

    /// In a cycle either failure undoes the cycle only: the swap fills, and nothing is
    /// left owed or held.
    function testBrokenWethFailsTheCycleNotTheSwap() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(backing), 50_000e18);
        vm.etch(address(backing), address(new BrokenUnwrapAsset()).code);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold,,) = _tally();
        assertEq(bought + sold, 0, "no cycle completed");
        assertEq(usd.balanceOf(treasury), 0, "nothing paid");
        _assertClean();
    }

    /// Only the pool manager and WETH may send ETH to the hook.
    function testOnlyThePoolManagerAndWethMaySendEther() public {
        (bool ok, bytes memory reason) = address(hook).call{ value: 1 }("");
        assertFalse(ok, "sent by a test");
        assertEq(bytes4(reason), ArbitrageHook.NotPoolManager.selector);
        vm.deal(team, 1);
        vm.prank(team);
        (ok, reason) = address(hook).call{ value: 1 }("");
        assertFalse(ok, "sent by an owner");
        assertEq(bytes4(reason), ArbitrageHook.NotPoolManager.selector);
        assertEq(address(hook).balance, 0);
    }

    // ----- pools of ETH and WETH -----

    /// A pool of ETH and WETH is pointless beside the link and is never picked, even though
    /// WETH is a token the market counts in.
    function testPoolOfEthAndWethIsNeverPicked() public {
        _countWethAndUsd();
        PoolKey memory both = _make(address(0), address(backing), 3_000, address(hook));
        assertEq(hook.partnerOf(_id(both)), address(0), "not searched");
        vm.expectRevert(ArbitrageHook.UnknownPool.selector);
        hook.arb(_id(both));
        vm.startPrank(team);
        hook.untrack(id, _id(both));
        hook.retrack(_id(both));
        vm.stopPrank();
        vm.expectRevert(ArbitrageHook.UnknownPool.selector);
        hook.arb(_id(both));
    }

    function _countWethAndUsd() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        vm.prank(team);
        hook.setTokens(id, tokens);
    }

    function testLeadersRefuseTwoEtherTokens() public {
        _countWethAndUsd();
        PoolKey memory both = _make(address(0), address(backing), 3_000, address(hook));
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(id, address(backing), address(0), _list(_id(both)));
        // Counting in ETH too.
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(0);
        hook.setTokens(id, tokens);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(id, address(0), address(backing), _list(_id(both)));
        // A group can always be emptied, whatever its two tokens are.
        hook.setLeaders(id, address(0), address(backing), new bytes32[](0));
        hook.setLeaders(id, address(backing), address(0), new bytes32[](0));
        vm.stopPrank();
    }

    // ----- gas -----

    /// What the wrap link costs inside a cycle: the conversion alone through the pool
    /// manager, and a whole swap that closes a gap with one, beside one that finds none.
    function testGasOfEachConversionFitsInATry() public {
        _probe();
        vm.cool(address(backing));
        uint256 wrap = meter.measure(address(0), 1e18);
        vm.cool(address(backing));
        uint256 unwrap = meter.measure(address(backing), 1e18);
        emit log_named_uint("conversion ETH to WETH gas", wrap);
        emit log_named_uint("conversion WETH to ETH gas", unwrap);
        (, uint256 attempt) = probe.gasAllowances();
        assertLt(wrap, attempt / 4, "wrap");
        assertLt(unwrap, attempt / 4, "unwrap");

        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(hooked, address(usd), 1e15);
        uint256 quiet = _swapGas(hooked);
        _in(venue, address(backing), 50_000e18);
        uint256 withUnwrap = _swapGas(hooked);
        _in(venue, address(usd), 100_000e18);
        uint256 withWrap = _swapGas(hooked);
        emit log_named_uint("swap with no gap gas", quiet);
        emit log_named_uint("swap closing a gap with an unwrap gas", withUnwrap);
        emit log_named_uint("swap closing a gap with a wrap gas", withWrap);
        // Both searches of the swap are in these figures, so the cycle itself is far less.
        assertLt(withUnwrap - quiet, attempt, "unwrap cycle fits one try");
        assertLt(withWrap - quiet, attempt, "wrap cycle fits one try");
    }

    function _swapGas(PoolKey memory pool) internal returns (uint256 used) {
        used = gasleft();
        _in(pool, address(usd), 1e15);
        used -= gasleft();
    }
}
