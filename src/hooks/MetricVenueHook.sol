// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "../interfaces/metric/IMetricPool.sol";

/// @notice The one call a wrapper makes on the arbitrage hook.
interface IVenueSearch {
    function venueSearch(bytes32 poolId, bool before, address sender) external;

    function setVenueTrigger(
        uint256 market,
        bytes32 poolId,
        address token,
        uint32 gasCap,
        bool on
    ) external;
}

/// @notice Wraps a Metric pool as a Uniswap v4 pool. The v4 pool holds no liquidity: every
/// swap is filled on Metric inside `beforeSwap`, and the hook returns a delta that takes the
/// whole specified amount, so v4 itself swaps nothing.
/// @dev A swap fills completely or reverts `Incomplete`. The v4 price limit is converted to
/// Metric's and honoured by Metric, so a limit that stops the fill short reverts.
///
/// Delta convention (v4's custom curve): the hook's own delta moves by the returned amounts,
/// a positive one being a credit the hook may `take`. The swapper gets the opposite.
///   exact input  (amountSpecified < 0): specified = +input,  unspecified = -output
///   exact output (amountSpecified > 0): specified = -output, unspecified = +input
/// The hook takes the input from the pool manager inside Metric's callback and settles the
/// output Metric sent it, so it ends every swap owing and owed nothing.
///
/// The pool manager must already hold the input when Metric asks for it (`Drained`
/// otherwise). A router that pays after the swap therefore cannot trade more than the pool
/// manager holds of the input token.
contract MetricVenueHook is IMetricSwapCallback {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    struct Binding {
        address pool;
        // True when the v4 pool's currency0 is the Metric pool's token1.
        bool flipped;
        // Set by `unbind`: every later swap reverts. The v4 pool stays initialized, so the
        // pair cannot be bound again.
        bool disabled;
        uint128 scale0;
        uint128 scale1;
    }

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager public immutable poolManager;
    address public immutable metricFactory;
    /// @notice The arbitrage hook whose searches run around each swap. Zero means none.
    address public immutable arbitrage;

    address public owner;
    address public nominee;
    mapping(PoolId => Binding) public bindings;

    // What the callback needs while a Metric swap is in progress.
    address internal transient active;
    address internal transient inputToken;
    bool internal transient metricZeroForOne;
    // The pool's own token the swapper marked as synced before the swap, put back once the
    // output is settled; see `_credit`.
    address internal transient marked;

    event Bound(PoolId indexed poolId, address indexed metricPool);
    event Unbound(PoolId indexed poolId);
    event OwnerNominated(address indexed nominee);
    event OwnerSet(address indexed owner);

    error InvalidHookAddress();
    error NotOwner();
    error NotNominee();
    error NotPoolManager();
    error InvalidKey();
    error WrongTokens();
    error WrongFactory();
    error AlreadyBound();
    error NotBound();
    error NotInitializer();
    error LiquidityNotAllowed();
    error NotMetricPool();
    error Drained();
    error Incomplete();
    error AmountTooLarge();
    error BadFill();
    error NoHook();

    constructor(address firstOwner, address factory, IPoolManager manager, address searcher) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != FLAGS) revert InvalidHookAddress();
        // Zero means no arbitrage hook. Any other address with no code would make every swap on
        // every binding revert for good.
        if (searcher != address(0)) {
            if (searcher.code.length == 0) revert NoHook();
        }
        owner = firstOwner;
        metricFactory = factory;
        poolManager = manager;
        arbitrage = searcher;
        emit OwnerSet(firstOwner);
    }

    // ---------------------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------------------

    function nominateOwner(address next) external {
        if (msg.sender != owner) revert NotOwner();
        nominee = next;
        emit OwnerNominated(next);
    }

    function acceptOwnership() external {
        if (nominee == address(0)) revert NotNominee();
        if (msg.sender != nominee) revert NotNominee();
        owner = msg.sender;
        nominee = address(0);
        emit OwnerSet(msg.sender);
    }

    /// @notice Chooses which markets' searches run around swaps in a bound pool, and for which
    /// profit token, by registering them with the arbitrage hook. Only this hook may do so
    /// there, so the choice is the owner's: the owner decides which markets a Metric swap
    /// searches, and a market's own owner cannot make these swaps pay for its searches. The
    /// arbitrage hook enforces its own limits (two per pool, a tracked pool, a countable
    /// token, `gasCap` at most `MAX_TRIGGER_GAS`) and its pricer requirement.
    function setTrigger(
        PoolKey calldata key,
        uint256 market,
        address token,
        uint32 gasCap,
        bool on
    ) external {
        if (msg.sender != owner) revert NotOwner();
        if (arbitrage == address(0)) revert NotBound();
        PoolId id = key.toId();
        if (bindings[id].pool == address(0)) revert NotBound();
        IVenueSearch(arbitrage).setVenueTrigger(market, PoolId.unwrap(id), token, gasCap, on);
    }

    // ---------------------------------------------------------------------------------
    // Binding
    // ---------------------------------------------------------------------------------

    /// @notice Binds `key` to a Metric pool of the same two tokens and creates the v4 pool.
    function bind(PoolKey calldata key, address metricPool) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(key.hooks) != address(this)) revert InvalidKey();
        if (key.fee != 0) revert InvalidKey();
        if (key.tickSpacing != 1) revert InvalidKey();
        if (key.currency0.isAddressZero()) revert InvalidKey();
        PoolId id = key.toId();
        if (bindings[id].pool != address(0)) revert AlreadyBound();

        // The pool's own claim about its factory proves nothing, so the factory is asked.
        if (!IMetricFactory(metricFactory).isPool(metricPool)) revert WrongFactory();
        MetricImmutables memory imm = IMetricPool(metricPool).getImmutables();
        if (imm.factory != metricFactory) revert WrongFactory();
        bool flipped = _orientation(key, imm);
        if (imm.token0ScaleMultiplier > type(uint128).max) revert WrongTokens();
        if (imm.token1ScaleMultiplier > type(uint128).max) revert WrongTokens();
        Binding memory b = Binding(
            metricPool,
            flipped,
            false,
            uint128(imm.token0ScaleMultiplier),
            uint128(imm.token1ScaleMultiplier)
        );
        bindings[id] = b;
        emit Bound(id, metricPool);

        (uint128 sell, uint128 buy) = IMetricPool(metricPool).getSellAndBuyPrices();
        uint256 mid = (uint256(sell) + uint256(buy)) / 2;
        poolManager.initialize(key, _sqrtPriceFromMetric(mid, b));
    }

    /// @notice Disables a binding, as a safety valve if the Metric pool's admin turns
    /// hostile. Swaps on the pool revert `NotBound` from then on.
    function unbind(PoolKey calldata key) external {
        if (msg.sender != owner) revert NotOwner();
        PoolId id = key.toId();
        Binding storage b = bindings[id];
        if (b.pool == address(0)) revert NotBound();
        b.disabled = true;
        emit Unbound(id);
    }

    function _orientation(PoolKey calldata key, MetricImmutables memory imm)
        internal
        pure
        returns (bool flipped)
    {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == imm.token0) {
            if (c1 == imm.token1) return false;
        }
        if (c0 == imm.token1) {
            if (c1 == imm.token0) return true;
        }
        revert WrongTokens();
    }

    /// @dev The pool holds no liquidity, so its price only has to be a valid one.
    function _sqrtPriceFromMetric(uint256 mid, Binding memory b)
        internal
        pure
        returns (uint160)
    {
        uint256 s0 = b.scale0;
        uint256 s1 = b.scale1;
        // The v4 price is raw token1 per raw token0, times 2^192, before the square root.
        uint256 ratio = b.flipped
            ? FullMath.mulDiv(s1 << 128, 1 << 128, mid * s0)
            : FullMath.mulDiv(mid, s0 << 128, s1);
        uint256 root = FixedPointMathLib.sqrt(ratio);
        if (root < TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE;
        if (root >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(root);
    }

    // ---------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (sender != address(this)) revert NotInitializer();
        if (bindings[key.toId()].pool == address(0)) revert NotBound();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert LiquidityNotAllowed();
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Binding memory b = bindings[key.toId()];
        if (b.pool == address(0)) revert NotBound();
        if (b.disabled) revert NotBound();

        bool exactIn = params.amountSpecified < 0;
        uint256 asked =
            exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (asked > uint256(uint128(type(int128).max))) revert AmountTooLarge();

        _search(key, true, sender);
        _credit(key, sender);
        (int128 paid, int128 got) =
            _fill(key, params, b, exactIn ? int256(asked) : -int256(asked));
        if (paid < 0) revert BadFill();
        if (got < 0) revert BadFill();
        if (uint128(exactIn ? paid : got) != asked) revert Incomplete();
        _settleOutput(params.zeroForOne ? key.currency1 : key.currency0, uint128(got));

        BeforeSwapDelta delta =
            exactIn ? toBeforeSwapDelta(paid, -got) : toBeforeSwapDelta(-got, paid);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @notice Searches again for what the fill just opened.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _search(key, false, sender);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Asks the arbitrage hook to search, and ignores whatever happens: the swap and
    /// its settlement must be the same whatever the search does. Called before this hook
    /// sets `active`, so a search that trades this pool as a venue can fill it.
    function _search(PoolKey calldata key, bool before, address sender) internal {
        if (arbitrage == address(0)) return;
        try IVenueSearch(arbitrage).venueSearch(PoolId.unwrap(key.toId()), before, sender) { }
            catch { }
    }

    /// @dev Swaps on Metric with this hook as recipient. `amount` is already in Metric's sign.
    /// Returns what the pool took in and what it sent out, in raw units.
    function _fill(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        Binding memory b,
        int256 amount
    ) internal returns (int128 paid, int128 got) {
        bool metricZfo = params.zeroForOne != b.flipped;
        uint128 limit = _limitX64(params.sqrtPriceLimitX96, params.zeroForOne, metricZfo, b);
        active = b.pool;
        inputToken = Currency.unwrap(params.zeroForOne ? key.currency0 : key.currency1);
        metricZeroForOne = metricZfo;
        (int128 amount0, int128 amount1) =
            IMetricPool(b.pool).swap(address(this), metricZfo, int128(amount), limit, "", "");
        active = address(0);
        (paid, got) = metricZfo ? (amount0, -amount1) : (amount1, -amount0);
    }

    /// @dev Metric asks for the input before it checks its own balance; the pool manager
    /// pays it straight to the pool.
    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
        override
    {
        if (msg.sender != active) revert NotMetricPool();
        int256 owed = metricZeroForOne ? amount0Delta : amount1Delta;
        if (owed <= 0) return;
        address token = inputToken;
        // The pool manager's own transfer failure would reach callers wrapped twice, which
        // nothing upstream can read, so a shortage is named here first.
        if (SafeTransferLib.balanceOf(token, address(poolManager)) < uint256(owed)) {
            revert Drained();
        }
        poolManager.take(Currency.wrap(token), msg.sender, uint256(owed));
    }

    function _settleOutput(Currency output, uint128 amount) internal {
        poolManager.sync(output);
        SafeTransferLib.safeTransfer(Currency.unwrap(output), address(poolManager), amount);
        poolManager.settle();
        // Settling the output replaced the swapper's mark, so it is put back: a swapper that
        // marks a token and pays after the swap is then credited as it expects.
        address token = marked;
        if (token == address(0)) return;
        marked = address(0);
        poolManager.sync(Currency.wrap(token));
    }

    /// @dev A router that pays first marks the input token as synced, sends it, swaps, and
    /// settles at the end. This hook's own `sync` for the output would replace that mark, so
    /// the router's settlement would credit nothing. A payment already made is therefore
    /// credited to the swapper now, before the Metric callback takes the input out of the
    /// pool manager (which would hide it), and the mark is put back once the output is
    /// settled. Only the pool's own two tokens are looked at, which Metric's pool has been
    /// checked against: any other token's mark is replaced and not restored, so that no
    /// other token is ever called.
    function _credit(PoolKey calldata key, address sender) internal {
        address synced = Currency.unwrap(poolManager.getSyncedCurrency());
        if (synced == address(0)) return;
        if (synced != Currency.unwrap(key.currency0)) {
            if (synced != Currency.unwrap(key.currency1)) return;
        }
        marked = synced;
        uint256 held = SafeTransferLib.balanceOf(synced, address(poolManager));
        if (held > poolManager.getSyncedReserves()) poolManager.settleFor(sender);
    }

    /// @dev Metric prices are whole token1 per whole token0 in Q64.64, whatever the
    /// decimals. A v4 price is a ratio of raw units, so it is scaled by the pool's two
    /// multipliers (raw amount times multiplier is the scaled amount). A limit at the v4
    /// extremes means no limit.
    function _limitX64(uint160 sqrtLimit, bool v4ZeroForOne, bool metricZfo, Binding memory b)
        internal
        pure
        returns (uint128)
    {
        uint128 open = metricZfo ? 0 : type(uint128).max;
        if (v4ZeroForOne) {
            if (sqrtLimit <= TickMath.MIN_SQRT_PRICE + 1) return open;
        } else {
            if (sqrtLimit >= TickMath.MAX_SQRT_PRICE - 1) return open;
        }
        uint256 s0 = b.scale0;
        uint256 s1 = b.scale1;
        uint256 price;
        if (b.flipped) {
            uint256 q = FullMath.mulDiv(1 << 128, s1, s0);
            uint256 q2 = FullMath.mulDiv(q, 1 << 96, sqrtLimit);
            price = FullMath.mulDiv(q2, 1 << 32, sqrtLimit);
        } else {
            price = FullMath.mulDiv(uint256(sqrtLimit) * s1, sqrtLimit, s0 << 128);
        }
        if (price > type(uint128).max) return type(uint128).max;
        return uint128(price);
    }
}
