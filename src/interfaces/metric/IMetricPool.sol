// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The leading fields of Metric's `getImmutables()` result. Every field is a static
/// type, so decoding only the first five reads the pool's full struct correctly.
struct MetricImmutables {
    address factory;
    address token0;
    address token1;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
}

/// @dev The part of a Metric pool this repo calls (Metricxyz/pool-contracts).
interface IMetricPool {
    function getImmutables() external view returns (MetricImmutables memory);

    /// Not view: it runs under the pool's swap lock. Whole token1 per whole token0, Q64.64.
    function getSellAndBuyPrices() external returns (uint128 sellPriceX64, uint128 buyPriceX64);

    /// A positive `amountSpecified` is exact input. Returns the pool's raw token deltas:
    /// positive is owed to the pool, negative was sent to `recipient`.
    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (int128 amount0, int128 amount1);
}

interface IMetricSwapCallback {
    function metricOmmSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata callbackData
    ) external;
}

/// @dev All of Metric's `getImmutables()` result, as `MetricVault` reads it: the liquidity
/// limits and the order words that say which extensions run around each action.
struct MetricPoolImmutables {
    address factory;
    address token0;
    address token1;
    uint256 token0ScaleMultiplier;
    uint256 token1ScaleMultiplier;
    uint256 initialScaledToken0PerShareE18;
    uint256 initialScaledToken1PerShareE18;
    uint256 minimalOperationalLiquidity;
    address immutablePriceProvider;
    int256 lowestBin;
    int256 highestBin;
    address extension1;
    address extension2;
    address extension3;
    address extension4;
    address extension5;
    address extension6;
    address extension7;
    uint256 beforeAddLiquidityOrder;
    uint256 afterAddLiquidityOrder;
    uint256 beforeRemoveLiquidityOrder;
    uint256 afterRemoveLiquidityOrder;
    uint256 beforeSwapOrder;
    uint256 afterSwapOrder;
}

struct MetricLiquidityDelta {
    int256[] binIdxs;
    uint256[] shares;
}

/// @dev The liquidity side of a Metric pool (Metricxyz/pool-contracts). `addLiquidity` asks
/// the caller for the tokens in `metricOmmModifyLiquidityCallback`; `removeLiquidity` pays
/// the owner, and only the owner may call it.
interface IMetricLiquidityPool {
    function getImmutables() external view returns (MetricPoolImmutables memory);

    function addLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (uint256 amount0Added, uint256 amount1Added);

    function removeLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (uint256 amount0Removed, uint256 amount1Removed);

    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IMetricModifyLiquidityCallback {
    function metricOmmModifyLiquidityCallback(
        uint256 amount0Delta,
        uint256 amount1Delta,
        bytes calldata callbackData
    ) external;
}
