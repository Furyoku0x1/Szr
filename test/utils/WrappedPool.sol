// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { TestAsset } from "./TestAsset.sol";
import { IVenuePricer } from "../../src/interfaces/IVenuePricer.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

interface IArbitrageOwner {
    function setRecipient(uint256 id, address recipient) external;
    function sweep(uint256 id, address base) external returns (uint256);
    function venueSearch(bytes32 poolId, bool before, address sender) external;
    function setVenueTrigger(uint256 id, bytes32 poolId, address base, uint32 gasCap, bool on)
        external;
}

/// @dev Stands in for one of Uniswap's aggregator hooks. Each pool on it wraps a
/// constant-product pool held here: a swap takes the input from the pool manager, pays the
/// output in by sync, send and settle, and returns a delta that cancels the pool's own
/// swap. It keeps no v4 liquidity. `mode` makes it misbehave in the middle of a swap.
contract WrappedPool {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FEE = 3_000;

    IPoolManager internal immutable manager;
    mapping(bytes32 poolId => uint256[2] held) public reserves;
    /// 1: trade `target` in the middle of the swap. 2: call the arbitrage hook as a
    /// market's owner. 3: fill an exact-output swap one unit short. 4: pay in one unit
    /// less than it reports. 5: credit the arbitrage hook with one unit of the output.
    /// 6: call the hook's `sweep`, keeping the selector it reverted with in `seen`.
    uint256 public mode;
    /// 7: pay an output of native ETH with `settle{ value }`, without syncing first.
    bytes4 public seen;
    PoolKey public target;
    address public arbitrage;
    uint256 public market;
    /// While set, a swap asks the arbitrage hook for the searches registered for its pool,
    /// before the fill and after it, as `MetricVenueHook` does.
    bool public watching;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    receive() external payable { }

    function seed(PoolKey calldata pool, uint256 first, uint256 second) external {
        reserves[PoolId.unwrap(pool.toId())] = [first, second];
    }

    function arm(uint256 value, PoolKey calldata pool, address hook, uint256 id) external {
        mode = value;
        target = pool;
        arbitrage = hook;
        market = id;
    }

    /// Registers a trigger for `pool` in market `id` and starts asking for it on every swap.
    function watch(PoolKey calldata pool, address hook, uint256 id, address base, uint32 cap)
        external
    {
        arbitrage = hook;
        watching = true;
        IArbitrageOwner(hook).setVenueTrigger(id, PoolId.unwrap(pool.toId()), base, cap, true);
    }

    function _ask(PoolKey calldata pool, address sender, bool before) internal {
        if (!watching) return;
        try IArbitrageOwner(arbitrage)
            .venueSearch(PoolId.unwrap(pool.toId()), before, sender) { }
            catch { }
    }

    function reservesOf(bytes32 poolId) external view returns (uint256, uint256) {
        return (reserves[poolId][0], reserves[poolId][1]);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(manager), "not the pool manager");
        _ask(pool, sender, true);
        bool exactInput = params.amountSpecified < 0;
        (uint256 paid, uint256 given) = _fill(pool, params);
        manager.take(params.zeroForOne ? pool.currency0 : pool.currency1, address(this), paid);
        _misbehave();
        uint256 sent = given;
        if (mode == 3) {
            if (!exactInput) sent = given - 1;
        }
        Currency output = params.zeroForOne ? pool.currency1 : pool.currency0;
        if (mode == 7) {
            manager.settle{ value: sent }();
        } else {
            manager.sync(output);
            TestAsset(Currency.unwrap(output))
                .transfer(address(manager), mode == 4 ? sent - 1 : sent);
            manager.settle();
        }
        if (mode == 5) {
            manager.sync(output);
            TestAsset(Currency.unwrap(output)).transfer(address(manager), 1);
            manager.settleFor(arbitrage);
        }
        _ask(pool, sender, false);
        int128 specified = exactInput ? int128(int256(paid)) : -int128(int256(sent));
        int128 unspecified = exactInput ? -int128(int256(sent)) : int128(int256(paid));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), 0);
    }

    /// Constant product with a fee on the way in, as a Uniswap V2 pair prices it.
    function _fill(PoolKey calldata pool, IPoolManager.SwapParams calldata params)
        internal
        returns (uint256 paid, uint256 given)
    {
        uint256[2] storage held = reserves[PoolId.unwrap(pool.toId())];
        uint256 inside = params.zeroForOne ? held[0] : held[1];
        uint256 outside = params.zeroForOne ? held[1] : held[0];
        if (params.amountSpecified < 0) {
            paid = uint256(-params.amountSpecified);
            uint256 net = paid * (1e6 - FEE);
            given = outside * net / (inside * 1e6 + net);
        } else {
            given = uint256(params.amountSpecified);
            paid = inside * given * 1e6 / ((outside - given) * (1e6 - FEE)) + 1;
        }
        held[params.zeroForOne ? 0 : 1] = inside + paid;
        held[params.zeroForOne ? 1 : 0] = outside - given;
    }

    function _misbehave() internal {
        if (mode == 1) {
            // A small sale of the target's first token, paid for and collected in full.
            BalanceDelta delta = manager.swap(
                target, IPoolManager.SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1), ""
            );
            manager.sync(target.currency0);
            TestAsset(Currency.unwrap(target.currency0)).transfer(address(manager), 1e18);
            manager.settle();
            manager.take(target.currency1, address(this), uint128(delta.amount1()));
        }
        if (mode == 2) IArbitrageOwner(arbitrage).setRecipient(market, address(this));
        if (mode == 6) {
            try IArbitrageOwner(arbitrage).sweep(market, address(0)) { }
            catch (bytes memory reason) {
                seen = bytes4(reason);
            }
        }
    }
}

