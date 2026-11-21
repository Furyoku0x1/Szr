// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MetricExtensionWorld } from "./MetricLiquidityExtension.t.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The Metric extension's own arbitrage-hook market.
contract MetricLiquidityExtensionMarketTest is MetricExtensionWorld {
    /// The extension opens a market, creates two plain v4 pools in it on the Metric pool's own
    /// pair through `marketCall` (the Metric pool is not wired in as a venue here), and a swap
    /// by someone else pays the market's profit to the extension.
    function testOwnMarketPaysTheExtension() public {
        uint256 market = mext.openMarket();
        assertEq(hook.market(market).owner, address(mext));
        assertEq(hook.market(market).recipient, address(mext));
        id = market;
        team = address(mext);
        address[] memory chosen = new address[](1);
        chosen[0] = address(usd);
        mext.marketCall(abi.encodeCall(hook.setTokens, (market, chosen)));
        PoolKey memory one = _pair(address(t0), address(t1), 1_000, address(hook));
        PoolKey memory two = _pair(address(t0), address(t1), 200, address(hook));
        mext.marketCall(abi.encodeCall(hook.createPool, (market, one, uint160(1 << 96))));
        mext.marketCall(abi.encodeCall(hook.createPool, (market, two, uint160(1 << 96))));
        _provide(one, 1_000_000e18);
        _provide(two, 1_000_000e18);
        _lead(address(usd), address(coin), _list(_id(one), _id(two)));
        _limits(address(usd), 1e15);
        uint256 before = usd.balanceOf(address(mext));
        _trade(one, address(coin), 50_000e18);
        assertGt(usd.balanceOf(address(mext)), before, "profit paid to the extension");
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        mext.marketCall(abi.encodeCall(hook.setRecipient, (market, alice)));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.createPool(market, one, uint160(1 << 96));
    }

    /// What every extension shares also holds for this one: swaps through a registered v4
    /// route, giving WETH to Core, wrapping, and the refused market calls.
    function testSharedBaseBehaviour() public {
        PoolKey memory route = _openPool(address(backing), address(coin), 3_000);
        backing.mint(address(mext), HELD);
        mext.registerRoute(route);
        bool zeroForOne = Currency.unwrap(route.currency0) == address(backing);
        (, uint256 got) = mext.swap(
            route, zeroForOne, 1_000e18, 1, zeroForOne ? FLOOR : CEILING, block.timestamp
        );
        assertGt(got, 0, "swapped through the route");
        uint256 cash = core.reserveCash();
        mext.toCore(address(backing), 5e18);
        assertEq(core.reserveCash(), cash + 5e18, "backing given to Core");
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        mext.toCore(address(coin), 1);
        vm.deal(address(mext), 2e18);
        mext.wrap(2e18);
        mext.unwrap(2e18);
        assertEq(address(mext).balance, 2e18, "1:1 round trip");
        uint256 market = mext.openMarket();
        bytes[] memory refused = new bytes[](5);
        refused[0] = abi.encodeCall(hook.setRecipient, (market, alice));
        refused[1] = abi.encodeCall(hook.nominateOwner, (market, alice));
        refused[2] = abi.encodeCall(hook.openMarket, (alice));
        refused[3] = abi.encodeCall(hook.acceptOwnership, (market));
        refused[4] = "";
        for (uint256 index; index < refused.length; index++) {
            vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
            mext.marketCall(refused[index]);
        }
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        mext.toCore(address(backing), 1);
    }
}
