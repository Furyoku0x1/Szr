// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MetricExtensionWorld, SwapPool } from "./MetricLiquidityExtension.t.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { MetricSwapping } from "../src/extensions/MetricSwapping.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";

/// @dev The v4 extension swaps on Metric pools directly, with no v4 wrapper
/// (`docs/specs/extension-cross-swaps.md`).
contract V4LiquidityExtensionMetricTest is MetricExtensionWorld {
    function setUp() public override {
        super.setUp();
        ext.addPool(address(pool));
    }

    function testTheV4ExtensionSwapsOnMetricBothWays() public {
        uint256 in0 = t0.balanceOf(address(ext));
        uint256 out1 = t1.balanceOf(address(ext));
        vm.expectEmit(true, false, false, true, address(ext));
        emit MetricSwapping.MetricSwapped(address(pool), true, 100e18, 100e18);
        (uint256 spent, uint256 got) =
            ext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        assertEq(spent, 100e18, "spent");
        assertEq(got, 100e18, "received");
        assertEq(t0.balanceOf(address(ext)), in0 - 100e18, "input paid in the callback");
        assertEq(t1.balanceOf(address(ext)), out1 + 100e18, "output received");
        vm.expectEmit(true, false, false, true, address(ext));
        emit MetricSwapping.MetricSwapped(address(pool), false, 50e18, 50e18);
        (spent, got) = ext.swapMetric(address(pool), false, 50e18, 50e18, 0, block.timestamp);
        assertEq(spent, 50e18, "spent back");
        assertEq(got, 50e18, "received back");
        assertEq(t0.balanceOf(address(ext)), in0 - 50e18, "token0 back");
        assertEq(t1.balanceOf(address(ext)), out1 + 50e18, "token1 paid");
    }

    function testOnlyTheManagerAddsAndSwaps() public {
        SwapPool fresh = _pool(address(t0), address(t1), none);
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        ext.addPool(address(fresh));
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        ext.swapMetric(address(pool), true, 1e18, 0, 0, block.timestamp);
        SwapPool unknown = _pool(address(t0), address(t1), none);
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        ext.swapMetric(address(unknown), true, 1e18, 0, 0, block.timestamp);
    }

    function testForeignAndSzrPoolsAreRefused() public {
        SwapPool foreign = SwapPool(
            deployCode(
                "MetricLiquidityExtension.t.sol:SwapPool",
                abi.encode(address(t0), address(t1), MIN, none)
            )
        );
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
        ext.addPool(address(foreign));
        SwapPool szrFirst = _pool(address(szr), address(t1), none);
        SwapPool szrSecond = _pool(address(t0), address(szr), none);
        vm.expectRevert(MetricSwapping.SzrPool.selector);
        ext.addPool(address(szrFirst));
        vm.expectRevert(MetricSwapping.SzrPool.selector);
        ext.addPool(address(szrSecond));
    }

    /// The v4 extension holds no Metric positions, so an extension around removal, which the
    /// Metric extension refuses, doesn't stop it trading.
    function testAPoolWithARemovalExtensionIsTradable() public {
        uint256[4] memory before = [uint256(0), 0, 1, 0];
        SwapPool blocking = _pool(address(t0), address(t1), before);
        vm.expectRevert(MetricLiquidityExtension.BlockingExtension.selector);
        mext.addPool(address(blocking));
        ext.addPool(address(blocking));
        t0.mint(address(blocking), HELD);
        t1.mint(address(blocking), HELD);
        (, uint256 got) =
            ext.swapMetric(address(blocking), true, 10e18, 10e18, 0, block.timestamp);
        assertEq(got, 10e18, "traded");
    }

    function testTheSwapCallbackAnswersOnlyThePoolBeingCalled() public {
        vm.expectRevert(MetricSwapping.NotPool.selector);
        ext.metricOmmSwapCallback(1, 1, "");
        vm.prank(address(pool));
        vm.expectRevert(MetricSwapping.NotPool.selector);
        ext.metricOmmSwapCallback(1, 1, "");
    }

    function testASecondPoolCannotCallBackWhileAnotherIsActive() public {
        SwapPool other = _pool(address(t0), address(t1), none);
        ext.addPool(address(other));
        pool.setPoke(other);
        vm.expectRevert(MetricSwapping.NotPool.selector);
        ext.swapMetric(address(pool), true, 1e18, 0, 0, block.timestamp);
    }

    /// Profit a hook search pays here mid-swap is not counted as the fill.
    function testProfitPaidDuringASwapIsNotCountedAsTheFill() public {
        pool.setBonus(0, 500e18);
        pool.setMaxFill(40e18);
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        ext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        uint256 out1 = t1.balanceOf(address(ext));
        (uint256 spent, uint256 got) =
            ext.swapMetric(address(pool), true, 100e18, 40e18, 0, block.timestamp);
        assertEq(spent, 40e18, "what the callback paid");
        assertEq(got, 40e18, "what the pool reported");
        assertEq(t1.balanceOf(address(ext)), out1 + 540e18, "the profit stayed here");
    }

    function testAMetricPoolsTokensBecomeDonatable() public {
        V4LiquidityExtension fresh = new V4LiquidityExtension(
            locker, address(hook), IMetricFactory(address(metricFactory))
        );
        assertFalse(fresh.donatable(address(t0)), "not before");
        fresh.addPool(address(pool));
        assertTrue(fresh.donatable(address(t0)), "token0");
        assertTrue(fresh.donatable(address(t1)), "token1");
    }

    function testTheConstructorRefusesAZeroFactory() public {
        vm.expectRevert(LiquidityExtension.ZeroAddress.selector);
        new V4LiquidityExtension(locker, address(hook), IMetricFactory(address(0)));
    }
}
