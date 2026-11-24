// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `search` and the unlock callback. A
/// separate contract so the monolithic test probe can reuse it.
abstract contract SearchPart is ArbitrageLogic, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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
}

/// @notice The deployed Search module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageSearch is SearchPart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
