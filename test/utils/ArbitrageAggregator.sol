// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IVenuePricer } from "../../src/interfaces/IVenuePricer.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";

interface IAggregatorHook {
    function poolIdToExternalPool(bytes32 poolId) external view returns (address);
}

interface IOutsidePool {
    function slot0() external view returns (uint160 sqrtPriceX96);
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

/// @dev Prices a pool on a deployed Uniswap aggregator hook (Slipstream variant) by
/// reading the pool it wraps. Test code only; a production pricer is a separate decision.
/// The hook fills a swap on the outside pool, so the wrapped pool's own slot0 is a
/// placeholder. The outside pool's `fee()` is read live. The hook's own cut of the output
/// (`ProtocolFeesCollected`, 1000 in the swap's trace) is not exposed by any view that
/// matches it: the pool manager's slot0 reads 40 for the pool, so it is passed in at
/// construction.
contract AggregatorPricer is IVenuePricer {
    using PoolIdLibrary for PoolKey;

    IAggregatorHook internal immutable aggregator;
    uint24 public immutable hookFee;

    constructor(IAggregatorHook hook, uint24 cut) {
        aggregator = hook;
        hookFee = cut;
    }

    function price(PoolKey calldata pool) external view returns (uint160, uint24, uint128) {
        IOutsidePool outside =
            IOutsidePool(aggregator.poolIdToExternalPool(PoolId.unwrap(pool.toId())));
        // Slipstream's slot0 has more words than this reads; only the first is the price.
        uint160 root = outside.slot0();
        return (root, outside.fee() + hookFee, outside.liquidity());
    }
}
