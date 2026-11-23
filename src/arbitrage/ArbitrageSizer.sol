// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `size`, the walk that finds a cycle's first size. It runs inside a
/// STATICCALL, which a delegatecall keeps.
abstract contract SizerPart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice The size of a cycle's first try, found by walking its legs across the
    /// initialised ticks they meet, up to `SIZING_STEPS` boundary events in all. Within one
    /// range the legs compose into one constant-product curve, whose best size has a closed
    /// form; when a leg reaches the edge of its range first, the walk moves every leg that
    /// far, crosses the tick, and solves again. It returns the focus pool's price limit and
    /// what it may pay in, or the plan's own estimate when the walk finds nothing to improve
    /// on. It only estimates: moves nothing, and a wrong answer is a worse size, caught by
    /// the profit check and the other sizes. A guard that trips reverts, and the first try
    /// then uses the estimate. Only cycles whose every leg is a plain pool, a wrapped pool, the
    /// wrap link or Core are sized; see `_sizeable`. A wrapped pool is read from the answers
    /// this search holds (its price and the range that holds over), and reaching the end of
    /// that range is the end of its leg. It
    /// is an under-trade, not a dead end: a cycle with a wrapped leg is never declined.
    /// `declined` is true when the walk reached its natural end and the best size there is
    /// cannot earn the smallest profit; `_attempt` then tries no size at all. `short` is true
    /// when it stopped short of its natural end (its step cap, too little gas for another
    /// step, legs that did not compose, a broken leg), so that the size is a partial one.
    function size(bytes32 poolId, Plan calldata plan)
        external
        view
        onlySelf
        returns (uint160 limit, uint256 spend, bool declined, bool short)
    {
        (limit, spend,, declined, short) = _walk(poolId, plan);
    }
}

/// @notice The deployed Sizer module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageSizer is SizerPart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
