// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MetricBook, IMetricStorage } from "../../../src/pricers/lib/MetricBook.sol";

/// @dev `MetricBook` from outside, one step at a time, and the whole reading of a pool's
/// current bin as `MetricPricer.price` puts the steps together.
contract MetricBookHarness {
    function fee(uint128 sell, uint128 buy, uint256 mid) external pure returns (uint24) {
        return MetricBook._fee(sell, buy, mid);
    }

    function readBin(address metric, MetricBook.Book memory book)
        external
        view
        returns (MetricBook.Book memory)
    {
        MetricBook._readBin(IMetricStorage(metric), book);
        return book;
    }

    function root(uint256 priceX64, MetricBook.Book memory book)
        external
        pure
        returns (uint160)
    {
        return MetricBook._root(priceX64, book);
    }

    function liquidity(MetricBook.Book memory book, uint160 at, uint160 lower, uint160 upper)
        external
        pure
        returns (uint128)
    {
        return MetricBook._liquidity(book, at, lower, upper);
    }

    /// A pool's price, fee, liquidity and range from its two prices and its storage, for a
    /// binding of the given orientation and scales.
    function quote(
        address metric,
        uint128 sell,
        uint128 buy,
        bool flipped,
        uint256 scale0,
        uint256 scale1
    )
        external
        view
        returns (uint160 at, uint24 total, uint128 units, uint160 lower, uint160 upper)
    {
        MetricBook.Book memory book;
        book.flipped = flipped;
        book.scale0 = scale0;
        book.scale1 = scale1;
        book.mid = (uint256(sell) + uint256(buy)) / 2;
        if (book.mid == 0) revert MetricBook.NoPrice();
        total = MetricBook._fee(sell, buy, book.mid);
        MetricBook._readBin(IMetricStorage(metric), book);
        if (total + book.widthFee >= MetricBook.PIPS) revert MetricBook.NoPrice();
        total = uint24(total + book.widthFee);
        at = MetricBook._root(book.mid, book);
        lower = MetricBook._root(flipped ? book.upperX64 : book.lowerX64, book);
        upper = MetricBook._root(flipped ? book.lowerX64 : book.upperX64, book);
        if (lower > at) lower = at;
        if (upper < at) upper = at;
        units = MetricBook._liquidity(book, at, lower, upper);
    }
}
