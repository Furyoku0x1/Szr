// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev What the pool manager and the wrapper hooks call on the hook itself.
abstract contract EntryPart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice Lets the hook of a wrapped venue ask for the searches that hook's owner chose
    /// for it (`setVenueTrigger`), around a swap that hook is filling inside the current
    /// unlock. A trigger runs one search from the swapped pool when that pool holds the
    /// trigger's token, and otherwise one from each group's first leader, as `sweep` does.
    /// Either way it runs within this unlock and with the swap's `before` flag, so the
    /// search before a swap keeps the larger gas floor that leaves room for the swap and
    /// the search after it. It is best effort: with too little gas a search is skipped and
    /// reported, and a failed one is undone and reported. Nothing here reverts once the
    /// caller is checked, so the wrapper's swap never depends on it.
    /// @dev When the swapped pool holds the trigger's token, the search before the fill
    /// closes gaps between the swapped pool and plain pools, so a swap that brings too
    /// little gas keeps the value of that gap. This is accepted: triggers are best effort
    /// by decision, and the same pool can be traded directly. `sender` is the swap's
    /// sender, whose waiting payment `_release` then credits, as for the hook's own pools;
    /// as for those, a cycle that fails is set aside. A trigger whose market has stopped
    /// tracking the pool, or no longer counts profit in its token, stays registered but is
    /// skipped.
    /// @dev A search only runs with `VENUE_RESERVE` to spare, and within the trigger's cap;
    /// see `_trigger`. A pay-after swap sized near the pool manager's whole holding of its
    /// input token can still fail `Drained` in the wrapper when the search before it traded
    /// the wrapper and moved that token out of the pool manager. When the pool holds the
    /// trigger's token, the search before the fill normally does trade the wrapper first.
    /// This is accepted.
    function venueSearch(bytes32 poolId, bool before, address sender) external {
        if (msg.sender != address(keys[poolId].hooks)) revert NotTrusted();
        if (pricers[msg.sender] == address(0)) revert NotTrusted();
        if (active != 0) return;
        if (!poolManager.isUnlocked()) return;
        Trigger[] memory list = triggers[poolId];
        for (uint256 index; index < list.length; index++) {
            _trigger(poolId, list[index], before, sender);
        }
        remembered = bytes32(0);
    }

    /// @notice Closes any gap that is already open before the swap trades, so the swap
    /// executes at the aligned price and the gap's value goes to the protocol (and, outside
    /// SZR's market, to the market) instead of the swapper.
    function beforeSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _run(sender, pool, true);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Closes the gap the swap itself just opened.
    function afterSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _run(sender, pool, false);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev The hook takes ETH from the pool manager and wraps it at once, and WETH sends
    /// it ETH when it unwraps. Anyone can have the pool manager send ETH here from their
    /// own unlock; that ETH is theirs to lose, and nothing reads the hook's balance.
    receive() external payable {
        if (msg.sender == address(poolManager)) return;
        if (msg.sender != backingAsset) revert NotPoolManager();
    }
}
