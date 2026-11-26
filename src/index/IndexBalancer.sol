// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IIndexHook } from "../interfaces/IIndexHook.sol";
import { IMetricPool, IMetricSwapCallback } from "../interfaces/metric/IMetricPool.sol";
import { SizingWalk } from "../arbitrage/lib/SizingWalk.sol";
import { V4Read } from "../arbitrage/lib/V4Read.sol";
import { IndexPool } from "./IndexPool.sol";
import { IndexPoolFactory } from "./IndexPoolFactory.sol";
import { Cycle, IndexCycle, IndexSizer } from "./IndexSizer.sol";
import { IndexMetric } from "./IndexMetric.sol";
import { IndexBalancerState } from "./IndexBalancerState.sol";
import { IndexSettings } from "./IndexSettings.sol";

/// @notice The hook that keeps an index pool in line with outside prices. Before and after
/// every swap, and whenever a keeper asks, it trades the pool against plain Uniswap v4 pools
/// and Metric pools that price each token in one common token, the unit, and donates
/// everything the trade
/// earned to the same pool. It never borrows: it takes from the pool manager only what its
/// outside trades have just made it owed. It holds nothing between calls.
/// @dev Spec: `docs/specs/index-balancer.md`. Failure is silence, with one exception: before a
/// swap, a pool manager short of what it owes the balancer blocks the swap (`Blocked`), since
/// a drained pool manager is a way to switch the hook off and take the gap.
contract IndexBalancer is IndexBalancerState, IIndexHook, IUnlockCallback, IMetricSwapCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// A token's best venue each way: what one unit of it sells for (`bid`, square-root
    /// units per token after fees), what one unit buys of it (`ask`, square-root tokens per
    /// unit after fees), the mid price of the `bid` venue, and the two routes.
    struct Quote {
        uint256 bid;
        uint256 ask;
        uint256 worth;
        uint256 bidRoute;
        uint256 askRoute;
        uint256[5] bidBook;
        uint256[5] askBook;
    }

    uint256 public constant TRIES = 5; // the walk's size, the whole gap, 1/2, 1/4, 1/8
    uint256 public constant BENCH_TIME = 3 minutes;
    uint256 public constant BENCH_ESCAPE = 2; // a gap this many times the failed one is tried
    uint256 public constant MAX_SHARE = IndexCycle.MAX_SHARE; // of a balance, in one cycle

    /// @dev The arbitrage hook's figures: the walk's gas, the least a try is started with,
    /// and a square-root gap (a 16x price) beyond which a venue is broken, not cheap.
    uint256 internal constant SIZING_GAS = 240_000;
    uint256 internal constant ATTEMPT_GAS = 150_000;
    uint256 internal constant MAX_EDGE = 4e18;
    /// The least gap acted on, as a multiple of the pool's swap fee (WAD).
    uint256 public constant FEE_FLOOR = 2e18;
    /// @dev Below this on entry nothing is tried, so a starved call returns instead of
    /// running out. Kept back after the work for clearing the re-entry flag, and after the
    /// tries for setting a pair aside.
    uint256 internal constant ENTRY_GAS = 100_000;
    uint256 internal constant EXIT_GAS = 10_000;
    uint256 internal constant END_GAS = 40_000;
    uint256 internal constant WAD = V4Read.WAD;
    uint256 internal constant Q96 = V4Read.Q96;
    uint256 internal constant Q192 = V4Read.Q192;
    uint256 internal constant MAX_CYCLE_RATE = SizingWalk.MAX_CYCLE_RATE;
    /// @dev The most a Metric price read may use. A real read costs about 104,000 the first
    /// time in a transaction.
    uint256 internal constant METRIC_READ_GAS = 300_000;
    /// @dev The most Metric venues one call drops: every one a pair can have.
    uint256 internal constant MAX_DROPS = 2 * MAX_VENUES;
    uint256 internal constant ENTERED_SLOT = uint256(keccak256("IndexBalancer.entered"));
    /// @dev Who called: a keeper through `balance`, or the pool before or after a swap.
    uint256 internal constant KEEPER = 0;
    uint256 internal constant BEFORE = 1;
    uint256 internal constant AFTER = 2;
    /// @dev What an unlock this contract opens is for: a cycle, or crediting a payment that
    /// was already waiting to the swap's caller.
    uint256 internal constant CYCLE = 0;
    uint256 internal constant RELEASE = 1;

    IndexSizer public immutable sizer;
    address public immutable settings;

    /// The one Metric pool whose callback may be answered, only while the balancer is calling
    /// it, with what it is to be paid in and, for the cycle's first trade, a hash of the
    /// cycle it carries and what the index pool returned inside it.
    address internal transient metricPool;
    address internal transient metricInput;
    bool internal transient metricZero;
    bytes32 internal transient metricHash;
    uint256 internal transient metricReceived;
    /// For the reordered shape's exact output: what the index pool returned to pay Metric
    /// with (zero for any other swap). The cycle's second Metric venue, when a Metric-first
    /// cycle has one. And the tag the balancer's own `Lost` carries out of a Metric call:
    /// written before the call, so it survives the call's revert, and unseen by the Metric
    /// pool, which cannot read this contract's transient storage. Only a revert carrying it
    /// is taken for the size losing; any other answer from inside Metric's call is Metric's.
    uint256 internal transient metricHeld;
    address internal transient metricInner;
    bytes32 internal transient lostTag;
    /// What stopped the last round's tries: a pool manager short of what it owed, or a
    /// Metric pool that would not trade.
    bool internal transient lastDrained;
    /// Whether a Metric venue read this call was locked: the call is inside a swap on it.
    bool internal transient metricLocked;
    address internal transient lastRefused;
    /// The pair and gap of the first round this call whose Metric venue would not trade, so
    /// that a pair with nothing left to fall back on is set aside as if its tries had failed.
    bytes32 internal transient refusedPair;
    uint256 internal transient refusedWidth;
    address internal transient refusedToken;

    event Balanced(
        address indexed pool,
        address indexed pay,
        address indexed take,
        uint256 spend,
        uint256 profit
    );
    event SetAside(
        address indexed pool, address indexed pay, address indexed take, uint256 gap
    );

    /// @dev `metric_` and `settings_` are deployed first and passed in: with them inside, the
    /// balancer's creation code would pass the 49,152-byte limit. The settings module must
    /// share this balancer's pool manager, factory and reader, or it would check routes
    /// against other contracts.
    constructor(
        IPoolManager poolManager_,
        IndexPoolFactory factory_,
        IndexMetric metric_,
        IndexSettings settings_
    ) IndexBalancerState(poolManager_, factory_, metric_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (address(factory_) == address(0)) revert ZeroAddress();
        if (address(metric_.factory()) == address(0)) revert ZeroAddress();
        if (settings_.poolManager() != poolManager_) revert WrongModule();
        if (settings_.factory() != factory_) revert WrongModule();
        if (settings_.metric() != metric_) revert WrongModule();
        sizer = new IndexSizer(poolManager_);
        settings = address(settings_);
    }

    /// @dev Every call the balancer does not answer itself, the creator's settings and their
    /// views, runs in `IndexSettings` on this contract's storage.
    fallback() external {
        address module = settings;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    function beforeSwap(address sender, address tokenIn, address tokenOut) external {
        _enter(msg.sender, tokenIn, tokenOut, BEFORE, sender);
    }

    function afterSwap(address sender, address tokenIn, address tokenOut, uint256, uint256)
        external
    {
        _enter(msg.sender, tokenIn, tokenOut, AFTER, sender);
    }

    /// Balances one pair of `pool` now. Anyone may call it; it pays the caller nothing.
    function balance(address pool, address tokenA, address tokenB)
        external
        returns (uint256 profit)
    {
        return _enter(pool, tokenA, tokenB, KEEPER, address(0));
    }

    /// @dev The work of one call, run as a call to itself so that whatever goes wrong inside
    /// it is undone and goes no further. `drained` says the pool manager was short of what
    /// it owed the balancer, which the caller turns into `Blocked` before a swap. A Metric
    /// venue that quoted but would not trade is dropped for the rest of the call and the
    /// pair tried again with the next best venue.
    function run(address pool, address tokenA, address tokenB, uint256 kind, address sender)
        external
        returns (uint256 profit, bool drained)
    {
        if (msg.sender != address(this)) revert NotSelf();
        // Transient storage outlives the call: an earlier hook call's record is not this one's.
        (refusedPair, metricLocked) = (bytes32(0), false);
        address[] memory skip = new address[](MAX_DROPS);
        assembly ("memory-safe") {
            mstore(skip, 0)
        }
        for (uint256 round; round <= MAX_DROPS; round++) {
            address failed;
            (profit, drained, failed) = _round(pool, tokenA, tokenB, kind, sender, skip);
            if (failed == address(0)) return (profit, drained);
            if (round == MAX_DROPS) {
                _asideRefused(pool, kind, skip);
                return (0, false);
            }
            // The array was made with room for every drop; only its length moves.
            assembly ("memory-safe") {
                let count := add(mload(skip), 1)
                mstore(skip, count)
                mstore(add(skip, mul(count, 0x20)), failed)
            }
        }
    }

    /// @dev One plan of the pair and its tries, with the Metric pools in `skip` left out.
    /// `failed` is a Metric pool that would not trade, when that is why the tries stopped.
    function _round(
        address pool,
        address tokenA,
        address tokenB,
        uint256 kind,
        address sender,
        address[] memory skip
    ) internal returns (uint256 profit, bool drained, address failed) {
        (Cycle memory cycle, uint256 width) = _plan(pool, tokenA, tokenB, skip);
        // A Metric venue of the pair read as locked: this call comes from inside a swap on
        // it, which would otherwise hide it. Treated as a drain: blocked before a swap (H-2).
        if (metricLocked) return (0, true, address(0));
        bytes32 pair = keccak256(abi.encode(pool, cycle.pay, cycle.take));
        if (!_worthTrying(cycle, width, pair)) {
            _asideRefused(pool, kind, skip);
            return (0, false, address(0));
        }
        // A keeper has no payment to credit: it is not the payer.
        (address resync, bool go, bool stuck) =
            _release(pool, cycle.unit, kind == KEEPER ? address(0) : sender);
        // A waiting payment that could not be sent back blocks before a swap (L-2).
        if (!go) return (0, stuck, address(0));
        bool aside;
        (lastDrained, lastRefused) = (false, address(0));
        (profit, aside) = _tries(cycle);
        (drained, failed) = (lastDrained, lastRefused);
        _resync(resync);
        if (profit != 0) return (_balanced(cycle, profit), false, address(0));
        if (failed != address(0)) {
            if (refusedPair == bytes32(0)) {
                (refusedPair, refusedWidth) = (pair, width);
                refusedToken = failed == cycle.sellPool ? cycle.take : cycle.pay;
            }
            return (0, false, failed);
        }
        // A keeper chooses its gas, so its failures set nothing aside, as with the arbitrage
        // hook's `arb`: otherwise a starved call could switch a pair off for swappers.
        if (!aside) return (0, drained, address(0));
        if (kind == KEEPER) return (0, false, address(0));
        _setAside(cycle, pair, width);
    }

    /// @dev A pair whose Metric venue would not trade earlier this call, and whose token has
    /// no other venue left to try, is set aside as a pair whose tries failed. One whose other
    /// venues show no gap is in line with them, and nothing is set aside.
    function _asideRefused(address pool, uint256 kind, address[] memory skip) internal {
        bytes32 pair = refusedPair;
        if (pair == bytes32(0)) return;
        refusedPair = bytes32(0);
        if (kind == KEEPER) return;
        uint256[] storage routes = live[pool][refusedToken];
        for (uint256 index; index < routes.length; index++) {
            uint256 word = routes[index];
            if (word & METRIC_FLAG == 0) return;
            if (!_skipped(skip, address(uint160(word)))) return;
        }
        benches[pair] = Bench(uint64(block.timestamp + BENCH_TIME), uint192(refusedWidth));
        emit SetAside(pool, address(0), address(0), refusedWidth);
    }

    function _setAside(Cycle memory cycle, bytes32 pair, uint256 width) internal {
        benches[pair] = Bench(uint64(block.timestamp + BENCH_TIME), uint192(width));
        emit SetAside(cycle.pool, cycle.pay, cycle.take, width);
    }

    function _balanced(Cycle memory cycle, uint256 profit) internal returns (uint256) {
        emit Balanced(cycle.pool, cycle.pay, cycle.take, cycle.spend, profit);
        return profit;
    }

    /// @dev Whether a gap is wide enough and its pair not set aside, and the cycle's limit.
    function _worthTrying(Cycle memory cycle, uint256 width, bytes32 pair)
        internal
        view
        returns (bool)
    {
        if (width == 0) return false;
        Limits memory limits = limitSet[cycle.pool];
        // Never a gap smaller than twice the pool's own fee. A cycle closing a gap g donates
        // about g/2 of what it moves, so at twice the fee it gives the pool no less than a
        // fee-paying swap would: a creator walking their own venue up step by step cannot
        // trade the pool more cheaply than by paying its fee (M-1).
        uint256 floor = IndexPool(cycle.pool).swapFee() * FEE_FLOOR / WAD;
        if (limits.minimumGap > floor) floor = limits.minimumGap;
        if (width < floor) return false;
        Bench memory bench = benches[pair];
        if (block.timestamp < bench.until) {
            if (width / BENCH_ESCAPE < bench.gap) return false;
        }
        cycle.minimumProfit = limits.minimumProfit;
        return true;
    }

    /// @dev One try at one size, undone by the caller unless it pays.
    function attempt(Cycle calldata cycle) external returns (uint256, uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        // A cycle whose outside trades are all on Metric never touches the pool manager.
        if (!_usesPoolManager(cycle)) return _cycle(cycle);
        // Inside someone else's unlock the pool manager cannot be unlocked again: the cycle
        // runs in the balancer's own name and ends with its balances back at zero.
        if (poolManager.isUnlocked()) return _cycle(cycle);
        return abi.decode(poolManager.unlock(abi.encode(CYCLE, cycle)), (uint256, uint256));
    }

    /// @dev Only the pool manager calls back, and only for an unlock this contract opened.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (abi.decode(data[:32], (uint256)) == CYCLE) {
            (, Cycle memory cycle) = abi.decode(data, (uint256, Cycle));
            (uint256 profit, uint256 spent) = _cycle(cycle);
            return abi.encode(profit, spent);
        }
        // A payment was waiting with the pool manager locked: settle it and send exactly
        // what it credited back to the swap's caller, who paid it.
        (, address asset, address payer) = abi.decode(data, (uint256, address, address));
        uint256 paid = poolManager.settle();
        poolManager.take(Currency.wrap(asset), payer, paid);
        return "";
    }

    /// @dev Only the Metric pool being called may ask to be paid, once, during that call, and
    /// only in the token it was given. The pool has already sent what it sold: for the
    /// cycle's first trade, the rest of the cycle runs here, paid for with that.
    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata data)
        external
    {
        if (msg.sender != metricPool) revert NotMetric();
        if (msg.sender == address(0)) revert NotMetric();
        metricPool = address(0);
        address input = metricInput;
        bytes32 tag = lostTag;
        (int256 owed, int256 sent) = metricZero ? (amount0, amount1) : (amount1, amount0);
        if (owed <= 0) revert Incomplete();
        if (sent >= 0) revert Incomplete();
        // The reordered shape: the index pool returned too little to pay for the units, so
        // this size lost (Low-1).
        uint256 held = metricHeld;
        if (held != 0) {
            if (uint256(owed) > held) revert Lost(tag);
        }
        if (data.length != 0) {
            if (keccak256(data) != metricHash) revert NotMetric();
            metricHash = bytes32(0);
            // The rest of the cycle, in a call to itself, so that its failure, the size losing,
            // reads as that and not as Metric's (L-1).
            try this.carry(abi.decode(data, (Cycle)), uint256(-sent)) returns (uint256 got) {
                metricReceived = got;
            } catch {
                _reraiseInner(abi.decode(data, (Cycle)).buyPool, tag);
            }
            if (metricReceived <= uint256(owed)) revert Lost(tag);
        }
        SafeTransferLib.safeTransfer(input, msg.sender, uint256(owed));
    }

    /// The gap the next call would see for this pair, and which way it runs. For front ends.
    function gap(address pool, address tokenA, address tokenB)
        external
        returns (uint256 size_, bool aIsCheap)
    {
        if (!factory.isPool(pool)) return (0, false);
        Cycle memory cycle;
        (cycle, size_) = _plan(pool, tokenA, tokenB, new address[](0));
        aIsCheap = size_ != 0 && cycle.take == tokenA;
    }

    /// @dev The rest of a Metric-first cycle, run from Metric's callback.
    function carry(Cycle calldata cycle, uint256 amount) external returns (uint256) {
        if (msg.sender != address(this)) revert NotSelf();
        return _onward(cycle, amount, true);
    }

    /// @dev A failure inside a Metric-first cycle's own work is the size losing (`Lost`),
    /// unless it was the cycle's second Metric venue refusing, which is passed on as that.
    function _reraiseInner(address inner, bytes32 tag) internal pure {
        if (inner != address(0)) {
            if (_revertedWith(MetricFailed.selector, 36)) {
                if (_named() == inner) revert MetricFailed(inner);
            }
        }
        revert Lost(tag);
    }

    /// @dev The caller check and the re-entry flag, then the work in a call to itself whose
    /// failure is ignored. The one thing that can make it revert is a pool manager short of
    /// what it owes the balancer before a swap: then the pool refuses the swap.
    function _enter(address pool, address tokenA, address tokenB, uint256 kind, address sender)
        internal
        returns (uint256 profit)
    {
        bool busy = _entered();
        if (busy) {
            if (kind != BEFORE) return 0;
        }
        if (!factory.isPool(pool)) return 0;
        if (IndexPool(pool).hook() != address(this)) return 0;
        // A swap in a pool of this hook made from inside a callback during a balancer call,
        // for instance by a token of another pool being balanced, would find the hook busy
        // and skip it: it is refused (H-1).
        if (busy) revert IIndexHook.Blocked();
        if (gasleft() < ENTRY_GAS) return 0;
        _setEntered(1);
        bool drained;
        try this.run{ gas: gasleft() - EXIT_GAS }(pool, tokenA, tokenB, kind, sender) returns (
            uint256 earned, bool short
        ) {
            (profit, drained) = (earned, short);
        } catch { }
        _setEntered(0);
        if (drained) {
            if (kind == BEFORE) revert IIndexHook.Blocked();
        }
    }

    /// @dev The arbitrage hook's `_release`, with the swap's caller as the payer. A token
    /// marked as being paid to the pool manager is never called unless the balancer trades
    /// it; one it trades is marked again afterwards (`resync`), and a payment already
    /// waiting in it is credited to the caller. `go` is false only when a payment is
    /// waiting and there is no caller to credit, in `balance`.
    function _release(address pool, address unit, address payer)
        internal
        returns (address resync, bool go, bool stuck)
    {
        address synced = Currency.unwrap(poolManager.getSyncedCurrency());
        if (synced == address(0)) return (address(0), true, false);
        // Not called: it could revert, burn gas or misreport. Its mark is lost when a cycle
        // marks its own token, and whoever set it has their own transaction fail later.
        if (synced != unit) {
            if (!_holds(pool, synced)) return (address(0), true, false);
        }
        uint256 held = SafeTransferLib.balanceOf(synced, address(poolManager));
        if (held <= poolManager.getSyncedReserves()) return (synced, true, false);
        if (payer == address(0)) return (address(0), false, false);
        if (poolManager.isUnlocked()) {
            poolManager.settleFor(payer);
        } else {
            try poolManager.unlock(abi.encode(RELEASE, synced, payer)) { }
            catch {
                return (address(0), false, true);
            }
        }
        return (synced, true, false);
    }

    /// @dev Marks the caller's token again, so that anything it pays in later still counts.
    function _resync(address resync) internal {
        if (resync != address(0)) poolManager.sync(Currency.wrap(resync));
    }

    /// @dev The walk's size, then the whole gap, a half, a quarter and an eighth, each a
    /// call that is undone unless it pays, in the manner of the arbitrage hook's `_attempt`.
    /// `aside` is false when the failure may have been for want of gas. A pool manager that
    /// could not pay what it owed stops the tries, as no smaller size changes that; so does a
    /// Metric pool that would not trade. Both are recorded in `lastDrained` and `lastRefused`.
    function _tries(Cycle memory cycle) internal returns (uint256, bool aside) {
        uint256 whole = _whole(cycle);
        uint256 first;
        try sizer.size{ gas: SIZING_GAS }(cycle) returns (uint256 found) {
            first = found;
        } catch { }
        uint256 total = gasleft() > END_GAS ? gasleft() - END_GAS : 0;
        uint256 budget = total;
        bool smallest;
        aside = true;
        for (uint256 number; number < TRIES; number++) {
            if (budget < ATTEMPT_GAS) return (0, false);
            uint256 amount = number == 0 ? first : whole >> (number - 1);
            if (amount == 0) continue;
            if (smallest) {
                if (number != TRIES - 1) continue;
            }
            // No try may use more than half the budget, so one that runs out of gas leaves
            // a full share for the next size.
            uint256 stipend = budget < total / 2 ? budget : total / 2;
            cycle.spend = amount;
            uint256 available = gasleft();
            uint256 profit = _try(cycle, stipend);
            if (profit != 0) return (profit, false);
            if (lastDrained) return (0, false);
            if (lastRefused != address(0)) return (0, false);
            uint256 used = available - gasleft();
            budget = used < budget ? budget - used : 0;
            // A try that ran out of gas deep down leaves each frame above it a 64th, so it
            // used most but not all of its share: from then on only the smallest is tried.
            if (stipend != total / 2) continue;
            if (used >= stipend - stipend / 16) {
                smallest = true;
                aside = false;
            }
        }
        return (0, aside);
    }

    /// @dev One try, undone unless it pays. A pool manager short of what it owes, or a
    /// Metric pool that would not trade, is recorded for the round.
    function _try(Cycle memory cycle, uint256 stipend) internal returns (uint256) {
        try this.attempt{ gas: stipend }(cycle) returns (uint256 profit, uint256 spent) {
            cycle.spend = spent;
            return profit;
        } catch {
            if (_drained()) lastDrained = true;
            lastRefused = _refused();
            return 0;
        }
    }

    /// @dev Sell `spend` of `take` for units and the units for `pay`, on v4 or Metric, swap
    /// all of that `pay` for `take` in the index pool fee-free, pay the `spend` of `take` owed,
    /// and donate what is left to the pool. Every leg is exact input, and nothing is taken
    /// from the pool manager that it does not already owe. When the first trade is on Metric
    /// the rest runs inside its callback and Metric is paid at the end of it.
    function _cycle(Cycle memory cycle) internal returns (uint256 profit, uint256) {
        uint256 open = poolManager.getNonzeroDeltaCount();
        bool onMetric = _firstPool(cycle) != address(0);
        uint256 received;
        if (!onMetric) received = _v4First(cycle);
        if (onMetric) {
            received = _secondOnV4(cycle) ? _metricLast(cycle) : _metricFirst(cycle);
        }
        if (received <= cycle.spend) revert Unprofitable();
        profit = received - cycle.spend;
        uint256 worth = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(profit, cycle.worth, Q96), cycle.worth, Q96
        );
        if (worth < cycle.minimumProfit) revert Unprofitable();
        if (!onMetric) _pay(cycle.take, cycle.spend);
        // Counted from the pool manager, never from a token's balance: nothing is left owed
        // either way in any token of the cycle.
        _settled(cycle.take, 0);
        _settled(cycle.pay, 0);
        if (cycle.pay != cycle.unit) _settled(cycle.unit, 0);
        SafeTransferLib.safeApprove(cycle.take, cycle.pool, profit);
        IndexPool(cycle.pool).donate(cycle.take, profit);
        SafeTransferLib.safeApprove(cycle.take, cycle.pool, 0);
        if (poolManager.getNonzeroDeltaCount() != open) revert V4Read.Unsettled();
        return (profit, cycle.spend);
    }

    /// @dev The first trade on v4: the `take` sold stays owed to the pool manager until the
    /// end of the cycle.
    function _v4First(Cycle memory cycle) internal returns (uint256) {
        PoolKey memory first = cycle.take != cycle.unit ? cycle.sell : cycle.buy;
        uint256 amount = _exactIn(first, cycle.take, cycle.spend, cycle.edge);
        return _onward(cycle, amount, false);
    }

    /// @dev The first trade on Metric, carrying the cycle into its callback, where any second
    /// trade is on Metric too: no pool manager balance is involved.
    function _metricFirst(Cycle memory cycle) internal returns (uint256) {
        bool zero = cycle.take != cycle.unit ? cycle.sellZero : cycle.buyZero;
        // Only the cycle's own second Metric venue may be named from inside this call.
        if (cycle.take != cycle.unit) metricInner = cycle.buyPool;
        _metricSwap(_firstPool(cycle), cycle.take, cycle.spend, zero, false, abi.encode(cycle));
        return metricReceived;
    }

    /// @dev Whether `take` is sold on Metric and the units sold for `pay` on v4.
    function _secondOnV4(Cycle memory cycle) internal pure returns (bool) {
        if (cycle.take == cycle.unit) return false;
        if (cycle.pay == cycle.unit) return false;
        return cycle.buyPool == address(0);
    }

    /// @dev Metric first, v4 second, run the other way round so that the take is outside
    /// Metric's call: the v4 trade on credit, the `pay` it leaves owed taken, the index pool,
    /// then exactly the units owed bought from Metric with `take`, and settled. A shortage
    /// at the take is then a drain, as anywhere else. The units are what Metric's reading
    /// gives for `spend`; `spend` becomes what Metric really asked.
    function _metricLast(Cycle memory cycle) internal returns (uint256 received) {
        uint256 units = sizer.metricOut(cycle.sellBook, cycle.take < cycle.unit, cycle.spend);
        if (units == 0) revert Incomplete();
        uint256 amount = _exactIn(cycle.buy, cycle.unit, units, cycle.edge);
        _takeOwed(cycle.pay, amount);
        received = _poolLeg(cycle, amount);
        metricHeld = received;
        cycle.spend = _metricSwap(cycle.sellPool, cycle.take, units, cycle.sellZero, true, "");
        metricHeld = 0;
        _pay(cycle.unit, units);
    }

    /// @dev From the first trade's output, held or owed by the pool manager: the second
    /// trade if there is one, then the `pay` in hand, then the index pool.
    function _onward(Cycle memory cycle, uint256 amount, bool held) internal returns (uint256) {
        bool second = cycle.take != cycle.unit;
        if (second) second = cycle.pay != cycle.unit;
        if (second) (amount, held) = _second(cycle, amount, held);
        if (!held) _takeOwed(cycle.pay, amount);
        return _poolLeg(cycle, amount);
    }

    /// @dev Units for `pay`. Metric is paid from units in hand; v4 is paid from units in
    /// hand straight after, or nets against units the pool manager owes.
    function _second(Cycle memory cycle, uint256 amount, bool held)
        internal
        returns (uint256, bool)
    {
        if (cycle.buyPool != address(0)) {
            if (!held) _takeOwed(cycle.unit, amount);
            return
                (_metricSwap(cycle.buyPool, cycle.unit, amount, cycle.buyZero, false, ""), true);
        }
        uint256 out = _exactIn(cycle.buy, cycle.unit, amount, cycle.edge);
        if (held) _pay(cycle.unit, amount);
        return (out, false);
    }

    /// @dev A swap on Metric of exactly `amount` in, or exactly `amount` out (`exactOut`),
    /// filled in full or not at all. Returns what came out, or for an exact output what was
    /// paid in. Whatever goes wrong inside it, the callback's work included, is Metric's
    /// failure, named by the pool, and only fails the try.
    function _metricSwap(
        address pool,
        address input,
        uint256 amount,
        bool zero,
        bool exactOut,
        bytes memory data
    ) internal returns (uint256) {
        if (amount > uint256(uint128(type(int128).max))) revert Incomplete();
        (metricPool, metricInput, metricZero) = (pool, input, zero);
        metricHash = data.length != 0 ? keccak256(data) : bytes32(0);
        address inner = metricInner;
        metricInner = address(0);
        lostTag = keccak256(abi.encode(gasleft(), metricHash, pool));
        int128 specified = int128(uint128(amount));
        uint128 limit = zero ? 0 : type(uint128).max;
        int128 paid;
        int128 got;
        try IMetricPool(pool)
            .swap(
                address(this), zero, exactOut ? -specified : specified, limit, data, ""
            ) returns (
            int128 amount0, int128 amount1
        ) {
            (paid, got) = zero ? (amount0, amount1) : (amount1, amount0);
        } catch {
            _reraiseMetric(pool, inner);
        }
        // A pool that never asked to be paid did not trade, and a partial fill is Metric's
        // failure too.
        if (metricPool != address(0)) revert MetricFailed(pool);
        if (paid <= 0) revert MetricFailed(pool);
        if (got >= 0) revert MetricFailed(pool);
        if (exactOut) {
            if (got != -specified) revert MetricFailed(pool);
            return uint256(uint128(paid));
        }
        if (paid != specified) revert MetricFailed(pool);
        return uint256(uint128(-got));
    }

    /// @dev The index pool leg: all of `amount` of `pay` in, exact input, fee-free.
    function _poolLeg(Cycle memory cycle, uint256 amount) internal returns (uint256 received) {
        SafeTransferLib.safeApprove(cycle.pay, cycle.pool, amount);
        (, received) = IndexPool(cycle.pool)
            .swap(cycle.pay, cycle.take, amount, true, 0, address(this), block.timestamp);
        SafeTransferLib.safeApprove(cycle.pay, cycle.pool, 0);
    }

    /// @dev Pays what a v4 venue is owed, as the arbitrage hook pays Core's redemption:
    /// sync, transfer, settle, checking that exactly that much was credited.
    function _pay(address asset, uint256 amount) internal {
        poolManager.sync(Currency.wrap(asset));
        SafeTransferLib.safeTransfer(asset, address(poolManager), amount);
        if (poolManager.settle() != amount) revert V4Read.InvalidDelta();
    }

    function _exactIn(PoolKey memory venue, address input, uint256 amount, uint256 edge)
        internal
        returns (uint256 received)
    {
        bool zeroForOne = Currency.unwrap(venue.currency0) == input;
        (uint160 price,,,) = poolManager.getSlot0(venue.toId());
        uint160 limit = V4Read._limitFrom(price, zeroForOne, edge);
        uint256 spent;
        (spent, received) = V4Read._trade(poolManager, venue, input, -int256(amount), limit);
        if (spent != amount) revert Incomplete();
    }

    /// @dev What a failed Metric swap means. Only two answers of the balancer's own are
    /// passed on through Metric's call: the size losing, and the cycle's second Metric venue
    /// refusing. Everything else is this pool's failure. So nothing inside Metric's call can
    /// ever reach the caller as `Drained`.
    function _reraiseMetric(address pool, address inner) internal view {
        if (_revertedWith(Lost.selector, 36)) {
            if (_word() == lostTag) revert Lost(lostTag);
        }
        if (inner != address(0)) {
            if (_revertedWith(MetricFailed.selector, 36)) {
                if (_named() == inner) revert MetricFailed(inner);
            }
        }
        revert MetricFailed(pool);
    }

    /// @dev Whether the last call reverted with exactly `size` bytes starting `selector`.
    function _revertedWith(bytes4 selector, uint256 size) internal pure returns (bool) {
        bytes32 word;
        assembly ("memory-safe") {
            if eq(returndatasize(), size) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, 4)
                word := mload(ptr)
            }
        }
        return bytes4(word) == selector;
    }

    /// @dev The address argument of the last call's 36-byte revert.
    function _named() internal pure returns (address) {
        return address(uint160(uint256(_word())));
    }

    /// @dev The 32-byte argument of the last call's 36-byte revert.
    function _word() internal pure returns (bytes32 word) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            returndatacopy(ptr, 4, 32)
            word := mload(ptr)
        }
    }

    /// @dev The Metric pool of the cycle's first trade, zero if it is on v4. The first trade
    /// sells `take` for units, or, when `take` is the unit, units for `pay`.
    function _firstPool(Cycle memory cycle) internal pure returns (address) {
        return cycle.take != cycle.unit ? cycle.sellPool : cycle.buyPool;
    }

    function _usesPoolManager(Cycle memory cycle) internal pure returns (bool) {
        if (cycle.take != cycle.unit) {
            if (cycle.sellPool == address(0)) return true;
        }
        if (cycle.pay != cycle.unit) {
            if (cycle.buyPool == address(0)) return true;
        }
        return false;
    }

    /// @dev Exactly what the pool manager owes the balancer in `asset`, and no more.
    function _takeOwed(address asset, uint256 amount) internal {
        _settled(asset, int256(amount));
        _take(asset, amount);
    }

    /// @dev Only what the balancer is owed, checked against what the pool manager holds. A
    /// shortage reverts `Drained`: an honest pool manager always holds what it owes.
    function _take(address asset, uint256 amount) internal {
        V4Read._funded(poolManager, Currency.wrap(asset), amount, false);
        poolManager.take(Currency.wrap(asset), address(this), amount);
    }

    function _settled(address asset, int256 expected) internal view {
        int256 held = poolManager.currencyDelta(address(this), Currency.wrap(asset));
        if (held != expected) revert V4Read.Unsettled();
    }

    /// @dev The cheaper side of the pair and everything a try needs, with the cycle's gap
    /// as a price (WAD). Zero when there is no gap or nothing to read.
    function _plan(address pool, address tokenA, address tokenB, address[] memory skip)
        internal
        returns (Cycle memory cycle, uint256 found)
    {
        address unit = units[pool];
        if (unit == address(0)) return (cycle, 0);
        if (tokenA == tokenB) return (cycle, 0);
        cycle.pool = pool;
        cycle.unit = unit;
        cycle.take = tokenA;
        cycle.pay = tokenB;
        if (!_state(cycle)) return (cycle, 0);
        (Quote memory quoteA, Quote memory quoteB) = _quotes(pool, tokenA, tokenB, unit, skip);
        found = _orient(cycle, quoteA, quoteB);
    }

    /// @dev Turns a cycle laid out with `tokenA` taken out the way its gap runs, if either
    /// way has one, and gives it its venues.
    function _orient(Cycle memory cycle, Quote memory quoteA, Quote memory quoteB)
        internal
        pure
        returns (uint256)
    {
        uint256 rateBA =
            _root(cycle.balanceTake * cycle.weightPay, cycle.balancePay * cycle.weightTake);
        uint256 rateAB =
            _root(cycle.balancePay * cycle.weightTake, cycle.balanceTake * cycle.weightPay);
        (uint256 gapA, uint256 edgeA) = _gap(rateBA, quoteA.bid, quoteB.ask);
        (uint256 gapB, uint256 edgeB) = _gap(rateAB, quoteB.bid, quoteA.ask);
        if (gapA == 0) {
            if (gapB == 0) return 0;
        }
        if (gapA > gapB) {
            (cycle.edge, cycle.rate) = (edgeA, rateBA);
            _venues(cycle, quoteA, quoteB);
            return gapA;
        }
        (cycle.take, cycle.pay) = (cycle.pay, cycle.take);
        (cycle.balanceTake, cycle.balancePay) = (cycle.balancePay, cycle.balanceTake);
        (cycle.weightTake, cycle.weightPay) = (cycle.weightPay, cycle.weightTake);
        (cycle.edge, cycle.rate) = (edgeB, rateAB);
        _venues(cycle, quoteB, quoteA);
        return gapB;
    }

    function _venues(Cycle memory cycle, Quote memory taken, Quote memory paid) internal pure {
        uint256 sell = taken.bidRoute;
        uint256 buy = paid.askRoute;
        if (sell & METRIC_FLAG == 0) cycle.sell = _key(cycle.take, cycle.unit, sell);
        if (sell & METRIC_FLAG != 0) {
            (cycle.sellPool, cycle.sellBook) = (address(uint160(sell)), taken.bidBook);
            // Its input is `take`: the pool's token0 when the route's token is.
            cycle.sellZero = sell & TOKEN_FIRST != 0;
        }
        if (buy & METRIC_FLAG == 0) cycle.buy = _key(cycle.pay, cycle.unit, buy);
        if (buy & METRIC_FLAG != 0) {
            (cycle.buyPool, cycle.buyBook) = (address(uint160(buy)), paid.askBook);
            // Its input is the unit: the pool's token0 when the route's token is not.
            cycle.buyZero = buy & TOKEN_FIRST == 0;
        }
        cycle.worth = taken.worth;
        cycle.askRate = paid.ask;
    }

    /// @dev The two tokens' balances and weights, `take` as laid out being `tokenA`. A
    /// balance too large for the sizing arithmetic, or a pool that cannot be read, is
    /// nothing to balance.
    function _state(Cycle memory cycle) internal view returns (bool) {
        address[] memory list = IndexPool(cycle.pool).tokens();
        uint256 indexA = list.length;
        uint256 indexB = list.length;
        for (uint256 index; index < list.length; index++) {
            if (list[index] == cycle.take) indexA = index;
            if (list[index] == cycle.pay) indexB = index;
        }
        if (indexA == list.length) return false;
        if (indexB == list.length) return false;
        // `balances` refuses to be read while the pool is mid-swap.
        try IndexPool(cycle.pool).balances() returns (uint256[] memory held) {
            (cycle.balanceTake, cycle.balancePay) = (held[indexA], held[indexB]);
        } catch {
            return false;
        }
        uint256[] memory weights = IndexPool(cycle.pool).weights();
        (cycle.weightTake, cycle.weightPay) = (weights[indexA], weights[indexB]);
        if (cycle.balanceTake == 0) return false;
        if (cycle.balancePay == 0) return false;
        if (cycle.balanceTake > type(uint128).max) return false;
        return cycle.balancePay <= type(uint128).max;
    }

    /// @dev Both tokens' venues: every v4 venue's price in one call to the pool manager, and
    /// each Metric venue by its own call.
    function _quotes(
        address pool,
        address tokenA,
        address tokenB,
        address unit,
        address[] memory skip
    ) internal returns (Quote memory quoteA, Quote memory quoteB) {
        uint256[] memory routesA = tokenA == unit ? new uint256[](0) : live[pool][tokenA];
        uint256[] memory routesB = tokenB == unit ? new uint256[](0) : live[pool][tokenB];
        uint256 countA = routesA.length;
        uint256[] memory routes = new uint256[](countA + routesB.length);
        address[] memory owners = new address[](routes.length);
        for (uint256 index; index < routes.length; index++) {
            bool isA = index < countA;
            owners[index] = isA ? tokenA : tokenB;
            routes[index] = isA ? routesA[index] : routesB[index - countA];
        }
        (bytes32[] memory words, uint256[5][] memory books) =
            _prices(owners, routes, unit, skip);
        quoteA = _best(tokenA, unit, routesA, words, books, 0);
        quoteB = _best(tokenB, unit, routesB, words, books, countA);
    }

    /// @dev Every route's price as a v4 state word, and each Metric route's whole reading.
    function _prices(
        address[] memory owners,
        uint256[] memory routes,
        address unit,
        address[] memory skip
    ) internal returns (bytes32[] memory words, uint256[5][] memory books) {
        words = new bytes32[](routes.length);
        books = new uint256[5][](routes.length);
        bytes32[] memory slots = new bytes32[](routes.length);
        uint256 plain;
        for (uint256 index; index < routes.length; index++) {
            uint256 word = routes[index];
            if (word & METRIC_FLAG != 0) {
                // A venue dropped earlier in this call has no price.
                books[index][0] = 1;
                if (_skipped(skip, address(uint160(word)))) continue;
                words[index] = _metricWord(owners[index], unit, word, books[index]);
                continue;
            }
            PoolKey memory key = _key(owners[index], unit, word);
            slots[plain++] = StateLibrary._getPoolStateSlot(key.toId());
        }
        _fill(words, books, slots, plain);
    }

    function _skipped(address[] memory skip, address venue) internal pure returns (bool) {
        for (uint256 index; index < skip.length; index++) {
            if (skip[index] == venue) return true;
        }
        return false;
    }

    /// @dev The v4 venues' state words, read in one call, into the places Metric's left.
    function _fill(
        bytes32[] memory words,
        uint256[5][] memory books,
        bytes32[] memory slots,
        uint256 plain
    ) internal view {
        if (plain == 0) return;
        assembly ("memory-safe") {
            mstore(slots, plain)
        }
        bytes32[] memory loaded = poolManager.extsload(slots);
        uint256 next;
        for (uint256 index; index < words.length; index++) {
            if (books[index][0] != 0) continue;
            if (words[index] != bytes32(0)) continue;
            if (next == plain) break;
            words[index] = loaded[next++];
        }
    }

    /// @dev A Metric venue read as a v4 state word (its price, and its fee where a v4 pool
    /// keeps its own), with the whole reading kept for sizing. No price if the read fails.
    function _metricWord(address token, address unit, uint256 word, uint256[5] memory book)
        internal
        returns (bytes32)
    {
        address low = token < unit ? token : unit;
        try metric.read{ gas: METRIC_READ_GAS }(address(uint160(word)), low) returns (
            uint256[5] memory answer
        ) {
            for (uint256 index; index < 5; index++) {
                book[index] = answer[index];
            }
            return bytes32(answer[0] | answer[1] << 208);
        } catch {
            // Marked as read, so the v4 words are not put in its place.
            book[0] = 1;
            if (_revertedWith(IndexMetric.Locked.selector, 4)) metricLocked = true;
            return bytes32(0);
        }
    }

    /// @dev The arbitrage hook's comparison of prices after fees: the best venue each way,
    /// of either kind. The unit is its own price, and needs no venue.
    function _best(
        address token,
        address unit,
        uint256[] memory routes,
        bytes32[] memory words,
        uint256[5][] memory books,
        uint256 offset
    ) internal pure returns (Quote memory quote) {
        if (token == unit) {
            (quote.bid, quote.ask, quote.worth) = (Q96, Q96, Q96);
            return quote;
        }
        bool tokenFirst = token < unit;
        for (uint256 index; index < routes.length; index++) {
            (uint256 rate, uint24 fee, uint24 levy) =
                V4Read._unpack(words[offset + index], tokenFirst);
            if (rate == 0) continue;
            uint256 keep = V4Read._keepFast(V4Read._swapFee(fee, levy));
            uint256 bid = FixedPointMathLib.fullMulDiv(rate, keep, WAD);
            uint256 ask = FixedPointMathLib.fullMulDiv(Q192 / rate, keep, WAD);
            if (bid > quote.bid) {
                (quote.bid, quote.bidRoute, quote.worth) = (bid, routes[index], rate);
                quote.bidBook = books[offset + index];
            }
            if (ask > quote.ask) {
                (quote.ask, quote.askRoute) = (ask, routes[index]);
                quote.askBook = books[offset + index];
            }
        }
    }

    /// @dev A cycle's gap from its three square-root rates: as a price for the comparison
    /// with `minimumGap`, and as a square root for the legs' price limits.
    function _gap(uint256 rate, uint256 bid, uint256 ask)
        internal
        pure
        returns (uint256 priceGap, uint256 edge)
    {
        if (rate == 0) return (0, 0);
        if (bid == 0) return (0, 0);
        if (ask == 0) return (0, 0);
        uint256 half = FixedPointMathLib.fullMulDiv(rate, bid, Q96);
        if (half > MAX_CYCLE_RATE) return (0, 0);
        uint256 cycleRate = FixedPointMathLib.fullMulDiv(half, ask, Q96);
        if (cycleRate <= Q96) return (0, 0);
        edge = FixedPointMathLib.fullMulDiv(cycleRate - Q96, WAD, Q96);
        if (edge > MAX_EDGE) return (0, 0);
        priceGap = FixedPointMathLib.fullMulDiv(edge, 2 * WAD + edge, WAD);
    }

    /// @dev `sqrt(numerator / denominator)` as a Q96 square-root price, or zero outside the
    /// band the pricing arithmetic is safe in.
    function _root(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        if (numerator / denominator >= 1 << 64) return 0;
        uint256 root =
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(numerator, Q192, denominator));
        if (root < V4Read.MIN_RATE) return 0;
        if (root > V4Read.MAX_RATE) return 0;
        return root;
    }

    /// @dev What of `take` closes the whole gap in the index pool alone, as the cycle's
    /// input: paying in `pay` raises the pool's price of `take` by
    /// `(balanceTake / balanceTake') ^ ((wTake + wPay) / wPay)`. No more than `_mostTaken`.
    function _whole(Cycle memory cycle) internal pure returns (uint256 amount) {
        uint256 wide = WAD + cycle.edge;
        uint256 ratio = FixedPointMathLib.fullMulDiv(wide, wide, WAD);
        uint256 exponent = FixedPointMathLib.fullMulDiv(
            cycle.weightPay, WAD, cycle.weightTake + cycle.weightPay
        );
        uint256 grown = uint256(FixedPointMathLib.powWad(int256(ratio), int256(exponent)));
        if (grown <= WAD) return 0;
        amount = FixedPointMathLib.fullMulDiv(cycle.balanceTake, grown - WAD, grown);
        uint256 most = _mostTaken(cycle);
        if (amount > most) amount = most;
    }

    /// @dev What the pool pays out of `take` for `IndexCycle._most` of `pay`, the most one
    /// cycle puts in: the same limit counted at the cycle's start.
    function _mostTaken(Cycle memory cycle) internal pure returns (uint256) {
        uint256 most = IndexCycle._most(cycle);
        uint256 base =
            FixedPointMathLib.fullMulDiv(cycle.balancePay, WAD, cycle.balancePay + most);
        uint256 exponent = FixedPointMathLib.fullMulDiv(cycle.weightPay, WAD, cycle.weightTake);
        uint256 kept = uint256(FixedPointMathLib.powWad(int256(base), int256(exponent)));
        if (kept >= WAD) return 0;
        return FixedPointMathLib.fullMulDiv(cycle.balanceTake, WAD - kept, WAD);
    }

    /// @dev The Metric pool named by the last try's `MetricFailed`, or zero. Only the first
    /// 36 bytes of what the try returned are read.
    function _refused() internal pure returns (address) {
        if (_revertedWith(MetricFailed.selector, 36)) return _named();
        return address(0);
    }

    /// @dev Whether the last try failed because the pool manager was short of something it
    /// owed the balancer. That is a drain, not a fault of the pair, so it is never set aside.
    /// Only the first four bytes of what the try returned are read.
    function _drained() internal pure returns (bool) {
        return _revertedWith(V4Read.Drained.selector, 4);
    }

    function _entered() internal view returns (bool entered) {
        uint256 slot = ENTERED_SLOT;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
    }

    function _setEntered(uint256 value) internal {
        uint256 slot = ENTERED_SLOT;
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
