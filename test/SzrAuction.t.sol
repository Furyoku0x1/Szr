// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { ContinuousAuction } from "../src/ContinuousAuction.sol";
import { ReleaseSchedule } from "../src/ReleaseSchedule.sol";

contract SzrAuctionTest is SzrWorld {
    function testOneSaleFundsBackingBeforeTreasuryAndNeedsOnlyWeth() public {
        address buyer = address(0x12345);
        backing.mint(buyer, 1e18);
        uint256 quantity = 1_000e18;
        (uint256 payment, uint256 required, uint256 funding) = core.quote(quantity);
        uint256 cash = core.reserveCash();
        uint256 supply = core.activeSupply();
        uint256 inventory = core.unreleasedSupply();
        uint256 held = locker.heldPrincipal(address(backing));
        uint256 nav = core.NAV();
        uint256 team = core.economics().claimableFees();
        assertGt(funding, 0);
        assertEq(payment, required + funding);
        assertEq(funding, (payment - core.backingRequired(quantity)) * 2 / 3);
        vm.startPrank(buyer);
        backing.approve(address(core), payment);
        core.buy(quantity, payment, block.timestamp);
        vm.stopPrank();
        assertEq(core.token().balanceOf(buyer), quantity);
        assertEq(core.activeSupply(), supply + quantity);
        assertEq(core.unreleasedSupply(), inventory - quantity);
        assertEq(core.reserveCash(), cash + required);
        assertEq(locker.heldPrincipal(address(backing)), held + funding);
        assertGt(core.NAV(), nav);
        assertEq(core.economics().claimableFees(), team);
        _assertCash();
    }

    function testSaleNeverAcceptsLessThanOneAndAHalfTimesNav() public {
        vm.warp(block.timestamp + 2 days);
        uint256 amount = 1_000e18;
        (uint256 payment, uint256 reserves, uint256 funding) = core.quote(amount);
        uint256 premium = payment - core.backingRequired(amount);
        assertGe(payment * 2, core.backingRequired(amount) * 3);
        assertEq(funding, premium * 2 / 3);
        assertEq(reserves, payment - funding);
        uint256 nav = core.NAV();
        vm.prank(alice);
        core.buy(amount, payment, block.timestamp);
        assertGt(core.NAV(), nav);
        _assertCash();
    }

    function _raiseNavTo(uint256 target) internal {
        uint256 gift = target * core.activeSupply() / 1e18 - core.backingAmount();
        backing.mint(address(this), gift);
        backing.approve(address(core), gift);
        core.donateBacking(gift);
    }

    /// The original pricing library stopped selling for good once 1.5x NAV passed about
    /// 0.67 WETH per SZR. The sale and every exit must now work far beyond that.
    function testSaleAndExitsWorkFarAboveTheOldPriceCeiling() public {
        _raiseNavTo(70_000e18);
        assertGt(core.NAV(), 69_999e18);
        (uint256 payment,,) = core.quote(1_000e18);
        assertGe(payment, 105_000_000e18); // 1,000 SZR at 1.5 x 70,000 WETH
        backing.mint(alice, payment);
        uint256 nav = core.NAV();
        vm.startPrank(alice);
        core.buy(1_000e18, payment, block.timestamp);
        assertGt(core.NAV(), nav);
        core.redeem(100e18, 0);
        core.donateSzr(1e18);
        core.borrow(100e18, core.backingRequired(50e18));
        vm.stopPrank();
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry);
        core.settleExpired(alice);
        (payment,,) = core.quote(1e18);
        assertGt(payment, 0);
        _assertCash();
    }

    /// Measured, not assumed: with the full supply the curve holds a floor up to about
    /// 115,000 WETH per SZR. Past that only new sales stop; exits are unaffected.
    function testPastTheNewCeilingOnlySalesStop() public {
        _raiseNavTo(77_000e18); // floor 115,500 WETH
        (uint256 payment,,) = core.quote(1e18);
        assertGt(payment, 0);
        _raiseNavTo(77_300e18); // floor 115,950 WETH
        vm.expectRevert(ContinuousAuction.UnrepresentableCurve.selector);
        core.quote(1e18);
        vm.expectRevert(ContinuousAuction.UnrepresentableCurve.selector);
        core.buy(1e18, type(uint256).max, block.timestamp);
        uint256 held = core.token().balanceOf(alice);
        vm.startPrank(alice);
        assertGt(core.redeem(held / 2, 0), 0);
        core.donateSzr(1e18);
        vm.stopPrank();
        assertGt(core.price(), 115_000e18);
        _assertCash();
    }

    function testFullyDecayedSaleStillChargesTheMinimumOnOneWei() public {
        vm.warp(block.timestamp + 365 days);
        uint256 floor = (core.backingRequired(1e18) * 3 + 1) / 2;
        assertEq(core.price(), floor);
        uint256 required = core.backingRequired(1);
        (uint256 payment,,) = core.quote(1);
        assertEq(payment, (required * 3 + 1) / 2);
        vm.prank(alice);
        core.buy(1, payment, block.timestamp);
        assertEq(core.auctionState().floorWad, floor);
    }

    /// The reserve third of the premium is shared with every holder, so a large holder
    /// who buys and redeems everything must end with less WETH than by redeeming alone.
    function testLargeHolderCannotProfitFromOwnPremium(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1e18, core.availableRelease());
        core.token().transfer(alice, core.token().balanceOf(address(this)));
        uint256 held = core.token().balanceOf(alice);
        assertGt(held * 4, core.activeSupply());
        uint256 start = backing.balanceOf(alice);
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        core.redeem(held, 0);
        uint256 redeemOnly = backing.balanceOf(alice) - start;
        vm.revertToState(snapshot);
        (uint256 payment,, uint256 funding) = core.quote(amount);
        assertGt(funding, 0);
        vm.startPrank(alice);
        core.buy(amount, payment, block.timestamp);
        core.redeem(held + amount, 0);
        vm.stopPrank();
        assertLe(backing.balanceOf(alice) + funding, start + redeemOnly);
    }

    function testMaximumDeadlineAndSharedCreditAreEnforced() public {
        (uint256 payment,,) = core.quote(1_000e18);
        vm.startPrank(alice);
        vm.expectRevert(SzrCore.AboveMaximum.selector);
        core.buy(1_000e18, payment - 1, block.timestamp);
        vm.expectRevert(SzrCore.DeadlinePassed.selector);
        core.buy(1_000e18, payment, block.timestamp - 1);
        uint256 credit = core.availableRelease();
        vm.expectRevert(SzrCore.ReleaseLimit.selector);
        core.buy(credit + 1, type(uint256).max, block.timestamp);
        vm.stopPrank();
        _assertCash();
    }

    function testRepeatedQuotesDoNotChangeTheSale() public view {
        (uint256 first,,) = core.quote(1e18);
        (uint256 second,,) = core.quote(1e18);
        assertEq(first, second);
    }

    function testReturnedSzrRefillsTheSameSaleWithoutCreatingCredit() public {
        uint256 inventory = core.publicInventory();
        uint256 credit = core.releaseCredit();
        uint256 price = core.price();
        vm.prank(alice);
        core.redeem(100e18, 0);
        assertEq(core.publicInventory(), inventory + 100e18);
        assertEq(core.releaseCredit(), credit);
        assertApproxEqAbs(core.price(), price, 1);
        _assertCash();
    }

    function testFuzzNewSalesPreserveBackingRatio(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, core.availableRelease());
        uint256 supply = core.activeSupply();
        uint256 backingBefore = core.backingAmount();
        (uint256 payment,,) = core.quote(amount);
        vm.prank(alice);
        core.buy(amount, payment, block.timestamp);
        assertGe(core.backingAmount() * supply, backingBefore * core.activeSupply());
        _assertCash();
    }

    function testAccountingFailureRollsBackBothPaymentAndIssuance() public {
        (uint256 payment,,) = core.quote(1_000e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 cash = core.reserveCash();
        uint256 funding = locker.heldPrincipal(address(backing));
        vm.mockCall(
            address(backing),
            abi.encodeWithSelector(
                backing.transferFrom.selector, alice, address(core), payment
            ),
            abi.encode(true)
        );
        vm.prank(alice);
        vm.expectRevert(SzrCore.TransferAmountMismatch.selector);
        core.buy(1_000e18, payment, block.timestamp);
        vm.clearMockedCalls();
        assertEq(core.unreleasedSupply(), inventory);
        assertEq(core.reserveCash(), cash);
        assertEq(locker.heldPrincipal(address(backing)), funding);
    }

    function testEveryUnpurchasedReleaseRemainsAvailableAndCanBeBought() public {
        vm.warp(core.auctionsOpenAt() + 7 days);
        uint256 scheduled = ReleaseSchedule.cumulativeScaled(7 days) / 1 days;
        uint256 unsold = scheduled - core.totalReleased();
        assertGt(unsold, 500_000e18);
        assertEq(core.releaseCredit(), unsold);
        assertEq(core.availableRelease(), unsold);
        (uint256 payment,,) = core.quote(unsold);
        vm.prank(alice);
        core.buy(unsold, payment, block.timestamp);
        assertEq(core.availableRelease(), 0);
        assertLt(core.releaseState().scaledCredit, 1 days);
        vm.warp(block.timestamp + 1 days);
        uint256 nextScheduled = ReleaseSchedule.cumulativeScaled(8 days) / 1 days;
        assertEq(core.availableRelease(), nextScheduled - core.totalReleased());
        assertGt(core.availableRelease(), 400_000e18);
        _assertCash();
    }
}

contract SzrInventoryTest is SzrWorld {
    function setUp() public override {
        initialSupply = 999_990_000e18;
        super.setUp();
    }

    function testEmptySaleFreezesPriceAndRecycledInventoryResumesIt() public {
        uint256 stock = core.publicInventory();
        assertEq(stock, 9_000e18);
        (uint256 payment,,) = core.quote(stock);
        vm.prank(alice);
        core.buy(stock, payment, block.timestamp);
        assertEq(core.publicInventory(), 0);
        uint256 price = core.price();
        vm.warp(block.timestamp + 100 days);
        assertEq(core.price(), price);
        uint256 scheduled = ReleaseSchedule.cumulativeScaled(
            block.timestamp - core.auctionsOpenAt()
        ) / 1 days;
        assertEq(core.releaseCredit(), scheduled - core.totalReleased());
        assertGt(core.releaseCredit(), 500_000e18);
        assertEq(core.availableRelease(), 0);
        vm.prank(alice);
        core.redeem(100e18, 0);
        assertEq(core.availableRelease(), 100e18);
        assertApproxEqAbs(core.price(), price, 1);
        _assertCash();
    }
}
