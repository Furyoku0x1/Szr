// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenuePricer } from "../interfaces/IVenuePricer.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { ProtocolFeeLibrary } from "v4-core/libraries/ProtocolFeeLibrary.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";

interface IAggregatorHook {
    function poolIdToExternalPool(PoolId poolId) external view returns (address);
    function poolManager() external view returns (address);
    function protocolFeeMultiplier() external view returns (uint24);
}

interface IOutsidePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96);
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

/// @notice Prices a pool on one of Uniswap's aggregator hooks (the Slipstream variant, at
/// Uniswap/v4-hooks-public commit e354058) from the outside pool the hook wraps.
/// @dev The hook's own cut of each swap's output is not fixed: the hook reads the pool
/// manager's protocol fee for the pool, which the manager's fee controller can change, and
/// multiplies it by its immutable `protocolFeeMultiplier`. The pool manager and the
/// multiplier are read once at construction and the protocol fee live on each call, so the
/// quoted fee follows the controller. The fee is taken per direction, and one answer
/// serves both, so the larger of the two is used: that can only understate the output.
/// The hook skips the cut while it has no token jar; this pricer counts it anyway, which
/// again can only understate. No owner, no state, no upgrade.
contract AggregatorPricer is IVenuePricer {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant PIPS = 1_000_000;

    IAggregatorHook public immutable aggregator;
    IPoolManager public immutable manager;
    uint24 public immutable multiplier;

    constructor(IAggregatorHook hook) {
        aggregator = hook;
        manager = IPoolManager(hook.poolManager());
        multiplier = hook.protocolFeeMultiplier();
    }

    /// A Slipstream pool holds only to its next tick, which this does not read, so it says
    /// nothing about its range and the hook sizes it by an estimate.
    function price(PoolKey calldata pool)
        external
        view
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        require(!_isNative(pool.currency0), "ETH");
        require(!_isNative(pool.currency1), "ETH");
        PoolId id = pool.toId();
        IOutsidePool outside = IOutsidePool(aggregator.poolIdToExternalPool(id));
        uint160 root = _root(outside, pool);
        uint256 total = uint256(outside.fee()) + _cut(id);
        require(total < PIPS, "fee");
        return (root, uint24(total), outside.liquidity(), root, root);
    }

    function _isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }

    /// The outside pool's price in the pool's own token order. Slipstream's slot0 has more
    /// words than this reads; only the first is the price.
    function _root(IOutsidePool outside, PoolKey calldata pool)
        internal
        view
        returns (uint160)
    {
        address token0 = outside.token0();
        address token1 = outside.token1();
        uint160 root = outside.slot0();
        if (token0 == Currency.unwrap(pool.currency0)) {
            require(token1 == Currency.unwrap(pool.currency1), "tokens");
            return root;
        }
        require(token0 == Currency.unwrap(pool.currency1), "tokens");
        require(token1 == Currency.unwrap(pool.currency0), "tokens");
        // The square root of the inverse price, 2^192 over the root.
        return uint160(FullMath.mulDiv(1 << 96, 1 << 96, root));
    }

    function _cut(PoolId id) internal view returns (uint256) {
        (,, uint24 raw,) = manager.getSlot0(id);
        uint24 down = ProtocolFeeLibrary.getZeroForOneFee(raw);
        uint24 up = ProtocolFeeLibrary.getOneForZeroFee(raw);
        return uint256(down > up ? down : up) * multiplier;
    }
}
