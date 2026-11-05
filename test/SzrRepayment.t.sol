// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";

contract SzrRepaymentTest is SzrWorld {
    function _openLoan() internal {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
    }

    function testRepayCreatesClaimWithoutTransferringCollateral() public {
        _openLoan();
        uint256 before = core.token().balanceOf(alice);
        uint256 supply = core.activeSupply();
        vm.prank(alice);
        core.repay(25e12);
        assertEq(core.token().balanceOf(alice), before);
        assertEq(core.reclaimableCollateral(alice), 50e18);
        assertEq(core.totalReclaimable(), 50e18);
        assertEq(core.pledgedSupply(), 50e18);
        assertEq(core.activeSupply(), supply);
        _assertCash();
    }

    function testClaimSurvivesFullRepaymentAndLoanDeletion() public {
        _openLoan();
        vm.startPrank(alice);
        core.repay(50e12);
        (uint256 collateral, uint256 debt, uint256 expiry) = core.loans(alice);
        assertEq(collateral + debt + expiry, 0);
        assertEq(core.reclaimableCollateral(alice), 100e18);
        core.reclaimCollateral(30e18);
        assertEq(core.reclaimableCollateral(alice), 70e18);
        core.reclaimCollateral(70e18);
        vm.expectRevert(SzrCore.InsufficientReclaimable.selector);
        core.reclaimCollateral(1);
        vm.stopPrank();
        assertEq(core.totalReclaimable(), 0);
        _assertCash();
    }

    function testCombinedRepaymentLeavesOlderClaimsUntouched() public {
        _openLoan();
        vm.startPrank(alice);
        core.repay(25e12);
        uint256 balance = core.token().balanceOf(alice);
        core.repayAndReclaim(25e12);
        vm.stopPrank();
        assertEq(core.token().balanceOf(alice), balance + 50e18);
        assertEq(core.reclaimableCollateral(alice), 50e18);
        assertEq(core.totalReclaimable(), 50e18);
        _assertCash();
    }

    function testNewLoanDoesNotEraseOldReclaimableCollateral() public {
        _openLoan();
        vm.startPrank(alice);
        core.repay(50e12);
        core.borrow(100e18, 50e12);
        core.reclaimCollateral(100e18);
        vm.stopPrank();
        (uint256 locked, uint256 debt,) = core.loans(alice);
        assertEq(locked, 100e18);
        assertEq(debt, 50e12);
        assertEq(core.reclaimableCollateral(alice), 0);
        _assertCash();
    }

    function testExpiryCannotRecyclePreviouslyFreedCollateral() public {
        _openLoan();
        vm.prank(alice);
        core.repay(25e12);
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry);
        core.settleExpired(alice);
        assertEq(core.reclaimableCollateral(alice), 50e18);
        vm.prank(alice);
        core.reclaimCollateral(50e18);
        assertEq(core.totalReclaimable(), 0);
        _assertCash();
    }

    function testLatePartialRepaymentRenewsNinetyDays() public {
        _openLoan();
        (,, uint256 expiry) = core.loans(alice);
        assertEq(expiry, block.timestamp + 90 days);
        vm.warp(expiry + 1);
        vm.prank(alice);
        core.repay(25e12);
        (,, uint256 renewed) = core.loans(alice);
        assertEq(renewed, block.timestamp + 90 days);
        assertEq(core.reclaimableCollateral(alice), 50e18);
        _assertCash();
    }

    function testOtherAccountCannotClaimOrRepayOwnersLoan() public {
        _openLoan();
        vm.prank(alice);
        core.repay(25e12);
        vm.startPrank(bob);
        vm.expectRevert(SzrCore.InsufficientReclaimable.selector);
        core.reclaimCollateral(1);
        vm.expectRevert(SzrCore.NoLoan.selector);
        core.repay(1);
        vm.stopPrank();
        assertEq(core.reclaimableCollateral(alice), 50e18);
        _assertCash();
    }

    function testFreedCollateralDoesNotCountTowardBorrowCapacity() public {
        _openLoan();
        vm.startPrank(alice);
        core.repay(25e12);
        vm.expectRevert(SzrCore.AboveNAV.selector);
        core.borrow(0, 30e12);
        vm.stopPrank();
        assertEq(core.reclaimableCollateral(alice), 50e18);
        _assertCash();
    }

    function testFuzzSeparateAndCombinedConserveCollateral(uint96 rawPayment) public {
        _openLoan();
        uint256 payment = bound(rawPayment, 1, 50e12);
        uint256 supply = core.activeSupply();
        vm.prank(alice);
        core.repay(payment);
        uint256 claimable = core.reclaimableCollateral(alice);
        (uint256 locked, uint256 debt,) = core.loans(alice);
        assertEq(locked + claimable, 100e18);
        assertEq(debt, 50e12 - payment);
        assertEq(core.activeSupply(), supply);
        if (claimable != 0) {
            vm.prank(alice);
            core.reclaimCollateral(claimable);
        }
        assertEq(core.totalReclaimable(), 0);
        _assertCash();
    }
}
