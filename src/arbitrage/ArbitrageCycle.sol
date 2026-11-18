// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `execute`, one whole cycle.
abstract contract CyclePart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice One whole cycle. It either nets at least `minimumProfit` SZR with no other
    /// token left owing, or reverts. The SZR stays as a credit until the search retires it.
    function execute(bytes32 poolId, Plan calldata plan)
        external
        onlySelf
        returns (uint256 profit)
    {
        (uint256 open, int256 held) = _tally();
        profit = plan.buying ? _buyCycle(poolId, plan) : _sellCycle(poolId, plan);
        if (profit == 0) revert Unprofitable();
        if (profit < minimumProfit[active][home]) revert Unprofitable();
        if (asking != 0) _requireTidy(open, held, profit);
        emit Arbitraged(poolId, plan.venue, plan.buying, profit);
    }
}

/// @notice The deployed Cycle module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageCycle is CyclePart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
