// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ExtensionWorld } from "./V4LiquidityExtension.t.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev What every extension shares: the manager gate, routes, swaps, Core, wrapping, the
/// extension's own market and funding from Liquidity.
contract LiquidityExtensionSharedTest is ExtensionWorld {
    function testOnlyTheCurrentManager() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        bytes[] memory calls = new bytes[](11);
        calls[0] = abi.encodeCall(ext.registerRoute, (pool));
        calls[1] = abi.encodeCall(ext.swap, (pool, true, 1, 0, FLOOR, block.timestamp));
        calls[2] = abi.encodeCall(ext.wrap, (1));
        calls[3] = abi.encodeCall(ext.unwrap, (1));
        calls[4] = abi.encodeCall(ext.toCore, (address(backing), 1));
        calls[5] = abi.encodeCall(ext.openMarket, ());
        calls[6] = abi.encodeCall(ext.marketCall, (""));
        calls[7] = abi.encodeCall(ext.addPosition, (pool, int24(-60), int24(60)));
        calls[8] = abi.encodeCall(ext.collect, (0));
        calls[9] = abi.encodeCall(ext.deploy, (0, 1, 1, 1, block.timestamp));
        calls[10] = abi.encodeCall(ext.withdraw, (0, 1, 0, 0, block.timestamp));
        for (uint256 index; index < calls.length; index++) {
            vm.prank(alice);
            (bool ok, bytes memory data) = address(ext).call(calls[index]);
            assertFalse(ok, "refused");
            assertEq(bytes4(data), LiquidityExtension.NotManager.selector, "as not manager");
        }
        // After a handover in Liquidity, the old manager is refused and the new one is not.
        locker.nominateManager(alice);
        vm.prank(alice);
        locker.acceptManager();
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        ext.registerRoute(pool);
        vm.prank(alice);
        ext.registerRoute(pool);
        assertTrue(ext.routeRegistered(_id(pool)));
    }

    function testToCoreGivesBackingAndRetiresSzr() public {
        uint256 cash = core.reserveCash();
        ext.toCore(address(backing), 5e18);
        assertEq(core.reserveCash(), cash + 5e18, "NAV backing raised");
        assertEq(backing.allowance(address(ext), address(core)), 0, "approval reset");
        uint256 retired = core.unreleasedSupply();
        ext.toCore(address(szr), 100e18);
        assertEq(core.unreleasedSupply(), retired + 100e18, "SZR retired");
        assertEq(szr.allowance(address(ext), address(core)), 0, "approval reset");
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        ext.toCore(address(coin), 1e18);
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        ext.toCore(address(0), 1);
    }

    function testSwapNeedsARouteAndHonoursMinimumAndDeadline() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        ext.swap(pool, true, 1e18, 0, FLOOR, block.timestamp);
        _route(pool);
        uint256 before = coin.balanceOf(address(ext));
        uint256 got = _extSwap(pool, address(backing), 1_000e18, 1);
        assertGt(got, 0);
        assertEq(coin.balanceOf(address(ext)), before + got, "received");
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        _extSwap(pool, address(backing), 1_000e18, 1_000e18);
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(backing);
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        ext.swap(pool, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING, block.timestamp - 1);
    }

    /// A gap left open in SZR's market is closed by the next swap through its pool, and a
    /// swap short of gas cannot skip it: the hook's own rule reverts it.
    function testShortGasSwapThroughHookPoolReverts() public {
        _route(usdPool);
        PoolKey memory low = _addHooked(address(usd), 500);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(low, address(szr), 150_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 0, 1.0001e18);
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(usd);
        bytes memory call = abi.encodeCall(
            ext.swap,
            (usdPool, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING, block.timestamp)
        );
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = address(ext).call{ gas: 300_000 }(call);
        assertFalse(ok, "short gas reverts");
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "the hook's error");
        vm.revertToState(snapshot);
        (ok,) = address(ext).call{ gas: 9_000_000 }(call);
        assertTrue(ok, "enough gas fills it");
    }

    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
        return false;
    }

    /// Earnings to WETH, WETH to SZR through Liquidity's pool, SZR held, sold back later,
    /// then bought again and retired.
    function testBuySzrHoldItSellItAndRetireIt() public {
        _route(publicPool);
        PoolKey memory main = locker.key(0);
        _route(main);
        uint256 wethBefore = backing.balanceOf(address(ext));
        uint256 gained = _extSwap(publicPool, address(usd), 10_000e18, 1);
        assertEq(backing.balanceOf(address(ext)), wethBefore + gained, "earnings in WETH");
        uint256 szrBefore = szr.balanceOf(address(ext));
        uint256 bought = _extSwap(main, address(backing), 5_000e18, 1);
        assertEq(szr.balanceOf(address(ext)), szrBefore + bought, "SZR held");
        vm.warp(block.timestamp + 1 days);
        uint256 weth = backing.balanceOf(address(ext));
        uint256 sold = _extSwap(main, address(szr), bought, 1);
        assertEq(backing.balanceOf(address(ext)), weth + sold, "sold back to WETH");
        uint256 again = _extSwap(main, address(backing), 5_000e18, 1);
        uint256 inventory = core.unreleasedSupply();
        ext.toCore(address(szr), again);
        assertEq(core.unreleasedSupply(), inventory + again, "retired");
    }

    function testWrapRoundTripAndEtherFromStrangersIsRefused() public {
        vm.deal(address(ext), 5e18);
        uint256 weth = backing.balanceOf(address(ext));
        ext.wrap(5e18);
        assertEq(backing.balanceOf(address(ext)), weth + 5e18);
        assertEq(address(ext).balance, 0);
        ext.unwrap(5e18);
        assertEq(backing.balanceOf(address(ext)), weth);
        assertEq(address(ext).balance, 5e18, "1:1 round trip");
        (bool ok, bytes memory data) = address(ext).call{ value: 1 }("");
        assertFalse(ok);
        assertEq(bytes4(data), LiquidityExtension.UnexpectedEther.selector);
        vm.deal(alice, 1e18);
        vm.prank(alice);
        (ok,) = address(ext).call{ value: 1 }("");
        assertFalse(ok, "not even the manager's friends");
    }

    /// The extension opens a market, creates its pools through `marketCall`, and a swap by
    /// someone else pays the market's profit to the extension.
    function testOwnMarketPaysTheExtension() public {
        uint256 market = ext.openMarket();
        assertEq(hook.market(market).owner, address(ext));
        assertEq(hook.market(market).recipient, address(ext));
        id = market;
        team = address(ext);
        address[] memory chosen = new address[](1);
        chosen[0] = address(backing);
        ext.marketCall(abi.encodeCall(hook.setTokens, (market, chosen)));
        PoolKey memory one = _pair(address(backing), address(coin), 1_000, address(hook));
        PoolKey memory two = _pair(address(backing), address(coin), 200, address(hook));
        ext.marketCall(abi.encodeCall(hook.createPool, (market, one, uint160(1 << 96))));
        ext.marketCall(abi.encodeCall(hook.createPool, (market, two, uint160(1 << 96))));
        _provide(one, 1_000_000e18);
        _provide(two, 1_000_000e18);
        _lead(address(backing), address(coin), _list(_id(one), _id(two)));
        _limits(address(backing), 1e15);
        uint256 before = backing.balanceOf(address(ext));
        uint256 protocol = backing.balanceOf(address(core));
        _trade(one, address(coin), 50_000e18);
        assertGt(backing.balanceOf(address(ext)), before, "profit paid to the extension");
        assertGt(backing.balanceOf(address(core)), protocol, "and the protocol's share");
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.createPool(market, one, uint160(1 << 96));
    }

    function testMarketCallRefusesRedirectingCalls() public {
        uint256 market = ext.openMarket();
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        ext.marketCall(abi.encodeCall(hook.setRecipient, (market, alice)));
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        ext.marketCall(abi.encodeCall(hook.nominateOwner, (market, alice)));
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        ext.marketCall(abi.encodeCall(hook.openMarket, (alice)));
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        ext.marketCall(abi.encodeCall(hook.acceptOwnership, (market)));
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        ext.marketCall("");
        // The hook's own owner check still applies to a market the extension does not own.
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        ext.marketCall(abi.encodeCall(hook.untrack, (market + 1, bytes32(0))));
    }

    /// Liquidity can send untouched sale funding here after the notice period.
    function testAcceptsFundingFromLiquidity() public {
        // A purchase feeds Liquidity's untouched funding.
        _acquire(bob);
        uint256 amount = locker.unallocatedFunding();
        assertGt(amount, 0, "funding to send");
        locker.announceDestination(address(ext));
        vm.warp(block.timestamp + locker.DESTINATION_DELAY());
        uint256 before = backing.balanceOf(address(ext));
        locker.sendFunding(address(ext), amount);
        assertEq(backing.balanceOf(address(ext)), before + amount);
    }

    /// Only the pool manager may call back, and only for the unlock this contract started.
    function testUnlockCallbackRefusesStrangersAndReplays() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        bytes memory data = abi.encode(uint256(0), bytes(""));
        vm.expectRevert(LiquidityExtension.NotPoolManager.selector);
        ext.unlockCallback(data);
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotPoolManager.selector);
        ext.unlockCallback(data);
        // The pool manager itself is refused when no unlock is pending.
        vm.prank(address(manager));
        vm.expectRevert(LiquidityExtension.UnexpectedCallback.selector);
        ext.unlockCallback(data);
        // A finished swap leaves nothing pending, so replaying its payload is refused.
        _route(pool);
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(backing);
        ext.swap(pool, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING, block.timestamp);
        bytes memory request = abi.encode(
            LiquidityExtension.SwapRequest(
                pool, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING
            )
        );
        vm.prank(address(manager));
        vm.expectRevert(LiquidityExtension.UnexpectedCallback.selector);
        ext.unlockCallback(abi.encode(uint256(0), request));
    }
}
