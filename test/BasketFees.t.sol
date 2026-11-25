// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Basket } from "../src/basket/Basket.sol";
import { BasketWorld } from "./utils/BasketWorld.sol";

/// @dev Fees, the protocol's cut, and a paused stock.
contract BasketFeesTest is BasketWorld {
    uint256 internal constant SWAP = 50_000e18;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
    }

    /// Any deposit collects every leg's fees first. One share in kind makes no swap, so it
    /// earns no new fees and adds at most a wei of each idle claim.
    function _harvest(Basket basket) internal {
        _fund(basket, bob, 1e30);
        vm.prank(bob);
        basket.deposit(1, _unbounded(basket.legCount() + 1), block.timestamp);
    }

    function _fundUnit(Basket basket, address who) internal {
        usd.mint(who, 1e30);
        vm.prank(who);
        usd.approve(address(basket), type(uint256).max);
    }

    function _total(uint256[] memory amounts) internal pure returns (uint256 sum) {
        for (uint256 index; index < amounts.length; index++) {
            sum += amounts[index];
        }
    }

    /// Every token is priced near one throughout, so token counts compare value.
    function test_feesRaiseWhatASharePays() public {
        Basket basket = _basket(3);
        _fund(basket, alice, 1e30);
        _fund(basket, bob, 1e30);
        uint256 aliceStart = _total(_balances(basket, alice));
        vm.prank(alice);
        basket.deposit(500e18, _unbounded(4), block.timestamp);
        _churn(3, SWAP);
        // Bob joins after the fees were earned, with the same shares.
        uint256 bobStart = _total(_balances(basket, bob));
        vm.prank(bob);
        basket.deposit(500e18, _unbounded(4), block.timestamp);
        vm.prank(alice);
        basket.redeem(500e18, _zeros(4), block.timestamp);
        vm.prank(bob);
        basket.redeem(500e18, _zeros(4), block.timestamp);
        assertGt(_total(_balances(basket, alice)), aliceStart, "alice earned the fees");
        assertLe(_total(_balances(basket, bob)), bobStart, "bob earned none of them");
    }

    function test_protocolCutIsFifteenPercent() public {
        Basket basket = _basket(3);
        _churn(3, SWAP);
        _harvest(basket);
        address[] memory list = basket.tokens();
        for (uint256 index; index < list.length; index++) {
            uint256 claims = _claims(basket, list[index]);
            assertGt(claims, 0, "fees collected");
            // One floor per leg that paid this token, and bob's wei.
            assertApproxEqAbs(basket.owed(list[index]), claims * 1500 / 10_000, 4, "15%");
            // The holders keep the rest.
            assertApproxEqAbs(_idle(basket, list[index]), claims * 8500 / 10_000, 4, "85%");
        }
    }

    function test_payProtocolPaysTheUnitToTheExtension() public {
        Basket basket = _basket(3);
        _churn(3, SWAP);
        _harvest(basket);
        address[] memory list = basket.tokens();
        uint256[] memory idleBefore = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            idleBefore[index] = _idle(basket, list[index]);
        }
        uint256 stocksBefore = _stocksHeld(basket);
        uint128 heldBefore = basket.liquidityOf(1);
        uint256 before = usd.balanceOf(address(protocol));
        uint256 paid = basket.payProtocol(0, block.timestamp);
        assertGt(paid, 0, "paid");
        assertEq(usd.balanceOf(address(protocol)) - before, paid, "to the extension");
        assertEq(_stocksHeld(basket), stocksBefore, "no stock moved");
        for (uint256 index; index < list.length; index++) {
            assertEq(basket.owed(list[index]), 0, "nothing owed");
            assertEq(_idle(basket, list[index]), idleBefore[index], "holders untouched");
        }
        assertEq(basket.liquidityOf(1), heldBefore, "positions untouched");
    }

    function test_payProtocolOnlyByManagerAndAboveFloor() public {
        Basket basket = _basket(2);
        _churn(2, SWAP);
        vm.prank(alice);
        vm.expectRevert(Basket.NotManager.selector);
        basket.payProtocol(0, block.timestamp);
        vm.expectRevert(Basket.BelowMinimum.selector);
        basket.payProtocol(type(uint256).max, block.timestamp);
        vm.expectRevert(Basket.DeadlinePassed.selector);
        basket.payProtocol(0, block.timestamp - 1);
        // It collects the fees itself, so it pays even with no deposit since the swaps.
        assertGt(basket.payProtocol(0, block.timestamp), 0, "paid");
    }

    function test_pausedStockBlocksOnlyInKind() public {
        Basket basket = _basket(3);
        _fund(basket, alice, 1e30);
        _churn(3, SWAP);
        vm.prank(alice);
        basket.deposit(300e18, _unbounded(4), block.timestamp);
        stocks[1].setPaused(true);
        vm.prank(alice);
        vm.expectRevert();
        basket.deposit(10e18, _unbounded(4), block.timestamp);
        vm.prank(alice);
        vm.expectRevert();
        basket.redeem(10e18, _zeros(4), block.timestamp);
        vm.startPrank(alice);
        uint256 paid = basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        uint256 received = basket.redeemUnit(200e18, 0, block.timestamp);
        vm.stopPrank();
        assertGt(paid, 0, "deposited in the unit token");
        assertGt(received, 0, "redeemed in the unit token");
        assertGt(basket.payProtocol(0, block.timestamp), 0, "the cut is still paid");
        stocks[1].setPaused(false);
        vm.prank(alice);
        basket.redeem(200e18, _zeros(4), block.timestamp);
    }
}
