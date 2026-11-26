// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice What an index pool calls around every swap that its hook did not make itself.
interface IIndexHook {
    /// The one failure an approved hook may use to refuse a swap, from `beforeSwap` only.
    error Blocked();

    /// Called by the pool before a swap is priced. `sender` is the swap's caller.
    function beforeSwap(address sender, address tokenIn, address tokenOut) external;
    /// Called by the pool after a swap is settled.
    function afterSwap(
        address sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    ) external;
}
