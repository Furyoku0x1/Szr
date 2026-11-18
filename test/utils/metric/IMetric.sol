// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Test-only subset of Metric's public interfaces (Metricxyz/pool-contracts and
/// oracle-contracts, main branch), written out by hand for the probes in
/// test/fork/MetricProbe.t.sol. Not for production use.

struct LiquidityDelta {
    int256[] binIdxs;
    uint256[] shares;
}

struct PoolImmutables {
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

interface IMetricPool {
    error PriceProviderFailed(bytes reason);
    error SimulateSwap(int256 amount0Delta, int256 amount1Delta);
    error PoolPaused();
    error NotAllowedToSwap();
    error NotAllowedToDeposit();

    function getSellAndBuyPrices() external returns (uint128 sellPriceX64, uint128 buyPriceX64);
    function getImmutables() external view returns (PoolImmutables memory);
    function inSwap() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (int128, int128);
    function simulateSwapAndRevert(
        address sender,
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 priceLimitX64,
        uint128 bidPriceX64,
        uint128 askPriceX64,
        uint128 referencePriceX64,
        bytes calldata extensionData
    ) external returns (int128, int128);
    function addLiquidity(
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata callbackData,
        bytes calldata extensionData
    ) external returns (uint256 amount0Added, uint256 amount1Added);
    function removeLiquidity(
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (uint256 amount0Removed, uint256 amount1Removed);
    function extsload(bytes32 slot) external view returns (bytes32);
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory);
}

interface IMetricProvider {
    function getQuote() external returns (uint128 bid, uint128 ask, uint128 refPrice);
}

interface IMetricSwapCallback {
    function metricOmmSwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata callbackData
    ) external;
}

interface IMetricModifyLiquidityCallback {
    function metricOmmModifyLiquidityCallback(
        uint256 amount0Delta,
        uint256 amount1Delta,
        bytes calldata callbackData
    ) external;
}

interface IMetricPoolAdmin {
    function setPause(uint8 newLevel) external;
}

/// The hooks every Metric extension exposes; the ones the pool does not wire to an action
/// are not called by it.
interface IMetricExtension {
    function beforeRemoveLiquidity(
        address sender,
        address owner,
        uint80 salt,
        LiquidityDelta calldata deltas,
        bytes calldata extensionData
    ) external returns (bytes4);
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

interface IMetricStopLoss {
    function oracleStopLossConfig(address pool)
        external
        view
        returns (uint32 drawdownE6, uint64 decayPerSecondE18, uint40 timelock, bool initialized);
    function currentHighWatermarks(address pool, int16 binIdx)
        external
        view
        returns (uint256 hwm0, uint256 hwm1);
}

interface IMetricVelocity {
    function priceVelocityState(address pool)
        external
        view
        returns (
            uint128 anchorMidPriceX64,
            uint128 lastObservedMidPriceX64,
            uint64 anchorBlock,
            uint64 lastObservedBlock,
            uint64 maxChangePerBlockE18
        );
}

/// Not Metric's public source: read only from the bytecode of the extension on the pool.
interface IMetricSession {
    function isTradingPaused(address pool) external view returns (bool);
}
