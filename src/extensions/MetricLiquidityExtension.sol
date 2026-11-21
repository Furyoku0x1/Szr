// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import {
    IMetricLiquidityPool,
    IMetricModifyLiquidityCallback,
    IMetricPool,
    IMetricSwapCallback,
    MetricLiquidityDelta,
    MetricPoolImmutables
} from "../interfaces/metric/IMetricPool.sol";
import { Liquidity } from "../Liquidity.sol";
import { LiquidityExtension } from "./LiquidityExtension.sol";

/// @notice Holds bins of Metric pools without SZR, funded by Liquidity, and swaps through
/// them. The extension is the owner of every position, so the tokens of a removal come back
/// here. Metric pools hold ERC20s only: native ETH reaches them as WETH (`wrap` first).
/// @dev A pool is refused if an extension runs around `removeLiquidity`, since the order
/// words are immutable and a reverting extension would hold every withdrawal back. Earnings
/// compound inside the bins, so removing liquidity realises them. Amounts paid and received
/// are what the callbacks paid and the pool reported, checked against this contract's balances.
/// A hook search may pay profit here in the middle of a call, so balance differences alone
/// cannot say what a call cost or returned.
contract MetricLiquidityExtension is
    LiquidityExtension,
    IMetricModifyLiquidityCallback,
    IMetricSwapCallback
{
    struct MetricInfo {
        bool added;
        address token0;
        address token1;
        int256 lowestBin;
        int256 highestBin;
    }

    IMetricFactory public immutable factory;
    mapping(address pool => MetricInfo) public metricPools;
    // The one pool whose callback may be answered, and only while this contract calls it.
    address internal transient active;
    // What the active pool's callbacks have been paid, per token of the pool.
    uint256 internal transient sent0;
    uint256 internal transient sent1;

    error InvalidPool();
    error SzrPool();
    error BlockingExtension();
    error InvalidBins();
    error NotPool();
    error ZeroAmount();

    event MetricPoolAdded(address indexed pool);
    event MetricAdded(address indexed pool, uint80 salt, uint256 paid0, uint256 paid1);
    event MetricRemoved(address indexed pool, uint80 salt, uint256 got0, uint256 got1);
    event MetricSwapped(address indexed pool, bool zeroForOne, uint256 spent, uint256 got);

    constructor(Liquidity liquidity_, address hook_, IMetricFactory factory_)
        LiquidityExtension(liquidity_, hook_)
    {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function addPool(address pool) external nonReentrant onlyManager {
        if (!factory.isPool(pool)) revert InvalidPool();
        MetricPoolImmutables memory imm = IMetricLiquidityPool(pool).getImmutables();
        if (imm.beforeRemoveLiquidityOrder != 0) revert BlockingExtension();
        if (imm.afterRemoveLiquidityOrder != 0) revert BlockingExtension();
        if (imm.token0 == szr) revert SzrPool();
        if (imm.token1 == szr) revert SzrPool();
        metricPools[pool] =
            MetricInfo(true, imm.token0, imm.token1, imm.lowestBin, imm.highestBin);
        emit MetricPoolAdded(pool);
    }

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
        emit MetricRemoved(pool, salt, got0, got1);
    }

    /// @notice One exact-input swap on a Metric pool. A partial fill is allowed: only
    /// `minimumOut` is checked. The input is paid in the pool's callback.
    function swapMetric(
        address pool,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minimumOut,
        uint128 priceLimitX64,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 spent, uint256 received) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (!metricPools[pool].added) revert UnknownPool();
        if (amountIn == 0) revert ZeroAmount();
        if (amountIn > uint256(uint128(type(int128).max))) revert AboveMaximum();
        (spent, received) = _trade(pool, zeroForOne, amountIn, priceLimitX64);
        if (spent > amountIn) revert AboveMaximum();
        if (received < minimumOut) revert BelowMinimum();
        emit MetricSwapped(pool, zeroForOne, spent, received);
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

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        if (msg.sender != active) revert NotPool();
        MetricInfo storage info = metricPools[msg.sender];
        if (amount0 > 0) {
            _send(info.token0, uint256(amount0));
            sent0 += uint256(amount0);
        }
        if (amount1 > 0) {
            _send(info.token1, uint256(amount1));
            sent1 += uint256(amount1);
        }
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

    /// @dev The input is what the callback paid and the output what the pool reports, since
    /// a hook search may pay profit here during the swap, in either token.
    function _trade(address pool, bool zeroForOne, uint256 amountIn, uint128 limit)
        internal
        returns (uint256 spent, uint256 received)
    {
        MetricInfo storage info = metricPools[pool];
        address tokenOut = zeroForOne ? info.token1 : info.token0;
        uint256 beforeOut = _balance(tokenOut);
        sent0 = 0;
        sent1 = 0;
        active = pool;
        (int128 amount0, int128 amount1) = IMetricPool(pool)
            .swap(address(this), zeroForOne, int128(uint128(amountIn)), limit, "", "");
        active = address(0);
        // The output token is never paid: a callback asking for it is a pool taking more.
        if (zeroForOne ? sent1 != 0 : sent0 != 0) revert TransferAmountMismatch();
        spent = zeroForOne ? sent0 : sent1;
        int128 output = zeroForOne ? amount1 : amount0;
        if (output < 0) received = uint256(-int256(output));
        if (_balance(tokenOut) < beforeOut + received) revert TransferAmountMismatch();
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

    function _send(address asset, uint256 amount) internal {
        if (amount == 0) return;
        SafeTransferLib.safeTransfer(asset, msg.sender, amount);
    }
}
