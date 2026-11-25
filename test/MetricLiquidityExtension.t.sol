// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ExtensionWorld } from "./V4LiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { MockLiquidityPool, Donor } from "./utils/metric/MockLiquidityPool.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { MetricSwapping } from "../src/extensions/MetricSwapping.sol";
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
    // Extra token0 sent and reported on every removal, to push a running total past 2^128.
    uint256 public bigOut;
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
        (uint256 one, uint256 two) = super.removeLiquidity(owner, salt, deltas, extensionData);
        if (bigOut != 0) SafeTransferLib.safeTransfer(token0, msg.sender, bigOut);
        return (one + bigOut, two);
    }

    function setBigOut(uint256 amount) external {
        bigOut = amount;
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
    ) public virtual returns (int128 amount0, int128 amount1) {
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
    SwapPool internal pool;
    TestAsset internal t0;
    TestAsset internal t1;
    uint256[4] internal none;

    function setUp() public virtual override {
        super.setUp();
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

    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
        return false;
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
        vm.expectRevert(MetricSwapping.NotPool.selector);
        mext.metricOmmModifyLiquidityCallback(1, 1, "");
        vm.expectRevert(MetricSwapping.NotPool.selector);
        mext.metricOmmSwapCallback(1, 1, "");
        // Another pool the extension has added is refused too: only the recorded one pays.
        SwapPool other = _pool(address(t0), address(t1), none);
        mext.addPool(address(other));
        vm.prank(address(other));
        vm.expectRevert(MetricSwapping.NotPool.selector);
        mext.metricOmmModifyLiquidityCallback(1, 1, "");
        vm.prank(address(other));
        vm.expectRevert(MetricSwapping.NotPool.selector);
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
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
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
        vm.expectRevert(MetricSwapping.SzrPool.selector);
        mext.addPool(address(szrFirst));
        vm.expectRevert(MetricSwapping.SzrPool.selector);
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
        vm.expectRevert(MetricSwapping.ZeroAmount.selector);
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
        vm.expectRevert(MetricSwapping.NotPool.selector);
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

    function _value(uint80 salt) internal view returns (uint256, uint256) {
        return mext.positionValue(address(pool), salt, _bins());
    }

    function _expected(int256 bin, uint256 shares) internal view returns (uint256, uint256) {
        (uint256 b0, uint256 b1) = pool.balancesOf(bin);
        uint256 total = pool.totalOf(bin);
        if (total == 0) return (0, 0);
        return (b0 * shares / total, b1 * shares / total);
    }

    function testPositionValueMatchesBinBalancesTimesShare() public {
        (uint256 zero0, uint256 zero1) = _value(1);
        assertEq(zero0 + zero1, 0, "an empty bin is worth nothing");
        _add();
        // Bin 0 gains earnings, and a second owner dilutes bin 1.
        pool.earn(0, 3e17, 7e17);
        t0.mint(address(pool), 3e17);
        t1.mint(address(pool), 7e17);
        Donor donor = new Donor();
        t0.mint(address(donor), 10e18);
        t1.mint(address(donor), 10e18);
        donor.donate(pool, address(donor), 1, 1, 1e18);
        assertEq(pool.totalOf(1), 2e18, "bin 1 is shared");
        uint256 want0;
        uint256 want1;
        int256[] memory bins = _bins();
        for (uint256 index; index < bins.length; index++) {
            (uint256 part0, uint256 part1) = _expected(bins[index], 1e18);
            want0 += part0;
            want1 += part1;
        }
        (uint256 value0, uint256 value1) = _value(1);
        assertEq(value0, want0, "token0 value");
        assertEq(value1, want1, "token1 value");
        assertGt(value0 + value1, 1e18, "the earnings are inside");
        // Another salt holds nothing, and a part of the bins counts only those bins.
        (value0, value1) = _value(2);
        assertEq(value0 + value1, 0, "no shares under another salt");
        int256[] memory one = new int256[](1);
        one[0] = 1;
        (value0, value1) = mext.positionValue(address(pool), 1, one);
        (want0, want1) = _expected(1, 1e18);
        assertEq(value0, want0);
        assertEq(value1, want1);
        // Bin 1 holds token0 only, so the share shows in token0.
        (uint256 full0,) = pool.balancesOf(1);
        assertLt(value0, full0, "only the extension's fraction of bin 1");
    }

    function testPositionValueRefusesUnknownPoolsAndBadBins() public {
        SwapPool stranger = _pool(address(t0), address(t1), none);
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        mext.positionValue(address(stranger), 1, _bins());
        int256[] memory far = new int256[](1);
        far[0] = 11;
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.positionValue(address(pool), 1, far);
        far[0] = -11;
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.positionValue(address(pool), 1, far);
        // Rejected by the pool's bounds; the int16 check behind them is not reached here.
        far[0] = int256(1) << 16;
        vm.expectRevert(MetricLiquidityExtension.InvalidBins.selector);
        mext.positionValue(address(pool), 1, far);
    }

    function _book(uint80 salt) internal view returns (uint256[4] memory out) {
        (uint256 in0, uint256 in1, uint256 out0, uint256 out1) =
            mext.ledger(address(pool), salt);
        out = [uint256(in0), in1, out0, out1];
    }

    function testLedgerGrowsByTheReportedAmountsNotTheBonus() public {
        // The bonus is paid to the extension in the middle of each call.
        pool.setBonus(50e18, 50e18);
        (uint256 paid0, uint256 paid1) = _add();
        uint256[4] memory book = _book(1);
        assertEq(book[0], paid0, "in0 is the callback total");
        assertEq(book[1], paid1, "in1 is the callback total");
        assertEq(book[2] + book[3], 0, "nothing out yet");
        (uint256 got0, uint256 got1) = mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(4e17), 0, 0, block.timestamp
        );
        book = _book(1);
        assertEq(book[2], got0, "out0 is the pool's report");
        assertEq(book[3], got1, "out1 is the pool's report");
        assertEq(book[0], paid0, "in is unchanged by a removal");
        (uint256 more0, uint256 more1) = _add();
        book = _book(1);
        assertEq(book[0], paid0 + more0, "in adds up");
        assertEq(book[1], paid1 + more1);
    }

    function testLedgerHoldsTotalsPastTwoToThe128() public {
        _add();
        uint256 big = uint256(1) << 127;
        t0.mint(address(pool), 2 * big);
        pool.setBigOut(big);
        (uint256 first,) = mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e17), 0, 0, block.timestamp
        );
        (uint256 second,) = mext.removeLiquidity(
            address(pool), 1, _bins(), _shares(1e17), 0, 0, block.timestamp
        );
        assertGt(first + second, type(uint128).max, "past the old counter");
        assertEq(_book(1)[2], first + second, "out0 is the sum");
    }

    function testTwoSaltsKeepSeparateLedgers() public {
        (uint256 paid0, uint256 paid1) = _add();
        (uint256 other0, uint256 other1) = mext.addLiquidity(
            address(pool), 2, _bins(), _shares(2e18), MAX, MAX, block.timestamp
        );
        uint256[4] memory book = _book(1);
        assertEq(book[0], paid0);
        assertEq(book[1], paid1);
        book = _book(2);
        assertEq(book[0], other0);
        assertEq(book[1], other1);
        (uint256 got0, uint256 got1) = mext.removeLiquidity(
            address(pool), 2, _bins(), _shares(2e18), 0, 0, block.timestamp
        );
        book = _book(2);
        assertEq(book[2], got0, "salt 2 out0");
        assertEq(book[3], got1, "salt 2 out1");
        book = _book(1);
        assertEq(book[2] + book[3], 0, "salt 1 took nothing out");
    }
}
