// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev What the pool manager and the wrapper hooks call on the hook itself.
abstract contract EntryPart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice Runs the same search without a swap, for gaps that opened on a hookless
    /// pool of SZR's market or through a change in NAV. The caller receives nothing. An
    /// outside market's hookless pool cannot be named here; see `sweep`.
    function arb(bytes32 poolId) external returns (uint256 profit) {
        Pool memory entry = pools[poolId];
        uint256 id = entry.market;
        address base = entry.home;
        bool picked = entry.picked;
        // A pool that runs no hook can only be named in SZR's market.
        if (id == 0) {
            if (!tracked[SZR_MARKET][poolId]) revert UnknownPool();
            id = SZR_MARKET;
            base = token;
            picked = true;
        }
        if (!picked) revert UnknownPool();
        if (active != 0) revert Busy();
        if (markets[id].gasLimit == 0) return 0;
        active = id;
        home = base;
        _begin(id);
        bytes memory data = abi.encode(poolId, _other(keys[poolId], base));
        profit = abi.decode(poolManager.unlock(data), (uint256));
        active = 0;
    }

    /// @notice Searches every group of market `id` that counts profit in `base`, centred
    /// on each group's first leader in turn, without a swap. This reaches the hookless heads
    /// of outside markets, which `arb` cannot name. It takes no pool, so the caller cannot
    /// steer it, and the caller receives nothing.
    function sweep(uint256 id, address base) external returns (uint256 profit) {
        if (active != 0) revert Busy();
        if (markets[id].gasLimit == 0) return 0;
        if (!_countable(id, base)) return 0;
        active = id;
        home = base;
        profit = abi.decode(poolManager.unlock(abi.encode(bytes32(0), address(0))), (uint256));
        active = 0;
    }

    /// @notice Asks a pricer about a pool and reverts, always, so that whatever the pricer
    /// did is undone, a pool-manager balance it opened included. Reverts with the answer when
    /// it gave exactly five words, and with nothing when it did not.
    /// @dev The call is an ordinary one, since a pricer may need to write to read its
    /// price. Only this contract can call it, and only `_poll` does.
    function askFrame(address pricer, bytes32 poolId) public virtual onlySelf {
        bytes memory question = abi.encodeCall(IVenuePricer.price, (keys[poolId]));
        uint256 allowance = asking;
        uint256[5] memory answer;
        bool heard;
        assembly ("memory-safe") {
            heard := call(
                allowance,
                pricer,
                0,
                add(question, 0x20),
                mload(question),
                answer,
                0xa0
            )
            if iszero(eq(returndatasize(), 0xa0)) { heard := 0 }
        }
        if (heard) revert Answer(answer);
        revert();
    }

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
        _forgetCentres();
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
