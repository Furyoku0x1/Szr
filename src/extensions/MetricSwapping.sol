// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import {
    IMetricLiquidityPool,
    IMetricPool,
    IMetricSwapCallback,
    MetricPoolImmutables
} from "../interfaces/metric/IMetricPool.sol";
import { Liquidity } from "../Liquidity.sol";
import { LiquidityExtension } from "./LiquidityExtension.sol";

/// @notice Swaps on Metric pools, shared by both extensions so that each can trade there.
/// Metric pools hold ERC20s only: native ETH reaches them as WETH (`wrap` first).
/// @dev Amounts paid are what the swap callback paid, and amounts received what the pool
/// reported, checked against this contract's balance. A hook search may pay profit here in
/// the middle of a call, so balance differences alone cannot say what a swap cost.
abstract contract MetricSwapping is LiquidityExtension, IMetricSwapCallback {
    struct MetricInfo {
        bool added;
        address token0;
        address token1;
        int256 lowestBin;
        int256 highestBin;
        uint256 token0ScaleMultiplier;
        uint256 token1ScaleMultiplier;
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
    error NotPool();
    error ZeroAmount();

    event MetricPoolAdded(address indexed pool);
    event MetricSwapped(address indexed pool, bool zeroForOne, uint256 spent, uint256 got);

    constructor(Liquidity liquidity_, address hook_, IMetricFactory factory_)
        LiquidityExtension(liquidity_, hook_)
    {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    /// @notice Adds a Metric pool of the factory, without SZR, to swap on.
    function addPool(address pool) external nonReentrant onlyManager {
        if (!factory.isPool(pool)) revert InvalidPool();
        MetricPoolImmutables memory imm = IMetricLiquidityPool(pool).getImmutables();
        _checkPool(imm);
        if (imm.token0 == szr) revert SzrPool();
        if (imm.token1 == szr) revert SzrPool();
        metricPools[pool] = MetricInfo(
            true,
            imm.token0,
            imm.token1,
            imm.lowestBin,
            imm.highestBin,
            imm.token0ScaleMultiplier,
            imm.token1ScaleMultiplier
        );
        _allowDonations(imm.token0, imm.token1);
        emit MetricPoolAdded(pool);
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

    /// @dev A further check before a pool is added. Holding positions needs more than
    /// swapping does.
    function _checkPool(MetricPoolImmutables memory imm) internal view virtual { }

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

    function _send(address asset, uint256 amount) internal {
        if (amount == 0) return;
        SafeTransferLib.safeTransfer(asset, msg.sender, amount);
    }
}
