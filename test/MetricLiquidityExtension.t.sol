// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ExtensionWorld } from "./V4LiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { MockLiquidityPool } from "./utils/metric/MockLiquidityPool.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import {
    IMetricSwapCallback,
    MetricLiquidityDelta
} from "../src/interfaces/metric/IMetricPool.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The liquidity mock plus an exact-input swap at price one, with a cap on the input it
/// takes so that a fill can be partial. It pays the output first and asks for the input in
/// the callback, as Metric does.
contract SwapPool is MockLiquidityPool {
    uint256 public maxFill = type(uint256).max;
    // Paid to the caller in the middle of a swap or an add, as a hook search paying profit
    // to the extension would, and extra asked for in the callback.
    uint256 public bonus0;
    uint256 public bonus1;
    uint256 public overAsk;
    // Asks for one unit of the output token in the callback, and reports more output than sent.
    bool public askOutput;
    bool public overReport;
    // Another pool to call the extension back during a swap.
    SwapPool public poke;

    constructor(address t0, address t1, uint256 minimum_, uint256[4] memory orders_)
        MockLiquidityPool(t0, t1, 1, 1, minimum_, orders_)
    { }

    function setMaxFill(uint256 cap) external {
        maxFill = cap;
    }

    function setBonus(uint256 one, uint256 two) external {
        bonus0 = one;
        bonus1 = two;
    }

    /// The callback is told the fill plus `overAsk` on the input side.
    function _ask(bool zeroForOne, int128 amount0, int128 amount1) internal {
        int128 extra = int128(int256(overAsk));
        if (zeroForOne) amount0 += extra;
        else amount1 += extra;
        if (askOutput) {
            if (zeroForOne) amount1 = 1;
            else amount0 = 1;
        }
        IMetricSwapCallback(msg.sender).metricOmmSwapCallback(amount0, amount1, "");
    }

    function setPoke(SwapPool other) external {
        poke = other;
    }

    function callBack(address target) external {
        IMetricSwapCallback(target).metricOmmSwapCallback(1, 1, "");
    }

    function setAskOutput(bool on) external {
        askOutput = on;
    }

    function setOverReport(bool on) external {
        overReport = on;
    }

    function removeLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) public override returns (uint256, uint256) {
        _payBonus(msg.sender);
        return super.removeLiquidity(owner, salt, deltas, extensionData);
    }

    function setOverAsk(uint256 extra) external {
        overAsk = extra;
    }

    function addLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) public override returns (uint256, uint256) {
        _payBonus(msg.sender);
        return super.addLiquidity(owner, salt, deltas, callbackData, extensionData);
    }

    function _payBonus(address to) internal {
        if (bonus0 != 0) SafeTransferLib.safeTransfer(token0, to, bonus0);
        if (bonus1 != 0) SafeTransferLib.safeTransfer(token1, to, bonus1);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128,
        bytes calldata,
        bytes calldata
    ) external returns (int128 amount0, int128 amount1) {
        uint256 amount = FixedPointMathLib.min(uint256(uint128(amountSpecified)), maxFill);
        SafeTransferLib.safeTransfer(zeroForOne ? token1 : token0, recipient, amount);
        _payBonus(recipient);
        if (address(poke) != address(0)) poke.callBack(recipient);
        uint256 before = SafeTransferLib.balanceOf(zeroForOne ? token0 : token1, address(this));
        int128 size = int128(int256(amount));
        (amount0, amount1) = zeroForOne ? (size, -size) : (-size, size);
        if (overReport) {
            if (zeroForOne) amount1 -= 1;
            else amount0 -= 1;
        }
        _ask(zeroForOne, amount0, amount1);
        uint256 after_ = SafeTransferLib.balanceOf(zeroForOne ? token0 : token1, address(this));
        require(after_ >= before + amount, "unpaid");
    }
}

