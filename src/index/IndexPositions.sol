// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "./IndexPool.sol";
import { IndexPoolFactory } from "./IndexPoolFactory.sol";

/// @notice Holds Uniswap v4 positions for their owners in any v4 pool with an index share
/// as a currency, and lets each owner take out the growth of the index shares in their own
/// position without closing it.
/// @dev Spec: `docs/specs/index-growth-harvest.md`, section 2. There is no owner and nothing
/// can be changed. Each position is its own v4 position under salt = id, so the pool manager
/// keeps every position's liquidity and fees apart. Everything is paid to the position's
/// owner, after its record is written, and native ETH goes last, once the pool manager is
/// locked again.
contract IndexPositions is ReentrancyGuard, IUnlockCallback {
    using FixedPointMathLib for uint256;
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;

    /// `last0` and `last1` are the growth baselines; a currency that is not an index share
    /// keeps zero.
    struct Record {
        address owner;
        bool share0;
        bool share1;
        int24 tickLower;
        int24 tickUpper;
        PoolKey key;
        uint256 last0;
        uint256 last1;
    }

    IPoolManager public immutable poolManager;
    address public immutable indexFactory;
    uint256 public positionCount;
    mapping(uint256 id => Record) internal records;
    /// The hash of the one unlock this contract is making, so a callback nobody here asked
    /// for is refused.
    bytes32 internal transient expected;

    error ZeroAddress();
    error NotOwner();
    error NotPoolManager();
    error UnexpectedCallback();
    error UnexpectedEther();
    error InvalidPool();
    error ZeroLiquidity();
    error DeadlinePassed();
    error InvalidDelta();
    error AboveMaximum();
    error BelowMinimum();
    error InsufficientEther();
    error TransferAmountMismatch();

    event Opened(uint256 indexed id, address indexed owner, bytes32 indexed poolId);
    /// `amount0` and `amount1` are what was paid: the principal removed plus the position's
    /// accrued v4 fees, which the removal collects.
    event Harvested(
        uint256 indexed id, uint128 liquidityRemoved, uint256 amount0, uint256 amount1
    );
    event OwnerTransferred(uint256 indexed id, address indexed to);

    constructor(IPoolManager poolManager_, address indexFactory_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (indexFactory_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        indexFactory = indexFactory_;
    }

    /// @dev ETH comes only from the pool manager, on its way to an owner in the same call.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedEther();
    }

    /// @notice Opens a position owned by the caller, who pays for it. `max0` and `max1`
    /// bound the cost; ETH sent beyond it is refunded.
    function open(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 id) {
        _checkDeadline(deadline);
        if (liquidity == 0) revert ZeroLiquidity();
        bool share0 = _isShare(key.currency0);
        bool share1 = _isShare(key.currency1);
        if (!share0) {
            if (!share1) revert InvalidPool();
        }
        // A hook that returns a delta on adding or removing liquidity could change what a
        // deposit costs or a withdrawal pays. Other hooks cannot, and the bounds cover price.
        if (key.hooks.hasPermission(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            revert InvalidPool();
        }
        if (key.hooks.hasPermission(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)) {
            revert InvalidPool();
        }
        id = ++positionCount;
        Record storage entry = records[id];
        entry.owner = msg.sender;
        entry.share0 = share0;
        entry.share1 = share1;
        entry.tickLower = tickLower;
        entry.tickUpper = tickUpper;
        entry.key = key;
        // A share whose index cannot be read gets no new position.
        _resetBaselines(entry, true);
        emit Opened(id, msg.sender, PoolId.unwrap(key.toId()));
        _modify(id, int256(uint256(liquidity)), max0, max1);
    }

    /// @notice Adds liquidity, paid by the owner. The growth so far is not harvested later.
    function increase(
        uint256 id,
        uint128 liquidity,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external payable nonReentrant {
        _checkDeadline(deadline);
        Record storage entry = _owned(id);
        if (liquidity == 0) revert ZeroLiquidity();
        _resetBaselines(entry, false);
        _modify(id, int256(uint256(liquidity)), max0, max1);
    }

    /// @notice Removes liquidity and pays the owner. The growth so far is not harvested
    /// later.
    function decrease(
        uint256 id,
        uint128 liquidity,
        uint256 min0,
        uint256 min1,
        uint256 deadline
    ) external nonReentrant {
        _checkDeadline(deadline);
        Record storage entry = _owned(id);
        if (liquidity == 0) revert ZeroLiquidity();
        _resetBaselines(entry, false);
        _modify(id, -int256(uint256(liquidity)), min0, min1);
    }

    /// @notice Pays the owner the v4 pool's own swap fees for the position.
    function collect(uint256 id)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _owned(id);
        return _paid(_modify(id, 0, 0, 0));
    }

    /// @notice Removes the share of the position that is index-share growth since the
    /// baselines, and pays it to the owner. What is paid includes the position's accrued v4
    /// fees, which the removal collects. `min0` and `min1` bound the principal removed only,
    /// and apply when nothing is, so a harvest that rounds to nothing can be refused.
    /// @dev Strict: it reverts if an index share's growth index cannot be read.
    function harvest(uint256 id, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        returns (uint128 liquidityRemoved)
    {
        _checkDeadline(deadline);
        Record storage entry = _owned(id);
        uint256 now0;
        uint256 now1;
        (liquidityRemoved, now0, now1) = _harvestable(entry, id);
        entry.last0 = now0;
        entry.last1 = now1;
        uint256 amount0;
        uint256 amount1;
        if (liquidityRemoved != 0) {
            (amount0, amount1) =
                _paid(_modify(id, -int256(uint256(liquidityRemoved)), min0, min1));
        } else {
            if (min0 != 0) revert BelowMinimum();
            if (min1 != 0) revert BelowMinimum();
        }
        emit Harvested(id, liquidityRemoved, amount0, amount1);
    }

    /// @notice Hands every right over the position to `to` in one step.
    function transferOwner(uint256 id, address to) external nonReentrant {
        Record storage entry = _owned(id);
        if (to == address(0)) revert ZeroAddress();
        entry.owner = to;
        emit OwnerTransferred(id, to);
    }

    function position(uint256 id)
        external
        view
        returns (
            address owner,
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 last0,
            uint256 last1
        )
    {
        Record storage entry = records[id];
        return (
            entry.owner,
            entry.key,
            entry.tickLower,
            entry.tickUpper,
            _liquidity(entry, id),
            entry.last0,
            entry.last1
        );
    }

    /// @notice What a harvest now would remove, at the pool's current price.
    function harvestable(uint256 id) external view returns (uint128 liquidity) {
        (liquidity,,) = _harvestable(records[id], id);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        // Never zero while set, so an unlock this contract did not start is refused.
        if (keccak256(data) != expected) revert UnexpectedCallback();
        expected = bytes32(0);
        (uint256 id, int256 change, uint256 bound0, uint256 bound1, uint256 ethIn) =
            abi.decode(data, (uint256, int256, uint256, uint256, uint256));
        Record storage entry = records[id];
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            entry.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: entry.tickLower,
                tickUpper: entry.tickUpper,
                liquidityDelta: change,
                salt: bytes32(id)
            }),
            ""
        );
        if (fees.amount0() < 0) revert InvalidDelta();
        if (fees.amount1() < 0) revert InvalidDelta();
        _checkPrincipal(delta - fees, change, bound0, bound1);
        // The whole delta settles at once: fees owed to the position offset what an
        // addition costs.
        address owner = entry.owner;
        _settle(entry.key.currency0, delta.amount0(), owner, ethIn);
        _settle(entry.key.currency1, delta.amount1(), owner, ethIn);
        return abi.encode(delta);
    }

    /// @dev Runs one liquidity change inside an unlock, then sends the owner any ETH: what
    /// was sent and not used, plus what the pool paid in ETH. Sending it after the unlock
    /// keeps the owner's code from running while the pool manager is unlocked.
    function _modify(uint256 id, int256 change, uint256 bound0, uint256 bound1)
        internal
        returns (BalanceDelta delta)
    {
        bytes memory data = abi.encode(id, change, bound0, bound1, msg.value);
        expected = keccak256(data);
        delta = abi.decode(poolManager.unlock(data), (BalanceDelta));
        if (expected != bytes32(0)) revert UnexpectedCallback();
        Record storage entry = records[id];
        int256 ether_ = int256(msg.value);
        if (entry.key.currency0.isAddressZero()) ether_ += delta.amount0();
        if (ether_ > 0) SafeTransferLib.safeTransferETH(entry.owner, uint256(ether_));
    }

    /// The share of the liquidity to remove, `p = (f0 v0 + f1 v1) / (v0 + v1)` rounded down
    /// in one division, and the growth indexes it was read at.
    function _harvestable(Record storage entry, uint256 id)
        internal
        view
        returns (uint128 removed, uint256 now0, uint256 now1)
    {
        uint256 f0;
        uint256 f1;
        (f0, now0) = _growth(entry.share0, entry.key.currency0, entry.last0);
        (f1, now1) = _growth(entry.share1, entry.key.currency1, entry.last1);
        uint128 liquidity = _liquidity(entry, id);
        (uint256 v0, uint256 v1) = _values(entry, liquidity);
        uint256 total = v0 + v1;
        if (total == 0) return (0, now0, now1);
        // Each value is at most the liquidity times 2^64, so neither product nor the
        // denominator can overflow, and the result is never above the liquidity.
        removed = uint128(uint256(liquidity).fullMulDiv(f0 * v0 + f1 * v1, total * 1e18));
    }

    /// `f = 1 - last / now`, rounded down, as WAD, or zero when the index has not risen.
    function _growth(bool share, Currency currency, uint256 last)
        internal
        view
        returns (uint256 fraction, uint256 current)
    {
        current = _current(share, currency);
        if (current <= last) return (0, current);
        fraction = 1e18 - last.fullMulDivUp(1e18, current);
    }

    /// The amounts the position holds at the pool's price, rounded down, valued in
    /// currency 1. `a0 × P` is taken through two divisions by 2^96, each bounded by the
    /// liquidity times 2^64.
    function _values(Record storage entry, uint128 liquidity)
        internal
        view
        returns (uint256 v0, uint256 v1)
    {
        (uint160 price,,,) = poolManager.getSlot0(entry.key.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        uint256 amount0;
        if (price <= lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(lower, upper, liquidity, false);
        } else if (price >= upper) {
            v1 = SqrtPriceMath.getAmount1Delta(lower, upper, liquidity, false);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(price, upper, liquidity, false);
            v1 = SqrtPriceMath.getAmount1Delta(lower, price, liquidity, false);
        }
        v0 = amount0.fullMulDiv(price, Q96).fullMulDiv(price, Q96);
    }

    /// Not `strict`, an index that cannot be read sets its baseline to the maximum, so no
    /// growth counts until a harvest reads it again: an index pool that has outgrown its
    /// bounds never locks an owner's liquidity in.
    function _resetBaselines(Record storage entry, bool strict) internal {
        entry.last0 = _baseline(entry.share0, entry.key.currency0, strict);
        entry.last1 = _baseline(entry.share1, entry.key.currency1, strict);
    }

    function _baseline(bool share, Currency currency, bool strict)
        internal
        view
        returns (uint256)
    {
        if (strict) return _current(share, currency);
        if (!share) return 0;
        try IndexPool(Currency.unwrap(currency)).growthIndex() returns (uint256 value) {
            return value;
        } catch {
            return type(uint256).max;
        }
    }

    function _current(bool share, Currency currency) internal view returns (uint256) {
        if (!share) return 0;
        return IndexPool(Currency.unwrap(currency)).growthIndex();
    }

    function _isShare(Currency currency) internal view returns (bool) {
        return IndexPoolFactory(indexFactory).isPool(Currency.unwrap(currency));
    }

    function _liquidity(Record storage entry, uint256 id) internal view returns (uint128 l) {
        (l,,) = poolManager.getPositionInfo(
            entry.key.toId(), address(this), entry.tickLower, entry.tickUpper, bytes32(id)
        );
    }

    /// @dev An addition may only cost, a removal may only return, and a collect moves no
    /// principal. The bounds apply to the principal alone, not to fees.
    function _checkPrincipal(
        BalanceDelta principal,
        int256 change,
        uint256 bound0,
        uint256 bound1
    ) internal pure {
        int128 one = principal.amount0();
        int128 two = principal.amount1();
        if (change == 0) {
            if (one != 0) revert InvalidDelta();
            if (two != 0) revert InvalidDelta();
        } else if (change > 0) {
            if (one > 0) revert InvalidDelta();
            if (two > 0) revert InvalidDelta();
            if (uint256(-int256(one)) > bound0) revert AboveMaximum();
            if (uint256(-int256(two)) > bound1) revert AboveMaximum();
        } else {
            if (one < 0) revert InvalidDelta();
            if (two < 0) revert InvalidDelta();
            if (uint128(one) < bound0) revert BelowMinimum();
            if (uint128(two) < bound1) revert BelowMinimum();
        }
    }

    /// Tokens come from the owner straight to the pool manager and go straight to the
    /// owner. ETH is paid from what the call was sent and taken here, to send last.
    function _settle(Currency currency, int128 amount, address owner, uint256 ethIn) internal {
        if (amount > 0) {
            address to = currency.isAddressZero() ? address(this) : owner;
            poolManager.take(currency, to, uint128(amount));
            return;
        }
        if (amount == 0) return;
        uint256 owed = uint256(-int256(amount));
        if (currency.isAddressZero()) {
            if (owed > ethIn) revert InsufficientEther();
            poolManager.settle{ value: owed }();
            return;
        }
        poolManager.sync(currency);
        SafeTransferLib.safeTransferFrom(
            Currency.unwrap(currency), owner, address(poolManager), owed
        );
        if (poolManager.settle() != owed) revert TransferAmountMismatch();
    }

    /// What a removal or collect paid, from the delta, which is never negative there.
    function _paid(BalanceDelta delta)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return (uint128(delta.amount0()), uint128(delta.amount1()));
    }

    function _owned(uint256 id) internal view returns (Record storage entry) {
        entry = records[id];
        if (entry.owner != msg.sender) revert NotOwner();
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlinePassed();
    }
}
