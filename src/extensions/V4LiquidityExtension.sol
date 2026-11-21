// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Liquidity } from "../Liquidity.sol";
import { LiquidityExtension } from "./LiquidityExtension.sol";

/// @notice Holds Uniswap v4 positions in pools without SZR, funded by Liquidity. A pool
/// must be a registered route, and run no hook or the arbitrage hook: any other hook could
/// have liquidity callbacks and hold a position.
/// @dev Positions are owned by this contract. Fees land here as plain balances.
contract V4LiquidityExtension is LiquidityExtension {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant KIND_MODIFY = 1;

    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    uint256 public positionCount;
    mapping(uint256 id => Position) public positions;

    error InvalidPool();
    error InvalidRange();
    error UnknownPosition();
    error ZeroLiquidity();

    event PositionAdded(uint256 indexed id, bytes32 indexed poolId, int24 lower, int24 upper);
    event Deployed(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Withdrawn(uint256 indexed id, uint256 amount0, uint256 amount1);
    event Collected(uint256 indexed id);

    constructor(Liquidity liquidity_, address hook_) LiquidityExtension(liquidity_, hook_) { }

    function addPosition(PoolKey calldata pool, int24 tickLower, int24 tickUpper)
        external
        nonReentrant
        onlyManager
        returns (uint256 id)
    {
        if (!routeRegistered[PoolId.unwrap(pool.toId())]) revert UnknownPool();
        if (Currency.unwrap(pool.currency0) == szr) revert InvalidPool();
        if (Currency.unwrap(pool.currency1) == szr) revert InvalidPool();
        if (address(pool.hooks) != address(0)) {
            if (address(pool.hooks) != hook) revert InvalidPool();
        }
        if (tickLower >= tickUpper) revert InvalidRange();
        if (tickLower % pool.tickSpacing != 0) revert InvalidRange();
        if (tickUpper % pool.tickSpacing != 0) revert InvalidRange();
        if (tickLower < TickMath.minUsableTick(pool.tickSpacing)) revert InvalidRange();
        if (tickUpper > TickMath.maxUsableTick(pool.tickSpacing)) revert InvalidRange();
        id = positionCount++;
        positions[id] = Position(pool, tickLower, tickUpper);
        emit PositionAdded(id, PoolId.unwrap(pool.toId()), tickLower, tickUpper);
    }

    /// @notice Adds liquidity. `max0` and `max1` bound what the principal costs.
    function deploy(uint256 id, uint128 amount, uint256 max0, uint256 max1, uint256 deadline)
        external
        nonReentrant
        onlyManager
    {
        if (amount == 0) revert ZeroLiquidity();
        (uint256 paid0, uint256 paid1) =
            _modify(id, int256(uint256(amount)), max0, max1, deadline);
        emit Deployed(id, paid0, paid1);
    }

    /// @notice Removes liquidity. The tokens stay here. `min0` and `min1` bound what comes
    /// back.
    function withdraw(uint256 id, uint128 amount, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        onlyManager
    {
        if (amount == 0) revert ZeroLiquidity();
        (uint256 got0, uint256 got1) =
            _modify(id, -int256(uint256(amount)), min0, min1, deadline);
        emit Withdrawn(id, got0, got1);
    }

    /// @notice Pulls a position's fees in with a zero-liquidity change.
    function collect(uint256 id) external nonReentrant onlyManager {
        _modify(id, 0, 0, 0, block.timestamp);
        emit Collected(id);
    }

    function _modify(
        uint256 id,
        int256 change,
        uint256 bound0,
        uint256 bound1,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (id >= positionCount) revert UnknownPosition();
        bytes memory response = _unlock(KIND_MODIFY, abi.encode(id, change, bound0, bound1));
        (amount0, amount1) = abi.decode(response, (uint256, uint256));
    }

    function _unlockAction(uint256 kind, bytes memory payload)
        internal
        override
        returns (bytes memory)
    {
        if (kind != KIND_MODIFY) revert UnexpectedCallback();
        (uint256 id, int256 change, uint256 bound0, uint256 bound1) =
            abi.decode(payload, (uint256, int256, uint256, uint256));
        Position storage entry = positions[id];
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            entry.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: entry.tickLower,
                tickUpper: entry.tickUpper,
                liquidityDelta: change,
                salt: bytes32(id + 1)
            }),
            ""
        );
        if (fees.amount0() < 0) revert InvalidDelta();
        if (fees.amount1() < 0) revert InvalidDelta();
        BalanceDelta principal = delta - fees;
        (uint256 amount0, uint256 amount1) = _checkPrincipal(principal, change, bound0, bound1);
        // The whole delta settles at once: fees owed to us offset what an addition costs.
        _settle(entry.key.currency0, delta.amount0());
        _settle(entry.key.currency1, delta.amount1());
        return abi.encode(amount0, amount1);
    }

    /// @dev An addition may only cost, a removal may only return, and a collect moves no
    /// principal. The bounds apply to the principal alone, not to fees.
    function _checkPrincipal(
        BalanceDelta principal,
        int256 change,
        uint256 bound0,
        uint256 bound1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        int128 one = principal.amount0();
        int128 two = principal.amount1();
        if (change == 0) {
            if (one != 0) revert InvalidDelta();
            if (two != 0) revert InvalidDelta();
        } else if (change > 0) {
            if (one > 0) revert InvalidDelta();
            if (two > 0) revert InvalidDelta();
            amount0 = uint256(-int256(one));
            amount1 = uint256(-int256(two));
            if (amount0 > bound0) revert AboveMaximum();
            if (amount1 > bound1) revert AboveMaximum();
        } else {
            if (one < 0) revert InvalidDelta();
            if (two < 0) revert InvalidDelta();
            amount0 = uint128(one);
            amount1 = uint128(two);
            if (amount0 < bound0) revert BelowMinimum();
            if (amount1 < bound1) revert BelowMinimum();
        }
    }

    function _settle(Currency currency, int128 amount) internal {
        if (amount < 0) _pay(currency, uint256(-int256(amount)));
        else if (amount > 0) _take(currency, uint128(amount));
    }
}