/// @dev Bins and swaps of the Metric extension against a local pool that keeps Metric's
/// liquidity rules, and the extension's own arbitrage-hook market.
abstract contract MetricExtensionWorld is ExtensionWorld {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant MIN = 1e9;

    MetricLiquidityExtension internal mext;
    MockMetricFactory internal metricFactory;
    SwapPool internal pool;
    TestAsset internal t0;
    TestAsset internal t1;
    uint256[4] internal none;

    function setUp() public override {
        super.setUp();
        metricFactory = new MockMetricFactory();
        // Deployed from artifacts: embedding the creation code would push the test
        // contract over the size limit.
        mext = MetricLiquidityExtension(
            payable(deployCode(
                    "MetricLiquidityExtension.sol:MetricLiquidityExtension",
                    abi.encode(locker, address(hook), address(metricFactory))
                ))
        );
        (t0, t1) = address(coin) < address(usd) ? (coin, usd) : (usd, coin);
        pool = _pool(address(t0), address(t1), none);
        mext.addPool(address(pool));
        t0.mint(address(mext), HELD);
        t1.mint(address(mext), HELD);
        t0.mint(address(pool), HELD);
        t1.mint(address(pool), HELD);
    }

    function _pool(address one, address two, uint256[4] memory orders)
        internal
        returns (SwapPool made)
    {
        made = SwapPool(
            deployCode(
                "MetricLiquidityExtension.t.sol:SwapPool", abi.encode(one, two, MIN, orders)
            )
        );
        metricFactory.register(address(made));
    }

    function _bins() internal pure returns (int256[] memory list) {
        list = new int256[](3);
        list[0] = -1;
        list[1] = 0;
        list[2] = 1;
    }

    function _shares(uint256 each) internal pure returns (uint256[] memory list) {
        list = new uint256[](3);
        list[0] = each;
        list[1] = each;
        list[2] = each;
    }

    function _add() internal returns (uint256, uint256) {
        return mext.addLiquidity(
            address(pool), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp
        );
    }
}

