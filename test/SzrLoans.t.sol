// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

contract SzrLoansTest is SzrWorld {
    function testTopUpUsesExistingCollateralAtHigherNAV() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 100e12);
        vm.prank(bob);
        core.donateBacking(1e18);
        uint256 capacity =
            FixedPointMathLib.fullMulDiv(100e18, core.backingAmount(), core.activeSupply());
        uint256 beforeBalance = backing.balanceOf(alice);
        uint256 draw = capacity - 100e12;
        vm.prank(alice);
        core.borrow(0, draw);
        (uint256 collateral, uint256 debt,) = core.loans(alice);
        assertEq(collateral, 100e18);
        assertEq(debt, capacity);
        assertEq(
            backing.balanceOf(alice) - beforeBalance, draw - FixedPointMathLib.divUp(draw, 100)
        );
        _assertCash();
    }

    function testRejectsDebtAboveTotalCollateralEntitlement() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 90e12);
        uint256 capacity =
            FixedPointMathLib.fullMulDiv(100e18, core.backingAmount(), core.activeSupply());
        vm.prank(alice);
        vm.expectRevert(SzrCore.AboveNAV.selector);
        core.borrow(0, capacity - 90e12 + 1);
        _assertCash();
    }

    function testBorrowWithoutCollateralOrActiveClaimsReverts() public {
        vm.prank(alice);
        vm.expectRevert(SzrCore.AboveNAV.selector);
        core.borrow(0, 100);
        _acquire(alice);
        vm.prank(bob);
        vm.expectRevert(SzrCore.AboveNAV.selector);
        core.borrow(0, 100);
    }

    function testTinyDrawCannotEvadeOpeningFee() public {
        _acquire(alice);
        vm.prank(alice);
        vm.expectRevert(SzrCore.ZeroAmount.selector);
        core.borrow(1e18, 1);
        uint256 beforeBalance = backing.balanceOf(alice);
        vm.prank(alice);
        core.borrow(1e18, 101);
        assertEq(backing.balanceOf(alice) - beforeBalance, 99);
        (, uint256 principal,) = core.loans(alice);
        assertEq(principal, 101);
        _assertCash();
    }

    function testFuzzPartialRepaymentRetainsCoverage(uint128 rawDebt, uint128 rawPayment)
        public
    {
        _acquire(alice);
        uint256 debt = bound(rawDebt, 2, 100e12);
        uint256 payment = bound(rawPayment, 1, debt);
        vm.prank(alice);
        core.borrow(100e18, debt);
        uint256 navBefore = core.NAV();
        uint256 beforeBalance = core.token().balanceOf(alice);
        vm.prank(alice);
        core.repayAndReclaim(payment);
        (uint256 collateral, uint256 remaining,) = core.loans(alice);
        uint256 released = FixedPointMathLib.fullMulDiv(100e18, payment, debt);
        assertEq(core.token().balanceOf(alice) - beforeBalance, released);
        assertEq(collateral, 100e18 - released);
        assertEq(remaining, debt - payment);
        uint256 capacity =
            FixedPointMathLib.fullMulDiv(collateral, core.backingAmount(), core.activeSupply());
        assertLe(remaining, capacity);
        assertEq(core.NAV(), navBefore);
        _assertCash();
    }

    function testOnlyBorrowerCanRenewAndExpiryBoundaryIsExact() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry - 1);
        vm.prank(bob);
        vm.expectRevert(SzrCore.NoLoan.selector);
        core.poke();
        vm.prank(bob);
        vm.expectRevert(SzrCore.NotExpired.selector);
        core.settleExpired(alice);
        vm.prank(alice);
        core.poke();
        (,, uint256 renewed) = core.loans(alice);
        assertEq(renewed, block.timestamp + core.INACTIVITY_SECONDS());
        vm.warp(renewed);
        vm.prank(alice);
        vm.expectRevert(SzrCore.LoanExpired.selector);
        core.poke();
        vm.prank(alice);
        vm.expectRevert(SzrCore.LoanExpired.selector);
        core.borrow(0, 2);
        vm.prank(bob);
        core.settleExpired(alice);
        _assertCash();
    }

    function testRepaymentBeforeSettlementCanRenewExpiredLoan() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry);
        vm.prank(alice);
        core.repayAndReclaim(25e12);
        (, uint256 debt, uint256 renewed) = core.loans(alice);
        assertEq(debt, 25e12);
        assertEq(renewed, block.timestamp + core.INACTIVITY_SECONDS());
        vm.expectRevert(SzrCore.NotExpired.selector);
        core.settleExpired(alice);
        _assertCash();
    }

    function testExpiredLoanCanBeRepaidInFullUntilSomeoneSettlesIt() public {
        _acquire(alice);
        uint256 tokens = core.token().balanceOf(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry + 365 days); // long expired, never settled
        vm.prank(alice);
        core.repayAndReclaim(50e12);
        assertEq(core.token().balanceOf(alice), tokens);
        assertEq(core.loanPrincipal(), 0);
        assertEq(core.pledgedSupply(), 0);
        vm.expectRevert(SzrCore.NoLoan.selector);
        core.settleExpired(alice);
        _assertCash();
    }

    function testSettlementLeavesEarlierFreedCollateralReclaimable() public {
        _acquire(alice);
        uint256 tokens = core.token().balanceOf(alice);
        vm.startPrank(alice);
        core.borrow(100e18, 50e12);
        core.repay(25e12); // frees 50 SZR but leaves it in Core
        vm.stopPrank();
        (,, uint256 expiry) = core.loans(alice);
        uint256 retired =
            FixedPointMathLib.fullMulDivUp(25e12, core.activeSupply(), core.backingAmount());
        vm.warp(expiry);
        core.settleExpired(alice);
        assertEq(core.token().balanceOf(alice), tokens - 50e18 - retired);
        assertEq(core.reclaimableCollateral(alice), 50e18);
        vm.prank(alice);
        core.reclaimCollateral(50e18);
        assertEq(core.token().balanceOf(alice), tokens - retired);
        assertEq(core.totalReclaimable(), 0);
        _assertCash();
    }

    function testSettlementReturnsExcessAndCannotExecuteTwice() public {
        _acquire(alice);
        vm.prank(alice);
        core.borrow(100e18, 25e12);
        (,, uint256 expiry) = core.loans(alice);
        uint256 retired =
            FixedPointMathLib.fullMulDivUp(25e12, core.activeSupply(), core.backingAmount());
        uint256 beforeBalance = core.token().balanceOf(alice);
        uint256 inventory = core.unreleasedSupply();
        uint256 reserve = core.reserveCash();
        uint256 navBefore = core.NAV();
        vm.warp(expiry);
        core.settleExpired(alice);
        assertEq(core.token().balanceOf(alice) - beforeBalance, 100e18 - retired);
        assertEq(core.unreleasedSupply(), inventory + retired);
        assertEq(core.reserveCash(), reserve);
        assertGe(core.NAV(), navBefore);
        vm.expectRevert(SzrCore.NoLoan.selector);
        core.settleExpired(alice);
        vm.prank(alice);
        vm.expectRevert(SzrCore.NoLoan.selector);
        core.repayAndReclaim(25e12);
        _assertCash();
    }

    function testFullRepaymentReturnsAllCollateral() public {
        _acquire(alice);
        uint256 tokens = core.token().balanceOf(alice);
        vm.prank(alice);
        core.borrow(100e18, 50e12);
        vm.prank(alice);
        core.repayAndReclaim(50e12);
        assertEq(core.token().balanceOf(alice), tokens);
        assertEq(core.loanPrincipal(), 0);
        assertEq(core.pledgedSupply(), 0);
        (uint256 collateral, uint256 principal, uint256 expiresAt) = core.loans(alice);
        assertEq(collateral + principal + expiresAt, 0);
        _assertCash();
    }
}
