// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import { IMetricPool, MetricImmutables } from "../interfaces/metric/IMetricPool.sol";
import { MetricBook, IMetricStorage } from "../pricers/lib/MetricBook.sol";

/// @notice The index balancer's reader of Metric pools, kept apart so the balancer fits in
/// 24,576 bytes. It checks that a pool is one of Metric's and pairs a token with the unit,
/// and reads a pool's current bin as one v4 range, exactly as `MetricPricer` does for a pool
/// bound to `MetricVenueHook`, but applied to the Metric pool directly. Stateless.
/// @dev `read` is not `view`: Metric's prices can only be read by a real call
/// (`getSellAndBuyPrices` takes the pool's swap lock). A paused pool, a feed that is down or
/// an empty bin makes it revert, which the balancer reads as "no price for this call".
contract IndexMetric {
    IMetricFactory public immutable factory;

    error NotMetricPool();
    error WrongPair();
    error WrongScale();
    /// The pool is in the middle of a swap: its price cannot be read now. Kept apart from
    /// every other failure, since a swap made from inside Metric's callback would otherwise
    /// hide this venue.
    error Locked();

    /// What a Metric pool's reentrancy guard reverts with, `ReentrancyGuardReentrantCall()`.
    bytes4 internal constant REENTRANT = 0x3ee5aeb5;

    constructor(IMetricFactory factory_) {
        factory = factory_;
    }

    /// @notice Whether `pool` is a Metric pool of `token` and `unit`, and if so whether
    /// `token` is its token0. Reverts otherwise. Its extensions are not looked at.
    function check(address pool, address token, address unit)
        external
        view
        returns (bool tokenFirst)
    {
        // The pool's own claim about its factory proves nothing, so the factory is asked.
        if (!factory.isPool(pool)) revert NotMetricPool();
        MetricImmutables memory imm = IMetricPool(pool).getImmutables();
        if (imm.factory != address(factory)) revert NotMetricPool();
        if (imm.token0ScaleMultiplier > type(uint128).max) revert WrongScale();
        if (imm.token1ScaleMultiplier > type(uint128).max) revert WrongScale();
        if (imm.token0 == token) {
            if (imm.token1 == unit) return true;
        }
        if (imm.token0 == unit) {
            if (imm.token1 == token) return false;
        }
        revert WrongPair();
    }

    /// @notice The pool's square-root price, fee, liquidity and range, in that order, in the
    /// order of a v4 pool of the same two tokens whose token0 is `low`: `MetricPricer.price`
    /// with the orientation and scales read from the pool itself.
    function read(address pool, address low) external returns (uint256[5] memory answer) {
        (uint160 root, uint24 fee, uint128 liquidity, uint160 lower, uint160 upper) =
            _read(pool, low);
        answer = [uint256(root), fee, liquidity, lower, upper];
    }

    /// @dev The pool's two prices. A read refused by its reentrancy guard is `Locked`; any
    /// other failure, a stalled feed or a pause among them, is no price.
    function _prices(address pool) internal returns (uint128, uint128) {
        try IMetricPool(pool).getSellAndBuyPrices() returns (uint128 sell, uint128 buy) {
            return (sell, buy);
        } catch {
            bytes32 word;
            assembly ("memory-safe") {
                if eq(returndatasize(), 4) {
                    let ptr := mload(0x40)
                    returndatacopy(ptr, 0, 4)
                    word := mload(ptr)
                }
            }
            if (bytes4(word) == REENTRANT) revert Locked();
            revert MetricBook.NoPrice();
        }
    }

    function _read(address pool, address low)
        internal
        returns (uint160 root, uint24 fee, uint128 liquidity, uint160 lower, uint160 upper)
    {
        MetricBook.Book memory book;
        MetricImmutables memory imm = IMetricPool(pool).getImmutables();
        book.flipped = imm.token0 != low;
        book.scale0 = imm.token0ScaleMultiplier;
        book.scale1 = imm.token1ScaleMultiplier;
        (uint128 sell, uint128 buy) = _prices(pool);
        book.mid = (uint256(sell) + uint256(buy)) / 2;
        if (book.mid == 0) revert MetricBook.NoPrice();
        fee = MetricBook._fee(sell, buy, book.mid);
        MetricBook._readBin(IMetricStorage(pool), book);
        if (fee + book.widthFee >= MetricBook.PIPS) revert MetricBook.NoPrice();
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
