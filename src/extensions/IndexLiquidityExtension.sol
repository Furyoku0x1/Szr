// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Liquidity } from "../Liquidity.sol";
import { IndexPool } from "../index/IndexPool.sol";
import { IndexPoolFactory } from "../index/IndexPoolFactory.sol";
import { IndexPositions } from "../index/IndexPositions.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import { MetricSwapping } from "./MetricSwapping.sol";

/// @notice The protocol's own positions in `IndexPositions`, owned by this contract and run
/// by Liquidity's manager, and the joins and exits that turn tokens into index shares and
/// back. Harvested shares are sold with the inherited `swap` and their SZR retired with
/// `toCore`.
/// @dev Spec: `docs/specs/index-growth-harvest.md`, section 3. Tokens leave only into v4
/// pools, into index pools by `join`, into `IndexPositions` for positions owned here, and
/// to Core. Every approval is for exactly what the call takes and is cleared after it.
/// There is no `transferOwner`: the positions never leave this contract.
contract IndexLiquidityExtension is MetricSwapping {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IndexPositions public immutable positions;
    IndexPoolFactory public immutable indexFactory;

    error InvalidPositions();
    error UnknownIndexPool();

    event IndexPositionChanged(uint256 indexed id, int256 liquidity);
    event IndexPositionCollected(uint256 indexed id, uint256 amount0, uint256 amount1);
    event IndexPositionHarvested(uint256 indexed id, uint128 liquidity);

    constructor(
        Liquidity liquidity_,
        address hook_,
        IMetricFactory metricFactory_,
        IndexPositions positions_,
        IndexPoolFactory indexFactory_
    ) MetricSwapping(liquidity_, hook_, metricFactory_) {
        if (address(positions_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(indexFactory_) == address(0)) revert ZeroAddress();
        // Positions on another pool manager or factory could not be priced or checked here.
        if (positions_.poolManager() != poolManager) revert InvalidPositions();
        if (positions_.indexFactory() != address(indexFactory_)) revert InvalidPositions();
        positions = positions_;
        indexFactory = indexFactory_;
    }

    /// @dev `IndexPositions` pays ETH here from a withdrawal, a collect, a harvest or the
    /// refund of an increase, on top of what the base takes.
    receive() external payable override {
        if (msg.sender == address(positions)) return;
        if (msg.sender == weth) return;
        if (msg.sender == address(poolManager)) return;
        revert UnexpectedEther();
    }

    /// @notice Opens a position owned here. `max0` and `max1` bound what it costs.
    function openIndexPosition(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 id) {
        _checkHook(key);
        uint256 value = _approveCost(key, tickLower, tickUpper, liquidity);
        id = positions.open{ value: value }(
            key, tickLower, tickUpper, liquidity, max0, max1, deadline
        );
        _clear(key);
        emit IndexPositionChanged(id, int256(uint256(liquidity)));
    }

    function increaseIndexPosition(
        uint256 id,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external nonReentrant onlyManager {
        (, PoolKey memory key, int24 tickLower, int24 tickUpper,,,) = positions.position(id);
        // A position handed to this contract by `transferOwner` could sit on any hook.
        _checkHook(key);
        uint256 value = _approveCost(key, tickLower, tickUpper, liquidity);
        // Fees the position has earned in ETH come back here as a refund.
        positions.increase{ value: value }(id, liquidity, max0, max1, deadline);
        _clear(key);
        emit IndexPositionChanged(id, int256(uint256(liquidity)));
    }

    /// @notice Removes liquidity; the tokens come here.
    function decreaseIndexPosition(
        uint256 id,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        uint256 deadline
    ) external nonReentrant onlyManager {
        positions.decrease(id, liquidity, min0, min1, deadline);
        emit IndexPositionChanged(id, -int256(uint256(liquidity)));
    }

    /// @notice Pulls the position's v4 swap fees here.
    function collectIndexPosition(uint256 id)
        external
        nonReentrant
        onlyManager
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = positions.collect(id);
        emit IndexPositionCollected(id, amount0, amount1);
    }

    /// @notice Takes the position's index-share growth out to here.
    function harvestIndexPosition(uint256 id, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        onlyManager
        returns (uint128 removed)
    {
        removed = positions.harvest(id, min0, min1, deadline);
        emit IndexPositionHarvested(id, removed);
    }

    /// @notice Mints `shares` of an index pool of the factory, paying exactly what it asks.
    function joinIndex(address pool, uint256 shares, uint256[] calldata maxIn, uint256 deadline)
        external
        nonReentrant
        onlyManager
    {
        _checkIndexPool(pool);
        address[] memory list = IndexPool(pool).tokens();
        // The pool takes exactly what its preview says, so nothing is left approved.
        uint256[] memory amounts = IndexPool(pool).previewJoin(shares);
        for (uint256 index; index < list.length; index++) {
            SafeTransferLib.safeApprove(list[index], pool, amounts[index]);
        }
        IndexPool(pool).join(shares, maxIn, deadline);
        for (uint256 index; index < list.length; index++) {
            SafeTransferLib.safeApprove(list[index], pool, 0);
        }
    }

    /// @notice Burns `shares` for the pool's tokens, which come here. Tokens in
    /// `deferring` are claimed later with `claimIndex`.
    function exitIndex(
        address pool,
        uint256 shares,
        uint256[] calldata minOut,
        address[] calldata deferring,
        uint256 deadline
    ) external nonReentrant onlyManager {
        _checkIndexPool(pool);
        IndexPool(pool).exit(shares, minOut, deferring, deadline);
    }

    function claimIndex(address pool, address token)
        external
        nonReentrant
        onlyManager
        returns (uint256 amount)
    {
        _checkIndexPool(pool);
        amount = IndexPool(pool).claim(token);
    }

    /// Protocol funds sit only behind no hook or the arbitrage hook, as in the v4 extension:
    /// any other hook could refuse a withdrawal.
    function _checkHook(PoolKey memory key) internal view {
        if (address(key.hooks) != address(0)) {
            if (address(key.hooks) != hook) revert InvalidPool();
        }
    }

    function _checkIndexPool(address pool) internal view {
        if (!indexFactory.isPool(pool)) revert UnknownIndexPool();
    }

    /// Approves `IndexPositions` for the principal an addition of `liquidity` costs at the
    /// pool's price, rounded up as the pool manager rounds it, and returns the ETH to send
    /// when currency 0 is native. Fees the position has earned only lower what is taken.
    function _approveCost(PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 value)
    {
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        uint256 amount0;
        uint256 amount1;
        if (price <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (price >= sqrtUpper) {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(price, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, price, liquidity, true);
        }
        _approve(key.currency0, amount0);
        _approve(key.currency1, amount1);
        if (key.currency0.isAddressZero()) value = amount0;
    }

    function _clear(PoolKey memory key) internal {
        _approve(key.currency0, 0);
        _approve(key.currency1, 0);
    }

    function _approve(Currency currency, uint256 amount) internal {
        if (currency.isAddressZero()) return;
        SafeTransferLib.safeApprove(Currency.unwrap(currency), address(positions), amount);
    }

    function _unlockAction(uint256, bytes memory)
        internal
        pure
        override
        returns (bytes memory)
    {
        revert UnexpectedCallback();
    }
}
