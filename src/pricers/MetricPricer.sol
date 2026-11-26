// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IVenuePricer } from "../interfaces/IVenuePricer.sol";
import { MetricVenueHook } from "../hooks/MetricVenueHook.sol";
import { IMetricPool } from "../interfaces/metric/IMetricPool.sol";
import { MetricBook, IMetricStorage } from "./lib/MetricBook.sol";

/// @notice Prices a v4 pool on `MetricVenueHook` from the Metric pool it is bound to.
/// @dev Metric's price can only be read by CALL (`getSellAndBuyPrices` takes the pool's
/// swap lock), so this is not `view`; the arbitrage hook asks it in a frame that reverts.
/// A paused pool, a stalled feed or an unbound pool makes the read revert, which the hook
/// reads as "no price".
///
/// The two prices `getSellAndBuyPrices` returns already include the current bin's own extra
/// fee and the notional fee (`FeeMath.binTotalFeeX64` in Metricxyz/pool-contracts), so the
/// fee reported here is just the worse side's distance from the midpoint.
///
/// The range is the current bin. Inside it Metric's price is linear in its position, and the
/// token1 held below the position and the token0 held above it are spread evenly over that
/// position. That is a constant-liquidity range to within the bin's width, so the pricer
/// reports the v4 liquidity that would trade the bin's reserves to each edge, the smaller
/// of the two sides. Leaving the bin ends a leg; the next search round goes on from there.
/// The edges are the bin's two ends scaled from the midpoint, not from Metric's own
/// reference price, which is not readable here, so the price always sits inside its range.
///
/// Rounding: the fee is rounded up, liquidity down, the edges inwards, and the price's own
/// rounding (about one part in 2^64) is far inside the fee's one-pip step.
///
/// Gas: a cold `price` call measured 136,239 on Robinhood Chain (the pool's own read is about
/// 104,000 of it). Set the market's pricer gas to at least 164,000, that plus 20%; the hook
/// rounds it up to a unit. No owner, no state, no upgrade.
contract MetricPricer is IVenuePricer {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant PIPS = MetricBook.PIPS;

    MetricVenueHook public immutable wrapper;

    error Unbound();

    constructor(MetricVenueHook hook) {
        wrapper = hook;
    }

    function price(PoolKey calldata key)
        external
        returns (uint160 root, uint24 fee, uint128 liquidity, uint160 lower, uint160 upper)
    {
        MetricBook.Book memory book;
        IMetricPool metric;
        {
            bool disabled;
            uint128 s0;
            uint128 s1;
            address pool;
            (pool, book.flipped, disabled, s0, s1) = wrapper.bindings(key.toId());
            if (pool == address(0)) revert Unbound();
            if (disabled) revert Unbound();
            metric = IMetricPool(pool);
            book.scale0 = s0;
            book.scale1 = s1;
        }
        (uint128 sell, uint128 buy) = metric.getSellAndBuyPrices();
        book.mid = (uint256(sell) + uint256(buy)) / 2;
        if (book.mid == 0) revert MetricBook.NoPrice();
        fee = MetricBook._fee(sell, buy, book.mid);
        MetricBook._readBin(IMetricStorage(address(metric)), book);
        if (fee + book.widthFee >= PIPS) revert MetricBook.NoPrice();
        fee = uint24(fee + book.widthFee);
        root = MetricBook._root(book.mid, book);
        lower = MetricBook._root(book.flipped ? book.upperX64 : book.lowerX64, book);
        upper = MetricBook._root(book.flipped ? book.lowerX64 : book.upperX64, book);
        // Rounding must never put the price outside its own range.
        if (lower > root) lower = root;
        if (upper < root) upper = root;
        liquidity = MetricBook._liquidity(book, root, lower, upper);
    }
}
