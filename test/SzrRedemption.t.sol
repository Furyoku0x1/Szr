// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { Szr } from "../src/Szr.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

contract SzrRedemptionTest is SzrWorld {
    function testDirectRedemptionRecyclesAndPreservesNAV() public {
        _acquire(alice);
        uint256 amount = 100e18;
        uint256 supply = core.activeSupply();
        uint256 inventory = core.unreleasedSupply();
        uint256 nav = core.NAV();
        uint256 expected = FixedPointMathLib.fullMulDiv(amount, core.backingAmount(), supply);
        uint256 balance = backing.balanceOf(alice);
        vm.prank(alice);
        assertEq(core.redeem(amount, expected), expected);
        assertEq(backing.balanceOf(alice), balance + expected);
        assertEq(core.unreleasedSupply(), inventory + amount);
        assertEq(core.activeSupply(), supply - amount);
        assertGe(core.NAV(), nav);
        _assertCash();
    }

    function testRedeemWithLoansPreservesDebtAndCashCoverage() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
        uint256 nav = core.NAV();
        vm.prank(alice);
        core.redeem(900e18, 0);
        assertGe(core.NAV(), nav);
        assertEq(core.loanPrincipal(), 50e12);
        assertEq(core.pledgedSupply(), 100e18);
        vm.prank(alice);
        core.repay(50e12);
        assertEq(core.reclaimableCollateral(alice), 100e18);
        vm.prank(alice);
        core.reclaimCollateral(100e18);
        vm.prank(alice);
        core.redeem(100e18, 0);
        _assertCash();
    }

    function testMinimumBackingFailureRollsBack() public {
        _acquire(alice);
        uint256 tokens = core.token().balanceOf(alice);
        uint256 inventory = core.unreleasedSupply();
        vm.prank(alice);
        vm.expectRevert(SzrCore.BelowMinimum.selector);
        core.redeem(100e18, type(uint256).max);
        assertEq(core.token().balanceOf(alice), tokens);
        assertEq(core.unreleasedSupply(), inventory);
        _assertCash();
    }

    function testReclaimableTokensCannotBeRedeemedFromCore() public {
        _acquire(alice);
        vm.startPrank(alice);
        core.borrow(100e18, 50e12);
        core.repay(50e12);
        core.redeem(core.token().balanceOf(alice), 0);
        vm.expectRevert();
        core.redeem(100e18, 0);
        vm.stopPrank();
        assertEq(core.reclaimableCollateral(alice), 100e18);
        _assertCash();
    }

    function testDonateSzrRetiresTokensToPublicInventory() public {
        _acquire(alice);
        uint256 amount = 100e18;
        uint256 activeSupply = core.activeSupply();
        uint256 inventory = core.unreleasedSupply();
        uint256 publicInventory = core.publicInventory();
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        Szr token = core.token();
        uint256 donorBalance = token.balanceOf(alice);
        uint256 coreBalance = token.balanceOf(address(core));
        vm.startPrank(alice);
        token.approve(address(core), amount);
        core.donateSzr(amount);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), donorBalance - amount);
        assertEq(token.balanceOf(address(core)), coreBalance + amount);
        assertEq(core.activeSupply(), activeSupply - amount);
        assertEq(core.unreleasedSupply(), inventory + amount);
        assertEq(core.publicInventory(), publicInventory + amount);
        assertEq(core.reserveCash(), reserves);
        assertGt(core.NAV(), nav);
        _assertCash();
    }

    function testDonateSzrRejectsZeroAmount() public {
        _acquire(alice);
        vm.prank(alice);
        vm.expectRevert(SzrCore.ZeroAmount.selector);
        core.donateSzr(0);
    }

    function testRecycleRequiresLiquidityController() public {
        _acquire(alice);
        vm.prank(alice);
        vm.expectRevert(SzrCore.NotLiquidity.selector);
        core.recycle(1);
    }

    function testAuthenticatedRecycleRetiresClaimsWithoutInventingCash() public {
        _acquire(alice);
        uint256 inventory = core.unreleasedSupply();
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        Szr token = core.token();
        vm.prank(alice);
        token.transfer(address(locker), 100e18);
        vm.startPrank(address(locker));
        core.token().approve(address(core), 100e18);
        core.recycle(100e18);
        vm.stopPrank();
        assertEq(core.unreleasedSupply(), inventory + 100e18);
        assertEq(core.reserveCash(), reserves);
        assertGt(core.NAV(), nav);
        _assertCash();
    }

    function testWholeWalletExitPreservesExactRatioAndReservedStock() public {
        uint256 tokens = core.token().balanceOf(alice);
        uint256 supply = core.activeSupply();
        uint256 beforeBacking = core.backingAmount();
        uint256 expected = FixedPointMathLib.fullMulDiv(tokens, beforeBacking, supply);
        uint256 inventory = core.unreleasedSupply();
        vm.prank(alice);
        core.redeem(tokens, expected);
        assertEq(core.token().balanceOf(alice), 0);
        assertEq(core.unreleasedSupply(), inventory + tokens);
        assertGe(core.backingAmount() * supply, beforeBacking * core.activeSupply());
        _assertCash();
    }

    function testFuzzRedemptionPreservesRatio(uint96 rawAmount) public {
        _acquire(alice);
        uint256 amount = bound(rawAmount, 1, core.token().balanceOf(alice));
        uint256 nav = core.NAV();
        uint256 supply = core.activeSupply();
        uint256 before = core.backingAmount();
        vm.prank(alice);
        core.redeem(amount, 0);
        assertGe(core.NAV(), nav);
        assertGe(core.backingAmount() * supply, before * core.activeSupply());
        _assertCash();
    }
}
