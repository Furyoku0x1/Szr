// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @notice Prices a pool whose trades are filled somewhere other than the pool manager,
/// such as one of Uniswap's aggregator hooks wrapping a pool of another exchange. The
/// arbitrage hook asks one of these, in place of the pool manager, about any pool on a hook
/// that Liquidity's manager has paired with it.
/// @dev The hook asks with an ordinary CALL, with the market's pricer gas, once per search,
/// inside a frame that always reverts. A pricer may therefore write storage or open a
/// pool-manager balance to read its price, and all of it is undone. Anything but exactly
/// these five words back, or a value out of range, is taken as "no price", and the pool is
/// then simply passed over. A pricer can never make a swap fail or move any funds; a wrong
/// answer only makes a cycle fail its profit check or go unnoticed.
interface IVenuePricer {
    /// @param pool The pool as the pool manager knows it. Its currencies, fee, tick spacing
    /// and hook are enough to find what it wraps.
    /// @return sqrtPriceX96 The square root of the price of `currency1` per `currency0`, as
    /// a Q96 number, in the form a Uniswap v4 pool reports its own.
    /// @return fee Everything a swap through the pool pays, in hundredths of a basis point:
    /// the wrapped exchange's fee together with any fee the wrapping hook adds.
    /// @return liquidity The liquidity in range at that price, in Uniswap v4's terms: what
    /// a v4 pool that responded to trades in the same way would report.
    /// @return lowerSqrtPriceX96 The lowest square-root price, in the same orientation as
    /// `sqrtPriceX96`, down to which the pool answers trades as a v4 range with `liquidity`
    /// would.
    /// @return upperSqrtPriceX96 The highest such price. A v2-style (constant-product) venue
    /// is one range over every price, so it returns `TickMath.MIN_SQRT_PRICE` and
    /// `TickMath.MAX_SQRT_PRICE`. A v3-style venue holds only to its next tick, and a
    /// stable-swap or weighted one only near the current price. A pricer that cannot say
    /// returns `lower == upper == sqrtPriceX96`, and the pool is then sized by an estimate.
    /// Both must lie within `TickMath`'s bounds, `lower` at or below the price and `upper`
    /// at or above it, or the whole answer is taken as "no price".
    function price(PoolKey calldata pool)
        external
        returns (
            uint160 sqrtPriceX96,
            uint24 fee,
            uint128 liquidity,
            uint160 lowerSqrtPriceX96,
            uint160 upperSqrtPriceX96
        );
}
