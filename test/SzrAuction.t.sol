// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
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
        vm.startPrank(buyer);
        backing.approve(address(core), payment);
        core.buy(quantity, payment, block.timestamp);
        vm.stopPrank();
        assertEq(core.token().balanceOf(buyer), quantity);
        assertEq(core.activeSupply(), supply + quantity);
        assertEq(core.unreleasedSupply(), inventory - quantity);
        assertEq(core.reserveCash(), cash + required);
        assertEq(locker.heldPrincipal(address(backing)), held + funding);
        assertGe(core.NAV(), nav);
        assertEq(core.economics().claimableFees(), team);
        _assertCash();
    }

    function testSaleNeverAcceptsLessThanExactNavBacking() public {
        vm.warp(block.timestamp + 2 days);
        uint256 amount = 1_000e18;
        (uint256 payment, uint256 backingRequired, uint256 funding) = core.quote(amount);
        assertGe(payment, backingRequired);
        assertEq(funding, payment - backingRequired);
        assertGt(funding, 0);
        assertEq(backingRequired, core.backingRequired(amount));
        uint256 nav = core.NAV();
        vm.prank(alice);
        core.buy(amount, payment, block.timestamp);
        assertGe(core.NAV(), nav);
        _assertCash();
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
