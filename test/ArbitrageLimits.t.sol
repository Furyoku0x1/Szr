// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";

contract ArbitrageLimitsTest is MarketsWorld {
    function _check(uint256 market, address base, address other) internal {
        ArbitrageHook.Market memory before = hook.market(market);
        uint128 kept = hook.minimumProfit(market, other);
        hook.setMinimumProfit(market, base, 7e18);
        ArbitrageHook.Market memory afterwards = hook.market(market);
        assertEq(hook.minimumProfit(market, base), 7e18, "profit set");
        assertEq(hook.minimumProfit(market, other), kept, "other token untouched");
        assertEq(afterwards.gasLimit, before.gasLimit, "gas unchanged");
        assertEq(afterwards.minimumEdge, before.minimumEdge, "edge unchanged");
    }

    function testSetsOnlyTheNamedProfitInOutsideMarket() public {
        vm.startPrank(team);
        _check(id, address(backing), address(usd));
        vm.stopPrank();
    }

    function testSetsOnlyTheNamedProfitInSzrMarket() public {
        _check(1, address(szr), address(backing));
    }

    function testEmitsStoredGasAndEdge() public {
        ArbitrageHook.Market memory settings = hook.market(id);
        vm.expectEmit(true, true, false, true, address(hook));
        emit ArbitrageHook.LimitsSet(
            id, address(backing), settings.gasLimit, 3e18, settings.minimumEdge
        );
        vm.prank(team);
        hook.setMinimumProfit(id, address(backing), 3e18);
    }

    function testOnlyTheOwnerSetsMinimumProfit() public {
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setMinimumProfit(id, address(backing), 1);
        vm.prank(team);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setMinimumProfit(1, address(szr), 1);
    }
}
