// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { SzrCore } from "./SzrCore.sol";
import { IndexPoolFactory } from "./index/IndexPoolFactory.sol";
import { IMetricFactory } from "./interfaces/metric/IMetricFactory.sol";
import { ISzrLiquidity } from "./interfaces/ISzrModules.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "./interfaces/metric/IMetricPool.sol";

interface ITreasuryWeth {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface ITreasuryIndexPool {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn,
        uint256 limit,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountIn, uint256 amountOut);
}

/// @notice The address that receives the index pools' protocol cut. It can do two things with
/// what it holds: swap it to SZR and hand that to Core (`retire`), or swap it to WETH, pay the
/// team its share and add the rest to Core's backing (`back`). Only Liquidity's manager may
/// call either, and picks the route and the least it accepts.
/// @dev No owner and no rescue. Only the manager calls, and a route must deliver the minimum.
/// Venues are authenticated and each hop's output comes from a source a venue cannot fake:
/// the pool manager's delta for v4, the pool's report for Metric pools of `metricFactory`, and
/// the return of `swap` for index pools of `indexFactory`, which this contract made. Balances
/// only back that up (a hop spends at most its input and delivers at least its output),
/// because anyone may pay this contract mid-hop, for example through `payProtocol`. Each hop
/// settles on its own. Native ETH only exists inside a v4 hop; between hops the treasury
/// holds WETH.
contract SzrTreasury is ReentrancyGuard, IUnlockCallback, IMetricSwapCallback {
    enum Venue {
        V4,
        METRIC,
        INDEX
    }

    struct Hop {
        Venue venue;
        PoolKey key; // V4 only
        address pool; // METRIC and INDEX only
        address tokenOut; // currency zero means native ETH, V4 only
    }

    uint256 public constant MAX_HOPS = 4;

    SzrCore public immutable core;
    IPoolManager public immutable poolManager;
    address public immutable szr;
    address public immutable weth;
    IMetricFactory public immutable metricFactory;
    // Made here, so that it surely pays its pools' cut to this treasury.
    IndexPoolFactory public immutable indexFactory;

    // The hash of the one unlock this contract has opened, and nothing otherwise.
    bytes32 internal transient expected;
    // The one Metric pool whose callback may be answered, while this contract calls it, with
    // the input token it may ask for and how much of it is left.
    address internal transient active;
    address internal transient activeToken;
    bool internal transient activeZeroForOne;
    uint256 internal transient activeLeft;

    event Backed(address indexed tokenIn, uint256 amountIn, uint256 backed, uint256 teamFee);
    event Retired(address indexed tokenIn, uint256 amountIn, uint256 retired);

    error NotManager();
    error DeadlinePassed();
    error ZeroAmount();
    error ZeroAddress();
    error TooManyHops();
    error BadRoute();
    error Overspent();
    error BelowMinimum();
    error NotPool();
    error NotWethOrPoolManager();
    error InvalidDelta();
    error TransferMismatch();
    error AboveMaximum();
    error UnknownPool();
    error ShortDelivery();

    constructor(SzrCore core_, IPoolManager poolManager_, IMetricFactory metricFactory_) {
        if (address(core_) == address(0)) revert ZeroAddress();
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (address(metricFactory_) == address(0)) revert ZeroAddress();
        core = core_;
        metricFactory = metricFactory_;
        indexFactory = new IndexPoolFactory(ISzrLiquidity(core_.liquidity()), address(this));
        poolManager = poolManager_;
        szr = address(core_.token());
        weth = core_.backingAsset();
    }

    /// @dev ETH comes only from an unwrap and from the pool manager paying out a swap.
    receive() external payable {
        if (msg.sender == weth) return;
        if (msg.sender == address(poolManager)) return;
        revert NotWethOrPoolManager();
    }

    /// @notice Liquidity's manager, read live so a new manager takes over with no change here.
    function manager() public view returns (address) {
        return ISzrLiquidity(core.liquidity()).manager();
    }

    /// @notice Swaps `amountIn` of `tokenIn` along `route` to WETH, pays the team its share
    /// and donates the rest to Core's backing. An empty `route` means `tokenIn` is WETH.
    function back(
        address tokenIn,
        uint256 amountIn,
        Hop[] calldata route,
        uint256 minimumOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 backed, uint256 teamFee) {
        _gate(deadline);
        uint256 received = _run(tokenIn, amountIn, route, weth, minimumOut);
        // The team's share is Core's own rule for fees, paid straight to the beneficiary:
        // only Core may record fees at SzrEconomics, so WETH sent there would go uncounted.
        teamFee = core.economics().liquidityTeamFee(received);
        if (teamFee != 0) {
            SafeTransferLib.safeTransfer(weth, core.economics().beneficiary(), teamFee);
        }
        backed = received - teamFee;
        SafeTransferLib.safeApprove(weth, address(core), backed);
        core.donateBacking(backed);
        SafeTransferLib.safeApprove(weth, address(core), 0);
        emit Backed(tokenIn, amountIn, backed, teamFee);
    }

    /// @notice Swaps `amountIn` of `tokenIn` along `route` to SZR and donates all of it to
    /// Core. An empty `route` means `tokenIn` is SZR. The team takes no share of this.
    function retire(
        address tokenIn,
        uint256 amountIn,
        Hop[] calldata route,
        uint256 minimumOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 retired) {
        _gate(deadline);
        retired = _run(tokenIn, amountIn, route, szr, minimumOut);
        SafeTransferLib.safeApprove(szr, address(core), retired);
        core.donateSzr(retired);
        SafeTransferLib.safeApprove(szr, address(core), 0);
        emit Retired(tokenIn, amountIn, retired);
    }

    /// @dev Only the pool manager, and only for the unlock this contract opened.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPool();
        if (keccak256(data) != expected) revert NotPool();
        expected = bytes32(0);
        (PoolKey memory key, bool zeroForOne, uint256 amount) =
            abi.decode(data, (PoolKey, bool, uint256));
        return abi.encode(_swapCallback(key, zeroForOne, amount));
    }

    /// @dev Only the Metric pool being called may ask, only for its input token, and never
    /// for more than the hop was given.
    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        if (msg.sender != active) revert NotPool();
        bool zeroForOne = activeZeroForOne;
        int256 input = zeroForOne ? amount0 : amount1;
        int256 output = zeroForOne ? amount1 : amount0;
        if (output > 0) revert Overspent();
        if (input <= 0) return;
        if (uint256(input) > activeLeft) revert Overspent();
        activeLeft -= uint256(input);
        SafeTransferLib.safeTransfer(activeToken, msg.sender, uint256(input));
    }

    function _gate(uint256 deadline) internal view {
        if (msg.sender != manager()) revert NotManager();
        if (block.timestamp > deadline) revert DeadlinePassed();
    }

    /// @dev Runs the hops, each spending what the last one received, and checks the route
    /// ends in `last` with at least `minimumOut`. Returns what the treasury now holds of it.
    function _run(
        address tokenIn,
        uint256 amountIn,
        Hop[] calldata route,
        address last,
        uint256 minimumOut
    ) internal returns (uint256 held) {
        if (amountIn == 0) revert ZeroAmount();
        if (route.length > MAX_HOPS) revert TooManyHops();
        // Outside a v4 hop the treasury holds only WETH, never native ETH.
        if (tokenIn == address(0)) revert BadRoute();
        address token = tokenIn;
        held = amountIn;
        for (uint256 index; index < route.length; index++) {
            Hop calldata hop = route[index];
            address out = hop.tokenOut;
            if (hop.venue == Venue.V4) {
                if (out == address(0)) out = weth;
            }
            if (out == address(0)) revert BadRoute();
            if (out == token) revert BadRoute();
            held = _hop(hop, token, out, held);
            token = out;
        }
        if (token != last) revert BadRoute();
        if (held < minimumOut) revert BelowMinimum();
    }

    /// @dev One hop. What it got is what the venue authenticates (the pool manager's delta,
    /// Metric's report, the index pool's return), never a balance rise alone: anyone may pay
    /// this contract mid-hop, for example through an index pool's `payProtocol`. The balance
    /// must still have risen by that much, and the token in must not have fallen by more than
    /// the hop was given. ETH a v4 hop leaves behind is wrapped.
    function _hop(Hop calldata hop, address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 received)
    {
        if (amount > type(uint128).max) revert AboveMaximum();
        uint256 inBefore = SafeTransferLib.balanceOf(tokenIn, address(this));
        uint256 outBefore = SafeTransferLib.balanceOf(tokenOut, address(this));
        uint256 ethBefore = address(this).balance;
        if (hop.venue == Venue.V4) received = _v4(hop, tokenIn, amount);
        else if (hop.venue == Venue.METRIC) received = _metric(hop, tokenIn, tokenOut, amount);
        else received = _index(hop, tokenIn, tokenOut, amount);
        uint256 ethAfter = address(this).balance;
        if (ethAfter > ethBefore) ITreasuryWeth(weth).deposit{ value: ethAfter - ethBefore }();
        uint256 inAfter = SafeTransferLib.balanceOf(tokenIn, address(this));
        // Tokens that arrive mid-hop only add to what the treasury holds.
        if (inBefore > inAfter) {
            if (inBefore - inAfter > amount) revert Overspent();
        }
        if (SafeTransferLib.balanceOf(tokenOut, address(this)) < outBefore + received) {
            revert ShortDelivery();
        }
    }

    function _v4(Hop calldata hop, address tokenIn, uint256 amount) internal returns (uint256) {
        bool zeroForOne = _direction(hop, tokenIn);
        Currency currencyIn = zeroForOne ? hop.key.currency0 : hop.key.currency1;
        if (Currency.unwrap(currencyIn) == address(0)) ITreasuryWeth(weth).withdraw(amount);
        bytes memory data = abi.encode(hop.key, zeroForOne, amount);
        expected = keccak256(data);
        bytes memory result = poolManager.unlock(data);
        if (expected != bytes32(0)) revert NotPool();
        return abi.decode(result, (uint256));
    }

    /// @dev Which way the swap goes: the token out must be one currency of the key and the
    /// token in the other, where WETH stands in for native ETH on the treasury's side.
    function _direction(Hop calldata hop, address tokenIn) internal view returns (bool) {
        address zero = Currency.unwrap(hop.key.currency0);
        address one = Currency.unwrap(hop.key.currency1);
        if (hop.tokenOut == one) {
            if (_matches(zero, tokenIn)) return true;
        }
        if (hop.tokenOut == zero) {
            if (_matches(one, tokenIn)) return false;
        }
        revert BadRoute();
    }

    function _matches(address currency, address token) internal view returns (bool) {
        if (currency == token) return true;
        return currency == address(0) && token == weth;
    }

    function _swapCallback(PoolKey memory key, bool zeroForOne, uint256 amount)
        internal
        returns (uint256)
    {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 input = zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = zeroForOne ? delta.amount1() : delta.amount0();
        if (input > 0) revert InvalidDelta();
        if (output < 0) revert InvalidDelta();
        uint256 spent = uint256(-int256(input));
        if (spent > amount) revert Overspent();
        // A swap through an empty pool spends nothing and only moves its price.
        if (spent != 0) _pay(zeroForOne ? key.currency0 : key.currency1, spent);
        // The pool manager's own delta is the output, whatever else lands during the swap.
        if (output != 0) {
            poolManager.take(
                zeroForOne ? key.currency1 : key.currency0, address(this), uint128(output)
            );
        }
        return uint128(output);
    }

    function _pay(Currency currency, uint256 amount) internal {
        address asset = Currency.unwrap(currency);
        if (asset == address(0)) {
            if (poolManager.settle{ value: amount }() != amount) revert TransferMismatch();
            return;
        }
        poolManager.sync(currency);
        SafeTransferLib.safeTransfer(asset, address(poolManager), amount);
        if (poolManager.settle() != amount) revert TransferMismatch();
    }

    /// @dev The pool's callback is answered only while this call is open, and with the
    /// widest price limit: the minimum out is the only price protection.
    function _metric(Hop calldata hop, address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 received)
    {
        if (amount > uint256(uint128(type(int128).max))) revert AboveMaximum();
        if (!metricFactory.isPool(hop.pool)) revert UnknownPool();
        MetricImmutables memory imm = IMetricPool(hop.pool).getImmutables();
        bool zeroForOne = imm.token0 == tokenIn;
        if (zeroForOne) {
            if (imm.token1 != tokenOut) revert BadRoute();
        } else {
            if (imm.token1 != tokenIn) revert BadRoute();
            if (imm.token0 != tokenOut) revert BadRoute();
        }
        active = hop.pool;
        activeToken = tokenIn;
        activeZeroForOne = zeroForOne;
        activeLeft = amount;
        (int128 amount0, int128 amount1) = IMetricPool(hop.pool)
            .swap(
                address(this),
                zeroForOne,
                int128(uint128(amount)),
                zeroForOne ? 0 : type(uint128).max,
                "",
                ""
            );
        active = address(0);
        activeLeft = 0;
        // The pool's report is the output; the balance check in `_hop` backs it.
        int128 output = zeroForOne ? amount1 : amount0;
        if (output < 0) received = uint256(-int256(output));
    }

    /// @dev The approval is exactly the input and is set back to zero after the swap.
    function _index(Hop calldata hop, address tokenIn, address tokenOut, uint256 amount)
        internal
        returns (uint256 received)
    {
        if (!indexFactory.isPool(hop.pool)) revert UnknownPool();
        SafeTransferLib.safeApprove(tokenIn, hop.pool, amount);
        (, received) = ITreasuryIndexPool(hop.pool)
            .swap(tokenIn, tokenOut, amount, true, 0, address(this), block.timestamp);
        SafeTransferLib.safeApprove(tokenIn, hop.pool, 0);
    }
}
