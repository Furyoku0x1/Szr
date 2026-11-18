// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "../../../src/interfaces/metric/IMetricPool.sol";

/// @dev Metric's factory as far as the hook asks: which pools it made.
contract MockMetricFactory {
    mapping(address => bool) public isPool;

    function register(address pool) external {
        isPool[pool] = true;
    }
}

/// @dev A Metric pool with one flat price and whatever it holds as liquidity. It keeps
/// Metric's order of work: pay the output first, ask for the input in the callback, then
/// check that its balance rose. A price limit it cannot meet fills nothing; `maxFill` caps
/// the raw input it will take.
contract MockMetricPool is IMetricPool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable scale0;
    uint256 public immutable scale1;
    uint128 public priceX64;
    uint256 public maxFill = type(uint256).max;
    // Misbehaviour for the tests. 1: reports a negative input. 2: reports a negative
    // output. 3: asks `extra` more input in the callback than it reports. 4: swaps on
    // another pool of the pool manager before it asks for the input. 5: swaps on another
    // pool of the pool manager after its own swap is paid, and settles that swap, so the
    // trade moves that pool's price without breaking the unlock. 6: burns `extra` gas after
    // the swap, as a costly fill does.
    uint8 public mode;
    uint256 public extra;
    IPoolManager internal nestedManager;
    PoolKey internal nestedKey;
    IPoolManager.SwapParams internal nestedParams;

    constructor(
        address factory_,
        address t0,
        address t1,
        uint256 s0,
        uint256 s1,
        uint128 price
    ) {
        factory = factory_;
        token0 = t0;
        token1 = t1;
        scale0 = s0;
        scale1 = s1;
        priceX64 = price;
    }

    function setMaxFill(uint256 cap) external {
        maxFill = cap;
    }

    function setMode(uint8 newMode, uint256 amount) external {
        mode = newMode;
        extra = amount;
    }

    function setNested(
        IPoolManager manager,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external {
        nestedManager = manager;
        nestedKey = key;
        nestedParams = params;
    }

    /// Calls the hook's callback as this pool, outside any swap of its own.
    function poke(address hook) external {
        IMetricSwapCallback(hook).metricOmmSwapCallback(int256(1), 0, "");
    }

    function getImmutables() external view returns (MetricImmutables memory) {
        return MetricImmutables(factory, token0, token1, scale0, scale1);
    }

    function getSellAndBuyPrices() external view returns (uint128, uint128) {
        return (priceX64, priceX64);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 limit,
        bytes calldata,
        bytes calldata
    ) external returns (int128 amount0, int128 amount1) {
        (uint256 inAmt, uint256 outAmt) = _fill(zeroForOne, amountSpecified, limit);
        (amount0, amount1) = zeroForOne
            ? (int128(int256(inAmt)), -int128(int256(outAmt)))
            : (-int128(int256(outAmt)), int128(int256(inAmt)));
        address tIn = zeroForOne ? token0 : token1;
        uint256 before = SafeTransferLib.balanceOf(tIn, address(this));
        SafeTransferLib.safeTransfer(zeroForOne ? token1 : token0, recipient, outAmt);
        if (mode == 4) nestedManager.swap(nestedKey, nestedParams, "");
        _callback(amount0, amount1, zeroForOne);
        require(SafeTransferLib.balanceOf(tIn, address(this)) >= before + inAmt, "not paid");
        if (mode == 5) _nest();
        if (mode == 6) _burn(extra);
        if (mode == 1) {
            (amount0, amount1) = zeroForOne ? (-amount0, amount1) : (amount0, -amount1);
        }
        if (mode == 2) {
            (amount0, amount1) = zeroForOne ? (amount0, -amount1) : (-amount0, amount1);
        }
    }

    function _burn(uint256 amount) internal view {
        uint256 stop = gasleft() > amount ? gasleft() - amount : 0;
        while (gasleft() > stop) { }
    }

    function _nest() internal {
        BalanceDelta delta = nestedManager.swap(nestedKey, nestedParams, "");
        _square(nestedKey.currency0, delta.amount0());
        _square(nestedKey.currency1, delta.amount1());
    }

    function _square(Currency currency, int128 amount) internal {
        if (amount < 0) {
            nestedManager.sync(currency);
            SafeTransferLib.safeTransfer(
                Currency.unwrap(currency), address(nestedManager), uint128(-amount)
            );
            nestedManager.settle();
        }
        if (amount > 0) nestedManager.take(currency, address(this), uint128(amount));
    }

    function _callback(int256 amount0, int256 amount1, bool zeroForOne) internal {
        int256 more = mode == 3 ? int256(extra) : int256(0);
        if (zeroForOne) amount0 += more;
        else amount1 += more;
        IMetricSwapCallback(msg.sender).metricOmmSwapCallback(amount0, amount1, "");
    }

    function _fill(bool zeroForOne, int128 amountSpecified, uint128 limit)
        internal
        view
        returns (uint256 inAmt, uint256 outAmt)
    {
        if (zeroForOne ? priceX64 < limit : priceX64 > limit) return (0, 0);
        if (amountSpecified > 0) {
            inAmt = FixedPointMathLib.min(uint256(uint128(amountSpecified)), maxFill);
            return (inAmt, _out(zeroForOne, inAmt));
        }
        outAmt = uint256(uint128(-amountSpecified));
        inAmt = _in(zeroForOne, outAmt);
        if (inAmt > maxFill) {
            inAmt = maxFill;
            outAmt = _out(zeroForOne, inAmt);
        }
    }

    // Scaled amounts are raw amounts times the pool's multiplier; the price is scaled
    // token1 per scaled token0.
    function _out(bool zeroForOne, uint256 inAmt) internal view returns (uint256) {
        if (zeroForOne) {
            return FixedPointMathLib.mulDiv(inAmt * scale0, priceX64, (1 << 64) * scale1);
        }
        return FixedPointMathLib.mulDiv(inAmt * scale1, 1 << 64, uint256(priceX64) * scale0);
    }

    function _in(bool zeroForOne, uint256 outAmt) internal view returns (uint256) {
        if (zeroForOne) {
            return
                FixedPointMathLib.mulDivUp(outAmt * scale1, 1 << 64, uint256(priceX64) * scale0);
        }
        return FixedPointMathLib.mulDivUp(outAmt * scale0, priceX64, (1 << 64) * scale1);
    }
}
