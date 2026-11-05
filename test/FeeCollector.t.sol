// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { TestAsset } from "./utils/TestAsset.sol";

contract FeeCollectorTest is SzrWorld {
    TestAsset internal feeAsset;

    function setUp() public override {
        super.setUp();
        feeAsset = _registerFeeAsset();
    }

    function testPartialPurchaseRetainsStockAndMergedReceiptsPreservePrice() public {
        _recordFee(feeAsset, 100e18);
        uint256 initialPrice = jar.price(address(feeAsset));
        _recordFee(feeAsset, 200e18);
        assertApproxEqAbs(jar.price(address(feeAsset)), initialPrice, 1);
        uint256 payment = jar.quote(address(feeAsset), 50e18);
        uint256 reserves = core.reserveCash();
        vm.prank(bob);
        jar.take(address(feeAsset), 50e18, payment, block.timestamp);
        assertEq(feeAsset.balanceOf(bob), 50e18);
        assertEq(jar.auction(address(feeAsset)).inventory, 250e18);
        uint256 team = payment * 3_300 / 10_000;
        assertEq(core.reserveCash(), reserves + payment - team);
        assertEq(core.economics().claimableFees(), team);
        assertGt(jar.price(address(feeAsset)), initialPrice);
        _assertCash();
    }

    function testEmptyPriceFreezesAndRefillResumesWithoutReset() public {
        _recordFee(feeAsset, 100e18);
        uint256 payment = jar.quote(address(feeAsset), 100e18);
        vm.prank(bob);
        jar.take(address(feeAsset), 100e18, payment, block.timestamp);
        uint256 frozen = jar.price(address(feeAsset));
        vm.warp(block.timestamp + 100 days);
        assertEq(jar.price(address(feeAsset)), frozen);
        _recordFee(feeAsset, 100e18);
        assertApproxEqAbs(jar.price(address(feeAsset)), frozen, 1);
        vm.warp(block.timestamp + 2 days);
        assertEq(jar.price(address(feeAsset)), jar.auction(address(feeAsset)).curve.floorWad);
    }

    function testAReceiptCannotBeRecordedTwiceAndOwnTokenNeverSellsHere() public {
        _recordFee(feeAsset, 10e18);
        vm.prank(address(locker));
        vm.expectRevert(FeeCollector.UnrecordedReceipt.selector);
        jar.recordFees(address(feeAsset), 10e18);
        address ownToken = address(core.token());
        vm.prank(address(locker));
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.recordFees(ownToken, 1);
        assertFalse(jar.accepts(address(core.token())));
    }

    function testDeadlineMaximumAndExactInventoryProtectBuyer() public {
        _recordFee(feeAsset, 10e18);
        uint256 payment = jar.quote(address(feeAsset), 10e18);
        vm.startPrank(bob);
        vm.expectRevert(FeeCollector.DeadlinePassed.selector);
        jar.take(address(feeAsset), 10e18, payment, block.timestamp - 1);
        vm.expectRevert(FeeCollector.AboveMaximum.selector);
        jar.take(address(feeAsset), 10e18, payment - 1, block.timestamp);
        jar.take(address(feeAsset), 10e18, payment, block.timestamp);
        vm.expectRevert(FeeCollector.InsufficientInventory.selector);
        jar.take(address(feeAsset), 1, payment, block.timestamp);
        vm.stopPrank();
        _assertCash();
    }

    function testDuplicateRegistrationCannotOverwriteAnyState() public {
        _recordFee(feeAsset, 10e18);
        FeeCollector.Auction memory beforeState = jar.auction(address(feeAsset));
        vm.prank(address(locker));
        jar.registerAsset(address(feeAsset), FeeCollector.AssetConfig(0, 0, 0));
        assertEq(
            keccak256(abi.encode(beforeState)),
            keccak256(abi.encode(jar.auction(address(feeAsset))))
        );
    }

    function testRegistrationHasNoLifetimeAssetCap() public {
        for (uint256 index; index < 20; index++) {
            _registerFeeAsset();
        }
        assertEq(jar.assetCount(), 21);
        assertEq(locker.poolCount(), 22);
    }

    function testPriceCannotFreezeOutsideExistingSupplyRefillDomain() public {
        TestAsset asset = new TestAsset();
        vm.prank(address(locker));
        jar.registerAsset(address(asset), FeeCollector.AssetConfig(1e18, 1, 1));
        _recordFee(asset, 10e18);
        vm.expectRevert(FixedPointMathLib.FullMulDivFailed.selector);
        jar.quote(address(asset), 10e18);
        assertEq(jar.auction(address(asset)).inventory, 10e18);
        _recordFee(asset, 1e18);
        assertEq(jar.auction(address(asset)).inventory, 11e18);
    }

    function testFalseSuccessfulBackingTransferCannotRecognizeRevenue() public {
        _recordFee(feeAsset, 10e18);
        uint256 payment = jar.quote(address(feeAsset), 1e18);
        uint256 beforeCash = core.reserveCash();
        bytes32 beforeAuction = keccak256(abi.encode(jar.auction(address(feeAsset))));
        vm.mockCall(
            address(backing),
            abi.encodeWithSelector(backing.transferFrom.selector, bob, address(core), payment),
            abi.encode(true)
        );
        vm.prank(bob);
        vm.expectRevert(FeeCollector.TransferAmountMismatch.selector);
        jar.take(address(feeAsset), 1e18, payment, block.timestamp);
        vm.clearMockedCalls();
        assertEq(core.reserveCash(), beforeCash);
        assertEq(keccak256(abi.encode(jar.auction(address(feeAsset)))), beforeAuction);
        assertEq(feeAsset.balanceOf(bob), 0);
        _assertCash();
    }

    function testConstructorAndRegistrationRejectInvalidAssetsAndRates() public {
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(SzrCore(address(0)));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(SzrCore(alice));
        FeeCollector.AssetConfig memory config = FeeCollector.AssetConfig(1e18, 1e18, 1);
        vm.expectRevert(FeeCollector.NotLiquidity.selector);
        jar.registerAsset(address(feeAsset), config);
        address own = address(core.token());
        vm.startPrank(address(locker));
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.registerAsset(own, config);
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.registerAsset(alice, config);
        vm.stopPrank();
        TestAsset other = new TestAsset();
        config.initialPoolRateWad = type(uint256).max;
        vm.prank(address(locker));
        vm.expectRevert(FeeCollector.InvalidRate.selector);
        jar.registerAsset(address(other), config);
    }

    function testUnknownAssetsEmptyReceiptsAndMissingBackingCannotBeSold() public {
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.quote(alice, 1);
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.price(alice);
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.take(alice, 1, type(uint256).max, block.timestamp);
        vm.expectRevert(FeeCollector.InsufficientInventory.selector);
        jar.quote(address(feeAsset), 1);
        vm.startPrank(address(locker));
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        jar.recordFees(address(feeAsset), 0);
        vm.expectRevert(FeeCollector.UnrecordedReceipt.selector);
        jar.recordFees(address(backing), 1);
        vm.stopPrank();
    }

    function testUnsetLaunchClockCannotOpenFeeSalesOrAgePrices() public {
        _recordFee(feeAsset, 10e18);
        uint256 price = jar.price(address(feeAsset));
        vm.mockCall(
            address(core), abi.encodeCall(core.auctionsOpenAt, ()), abi.encode(uint256(0))
        );
        assertEq(jar.price(address(feeAsset)), price);
        vm.expectRevert(FeeCollector.AuctionNotOpen.selector);
        jar.take(address(feeAsset), 1, type(uint256).max, block.timestamp);
        vm.clearMockedCalls();
    }

    function testDirectBackingFalseTransferCannotRecognizeFees() public {
        backing.mint(address(jar), 80e18);
        uint256 reserve = core.reserveCash();
        vm.mockCall(
            address(backing),
            abi.encodeWithSelector(backing.transfer.selector, address(core), uint256(80e18)),
            abi.encode(true)
        );
        vm.prank(address(locker));
        vm.expectRevert(FeeCollector.TransferAmountMismatch.selector);
        jar.recordFees(address(backing), 80e18);
        assertEq(core.reserveCash(), reserve);
        assertEq(backing.balanceOf(address(jar)), 80e18);
        vm.clearMockedCalls();
        _assertCash();
    }

    function testFalseAssetPayoutRollsBackFeeSplitAndAuction() public {
        _recordFee(feeAsset, 10e18);
        uint256 payment = jar.quote(address(feeAsset), 1e18);
        uint256 reserve = core.reserveCash();
        vm.mockCall(
            address(feeAsset),
            abi.encodeWithSelector(feeAsset.transfer.selector, bob, uint256(1e18)),
            abi.encode(true)
        );
        vm.prank(bob);
        vm.expectRevert(FeeCollector.TransferAmountMismatch.selector);
        jar.take(address(feeAsset), 1e18, payment, block.timestamp);
        assertEq(core.reserveCash(), reserve);
        assertEq(core.economics().claimableFees(), 0);
        assertEq(jar.auction(address(feeAsset)).inventory, 10e18);
        vm.clearMockedCalls();
        _assertCash();
    }

    function testFuzzSplitCostIsNotCheaper(uint96 rawQuantity) public {
        _recordFee(feeAsset, 1_000e18);
        uint256 quantity = bound(rawQuantity, 2, 1_000e18);
        uint256 combined = jar.quote(address(feeAsset), quantity);
        uint256 first = jar.quote(address(feeAsset), quantity / 2);
        vm.prank(bob);
        jar.take(address(feeAsset), quantity / 2, first, block.timestamp);
        uint256 second = jar.quote(address(feeAsset), quantity - quantity / 2);
        assertGe(first + second, combined);
        assertLe(first + second, combined + 1);
    }
}
