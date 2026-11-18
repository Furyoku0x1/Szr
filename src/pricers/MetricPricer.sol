// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IVenuePricer } from "../interfaces/IVenuePricer.sol";
import { MetricVenueHook } from "../hooks/MetricVenueHook.sol";
import { IMetricPool } from "../interfaces/metric/IMetricPool.sol";

/// @dev Metric pools expose their storage through this (`Extsload`).
interface IMetricStorage {
    function extsload(bytes32 slot) external view returns (bytes32);
}

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

    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant MAX_POS = type(uint104).max;

    MetricVenueHook public immutable wrapper;

    struct Book {
        uint256 mid;
        uint256 scale0;
        uint256 scale1;
        bool flipped;
        uint256 lowerX64;
        uint256 upperX64;
        uint256 token0;
        uint256 token1;
        uint256 widthFee;
    }

    error Unbound();
    error NoPrice();

    constructor(MetricVenueHook hook) {
        wrapper = hook;
    }

    function price(PoolKey calldata key)
        external
        returns (uint160 root, uint24 fee, uint128 liquidity, uint160 lower, uint160 upper)
    {
        Book memory book;
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
        if (book.mid == 0) revert NoPrice();
        fee = _fee(sell, buy, book.mid);
        _readBin(IMetricStorage(address(metric)), book);
        if (fee + book.widthFee >= PIPS) revert NoPrice();
        fee = uint24(fee + book.widthFee);
        root = _root(book.mid, book);
        lower = _root(book.flipped ? book.upperX64 : book.lowerX64, book);
        upper = _root(book.flipped ? book.lowerX64 : book.upperX64, book);
        // Rounding must never put the price outside its own range.
        if (lower > root) lower = root;
        if (upper < root) upper = root;
        liquidity = _liquidity(book, root, lower, upper);
    }

    /// The worse side's distance from the midpoint, rounded up. Selling pays `mid * (1 -
    /// fee)` in a v4 pool and buying costs at most `mid / (1 - fee)`, so using the distance
    /// itself for both overcharges the buy side a little, which is the safe way.
    function _fee(uint128 sell, uint128 buy, uint256 mid) internal pure returns (uint24) {
        uint256 down;
        uint256 up;
        if (sell < mid) down = FullMath.mulDivRoundingUp(mid - sell, PIPS, mid);
        if (buy > mid) up = FullMath.mulDivRoundingUp(buy - mid, PIPS, mid);
        uint256 total = down > up ? down : up;
        if (total >= PIPS) revert NoPrice();
        return uint24(total);
    }

    /// The current bin's two ends, as Metric prices scaled from the midpoint, and what the
    /// bin holds, from slot 0 and the bin's word (`PoolStateLibrary`: bins are at slot 4).
    function _readBin(IMetricStorage metric, Book memory book) internal view {
        uint256 raw0 = uint256(metric.extsload(bytes32(0)));
        int256 idx = int256(int16(uint16(raw0 >> 8)));
        uint256 pos = uint104(raw0 >> 24);
        int256 dist = int256(int24(uint24(raw0 >> 128)));
        uint256 rawBin = uint256(metric.extsload(keccak256(abi.encode(idx, uint256(4)))));
        book.token0 = uint104(rawBin);
        book.token1 = uint104(rawBin >> 104);
        uint256 length = uint16(rawBin >> 208);
        // Metric stops quoting a paused pool's swaps but not its prices, so read the pause.
        if (uint8(raw0) != 0) revert NoPrice();
        if (length == 0) revert NoPrice();
        // Metric's price is linear in position and the v4 model is convex, so the model
        // overstates output for a wide bin by up to about 0.14 * w^2 of the leg, where w is
        // the bin's width as a fraction; 0.15 * w^2 is added to the fee to cover it.
        book.widthFee = FullMath.mulDivRoundingUp(15 * length, length, 1e8);
        if (dist <= -int256(PIPS)) revert NoPrice();
        uint256 low = uint256(int256(PIPS) + dist);
        uint256 high = low + length;
        // The reference price scales out: the edges are in the same ratio to the midpoint as
        // they are to the marginal price at `pos`.
        uint256 den = low * (MAX_POS - pos) + high * pos;
        book.lowerX64 = FullMath.mulDivRoundingUp(book.mid, low * MAX_POS, den);
        book.upperX64 = FullMath.mulDiv(book.mid, high * MAX_POS, den);
    }

    /// The v4 square-root price of a Metric price (whole token1 per whole token0, Q64.64),
    /// in the v4 pool's own token order.
    function _root(uint256 priceX64, Book memory book) internal pure returns (uint160) {
        uint256 s0 = book.scale0;
        uint256 s1 = book.scale1;
        // The v4 price is raw token1 per raw token0, times 2^192, before the square root.
        uint256 ratio = book.flipped
            ? FullMath.mulDiv(s1 << 128, 1 << 128, priceX64 * s0)
            : FullMath.mulDiv(priceX64, s0 << 128, s1);
        uint256 value = FixedPointMathLib.sqrt(ratio);
        if (value < TickMath.MIN_SQRT_PRICE) revert NoPrice();
        if (value >= TickMath.MAX_SQRT_PRICE) revert NoPrice();
        return uint160(value);
    }

    /// The v4 liquidity that trades the bin's reserves to each edge, the smaller side. A
    /// side with no width (the position is at that edge) has no reserves to walk through and
    /// does not limit the other.
    function _liquidity(Book memory book, uint160 root, uint160 lower, uint160 upper)
        internal
        pure
        returns (uint128)
    {
        // Raw amounts, in the v4 pool's order: v4's token0 is Metric's token1 when flipped.
        uint256 x = book.flipped ? book.token1 / book.scale1 : book.token0 / book.scale0;
        uint256 y = book.flipped ? book.token0 / book.scale0 : book.token1 / book.scale1;
        uint256 byY = type(uint256).max;
        uint256 byX = type(uint256).max;
        if (root > lower) byY = FullMath.mulDiv(y, 1 << 96, root - lower);
        if (upper > root) {
            byX = FullMath.mulDiv(x, FullMath.mulDiv(root, upper, 1 << 96), upper - root);
        }
        uint256 result = byY < byX ? byY : byX;
        if (result == type(uint256).max) return 0;
        if (result > type(uint128).max) return type(uint128).max;
        return uint128(result);
    }
}
