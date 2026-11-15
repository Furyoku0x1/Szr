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
    uint256 public mode;
    PoolKey public target;
    address public arbitrage;
    uint256 public market;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function seed(PoolKey calldata pool, uint256 first, uint256 second) external {
        reserves[PoolId.unwrap(pool.toId())] = [first, second];
    }

    function arm(uint256 value, PoolKey calldata pool, address hook, uint256 id) external {
        mode = value;
        target = pool;
        arbitrage = hook;
        market = id;
    }

    function reservesOf(bytes32 poolId) external view returns (uint256, uint256) {
        return (reserves[poolId][0], reserves[poolId][1]);
    }

    function beforeSwap(
        address,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(manager), "not the pool manager");
        bool exactInput = params.amountSpecified < 0;
        (uint256 paid, uint256 given) = _fill(pool, params);
        manager.take(params.zeroForOne ? pool.currency0 : pool.currency1, address(this), paid);
        _misbehave();
        uint256 sent = given;
        if (mode == 3) {
            if (!exactInput) sent = given - 1;
        }
        Currency output = params.zeroForOne ? pool.currency1 : pool.currency0;
        manager.sync(output);
        TestAsset(Currency.unwrap(output))
            .transfer(address(manager), mode == 4 ? sent - 1 : sent);
        manager.settle();
        if (mode == 5) {
            manager.sync(output);
            TestAsset(Currency.unwrap(output)).transfer(address(manager), 1);
            manager.settleFor(arbitrage);
        }
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
    }
}

/// @dev Prices pools on a `WrappedPool` from the reserves it holds. `mode` makes it give a
/// bad answer.
contract WrappedPricer is IVenuePricer {
    using PoolIdLibrary for PoolKey;

    WrappedPool internal immutable wrapper;
    /// 1: revert. 2: burn all the gas given. 3: answer with four words. 4: answer with a
    /// very long one. 5: a fee of more than everything. 6: a price too large for a pool.
    /// 7: liquidity too large for a pool. 8: a fee that does not fit in its field.
    uint256 public mode;

    constructor(WrappedPool pool) {
        wrapper = pool;
    }

    function arm(uint256 value) external {
        mode = value;
    }

    function price(PoolKey calldata pool) external view returns (uint160, uint24, uint128) {
        uint256 state = mode;
        if (state == 1) revert("no price");
        if (state == 2) {
            uint256 spin;
            while (gasleft() > 200) spin++;
        }
        (uint256 first, uint256 second) = wrapper.reservesOf(PoolId.unwrap(pool.toId()));
        uint256 root =
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(second, 1 << 192, first));
        uint256 units = FixedPointMathLib.sqrt(first * second);
        // A right answer with something after it: one word more, or a great many.
        if (state == 3) _answer(root, 3_000, units, 0x80);
        if (state == 4) _answer(root, 3_000, units, 0x4000);
        // Three words of the right length, one of them out of range.
        if (state == 6) _answer(1 << 161, 3_000, units, 0x60);
        if (state == 7) _answer(root, 3_000, 1 << 129, 0x60);
        if (state == 8) _answer(root, 1 << 24, units, 0x60);
        if (state == 5) return (uint160(root), type(uint24).max, uint128(units));
        return (uint160(root), 3_000, uint128(units));
    }

    function _answer(uint256 root, uint256 fee, uint256 units, uint256 length) internal pure {
        assembly ("memory-safe") {
            let start := mload(0x40)
            mstore(start, root)
            mstore(add(start, 0x20), fee)
            mstore(add(start, 0x40), units)
            return(start, length)
        }
    }
}
