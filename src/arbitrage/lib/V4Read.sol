// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Reading and trading a Uniswap v4 pool, as the arbitrage hook does it. Stateless:
/// the pool manager is always an argument, so any contract can use the same code.
/// @dev The errors share their names and selectors with the hook's own, which raises them
/// in the same cases.
library V4Read {
    /// @dev Bounds that keep the pricing arithmetic from overflowing whatever a pool's state.
    /// An empty pool's price can be pushed anywhere for free, and one overflow would stop
    /// the search for every pool. A square-root price outside the band (a price ratio beyond
    /// about 5e33 either way) is treated as no price at all.
    uint256 internal constant MIN_RATE = 1 << 40;
    uint256 internal constant MAX_RATE = 1 << 152;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    error InvalidDelta();
    error Unsettled();
    error Drained();

    /// @dev Depths in a chain combine like resistors in parallel. An empty leg gives zero.
    function _harmonic(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        if (b == 0) return 0;
        return FixedPointMathLib.fullMulDiv(a, b, a + b);
    }

    /// @dev A pool's first storage word holds, from the low end: the square-root price (160
    /// bits), the tick (24), the protocol fee (24) and the pool's own fee (24).
    function _unpack(bytes32 word, bool baseFirst)
        internal
        pure
        returns (uint256 rate, uint24 fee, uint24 levy)
    {
        uint256 packed = uint256(word);
        uint256 price = uint160(packed);
        levy = uint24(packed >> 184);
        fee = uint24(packed >> 208);
        if (price == 0) return (0, fee, levy);
        rate = baseFirst ? price : Q192 / price;
        if (rate < MIN_RATE) return (0, fee, levy);
        if (rate > MAX_RATE) return (0, fee, levy);
    }

    /// @dev What a swap pays in all, as v4 combines the two fees. The protocol fee is set
    /// separately for each direction; the larger is used for both, which can only make a
    /// cycle look slightly less profitable than it is.
    function _swapFee(uint24 fee, uint24 levy) internal pure returns (uint24) {
        if (levy == 0) return fee;
        uint256 forward = levy & 0xFFF;
        uint256 backward = levy >> 12;
        uint256 larger = forward > backward ? forward : backward;
        return uint24(larger + fee - larger * fee / 1e6);
    }

    /// @dev The square root of the share a trade keeps after `fee`, in WAD. The four common
    /// tiers are constants, each equal to what `_keep` gives, since this runs for every
    /// venue of every search. Only the book and the routes use it: the sizing walk keeps the
    /// `sqrt` of `_keep`, because its cost is part of what fits in the walk's gas.
    function _keepFast(uint24 fee) internal pure returns (uint256) {
        if (fee == 3000) return 998498873309329277;
        if (fee == 500) return 999749968742185057;
        if (fee == 10000) return 994987437106619954;
        if (fee == 100) return 999949998749937496;
        return _keep(fee);
    }

    function _keep(uint24 fee) internal pure returns (uint256) {
        if (fee >= 1e6) return 0;
        return FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
    }

    /// @dev `price` moved against a trade by `(1 + gap)²`, inside `TickMath`'s range.
    function _limitFrom(uint160 price, bool zeroForOne, uint256 gap)
        internal
        pure
        returns (uint160)
    {
        uint256 wide = WAD + gap;
        uint256 factor = FixedPointMathLib.fullMulDiv(wide, wide, WAD);
        if (zeroForOne) {
            uint256 low = FixedPointMathLib.fullMulDiv(price, WAD, factor);
            return low > TickMath.MIN_SQRT_PRICE ? uint160(low) : TickMath.MIN_SQRT_PRICE + 1;
        }
        uint256 high = FixedPointMathLib.fullMulDiv(price, factor, WAD);
        return high < TickMath.MAX_SQRT_PRICE ? uint160(high) : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @dev `amount` follows v4: negative is an exact input, positive an exact output.
    /// A zero `limit` means no price limit.
    function _trade(
        IPoolManager manager,
        PoolKey memory pool,
        address input,
        int256 amount,
        uint160 limit
    ) internal returns (uint256 spent, uint256 received) {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        BalanceDelta delta =
            manager.swap(pool, IPoolManager.SwapParams(zeroForOne, amount, limit), "");
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 got = zeroForOne ? delta.amount1() : delta.amount0();
        if (paid > 0) revert InvalidDelta();
        if (got < 0) revert InvalidDelta();
        spent = uint256(-int256(paid));
        received = uint256(int256(got));
    }

    /// @dev Whether the pool manager holds `amount` of `asset`, which is about to be taken.
    /// At payout (`payout` true) a read that failed with at least half of its gas left
    /// failed on purpose, as no call that ran out of gas leaves more than a 64th. That is
    /// the named `Unsettled`, which undoes the search and lets the swap go on. Anywhere else,
    /// and when little gas is left, the empty revert stays: it reads as too little gas.
    function _funded(IPoolManager manager, Currency asset, uint256 amount, bool payout)
        internal
        view
    {
        address id = Currency.unwrap(asset);
        uint256 held;
        if (id == address(0)) {
            held = address(manager).balance;
        } else {
            uint256 gas = gasleft();
            (bool ok, bytes memory data) =
                id.staticcall(abi.encodeCall(IERC20Balance.balanceOf, (address(manager))));
            bool bad = !ok;
            if (data.length < 32) bad = true;
            if (bad) {
                if (payout) {
                    if (gasleft() >= gas / 2) revert Unsettled();
                }
                revert();
            }
            held = abi.decode(data, (uint256));
        }
        if (held < amount) revert Drained();
    }
}
