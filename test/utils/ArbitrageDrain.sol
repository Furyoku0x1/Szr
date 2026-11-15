// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestAsset } from "./TestAsset.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

/// @dev A router that borrows the pool manager's balance of a token with `take`, swaps, and
/// repays at the end, as anyone controlling an unlock may. While the balance is gone the
/// hook's own takes of that token cannot be filled. `leave` is what stays in the pool
/// manager: zero takes it all, and the largest number takes nothing, which is the control.
/// ETH it needs for the swap or the repayment comes from its own balance.
contract DrainRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    uint256 internal constant NONE = type(uint256).max;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    receive() external payable { }

    function trade(
        PoolKey calldata pool,
        address input,
        uint256 amount,
        address drained,
        uint256 leave
    ) external returns (uint256 received) {
        bytes memory result = manager.unlock(
            abi.encode(msg.sender, pool, input, amount, drained, leave, address(0), "")
        );
        return abi.decode(result, (uint256));
    }

    /// Takes the whole balance of `drained`, then calls `target`. `arb` and `sweep` unlock
    /// the pool manager themselves, so they cannot run inside someone else's unlock.
    function callWhileDrained(address drained, address target, bytes calldata data) external {
        PoolKey memory none;
        manager.unlock(abi.encode(msg.sender, none, address(0), 0, drained, 0, target, data));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            address payer,
            PoolKey memory pool,
            address input,
            uint256 amount,
            address drained,
            uint256 leave,
            address target,
            bytes memory call
        ) = abi.decode(
            data, (address, PoolKey, address, uint256, address, uint256, address, bytes)
        );
        uint256 grabbed = _grab(drained, leave);
        if (target != address(0)) {
            (bool ok, bytes memory reason) = target.call(call);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            return "";
        }
        (uint256 spent, uint256 received, Currency output) = _swap(pool, input, amount);
        if (grabbed != 0) _repay(drained, grabbed);
        _pay(payer, input, spent);
        if (received != 0) manager.take(output, payer, received);
        return abi.encode(received);
    }

    function _grab(address drained, uint256 leave) internal returns (uint256 grabbed) {
        if (leave == NONE) return 0;
        uint256 held = drained == address(0)
            ? address(manager).balance
            : TestAsset(drained).balanceOf(address(manager));
        if (held <= leave) return 0;
        grabbed = held - leave;
        manager.take(Currency.wrap(drained), address(this), grabbed);
    }

    function _swap(PoolKey memory pool, address input, uint256 amount)
        internal
        returns (uint256 spent, uint256 received, Currency output)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        output = zeroForOne ? pool.currency1 : pool.currency0;
    }

    function _pay(address payer, address input, uint256 spent) internal {
        if (spent == 0) return;
        manager.sync(Currency.wrap(input));
        if (input == address(0)) {
            manager.settle{ value: spent }();
            return;
        }
        TestAsset(input).transferFrom(payer, address(manager), spent);
        manager.settle();
    }

    function _repay(address drained, uint256 grabbed) internal {
        manager.sync(Currency.wrap(drained));
        if (drained == address(0)) {
            manager.settle{ value: grabbed }();
        } else {
            TestAsset(drained).transfer(address(manager), grabbed);
            manager.settle();
        }
    }
}