/// @dev Prices pools on a `WrappedPool` from the reserves it holds. A constant-product pool
/// is one range over every price, so that is the range it reports. `mode` makes it give a
/// bad answer.
contract WrappedPricer is IVenuePricer {
    using PoolIdLibrary for PoolKey;

    WrappedPool internal immutable wrapper;
    /// 1: revert. 2: burn all the gas given. 3: answer with four words. 4: answer with a
    /// very long one. 5: a fee of more than everything. 6: a price too large for a pool.
    /// 7: liquidity too large for a pool. 8: a fee that does not fit in its field. 9: no range
    /// (it cannot say how far its answer holds). 10: a short range, `reach` parts per million
    /// of the price either side. 11: a lower bound above the price. 12: an upper bound below
    /// it. 13: a lower bound below `TickMath`'s. 14: an upper bound above it. 15: six words.
    uint256 public mode;
    /// The distance, in parts per million of the square-root price, that mode 10 holds over.
    uint256 public reach;

    constructor(WrappedPool pool) {
        wrapper = pool;
    }

    function arm(uint256 value) external {
        mode = value;
    }

    function setReach(uint256 ppm) external {
        reach = ppm;
    }

    function price(PoolKey calldata pool)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        uint256 state = mode;
        if (state == 1) revert("no price");
        if (state == 2) _burn();
        (uint256 first, uint256 second) = wrapper.reservesOf(PoolId.unwrap(pool.toId()));
        uint256 root =
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(second, 1 << 192, first));
        uint256 units = FixedPointMathLib.sqrt(first * second);
        // A right answer with something after it or missing from it.
        if (state == 3) _answer(root, 3_000, units, root, root, 0x80);
        if (state == 4) _answer(root, 3_000, units, root, root, 0x4000);
        if (state == 15) _answer(root, 3_000, units, TickMath.MIN_SQRT_PRICE, root, 0xc0);
        // Five words of the right length, one of them out of range.
        uint256 low = TickMath.MIN_SQRT_PRICE;
        uint256 high = TickMath.MAX_SQRT_PRICE;
        if (state == 6) _answer(1 << 161, 3_000, units, low, high, 0xa0);
        if (state == 7) _answer(root, 3_000, 1 << 129, low, high, 0xa0);
        if (state == 8) _answer(root, 1 << 24, units, low, high, 0xa0);
        if (state == 9) {
            return (uint160(root), 3_000, uint128(units), uint160(root), uint160(root));
        }
        if (state == 10) {
            return (
                uint160(root),
                3_000,
                uint128(units),
                uint160(root * (1e6 - reach) / 1e6),
                uint160(root * (1e6 + reach) / 1e6)
            );
        }
        if (state == 11) _answer(root, 3_000, units, root + 1, high, 0xa0);
        if (state == 12) _answer(root, 3_000, units, low, root - 1, 0xa0);
        if (state == 13) _answer(root, 3_000, units, low - 1, high, 0xa0);
        if (state == 14) _answer(root, 3_000, units, low, high + 1, 0xa0);
        uint24 fee = state == 5 ? type(uint24).max : 3_000;
        return (uint160(root), fee, uint128(units), uint160(low), uint160(high));
    }

    function _burn() internal view {
        uint256 spin;
        while (gasleft() > 200) spin++;
    }

    function _answer(
        uint256 root,
        uint256 fee,
        uint256 units,
        uint256 lower,
        uint256 upper,
        uint256 length
    ) internal pure {
        assembly ("memory-safe") {
            let start := mload(0x40)
            mstore(start, root)
            mstore(add(start, 0x20), fee)
            mstore(add(start, 0x40), units)
            mstore(add(start, 0x60), lower)
            mstore(add(start, 0x80), upper)
            mstore(add(start, 0xa0), 0)
            return(start, length)
        }
    }
}

