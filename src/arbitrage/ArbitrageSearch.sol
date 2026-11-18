// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `search`, `searchMany`, `arb`, `sweep` and the unlock callback. A
/// separate contract so the monolithic test probe can reuse it.
abstract contract SearchPart is ArbitrageLogic, IUnlockCallback {
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

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bytes32 poolId, address partner) = abi.decode(data, (bytes32, address));
        if (poolId == bytes32(0)) return abi.encode(_sweep());
        return abi.encode(_search(poolId, partner, true, false, address(0)));
    }

    function search(
        bytes32 poolId,
        uint256 id,
        address base,
        address partner,
        bool capped,
        bool before,
        address payer
    ) external onlySelf returns (uint256 profit) {
        active = id;
        home = base;
        _begin(id);
        profit = _search(poolId, partner, capped, before, payer);
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
}

/// @notice The deployed Search module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageSearch is SearchPart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
