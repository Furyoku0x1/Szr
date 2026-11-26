// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { MetricPricer } from "../src/pricers/MetricPricer.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { MetricBook } from "../src/pricers/lib/MetricBook.sol";
import { MockBook, MockWrapper } from "./MetricPricer.t.sol";
import { MetricBookHarness } from "./utils/metric/MetricBookHarness.sol";

/// @dev Reading a Metric pool's bin on its own, against `MetricPricer`'s own fixtures: the
/// library gives exactly what the pricer reports.
contract MetricBookTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q64 = 1 << 64;
    uint104 internal constant MAX_POS = type(uint104).max;

    MockBook internal book;
    MockWrapper internal wrapper;
    MetricPricer internal pricer;
    MetricBookHarness internal reader;
    PoolKey internal key;

    function setUp() public {
        book = new MockBook();
        wrapper = new MockWrapper();
        pricer = new MetricPricer(MetricVenueHook(payable(address(wrapper))));
        reader = new MetricBookHarness();
        key = PoolKey(
            Currency.wrap(address(0xA0)), Currency.wrap(address(0xB0)), 0, 1, IHooks(address(1))
        );
    }

    function _same(bool flipped, uint128 s0, uint128 s1) internal {
        (uint128 sell, uint128 buy) = book.getSellAndBuyPrices();
        (uint160 a0, uint24 a1, uint128 a2, uint160 a3, uint160 a4) =
            reader.quote(address(book), sell, buy, flipped, s0, s1);
        (uint160 b0, uint24 b1, uint128 b2, uint160 b3, uint160 b4) = pricer.price(key);
        assertEq(a0, b0, "root");
        assertEq(a1, b1, "fee");
        assertEq(a2, b2, "liquidity");
        assertEq(a3, b3, "lower");
        assertEq(a4, b4, "upper");
    }

    function _bind(bool flipped, uint128 s0, uint128 s1) internal {
        wrapper.bind(key.toId(), MockWrapper.Binding(address(book), flipped, false, s0, s1));
    }

    /// The pricer's standard fixture, both ways round.
    function testStandardBinMatchesThePricer() public {
        for (uint256 turn; turn < 2; turn++) {
            bool flipped = turn == 1;
            _bind(flipped, 1, 1);
            book.setPrices(uint128(4 * Q64 * 999 / 1000), uint128(4 * Q64 * 1001 / 1000));
            book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
            _same(flipped, 1, 1);
        }
    }

    /// The pricer's decimals fixture, both ways round.
    function testScaledBinMatchesThePricer() public {
        for (uint256 turn; turn < 2; turn++) {
            bool flipped = turn == 1;
            _bind(flipped, 1, 1e12);
            book.setPrices(
                uint128(2000 * Q64 * 9999 / 10_000), uint128(2000 * Q64 * 10_001 / 10_000)
            );
            book.setBin(0, MAX_POS / 2, -1000, 5e18, 5000e18, 2000);
            _same(flipped, 1, 1e12);
        }
    }

    function testFuzzBinMatchesThePricer(uint104 pos, int24 dist, uint16 length, bool flipped)
        public
    {
        pos = uint104(bound(pos, 1, MAX_POS - 1));
        dist = int24(bound(dist, -20_000, 20_000));
        length = uint16(bound(length, 1, 50_000));
        _bind(flipped, 1, 1);
        book.setPrices(uint128(4 * Q64 * 999 / 1000), uint128(4 * Q64 * 1001 / 1000));
        book.setBin(-2, pos, dist, 2e18, 1e18, length);
        _same(flipped, 1, 1);
    }

    /// The fee is the worse side's distance from the midpoint, rounded up to a pip: 300.5
    /// pips is 301.
    function testFeeRoundsUp() public view {
        uint128 mid = uint128(4 * Q64);
        uint128 gap = uint128(uint256(mid) * 3005 / 10_000_000);
        assertEq(reader.fee(mid - gap, mid + gap / 2, mid), 301);
        assertEq(reader.fee(mid - gap / 2, mid + gap, mid), 301);
        assertEq(reader.fee(mid, mid, mid), 0);
    }

    /// The bin's edges round inwards and its width adds `ceil(0.15 * w²)` of fee.
    function testReadBin() public {
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
        MetricBook.Book memory read;
        read.mid = 4 * Q64;
        read = reader.readBin(address(book), read);
        assertEq(read.token0, 2e18, "token0");
        assertEq(read.token1, 1e18, "token1");
        assertEq(read.widthFee, 15, "1% wide");
        assertLt(read.lowerX64, read.mid, "lower edge below the midpoint");
        assertGt(read.upperX64, read.mid, "upper edge above it");
    }

    /// Paused, or without a bin, a pool has no price: `MetricPricer`'s own error.
    function testNoPrice() public {
        assertEq(MetricBook.NoPrice.selector, bytes4(keccak256("NoPrice()")));
        MetricBook.Book memory read;
        read.mid = 4 * Q64;
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 0);
        vm.expectRevert(MetricBook.NoPrice.selector);
        reader.readBin(address(book), read);
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
        book.setPause(1);
        vm.expectRevert(MetricBook.NoPrice.selector);
        reader.readBin(address(book), read);
    }
}
