// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageProbe } from "./ArbitrageProbe.sol";

/// @dev Stands in for the hook of a venue that starts searches, as `MetricVenueHook` does,
/// and looks at what the arbitrage hook has left remembered the moment `venueSearch`
/// returns, which the hook's own storage cannot show once the transaction is over. The
/// arbitrage hook must have the probe's code.
contract PeekVenue is IUnlockCallback {
    IPoolManager internal immutable manager;
    ArbitrageApi internal immutable arbitrage;
    bytes32 internal poolId;
    bool internal before;
    /// What was remembered right after the last `venueSearch`.
    bytes32 public seen;

    constructor(IPoolManager poolManager, ArbitrageApi target) {
        manager = poolManager;
        arbitrage = target;
    }

    function setTrigger(uint256 id, bytes32 pool, address base, uint32 gasCap) external {
        arbitrage.setVenueTrigger(id, pool, base, gasCap, true);
    }

    function run(bytes32 pool, bool first) external {
        poolId = pool;
        before = first;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        arbitrage.venueSearch(poolId, before, address(this));
        seen = ArbitrageProbe(payable(address(arbitrage))).rememberedNow();
        return "";
    }
}
