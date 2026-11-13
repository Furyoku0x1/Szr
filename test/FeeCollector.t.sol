// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { Liquidity } from "../src/Liquidity.sol";
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

    function _feeAssetWithFloor(uint256 floor) internal returns (TestAsset asset) {
        asset = new TestAsset();
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(asset);
        locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, floor));
    }

    function _takeAll(TestAsset asset) internal {
        uint256 inventory = jar.auction(address(asset)).inventory;
        uint256 payment = jar.quote(address(asset), inventory);
        vm.prank(alice);
        jar.take(address(asset), inventory, payment, block.timestamp);
    }

    /// Found in the final audit: the price only decays, so once it has run down, a batch that
    /// arrives sells at the floor. The floor is therefore the protection: with the minimum
    /// floor 600 WETH of fees sell for dust, with a real one they cannot sell below it.
    function testFix_ARealFloorBoundsABatchThatArrivesAfterTheDecay() public {
        TestAsset dust = _feeAssetWithFloor(1);
        TestAsset kept = _feeAssetWithFloor(9e17); // market 1 WETH per token, floor 0.9
        _recordFee(dust, 1);
        _recordFee(kept, 1);
        vm.warp(block.timestamp + 2 days);
        _recordFee(dust, 600e18);
        _recordFee(kept, 600e18);
        assertLt(jar.quote(address(dust), 600e18), 1_000);
        assertEq(jar.price(address(kept)), 9e17);
        assertGe(jar.quote(address(kept), 600e18), 540e18);
    }

    function testUpdateAssetIsManagerKeptAndRestartsTheAuction() public {
        TestAsset asset = _feeAssetWithFloor(1);
        FeeCollector.AssetConfig memory config = FeeCollector.AssetConfig(3e18, 600e18, 27e17);
        vm.prank(alice);
        vm.expectRevert(FeeCollector.NotManager.selector);
        jar.updateAsset(address(asset), config);
        vm.expectRevert(FeeCollector.InvalidAsset.selector);
        jar.updateAsset(address(0xDEAD), config);
        vm.expectRevert(FeeCollector.ZeroAmount.selector);
        jar.updateAsset(address(asset), FeeCollector.AssetConfig(3e18, 0, 27e17));
        vm.expectRevert(); // the floor must sit below twice the rate
        jar.updateAsset(address(asset), FeeCollector.AssetConfig(1e18, 600e18, 2e18));

        // 600 fee tokens have waited until their price is almost gone; the market is now 3.
        _recordFee(asset, 600e18);
        vm.warp(block.timestamp + 2 days - 1);
        assertLt(jar.quote(address(asset), 600e18), 1e18);
        vm.expectEmit(address(jar));
        emit FeeCollector.AssetUpdated(address(asset), 600e18, 6e18, 27e17);
        jar.updateAsset(address(asset), config);
        FeeCollector.Auction memory stored = jar.auction(address(asset));
        assertEq(stored.buffer, 600e18);
        assertEq(stored.inventory, 600e18);
        assertEq(stored.curve.floorWad, 27e17);
        assertEq(jar.price(address(asset)), 6e18); // restarted at twice the given rate
        vm.warp(block.timestamp + 2 days);
        assertEq(jar.price(address(asset)), 27e17); // and decays to the new floor, no lower
        assertGe(jar.quote(address(asset), 600e18), 600 * 27e17);
        _takeAll(asset);
        _assertCash();
    }

    /// A dust buffer lets one cheap purchase push the frozen price so high that, once the
    /// token's supply has grown, a later receipt cannot be recorded (and Liquidity withdrawals
    /// record fees). Updating the asset restarts its auction and clears that.
    function testFix_UpdatingAnAssetClearsAnAuctionPushedOutOfRange() public {
        TestAsset asset = new TestAsset();
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(asset);
        locker.addPool(config, FeeCollector.AssetConfig(1e18, 14_902, 1));
        backing.mint(alice, 1e40);
        _recordFee(asset, 4.8e9);
        _takeAll(asset);
        _recordFee(asset, 2.6e11);
        _takeAll(asset);

        asset.mint(address(jar), 1.6e23);
        vm.prank(address(locker));
        vm.expectRevert();
        jar.recordFees(address(asset), 1.6e23);

        jar.updateAsset(address(asset), FeeCollector.AssetConfig(1e18, 1e22, 9e17));
        vm.prank(address(locker));
        jar.recordFees(address(asset), 1.6e23);
        assertEq(jar.auction(address(asset)).inventory, 1.6e23);
        assertEq(jar.price(address(asset)), 2e18);
    }

    /// Whatever arrives, waits, is bought or is updated, no fee token sells below its floor.
    function testFuzzFeesNeverSellBelowTheFloor(
        uint64[8] memory amounts,
        uint32[8] memory waits,
        uint64[8] memory floors
    ) public {
        TestAsset asset = _feeAssetWithFloor(9e17);
        backing.mint(alice, 1e36);
        uint256 floor = 9e17;
        for (uint256 index; index < 8; index++) {
            vm.warp(block.timestamp + bound(waits[index], 0, 3 days));
            _recordFee(asset, bound(amounts[index], 1, 1e24));
            if (index % 4 == 3) {
                floor = bound(floors[index], 1, 1e20);
                jar.updateAsset(
                    address(asset),
                    FeeCollector.AssetConfig(floor, bound(amounts[index], 1, 1e24), floor)
                );
            }
            uint256 inventory = jar.auction(address(asset)).inventory;
            uint256 part = inventory / 2 + 1;
            uint256 payment = jar.quote(address(asset), part);
            assertGe(payment, FixedPointMathLib.fullMulDiv(part, floor, 1e18));
            assertGe(jar.price(address(asset)), floor);
            if (index % 3 == 2) {
                vm.prank(alice);
                jar.take(address(asset), part, payment, block.timestamp);
            }
        }
        _assertCash();
    }
}
