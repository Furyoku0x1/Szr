// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { ArbitrageApi } from "../arbitrage/ArbitrageApi.sol";
import { SZR_MARKET_ID } from "../arbitrage/ArbitrageLogic.sol";
import { IMarketController } from "../interfaces/IMarketController.sol";
import { HookVault } from "./HookVault.sol";

/// @notice A market vault whose primary hook is the arbitrage hook: its positions are
/// Uniswap v4 ranges in its one home pool, fixed when the vault is made. The home pool is a
/// pool the vault's market tracks, either created on the hook or a hookless venue the market
/// added, and its currencies are the vault's pair. The curator can re-range within it and
/// swap idle principal through it, and can never move liquidity to another pool.
/// @dev Disclosure: depositors fully trust the curator. The curator can move the home pool's
/// price with their own capital, then `rebalance` or `swapIdle` the vault's principal against
/// that price and push it back, which can take most of the depositors' funds. The price check
/// and the one-move-per-block rule do not stop this. Re-ranging against a reference price the
/// curator cannot move is planned.
/// @dev The hook has no liquidity permission and `modifyLiquidity` does not swap, so a
/// deposit or a withdrawal starts no search itself. A pair token that runs code on transfer
/// (ERC777-like) could still give its payer control in the middle of an unlock, and that
/// code could swap and so start a search that pays this vault. That is harmless to
/// accounting: principal is booked only from the deltas of the vault's own calls, and
/// anything else that arrives is unbooked. Swaps by the vault, which come with the curator's
/// moves, carry `gasForSwap`.
/// @dev Views (`unitsOf`, `principal`, `quoteDeposit`, `unbooked`) are inconsistent in the
/// middle of a deposit or a withdrawal, since storage is updated before the pools are. An
/// integrator reading them from a callback during one must not trust them.
contract ArbitrageVault is HookVault, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant MAX_POSITIONS = 8;
    // How far a pool's price may be from the curator's expected price, in basis points of
    // price (not of its square root).
    uint256 internal constant TOLERANCE_BPS = 100;
    uint256 internal constant KIND_MODIFY = 0;
    uint256 internal constant KIND_SWAP = 1;

    error PriceOutOfRange();
    error MovedThisBlock();
    error InsufficientIdle();
    error PositionNotEmpty();
    error InsufficientGas();
    error ZeroAmount();

    event PositionAdded(
        uint256 indexed index, bytes32 indexed poolId, int24 lower, int24 upper
    );
    event PositionDropped(uint256 indexed index);
    event Rebalanced(uint256 changes);
    event IdleSwapped(bytes32 indexed poolId, bool zeroForOne, uint256 amountIn, uint256 out);

    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        // The pool manager keys a position by this, so dropping one never renames another.
        uint256 salt;
    }

    struct Change {
        uint256 index;
        int128 liquidityDelta;
    }

    ArbitrageApi public immutable hook;
    IPoolManager public immutable poolManager;
    uint256 public immutable market;
    bytes32 public immutable homeId;
    PoolKey internal home;
    Position[] internal positions;
    uint256 internal saltCount;
    /// The last block a curator move touched the home pool in.
    uint256 internal lastMoveBlock;
    bytes32 internal transient expected;

    constructor(
        ArbitrageApi arbitrageHook,
        uint256 marketId,
        PoolKey memory home_,
        address curator_,
        IMarketController controller_,
        uint16 feeBps_
    )
        HookVault(
            curator_,
            Currency.unwrap(home_.currency0),
            Currency.unwrap(home_.currency1),
            controller_,
            feeBps_
        )
    {
        // SZR's market belongs to Liquidity, and its pools hold SZR.
        if (marketId <= SZR_MARKET_ID) revert InvalidPair();
        if (arbitrageHook.market(marketId).owner == address(0)) revert InvalidPair();
        if (token0 == arbitrageHook.token()) revert InvalidPair();
        if (token1 == arbitrageHook.token()) revert InvalidPair();
        hook = arbitrageHook;
        poolManager = arbitrageHook.poolManager();
        market = marketId;
        homeId = PoolId.unwrap(home_.toId());
        home = home_;
        _requireHome(home_);
    }

    function primaryHook() external view returns (address) {
        return address(hook);
    }

    /// @notice The first deposit, which only the curator makes. It fixes the positions and
    /// mints their total liquidity as shares, `MINIMUM_SHARES` of which are locked.
    function seed(
        Range[] calldata ranges,
        uint256[] calldata liquidity,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external onlyCurator nonReentrant {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (totalSupply() != 0) revert AlreadySeeded();
        uint256 count = ranges.length;
        if (count == 0) revert InvalidPosition();
        if (count > MAX_POSITIONS) revert TooManyPositions();
        if (liquidity.length != count) revert InvalidPosition();
        int256[] memory deltas = new int256[](count);
        uint256 total;
        for (uint256 index; index < count; index++) {
            _checkTicks(ranges[index].tickLower, ranges[index].tickUpper);
            uint128 units = SafeCastLib.toUint128(liquidity[index]);
            if (units == 0) revert InvalidPosition();
            positions.push(
                Position(ranges[index].tickLower, ranges[index].tickUpper, units, ++saltCount)
            );
            deltas[index] = int256(uint256(units));
            total += units;
        }
        (uint256 paid0, uint256 paid1) = _modifyAll(deltas, msg.sender);
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
        _open(total);
    }

    /// @notice Adds an empty range of the home pool, to be funded by `rebalance`.
    function addPosition(int24 tickLower, int24 tickUpper) external onlyCurator nonReentrant {
        if (totalSupply() == 0) revert NotSeeded();
        if (positions.length >= MAX_POSITIONS) revert TooManyPositions();
        _checkTicks(tickLower, tickUpper);
        positions.push(Position(tickLower, tickUpper, 0, ++saltCount));
        emit PositionAdded(positions.length - 1, homeId, tickLower, tickUpper);
    }

    /// @dev A range must be ordered, inside the ticks the pool manager allows and on the
    /// home pool's spacing.
    function _checkTicks(int24 lower, int24 upper) internal view {
        if (lower >= upper) revert InvalidPosition();
        if (lower < TickMath.MIN_TICK) revert InvalidPosition();
        if (upper > TickMath.MAX_TICK) revert InvalidPosition();
        int24 spacing = home.tickSpacing;
        if (lower % spacing != 0) revert InvalidPosition();
        if (upper % spacing != 0) revert InvalidPosition();
    }

    /// @notice Removes a position that holds no liquidity. The last one takes its index.
    function dropPosition(uint256 index) external onlyCurator nonReentrant {
        uint256 last = positions.length;
        if (index >= last) revert InvalidPosition();
        if (positions[index].liquidity != 0) revert PositionNotEmpty();
        positions[index] = positions[last - 1];
        positions.pop();
        emit PositionDropped(index);
    }

    /// @notice Moves liquidity between positions in one unlock: removals first, into idle
    /// principal, then additions out of idle principal. Each change names the price the
    /// curator expects in its pool, and the pool must be within `TOLERANCE_BPS` of it.
    function rebalance(
        Change[] calldata changes,
        uint160[] calldata expectedSqrtPrices,
        uint256 deadline
    ) external onlyCurator nonReentrant {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (changes.length == 0) revert InvalidPosition();
        if (changes.length != expectedSqrtPrices.length) revert InvalidPosition();
        uint256 count = positions.length;
        int256[] memory deltas = new int256[](count);
        for (uint256 index; index < changes.length; index++) {
            Change calldata move = changes[index];
            if (move.index >= count) revert InvalidPosition();
            if (move.liquidityDelta == 0) revert InvalidPosition();
            _checkMove(expectedSqrtPrices[index]);
            deltas[move.index] += move.liquidityDelta;
        }
        lastMoveBlock = block.number;
        for (uint256 index; index < changes.length; index++) {
            Position storage entry = positions[changes[index].index];
            int256 change = changes[index].liquidityDelta;
            if (change > 0) {
                entry.liquidity += SafeCastLib.toUint128(uint256(change));
            } else {
                if (uint256(-change) > entry.liquidity) revert InvalidPosition();
                entry.liquidity -= SafeCastLib.toUint128(uint256(-change));
            }
        }
        _modifyAll(deltas, address(this));
        emit Rebalanced(changes.length);
    }

    /// @notice Swaps idle principal through the home pool, in the vault's own unlock and
    /// under the same price check. A swap that brings less gas than the hook needs for a
    /// full search reverts, so a gap can never be skipped by it. The pool, and so its fee,
    /// is fixed: the curator cannot route a swap through a pool of their own making.
    function swapIdle(
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        uint160 expectedSqrtPrice,
        uint256 deadline
    ) external onlyCurator nonReentrant {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amountIn == 0) revert ZeroAmount();
        _checkMove(expectedSqrtPrice);
        lastMoveBlock = block.number;
        if (amountIn > (zeroForOne ? idle0 : idle1)) revert InsufficientIdle();
        if (gasleft() < hook.gasForSwap(market)) revert InsufficientGas();
        bytes memory payload = abi.encode(KIND_SWAP, zeroForOne, amountIn, minOut);
        expected = keccak256(payload);
        bytes memory response = poolManager.unlock(payload);
        if (expected != bytes32(0)) revert UnexpectedCallback();
        emit IdleSwapped(homeId, zeroForOne, amountIn, abi.decode(response, (uint256)));
    }

    /// @dev One move per pool per block, and the price must be where the curator expects
    /// it: within `TOLERANCE_BPS` in price, compared exactly on the squares of the square
    /// roots. There is no oracle, so a curator that moves a pool itself can still take up to
    /// the tolerance on each move.
    function _checkMove(uint160 expectedPrice) internal view {
        if (lastMoveBlock == block.number) revert MovedThisBlock();
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(homeId));
        (uint256 high, uint256 low) = _squared(price, 10_000);
        (uint256 upHigh, uint256 upLow) = _squared(expectedPrice, 10_000 + TOLERANCE_BPS);
        if (_greater(high, low, upHigh, upLow)) revert PriceOutOfRange();
        (uint256 downHigh, uint256 downLow) = _squared(expectedPrice, 10_000 - TOLERANCE_BPS);
        if (_greater(downHigh, downLow, high, low)) revert PriceOutOfRange();
    }

    /// @dev `value * value * factor` as a 512-bit number, for a value under 2^160.
    function _squared(uint256 value, uint256 factor)
        internal
        pure
        returns (uint256 high, uint256 low)
    {
        assembly ("memory-safe") {
            let squareLow := mul(value, value)
            let top := mulmod(value, value, not(0))
            let squareHigh := sub(sub(top, squareLow), lt(top, squareLow))
            low := mul(squareLow, factor)
            let carry := mulmod(squareLow, factor, not(0))
            carry := sub(sub(carry, low), lt(carry, low))
            high := add(mul(squareHigh, factor), carry)
        }
    }

    function _greater(uint256 highA, uint256 lowA, uint256 highB, uint256 lowB)
        internal
        pure
        returns (bool)
    {
        if (highA != highB) return highA > highB;
        return lowA > lowB;
    }

    /// @dev The home pool must trade on the arbitrage hook or on none, and be tracked by
    /// this vault's market. `tracked` is keyed by pool id, so a pool another market created
    /// or added is refused unless this market tracks it too. A market can untrack the pool
    /// later; the positions stay and can still be withdrawn.
    function _requireHome(PoolKey memory key) internal view {
        address hooks = address(key.hooks);
        if (hooks != address(0)) {
            if (hooks != address(hook)) revert InvalidPool();
        }
        if (!hook.tracked(market, homeId)) revert InvalidPool();
    }

    function _positionCount() internal view override returns (uint256) {
        return positions.length;
    }

    function _unitsOf(uint256 index) internal view override returns (uint256) {
        return positions[index].liquidity;
    }

    function _addFraction(uint256 shares, uint256 supply, uint256 max0, uint256 max1)
        internal
        override
        returns (uint256 paid0, uint256 paid1)
    {
        uint256 count = positions.length;
        int256[] memory deltas = new int256[](count);
        for (uint256 index; index < count; index++) {
            uint256 units =
                FixedPointMathLib.fullMulDivUp(positions[index].liquidity, shares, supply);
            positions[index].liquidity += SafeCastLib.toUint128(units);
            deltas[index] = int256(units);
        }
        (paid0, paid1) = _modifyAll(deltas, msg.sender);
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
    }

    function _removeFraction(uint256 shares, uint256 supply)
        internal
        override
        returns (uint256 out0, uint256 out1)
    {
        uint256 count = positions.length;
        int256[] memory deltas = new int256[](count);
        for (uint256 index; index < count; index++) {
            uint256 units =
                FixedPointMathLib.fullMulDiv(positions[index].liquidity, shares, supply);
            positions[index].liquidity -= SafeCastLib.toUint128(units);
            deltas[index] = -int256(units);
        }
        (out0, out1) = _modifyAll(deltas, msg.sender);
    }

    /// @dev A change of nothing collects a position's fees and no principal. Every deposit
    /// and withdrawal does so for every position, since a change collects them too.
    function _harvest() internal override {
        _modifyAll(new int256[](positions.length), address(this));
    }

    function _quoteAdd(uint256 shares, uint256 supply)
        internal
        view
        override
        returns (uint256 need0, uint256 need1)
    {
        uint256 count = positions.length;
        for (uint256 index; index < count; index++) {
            Position storage entry = positions[index];
            uint256 units = FixedPointMathLib.fullMulDivUp(entry.liquidity, shares, supply);
            (uint256 amount0, uint256 amount1) = _amounts(entry, SafeCastLib.toUint128(units));
            need0 += amount0;
            need1 += amount1;
        }
    }

    /// @dev What adding `units` costs at the pool's price now, rounded up as the pool does.
    function _amounts(Position storage entry, uint128 units)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 price,,,) = poolManager.getSlot0(PoolId.wrap(homeId));
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        if (price <= lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(lower, upper, units, true);
        } else if (price < upper) {
            amount0 = SqrtPriceMath.getAmount0Delta(price, upper, units, true);
            amount1 = SqrtPriceMath.getAmount1Delta(lower, price, units, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(lower, upper, units, true);
        }
    }

    /// @dev Changes every position in one unlock. Principal goes between `who` and the
    /// pool; fees go to the vault. The totals are what `who` paid or received. When `who`
    /// is the vault itself, principal goes to and from idle principal instead.
    function _modifyAll(int256[] memory deltas, address who)
        internal
        returns (uint256 total0, uint256 total1)
    {
        bytes memory payload = abi.encode(KIND_MODIFY, who, deltas);
        expected = keccak256(payload);
        bytes memory response = poolManager.unlock(payload);
        if (expected != bytes32(0)) revert UnexpectedCallback();
        (total0, total1) = abi.decode(response, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (expected == bytes32(0)) revert UnexpectedCallback();
        if (keccak256(data) != expected) revert UnexpectedCallback();
        expected = bytes32(0);
        if (abi.decode(data, (uint256)) == KIND_SWAP) return _runSwap(data);
        return _runModify(data);
    }

    /// @dev Removals run before additions, so what a rebalance adds can come from what it
    /// removes.
    function _runModify(bytes calldata data) internal returns (bytes memory) {
        (, address who, int256[] memory deltas) = abi.decode(data, (uint256, address, int256[]));
        (uint256 out0, uint256 out1) = _pass(deltas, who, true);
        (uint256 in0, uint256 in1) = _pass(deltas, who, false);
        uint256 total0 = out0 + in0;
        uint256 total1 = out1 + in1;
        return abi.encode(total0, total1);
    }

    function _pass(int256[] memory deltas, address who, bool removals)
        internal
        returns (uint256 total0, uint256 total1)
    {
        for (uint256 index; index < deltas.length; index++) {
            if ((deltas[index] < 0) != removals) continue;
            (uint256 amount0, uint256 amount1) = _modifyOne(index, deltas[index], who);
            total0 += amount0;
            total1 += amount1;
        }
    }

    /// @dev An exact-input swap, paid from idle principal. What is spent and received is
    /// the pool's delta, so a partial fill leaves the rest idle.
    function _runSwap(bytes calldata data) internal returns (bytes memory) {
        (, bool zeroForOne, uint128 amountIn, uint128 minOut) =
            abi.decode(data, (uint256, bool, uint128, uint128));
        BalanceDelta delta = poolManager.swap(
            home,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 spent = zeroForOne ? delta.amount0() : delta.amount1();
        int128 got = zeroForOne ? delta.amount1() : delta.amount0();
        if (spent > 0) revert InvalidDelta();
        if (got < 0) revert InvalidDelta();
        (Currency from, Currency to) =
            zeroForOne ? (home.currency0, home.currency1) : (home.currency1, home.currency0);
        uint256 paid = _settle(from, spent, address(this));
        uint256 out = _settle(to, got, address(this));
        if (out < uint256(minOut)) revert BelowMinimum();
        if (zeroForOne) {
            idle0 -= paid;
            idle1 += out;
        } else {
            idle1 -= paid;
            idle0 += out;
        }
        return abi.encode(out);
    }

    /// @dev Principal is the call's delta less its fees, and only that moves between `who`
    /// and the pool. Fees are kept by the vault, unbooked. The pool refuses to touch an
    /// empty position, so one is skipped.
    function _modifyOne(uint256 index, int256 change, address who)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage entry = positions[index];
        if (change == 0) {
            if (entry.liquidity == 0) return (0, 0);
        }
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: entry.tickLower,
            tickUpper: entry.tickUpper,
            liquidityDelta: change,
            salt: bytes32(entry.salt)
        });
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(home, params, "");
        if (fees.amount0() < 0) revert InvalidDelta();
        if (fees.amount1() < 0) revert InvalidDelta();
        BalanceDelta net = delta - fees;
        if (change == 0) {
            if (BalanceDelta.unwrap(net) != 0) revert InvalidDelta();
        }
        amount0 = _settle(home.currency0, net.amount0(), who);
        amount1 = _settle(home.currency1, net.amount1(), who);
        if (who == address(this)) _moveIdle(change, amount0, amount1);
        if (fees.amount0() != 0) {
            poolManager.take(home.currency0, address(this), uint128(fees.amount0()));
        }
        if (fees.amount1() != 0) {
            poolManager.take(home.currency1, address(this), uint128(fees.amount1()));
        }
    }

    /// @dev A removal adds what it returned to idle principal. An addition may spend only
    /// idle principal, never what the vault holds for rewards.
    function _moveIdle(int256 change, uint256 amount0, uint256 amount1) internal {
        if (change < 0) {
            idle0 += amount0;
            idle1 += amount1;
            return;
        }
        if (amount0 > idle0) revert InsufficientIdle();
        if (amount1 > idle1) revert InsufficientIdle();
        idle0 -= amount0;
        idle1 -= amount1;
    }

    /// @dev A negative amount is owed to the pool and paid by `who`; a positive one is
    /// owed by the pool and sent to `who`.
    function _settle(Currency currency, int128 amount, address who)
        internal
        returns (uint256 size)
    {
        if (amount < 0) {
            size = uint256(-int256(amount));
            poolManager.sync(currency);
            if (who == address(this)) {
                SafeTransferLib.safeTransfer(
                    Currency.unwrap(currency), address(poolManager), size
                );
            } else {
                SafeTransferLib.safeTransferFrom(
                    Currency.unwrap(currency), who, address(poolManager), size
                );
            }
            if (poolManager.settle() != size) revert TransferAmountMismatch();
        } else if (amount > 0) {
            size = uint128(amount);
            poolManager.take(currency, who, size);
        }
    }
}
