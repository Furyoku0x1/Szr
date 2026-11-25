// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import {
    IMetricLiquidityPool,
    IMetricModifyLiquidityCallback,
    MetricLiquidityDelta,
    MetricPoolImmutables
} from "../interfaces/metric/IMetricPool.sol";
import { Liquidity } from "../Liquidity.sol";
import { MetricSwapping } from "./MetricSwapping.sol";

/// @notice Holds bins of Metric pools without SZR, funded by Liquidity, and swaps through
/// them (`MetricSwapping`). The extension is the owner of every position, so the tokens of a
/// removal come back here.
/// @dev A pool is refused if an extension runs around `removeLiquidity`, since the order
/// words are immutable and a reverting extension would hold every withdrawal back. Earnings
/// compound inside the bins, so removing liquidity realises them. Amounts paid and received
/// are what the callbacks paid and the pool reported, checked against this contract's balances.
/// A hook search may pay profit here in the middle of a call, so balance differences alone
/// cannot say what a call cost or returned.
contract MetricLiquidityExtension is MetricSwapping, IMetricModifyLiquidityCallback {
    /// @dev What a position cost and returned, in token units, as the events report it.
    struct Ledger {
        uint256 in0;
        uint256 in1;
        uint256 out0;
        uint256 out1;
    }

    uint256 internal constant BINS_SLOT = 4;
    uint256 internal constant TOTALS_SLOT = 5;
    uint256 internal constant SHARES_SLOT = 6;

    mapping(address pool => mapping(uint80 salt => Ledger)) public ledger;

    error BlockingExtension();
    error InvalidBins();

    event MetricAdded(address indexed pool, uint80 salt, uint256 paid0, uint256 paid1);
    event MetricRemoved(address indexed pool, uint80 salt, uint256 got0, uint256 got1);

    constructor(Liquidity liquidity_, address hook_, IMetricFactory factory_)
        MetricSwapping(liquidity_, hook_, factory_)
    { }

    /// @notice Adds bin shares. `max0` and `max1` bound what the pool takes.
    function addLiquidity(
        address pool,
        uint80 salt,
        int256[] calldata binIdxs,
        uint256[] calldata shares,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 paid0, uint256 paid1) {
        _checked(pool, binIdxs, shares.length, deadline);
        (paid0, paid1) = _add(pool, salt, MetricLiquidityDelta(binIdxs, shares));
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
        Ledger storage book = ledger[pool][salt];
        book.in0 += paid0;
        book.in1 += paid1;
        emit MetricAdded(pool, salt, paid0, paid1);
    }

    /// @notice Removes bin shares. The tokens stay here. `min0` and `min1` bound what comes
    /// back.
    function removeLiquidity(
        address pool,
        uint80 salt,
        int256[] calldata binIdxs,
        uint256[] calldata shares,
        uint256 min0,
        uint256 min1,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 got0, uint256 got1) {
        _checked(pool, binIdxs, shares.length, deadline);
        (got0, got1) = _remove(pool, salt, MetricLiquidityDelta(binIdxs, shares));
        if (got0 < min0) revert BelowMinimum();
        if (got1 < min1) revert BelowMinimum();
        Ledger storage book = ledger[pool][salt];
        book.out0 += got0;
        book.out1 += got1;
        emit MetricRemoved(pool, salt, got0, got1);
    }

    /// @notice What this extension's shares in `bins` of a pool are worth now, in token
    /// units, each bin rounded down and the sum scaled down once. Bins are the caller's list.
    function positionValue(address pool, uint80 salt, int256[] calldata bins)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        MetricInfo storage info = metricPools[pool];
        if (!info.added) revert UnknownPool();
        uint256 scaled0;
        uint256 scaled1;
        for (uint256 index; index < bins.length; index++) {
            int256 bin = bins[index];
            if (bin < info.lowestBin) revert InvalidBins();
            if (bin > info.highestBin) revert InvalidBins();
            if (bin != int256(int16(bin))) revert InvalidBins();
            (uint256 part0, uint256 part1) = _binValue(pool, salt, bin);
            scaled0 += part0;
            scaled1 += part1;
        }
        amount0 = scaled0 / info.token0ScaleMultiplier;
        amount1 = scaled1 / info.token1ScaleMultiplier;
    }

    /// @dev Only the pool this contract is calling may ask for tokens, and only while it does.
    function metricOmmModifyLiquidityCallback(uint256 amount0, uint256 amount1, bytes calldata)
        external
    {
        if (msg.sender != active) revert NotPool();
        MetricInfo storage info = metricPools[msg.sender];
        _send(info.token0, amount0);
        _send(info.token1, amount1);
        sent0 += amount0;
        sent1 += amount1;
    }

    /// @dev A pool is held as positions here, so an extension around `removeLiquidity`, which
    /// could hold every withdrawal back, is refused.
    function _checkPool(MetricPoolImmutables memory imm) internal pure override {
        if (imm.beforeRemoveLiquidityOrder != 0) revert BlockingExtension();
        if (imm.afterRemoveLiquidityOrder != 0) revert BlockingExtension();
    }

    /// @dev This contract has no unlock actions of its own: its swaps unlock through the base.
    function _unlockAction(uint256, bytes memory)
        internal
        pure
        override
        returns (bytes memory)
    {
        revert UnexpectedCallback();
    }

    function _add(address pool, uint80 salt, MetricLiquidityDelta memory delta)
        internal
        returns (uint256 paid0, uint256 paid1)
    {
        sent0 = 0;
        sent1 = 0;
        active = pool;
        IMetricLiquidityPool(pool).addLiquidity(address(this), salt, delta, "", "");
        active = address(0);
        (paid0, paid1) = (sent0, sent1);
    }

    /// @dev The pool's reported amounts are checked against the balance rise, which can only
    /// be larger when something else paid this contract meanwhile.
    function _remove(address pool, uint80 salt, MetricLiquidityDelta memory delta)
        internal
        returns (uint256 got0, uint256 got1)
    {
        MetricInfo storage info = metricPools[pool];
        uint256 before0 = _balance(info.token0);
        uint256 before1 = _balance(info.token1);
        (got0, got1) =
            IMetricLiquidityPool(pool).removeLiquidity(address(this), salt, delta, "");
        if (_balance(info.token0) < before0 + got0) revert TransferAmountMismatch();
        if (_balance(info.token1) < before1 + got1) revert TransferAmountMismatch();
    }

    /// @dev The pool must be one added here, and every bin inside its range.
    function _checked(address pool, int256[] calldata bins, uint256 count, uint256 deadline)
        internal
        view
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        MetricInfo storage info = metricPools[pool];
        if (!info.added) revert UnknownPool();
        if (bins.length == 0) revert InvalidBins();
        if (bins.length != count) revert InvalidBins();
        for (uint256 index; index < bins.length; index++) {
            if (bins[index] < info.lowestBin) revert InvalidBins();
            if (bins[index] > info.highestBin) revert InvalidBins();
        }
    }

    function _binValue(address pool, uint80 salt, int256 bin)
        internal
        view
        returns (uint256 value0, uint256 value1)
    {
        IMetricLiquidityPool source = IMetricLiquidityPool(pool);
        bytes32 key = keccak256(abi.encode(address(this), salt, int16(bin)));
        uint256 held = uint256(source.extsload(keccak256(abi.encode(key, SHARES_SLOT))));
        uint256 total = uint256(source.extsload(keccak256(abi.encode(bin, TOTALS_SLOT))));
        if (total == 0) return (0, 0);
        uint256 raw = uint256(source.extsload(keccak256(abi.encode(bin, BINS_SLOT))));
        value0 = FixedPointMathLib.fullMulDiv(uint104(raw), held, total);
        value1 = FixedPointMathLib.fullMulDiv(uint104(raw >> 104), held, total);
    }
}