/// @dev Bins and swaps against the local pool.
contract MetricLiquidityExtensionTest is MetricExtensionWorld {
    function testAddAndRemoveBins() public {
        uint256 before0 = t0.balanceOf(address(mext));
        uint256 before1 = t1.balanceOf(address(mext));
        (uint256 paid0, uint256 paid1) = _add();
        assertGt(paid0, 0, "token0 paid");
        assertGt(paid1, 0, "token1 paid");
        assertEq(t0.balanceOf(address(mext)), before0 - paid0, "measured token0");
        assertEq(t1.balanceOf(address(mext)), before1 - paid1, "measured token1");
        assertEq(pool.sharesOf(address(mext), 1, 0), 1e18, "the extension owns the bins");
        (uint256 got0, uint256 got1) = mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e18), 0, 0, block.timestamp
        );
        assertEq(got0, paid0, "token0 back");
        assertEq(got1, paid1, "token1 back");
        assertEq(t0.balanceOf(address(mext)), before0, "all token0 returned here");
        assertEq(t1.balanceOf(address(mext)), before1, "all token1 returned here");
        assertEq(pool.sharesOf(address(mext), 1, 0), 0);
    }

    function testBoundsDeadlineAndBinsAreEnforced() public {
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        mext.addLiquidity(address(pool), 1, _bins(), _shares(1e18), 1, 1, block.timestamp);
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        mext.addLiquidity(
            address(pool), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp - 1
        );
        _add();
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp
        );
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e18), 0, 0, block.timestamp - 1
        );
        int256[] memory far = new int256[](1);
        far[0] = 11;
        uint256[] memory one = new uint256[](1);
        one[0] = 1e18;
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.addLiquidity(address(pool), 1, far, one, MAX, MAX, block.timestamp);
        far[0] = -11;
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.removeLiquidity(address(pool), 1, far, one, 0, 0, block.timestamp);
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.addLiquidity(address(pool), 1, _bins(), one, MAX, MAX, block.timestamp);
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.addLiquidity(
            address(pool), 1, new int256[](0), new uint256[](0), MAX, MAX, block.timestamp
        );
        SwapPool stranger = _pool(address(t0), address(t1), none);
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        mext.addLiquidity(
            address(stranger), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp
        );
    }

    function testCallbacksRefuseAnyoneButTheCalledPool() public {
        // Not during a call at all.
        vm.expectRevert(MetricLiquidityExtension.NotPool.selector);
        mext.metricOmmModifyLiquidityCallback(1, 1, "");
        vm.expectRevert(MetricLiquidityExtension.NotPool.selector);
        mext.metricOmmSwapCallback(1, 1, "");
        // Another pool the extension has added is refused too: only the recorded one pays.
        SwapPool other = _pool(address(t0), address(t1), none);
        mext.addPool(address(other));
        vm.prank(address(other));
        vm.expectRevert(MetricLiquidityExtension.NotPool.selector);
        mext.metricOmmModifyLiquidityCallback(1, 1, "");
        vm.prank(address(other));
        vm.expectRevert(MetricLiquidityExtension.NotPool.selector);
        mext.metricOmmSwapCallback(1, 1, "");
    }

    function testRefusedPools() public {
        // Not made by the factory.
        SwapPool foreign = SwapPool(
            deployCode(
                "MetricLiquidityExtension.t.sol:SwapPool",
                abi.encode(address(t0), address(t1), MIN, none)
            )
        );
        vm.expectRevert(MetricLiquidityExtension.InvalidPool.selector);
        mext.addPool(address(foreign));
        // An extension around removal could hold every withdrawal back.
        uint256[4] memory before = [uint256(0), 0, 1, 0];
        SwapPool blocking = _pool(address(t0), address(t1), before);
        vm.expectRevert(MetricLiquidityExtension.BlockingExtension.selector);
        mext.addPool(address(blocking));
        uint256[4] memory afterwards = [uint256(0), 0, 0, 1];
        blocking = _pool(address(t0), address(t1), afterwards);
        vm.expectRevert(MetricLiquidityExtension.BlockingExtension.selector);
        mext.addPool(address(blocking));
        // An extension around adding does not block withdrawal.
        uint256[4] memory adding = [uint256(1), 1, 0, 0];
        mext.addPool(address(_pool(address(t0), address(t1), adding)));
        // SZR pairs belong to Liquidity, on either side.
        SwapPool szrFirst = _pool(address(szr), address(t1), none);
        SwapPool szrSecond = _pool(address(t0), address(szr), none);
        vm.expectRevert(MetricLiquidityExtension.SzrPool.selector);
        mext.addPool(address(szrFirst));
        vm.expectRevert(MetricLiquidityExtension.SzrPool.selector);
        mext.addPool(address(szrSecond));
    }

    function testSwapMetricAndPartialFill() public {
        uint256 in0 = t0.balanceOf(address(mext));
        uint256 out1 = t1.balanceOf(address(mext));
        (uint256 spent, uint256 got) =
            mext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        assertEq(spent, 100e18);
        assertEq(got, 100e18);
        assertEq(t0.balanceOf(address(mext)), in0 - 100e18, "input paid in the callback");
        assertEq(t1.balanceOf(address(mext)), out1 + 100e18, "output received");
        // Swapping back.
        (spent, got) = mext.swapMetric(address(pool), false, 50e18, 1, 0, block.timestamp);
        assertEq(got, 50e18);
        // A partial fill is allowed when it clears the minimum, and reverts below it.
        pool.setMaxFill(40e18);
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        mext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        (spent, got) = mext.swapMetric(address(pool), true, 100e18, 40e18, 0, block.timestamp);
        assertEq(spent, 40e18, "only the filled part is paid");
        assertEq(got, 40e18);
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        mext.swapMetric(address(pool), true, 1, 0, 0, block.timestamp - 1);
        vm.expectRevert(MetricLiquidityExtension.ZeroAmount.selector);
        mext.swapMetric(address(pool), true, 0, 0, 0, block.timestamp);
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        mext.swapMetric(address(pool), true, MAX, 0, 0, block.timestamp);
        SwapPool stranger = _pool(address(t0), address(t1), none);
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        mext.swapMetric(address(stranger), true, 1, 0, 0, block.timestamp);
    }

    function testProfitPaidDuringASwapIsNotCountedAsTheFill() public {
        // Profit in the output token must not lift a short fill past the minimum.
        pool.setBonus(0, 500e18);
        pool.setMaxFill(40e18);
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        mext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        uint256 out1 = t1.balanceOf(address(mext));
        (uint256 spent, uint256 got) =
            mext.swapMetric(address(pool), true, 100e18, 40e18, 0, block.timestamp);
        assertEq(spent, 40e18, "what the callback paid");
        assertEq(got, 40e18, "what the pool reported");
        assertEq(t1.balanceOf(address(mext)), out1 + 540e18, "the profit stayed here");
        // Profit in the input token, larger than the input: no underflow.
        pool.setBonus(500e18, 0);
        pool.setMaxFill(MAX);
        (spent, got) = mext.swapMetric(address(pool), true, 100e18, 100e18, 0, block.timestamp);
        assertEq(spent, 100e18, "input is what was paid");
        assertEq(got, 100e18);
    }

    function testProfitPaidDuringAnAddIsNotCountedAsTheCost() public {
        (uint256 paid0, uint256 paid1) = _add();
        mext.removeLiquidity(address(pool), 1, _bins(), _shares(1e18), 0, 0, block.timestamp);
        pool.setBonus(50e18, 50e18);
        uint256 before0 = t0.balanceOf(address(mext));
        // The bound is the real cost, below what the profit added.
        (uint256 again0, uint256 again1) = mext.addLiquidity(
            address(pool), 1, _bins(), _shares(1e18), paid0, paid1, block.timestamp
        );
        assertEq(again0, paid0, "token0 cost");
        assertEq(again1, paid1, "token1 cost");
        assertEq(t0.balanceOf(address(mext)), before0 + 50e18 - paid0, "profit stayed here");
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        mext.addLiquidity(
            address(pool), 2, _bins(), _shares(1e18), paid0 - 1, paid1, block.timestamp
        );
    }

    function testAPoolAskingForMoreThanTheInputIsRefused() public {
        pool.setOverAsk(1);
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        mext.swapMetric(address(pool), true, 100e18, 0, 0, block.timestamp);
    }

    function testASecondPoolCannotCallBackWhileAnotherIsActive() public {
        SwapPool other = _pool(address(t0), address(t1), none);
        mext.addPool(address(other));
        pool.setPoke(other);
        vm.expectRevert(MetricLiquidityExtension.NotPool.selector);
        mext.swapMetric(address(pool), true, 1e18, 0, 0, block.timestamp);
    }

    function testAPoolAskingForTheOutputTokenIsRefused() public {
        pool.setAskOutput(true);
        // Profit paid in both tokens meanwhile would hide the pull from the balances.
        pool.setBonus(5, 5);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        mext.swapMetric(address(pool), true, 100e18, 0, 0, block.timestamp);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        mext.swapMetric(address(pool), false, 100e18, 0, 0, block.timestamp);
    }

    function testRemovalReportsTheStatedAmountsNotTheBonus() public {
        (uint256 paid0, uint256 paid1) = _add();
        pool.setBonus(50e18, 50e18);
        // A measured rise would include the bonus and clear this minimum.
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e18), paid0 + 1, paid1, block.timestamp
        );
        uint256 before0 = t0.balanceOf(address(mext));
        (uint256 got0, uint256 got1) = mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e18), paid0, paid1, block.timestamp
        );
        assertEq(got0, paid0, "token0 stated");
        assertEq(got1, paid1, "token1 stated");
        assertEq(t0.balanceOf(address(mext)), before0 + paid0 + 50e18, "bonus stayed here");
    }

    function testAPoolReportingMoreThanItSentIsRefused() public {
        _add();
        pool.setMode(1);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        mext.removeLiquidity(address(pool), 1, _bins(), _shares(1e18), 0, 0, block.timestamp);
        pool.setOverReport(true);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        mext.swapMetric(address(pool), true, 100e18, 0, 0, block.timestamp);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        mext.swapMetric(address(pool), false, 100e18, 0, 0, block.timestamp);
    }

    function testOnlyTheCurrentManager() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(mext.addPool, (address(pool)));
        calls[1] = abi.encodeCall(
            mext.addLiquidity, (address(pool), 1, _bins(), _shares(1e18), MAX, MAX, 1)
        );
        calls[2] = abi.encodeCall(
            mext.removeLiquidity, (address(pool), 1, _bins(), _shares(1e18), 0, 0, 1)
        );
        calls[3] = abi.encodeCall(mext.swapMetric, (address(pool), true, 1, 0, 0, 1));
        for (uint256 index; index < calls.length; index++) {
            vm.prank(alice);
            (bool ok, bytes memory data) = address(mext).call(calls[index]);
            assertFalse(ok, "refused");
            assertEq(bytes4(data), LiquidityExtension.NotManager.selector);
        }
    }
}
