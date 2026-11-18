// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The parts of Metric's `IMetricOmmExtensions` that a swap extension implements
/// (Metricxyz/pool-contracts). Each returns its own selector on success.
interface IMetricOmmExtensions {
    function initialize(address pool, bytes calldata data) external returns (bytes4);

    function beforeSwap(
        address sender,
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint256 packedSlot0Initial,
        uint128 bidPriceX64,
        uint128 askPriceX64,
        uint128 referencePriceX64,
        bytes calldata extensionData
    ) external returns (bytes4);
}

/// @dev Metric's `afterSwap`, kept apart because 14 arguments are too many for the stack of
/// a contract that implements it (this repo does not use viaIR), so the extension answers
/// it from its fallback and a test checks the selector against this declaration.
interface IMetricAfterSwap {
    function afterSwap(
        address sender,
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint256 packedSlot0Initial,
        uint256 packedSlot0Final,
        uint128 bidPriceX64,
        uint128 askPriceX64,
        uint128 referencePriceX64,
        int128 amount0Delta,
        int128 amount1Delta,
        uint256 platformFeeAmount,
        bytes calldata extensionData
    ) external returns (bytes4);
}

/// @dev Metric's `inSwap()`: the price provider while the pool runs a real `swap`, and zero
/// at any other time, including inside `simulateSwapAndRevert`.
interface IMetricSwapState {
    function inSwap() external view returns (address);
}

struct LiquidityDelta {
    int256[] binIdxs;
    uint256[] shares;
}

/// @dev Metric's four liquidity extension points. The extension answers them as no-ops from
/// its fallback, so that listing it in a liquidity order can never block deposits or
/// withdrawals; a test pins the selectors against these declarations.
interface IMetricLiquidityPoints {
    function beforeAddLiquidity(
        address sender,
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (bytes4);

    function afterAddLiquidity(
        address sender,
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        uint256 amount0Added,
        uint256 amount1Added,
        bytes calldata extensionData
    ) external returns (bytes4);

    function beforeRemoveLiquidity(
        address sender,
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (bytes4);

    function afterRemoveLiquidity(
        address sender,
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        uint256 amount0Removed,
        uint256 amount1Removed,
        bytes calldata extensionData
    ) external returns (bytes4);
}