/// @dev A pricer that answers the same five words whatever it is asked, at almost no gas of
/// its own, so that a test can measure what asking costs the hook beyond the pricer's work.
contract FlatPricer is IVenuePricer {
    function price(PoolKey calldata)
        external
        pure
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        return (
            uint160(1 << 96),
            3_000,
            1_000_000e18,
            TickMath.MIN_SQRT_PRICE,
            TickMath.MAX_SQRT_PRICE
        );
    }
}

/// @dev A pricer that needs a normal call, as Metric's does: it writes storage before it
/// answers, which a STATICCALL refuses. It answers as `inner` does.
contract CallOnlyPricer {
    WrappedPricer internal immutable inner;
    uint256 public calls;

    constructor(WrappedPricer answers) {
        inner = answers;
    }

    function price(PoolKey calldata pool)
        external
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        calls++;
        return inner.price(pool);
    }
}

/// @dev A pricer that does more than answer. `mode` 1: it takes one unit of `asset` out of
/// the pool manager, which opens a balance it never settles. 2: it tries to swap `target`,
/// a pool of the arbitrage hook, in the middle of the ask. It always writes `marker` too.
contract MeddlingPricer {
    IPoolManager internal immutable manager;
    WrappedPricer internal immutable inner;
    address internal immutable asset;
    uint256 public marker;
    uint256 public mode;
    PoolKey public target;

    constructor(IPoolManager poolManager, WrappedPricer answers, address token) {
        manager = poolManager;
        inner = answers;
        asset = token;
    }

    function arm(uint256 value, PoolKey calldata pool) external {
        mode = value;
        target = pool;
    }

    function price(PoolKey calldata pool)
        external
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        marker = 1;
        if (mode == 1) manager.take(Currency.wrap(asset), address(this), 1);
        if (mode == 2) {
            try manager.swap(
                target, IPoolManager.SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1), ""
            ) { }
                catch { }
        }
        return inner.price(pool);
    }
}

/// @dev A pricer that reverts with a good answer in its revert data, to look like what
/// `askFrame` itself reverts with. `mode` 1: exactly the five words. 2: the same behind
/// the selector of `Answer`.
contract EchoRevertPricer {
    error Answer(uint256[5] answer);

    uint256 public mode = 1;

    function arm(uint256 value) external {
        mode = value;
    }

    function price(PoolKey calldata)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        uint256[5] memory good = [uint256(1 << 96), 3_000, 1_000e18, 0, 0];
        good[3] = TickMath.MIN_SQRT_PRICE;
        good[4] = TickMath.MAX_SQRT_PRICE;
        if (mode == 2) revert Answer(good);
        assembly ("memory-safe") {
            revert(good, 0xa0)
        }
    }
}

/// @dev A pricer that needs `cost` gas to answer, as one that reads a pool of another
/// exchange does. Given less it runs out and has no answer.
contract HungryPricer {
    WrappedPricer internal immutable inner;
    uint256 internal immutable cost;

    constructor(WrappedPricer answers, uint256 gas) {
        inner = answers;
        cost = gas;
    }

    function price(PoolKey calldata pool)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        uint256 start = gasleft();
        while (start - gasleft() < cost) { }
        return inner.price(pool);
    }
}

/// @dev A pricer that refuses at once when it is given less than `gate` gas, as one that
/// checks its budget before a costly read does. Unlike `HungryPricer`, which burns what it
/// is given and so starves the search around it anyway, it leaves the search able to go on
/// with "no price", which is what a short ask must never be allowed to cause.
contract GatedPricer {
    WrappedPricer internal immutable inner;
    uint256 internal immutable gate;

    constructor(WrappedPricer answers, uint256 limit) {
        inner = answers;
        gate = limit;
    }

    function price(PoolKey calldata pool)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        if (gasleft() < gate) revert("short of gas");
        return inner.price(pool);
    }
}
