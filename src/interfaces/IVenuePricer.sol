// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @notice Prices a pool whose trades are filled somewhere other than the pool manager,
/// such as one of Uniswap's aggregator hooks wrapping a pool of another exchange. The
/// arbitrage hook asks one of these, in place of the pool manager, about any pool on a hook
/// that Liquidity's manager has paired with it.
/// @dev The call is read-only and is given very little gas. Anything but exactly these
/// three words back, or a value out of range, is taken as "no price", and the pool is then
/// simply passed over. A pricer can never make a swap fail or move any funds; a wrong
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
    function price(PoolKey calldata pool)
        external
        view
        returns (uint160 sqrtPriceX96, uint24 fee, uint128 liquidity);
}
