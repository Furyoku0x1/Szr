// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";

/// @dev Anyone can open a market inside the hook for pools pairing WETH with their own
/// token. It is searched on its own, and its profit is WETH: 30% to the protocol, the rest
/// to the market.
contract ArbitrageMarketsTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal team = address(0x7EA3);
    address internal treasury = address(0x7EA4);
    TestAsset internal coin;
    uint256 internal id;
    PoolKey internal first;
    PoolKey internal second;

    function setUp() public override {
        super.setUp();
        coin = new TestAsset();
        _approve(coin);
        vm.prank(team);
        id = hook.openMarket(treasury);
        first = _create(address(coin), 3_000);
        second = _create(address(coin), 500);
        bytes32[] memory list = new bytes32[](2);
        list[0] = _id(first);
        list[1] = _id(second);
        vm.startPrank(team);
        hook.setLeaders(id, address(coin), list);
        hook.setLimits(id, uint32(hook.minimumGasLimit(id)), 1e15, 1.0001e18);
        vm.stopPrank();
    }

    /// A pool pairing WETH with `partner`.
    function _key(address partner, uint24 fee, address hooks)
        internal
        view
        returns (PoolKey memory)
    {
        return _pair(address(backing), partner, fee, hooks);
    }

    function _pair(address one, address other, uint24 fee, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        bool oneFirst = one < other;
        return PoolKey(
            Currency.wrap(oneFirst ? one : other),
            Currency.wrap(oneFirst ? other : one),
            fee,
            60,
            IHooks(hooks)
        );
    }

    function _create(address partner, uint24 fee) internal returns (PoolKey memory pool) {
        pool = _key(partner, fee, address(hook));
        vm.prank(team);
        hook.createPool(id, pool, uint160(1 << 96));
        _provide(pool, 1_000_000e18);
    }

    function _list(bytes32 only) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = only;
    }

    /// The protocol's share is sent to Core, where it waits to be counted as backing.
    function _assertNothingHeld() internal {
        if (backing.balanceOf(address(core)) != core.reserveCash()) core.absorbBacking();
        assertEq(coin.balanceOf(address(hook)), 0, "hook coin");
        _assertHookEmpty();
    }

    /// A sale opens a gap between the market's two pools. The hook closes it with a cycle
    /// that starts and ends in WETH, and splits what is left exactly: 30% to the protocol,
    /// the rest to the team.
    function testProfitIsPaidInWethAndSplit() public {
        uint256 protocol = backing.balanceOf(address(core));
        uint256 inventory = core.unreleasedSupply();
        _trade(first, address(coin), 50_000e18);
        uint256 kept = backing.balanceOf(treasury);
        uint256 share = backing.balanceOf(address(core)) - protocol;
        assertGt(kept, 0, "team paid in WETH");
        assertEq(share, (kept + share) * 30 / 100, "protocol took exactly 30%");
        uint256 cash = core.reserveCash();
        assertEq(core.absorbBacking(), share, "and Core can count it as backing");
        assertEq(core.reserveCash(), cash + share);
        assertEq(coin.balanceOf(treasury), 0, "nothing paid in the team's token");
        assertEq(core.unreleasedSupply(), inventory, "no SZR retired by another market");
        _assertNothingHeld();
    }

    /// A market's search touches nothing in SZR's market, and the reverse.
    function testMarketsAreSearchedApart() public {
        hook.setLimits(1, 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, 8_000_000, 10e18, 1.0001e18);
        // An open gap in SZR's market is left exactly as it is by the other market's swap.
        uint256 gap = _price(usdPool);
        uint256 inventory = core.unreleasedSupply();
        _trade(first, address(coin), 50_000e18);
        assertEq(_price(usdPool), gap, "SZR pool untouched");
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        // And SZR's own search pays the team nothing and leaves its pools alone.
        uint256 kept = backing.balanceOf(treasury);
        (uint160 before,,,) = manager.getSlot0(second.toId());
        _trade(usdPool, address(szr), 1_000e18);
        assertGt(core.unreleasedSupply(), inventory, "SZR gap closed by its own market");
        (uint160 afterwards,,,) = manager.getSlot0(second.toId());
        assertEq(afterwards, before, "team pool untouched");
        assertEq(backing.balanceOf(treasury), kept, "team not paid");
        _assertNothingHeld();
    }

    /// A market other than the team's, and Liquidity's manager, cannot configure it.
    function testOnlyTheOwnerConfiguresAMarket() public {
        PoolKey memory extra = _key(address(usd), 3_000, address(hook));
        bytes32[] memory list = _list(_id(second));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.createPool(id, extra, uint160(1 << 96));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLeaders(id, address(coin), list);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLimits(id, 0, 0, 1.0001e18);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setConnector(id, extra, true);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setRecipient(id, address(this));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.untrack(_id(second));
        // Nor can the team touch SZR's market, or the protocol's recipient.
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLimits(1, 0, 0, 1.0001e18);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLeaders(1, address(usd), list);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.untrack(_id(usdPool));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setProtocolRecipient(team);
        // A pool of one market cannot lead in another.
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(id, address(usd), _list(_id(usdPool)));
        vm.stopPrank();
    }

    /// A pool joins a market only by being created through the hook, on the hook, pairing
    /// WETH with something other than SZR.
    function testPoolsJoinOnlyByBeingCreatedThroughTheHook() public {
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.createPool(id, _key(address(usd), 3_000, address(0)), uint160(1 << 96));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.createPool(id, _key(address(szr), 3_000, address(hook)), uint160(1 << 96));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.createPool(id, usdPool, uint160(1 << 96));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.createPool(1, _key(address(usd), 3_000, address(hook)), uint160(1 << 96));
        vm.stopPrank();
        // A pool somebody else already created on the hook cannot be claimed.
        PoolKey memory taken = _key(address(usd), 3_000, address(hook));
        manager.initialize(taken, uint160(1 << 96));
        vm.prank(team);
        vm.expectRevert();
        hook.createPool(id, taken, uint160(1 << 96));
        assertEq(hook.partnerOf(_id(taken)), address(0), "not tracked");
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.openMarket(address(0));
    }

    /// Connecting pools of an open market may not run any hook, this one included, and
    /// may not contain WETH.
    function testConnectingPoolsMustBeHookless() public {
        PoolKey memory route = _pair(address(coin), address(usd), 3_000, address(hook));
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setConnector(id, route, true);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setConnector(id, _key(address(usd), 3_000, address(0)), true);
        route.hooks = IHooks(address(0));
        hook.setConnector(id, route, true);
        vm.stopPrank();
        assertEq(
            hook.connector(
                id, Currency.unwrap(route.currency0), Currency.unwrap(route.currency1)
            ),
            _id(route)
        );
    }

    /// The owner sets their pools' fees and prices, and the split does not depend on
    /// either: the profit is WETH left over once every other token has netted to nothing.
    function testSplitDoesNotDependOnTheOwnersPools() public {
        // A pool with a tenth of the price and a 10% fee leads. Nothing is paid through it.
        PoolKey memory toll = _key(address(coin), 100_000, address(hook));
        vm.prank(team);
        hook.createPool(id, toll, uint160(1 << 96) / 3);
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(toll);
        list[1] = _id(first);
        list[2] = _id(second);
        vm.startPrank(team);
        hook.setLimits(id, 0, 1e15, 1.0001e18);
        hook.setLeaders(id, address(coin), list);
        hook.setLimits(id, uint32(hook.minimumGasLimit(id)), 1e15, 1.0001e18);
        vm.stopPrank();
        uint256 protocol = backing.balanceOf(address(core));
        _trade(first, address(coin), 50_000e18);
        uint256 kept = backing.balanceOf(treasury);
        uint256 share = backing.balanceOf(address(core)) - protocol;
        assertGt(kept, 0, "team paid");
        assertEq(share, (kept + share) * 30 / 100, "protocol took exactly 30%");
        _assertNothingHeld();
    }

    /// A pool for one token is compared with a pool for another through a hookless pool
    /// connecting the two tokens, and the profit is still WETH.
    function testTriangleThroughAConnectingPool() public {
        PoolKey memory dollars = _create(address(usd), 3_000);
        PoolKey memory route = _pair(address(coin), address(usd), 3_000, address(0));
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 5_000_000e18);
        vm.startPrank(team);
        hook.setConnector(id, route, true);
        hook.setLimits(id, 0, 1e15, 1.0001e18);
        // One leader per token, so the only cycle is the one across the connecting pool.
        hook.setLeaders(id, address(coin), _list(_id(first)));
        hook.setLeaders(id, address(usd), _list(_id(dollars)));
        hook.setLimits(id, uint32(hook.minimumGasLimit(id)), 1e15, 1.0001e18);
        vm.stopPrank();
        _trade(first, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "team paid in WETH");
        assertEq(usd.balanceOf(treasury), 0, "and in nothing else");
        assertEq(coin.balanceOf(treasury), 0, "and in nothing else");
        _assertNothingHeld();
    }

    /// A pool taken out of a market can be put back by its owner, and by nobody else.
    function testUntrackedPoolCanBeTrackedAgain() public {
        PoolKey memory extra = _create(address(usd), 3_000);
        vm.prank(team);
        hook.untrack(_id(extra));
        assertEq(hook.partnerOf(_id(extra)), address(0));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.retrack(_id(extra));
        vm.expectRevert(ArbitrageHook.UnknownPool.selector);
        hook.retrack(_id(usdPool));
        vm.prank(team);
        hook.retrack(_id(extra));
        assertEq(hook.partnerOf(_id(extra)), address(usd));
        assertEq(hook.market(id).poolCount, 3);
    }
}
