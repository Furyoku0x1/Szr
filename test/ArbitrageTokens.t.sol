// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Liquidity's manager approves tokens profit may be counted in, without order or
/// cap; each market chooses up to eight of them, in its own order.
contract ArbitrageTokensTest is MarketsWorld {
    PoolKey internal dollars;
    PoolKey internal cheap;

    function setUp() public override {
        super.setUp();
        dollars = _create(address(usd), address(coin), 3_000);
        cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        _limits(address(usd), 1e15);
    }

    function _only(address one) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = one;
    }

    function _two(address one, address other) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = one;
        list[1] = other;
    }

    function _choose(uint256 market, address[] memory list) internal {
        vm.prank(team);
        hook.setTokens(market, list);
    }

    function _paid() internal returns (uint256 count, uint256 amount, uint256 share) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.ProfitPaid.selector) continue;
            (uint256 paid, uint256 kept) = abi.decode(logs[index].data, (uint256, uint256));
            count++;
            amount += paid;
            share += kept;
        }
    }

    function _shortSwap() internal returns (bool filled) {
        return _swapWithGas(700_000);
    }

    function _swapWithGas(uint256 gas) internal returns (bool filled) {
        bool zeroForOne = Currency.unwrap(dollars.currency0) == address(coin);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(1e15),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.cool(address(manager));
        vm.cool(address(hook));
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (dollars, params, settings, ""))
        );
    }

    function testApprovedTokensHaveNoCap() public {
        for (uint160 index = 1; index <= 20; index++) {
            hook.setProfitToken(address(0x1000 + index), address(0x2000 + index));
        }
        for (uint160 index = 1; index <= 20; index++) {
            assertEq(hook.shareRecipient(address(0x1000 + index)), address(0x2000 + index));
        }
    }

    function testSetProfitTokenRules() public {
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setProfitToken(address(szr), desk);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setProfitToken(address(usd), address(hook));
        vm.prank(team);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setProfitToken(address(usd), desk);
    }

    function testSetTokensRules() public {
        vm.startPrank(team);
        uint256 fresh = hook.openMarket(treasury);
        vm.stopPrank();
        address[] memory nine = new address[](9);
        for (uint160 index; index < 9; index++) {
            nine[index] = address(0x1000 + index);
            hook.setProfitToken(nine[index], desk);
        }
        vm.startPrank(team);
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setTokens(fresh, nine);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setTokens(fresh, _only(address(0xBAD)));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setTokens(fresh, _two(address(usd), address(usd)));
        vm.stopPrank();
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setTokens(1, _only(address(usd)));
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setTokens(fresh, _only(address(usd)));
        // Eight is allowed.
        address[] memory eight = new address[](8);
        for (uint256 index; index < 8; index++) {
            eight[index] = nine[index];
        }
        _choose(fresh, eight);
        assertEq(hook.tokensOf(fresh).length, 8);
        assertEq(hook.tokensOf(fresh)[7], nine[7]);
    }

    function testNewMarketCountsInWethWithoutSetTokens() public {
        vm.prank(team);
        id = hook.openMarket(treasury);
        address[] memory list = hook.tokensOf(id);
        assertEq(list.length, 1);
        assertEq(list[0], address(backing));
        PoolKey memory one = _create(address(backing), address(coin), 2_000);
        PoolKey memory two = _create(address(backing), address(coin), 800);
        _lead(address(backing), address(coin), _list(_id(one), _id(two)));
        _limits(address(backing), 1e15);
        _trade(one, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertNothingHeld();
    }

    function testMarketsWithOppositeOrdersPickDifferentTokens() public {
        TestAsset other = new TestAsset();
        _approve(other);
        hook.setProfitToken(address(other), desk);
        uint256 original = id;
        vm.startPrank(team);
        uint256 forward = hook.openMarket(treasury);
        uint256 reverse = hook.openMarket(treasury);
        vm.stopPrank();
        _choose(forward, _two(address(usd), address(other)));
        _choose(reverse, _two(address(other), address(usd)));
        id = forward;
        PoolKey memory one = _create(address(usd), address(other), 3_000);
        id = reverse;
        PoolKey memory two = _create(address(usd), address(other), 500);
        id = original;
        assertEq(hook.partnerOf(_id(one)), address(other), "counted in USD");
        assertEq(hook.partnerOf(_id(two)), address(usd), "counted in the other token");
    }

    function testDroppedTokenIdlesItsPoolsAndResumes() public {
        _choose(id, _only(address(backing)));
        vm.recordLogs();
        _trade(dollars, address(coin), 50_000e18);
        (uint256 count,,) = _paid();
        assertEq(count, 0, "nothing paid");
        assertEq(usd.balanceOf(treasury), 0, "no USD paid");
        assertTrue(_shortSwap(), "little gas does not fail the swap");
        _choose(id, _two(address(backing), address(usd)));
        vm.recordLogs();
        _trade(dollars, address(coin), 1_000e18);
        (count,,) = _paid();
        assertGt(count, 0, "resumed with no re-tracking");
        assertGt(usd.balanceOf(treasury), 0, "paid in USD again");
        _assertNothingHeld();
    }

    function testTakingATokenOffGloballyStopsEveryMarketAndApprovingResumes() public {
        uint256 original = id;
        address other = address(0xA11CE);
        vm.prank(team);
        uint256 rival = hook.openMarket(other);
        _choose(rival, _only(address(usd)));
        id = rival;
        PoolKey memory mine = _create(address(usd), address(coin), 3_060);
        PoolKey memory mineToo = _create(address(usd), address(coin), 510);
        _lead(address(usd), address(coin), _list(_id(mine), _id(mineToo)));
        _limits(address(usd), 1e15);
        id = original;
        hook.setProfitToken(address(usd), address(0));
        vm.recordLogs();
        _trade(dollars, address(coin), 50_000e18);
        _trade(mine, address(coin), 50_000e18);
        (uint256 count,,) = _paid();
        assertEq(count, 0, "nothing paid");
        assertEq(usd.balanceOf(treasury), 0, "first market unpaid");
        assertEq(usd.balanceOf(other), 0, "second market unpaid");
        hook.setProfitToken(address(usd), desk);
        vm.recordLogs();
        _trade(dollars, address(coin), 1_000e18);
        (count,,) = _paid();
        assertGt(count, 0, "first market paid again once approved");
        assertGt(usd.balanceOf(treasury), 0, "first market paid in USD");
        vm.recordLogs();
        _trade(mine, address(coin), 1_000e18);
        (count,,) = _paid();
        assertGt(count, 0, "second market paid again once approved");
        assertGt(usd.balanceOf(other), 0, "second market paid in USD");
        _assertNothingHeld();
    }

    /// A plain outside market (no pricer) on a pool counting in USD reads two cold slots
    /// to see the pool is countable; the stated gas still covers a swap that meets a gap.
    function testStatedGasIsEnoughForAnOutsideMarketCountingInUsd() public {
        vm.prank(team);
        hook.setLimits(id, address(usd), 0, 1e15, 1.0001e18);
        _trade(dollars, address(coin), 50_000e18);
        _limits(address(usd), 1e15);
        uint256 stated = hook.gasForSwap(id);
        uint256 before = usd.balanceOf(treasury);
        // The router and the pool manager use some gas before the hook is reached.
        uint256 start = gasleft();
        assertTrue(_swapWithGas(stated + 200_000), "stated gas is enough");
        uint256 used = start - gasleft();
        assertGt(usd.balanceOf(treasury), before, "the gap was closed");
        emit log_named_uint("gasForSwap", stated);
        emit log_named_uint("swap gas used", used);
    }

    function testMinimumGasIgnoresDroppedTokensAndChoosingThemAgainNeedsRoom() public {
        PoolKey memory wide = _create(address(usd), address(coin), 10_000);
        bytes32[] memory three = new bytes32[](3);
        three[0] = _id(dollars);
        three[1] = _id(cheap);
        three[2] = _id(wide);
        _lead(address(usd), address(coin), three);
        uint256 withUsd = hook.minimumGasLimit(id);
        _choose(id, _only(address(backing)));
        uint256 without = hook.minimumGasLimit(id);
        assertLt(without, withUsd, "dropped groups do not count");
        // The allowance still fits the groups of WETH alone, not the three leaders of USD.
        vm.startPrank(team);
        hook.setLimits(
            id,
            address(backing),
            uint32(without),
            hook.minimumProfit(id, address(backing)),
            1.0001e18
        );
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setTokens(id, _two(address(backing), address(usd)));
        vm.stopPrank();
    }

    function testProtocolShareGoesToTheTokensRecipientRoundedUp() public {
        address elsewhere = address(0xD35C);
        hook.setProfitToken(address(usd), elsewhere);
        vm.recordLogs();
        _trade(dollars, address(coin), 50_000e18);
        (uint256 count, uint256 amount, uint256 share) = _paid();
        assertGt(count, 0, "profit paid");
        assertEq(usd.balanceOf(elsewhere), share, "share went to the recipient");
        assertEq(usd.balanceOf(desk), 0, "not to the old one");
        assertEq(usd.balanceOf(treasury), amount - share, "the rest to the market");
        assertGe(share * 100, amount * 30, "rounded up");
        assertLt(share * 100 - amount * 30, count * 100, "by less than one unit a payout");
    }
}
