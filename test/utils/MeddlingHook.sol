// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { BaseTestHooks } from "v4-core/test/BaseTestHooks.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ArbitrageHook } from "../../src/ArbitrageHook.sol";

/// @dev A hook on a connecting pool that, every time that pool is swapped, tries to start
/// the arbitrage hook's own search from inside it.
contract MeddlingHook is BaseTestHooks {
    ArbitrageHook public immutable target;
    bytes32 public immutable poolId;
    uint256 public swaps;
    uint256 public refused;

    constructor(ArbitrageHook arbitrage, bytes32 tracked) {
        target = arbitrage;
        poolId = tracked;
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        swaps++;
        try target.arb(poolId) { }
        catch {
            refused++;
        }
        return (IHooks.afterSwap.selector, 0);
    }
}
