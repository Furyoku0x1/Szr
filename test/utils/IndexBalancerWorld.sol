// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";
import { IndexBalancer } from "../../src/index/IndexBalancer.sol";
import { IndexMetric } from "../../src/index/IndexMetric.sol";
import { IndexBalancerState } from "../../src/index/IndexBalancerState.sol";
import { IndexSettings } from "../../src/index/IndexSettings.sol";
import { Cycle } from "../../src/index/IndexSizer.sol";
import { SizingQuoter } from "./ArbitrageSizing.sol";
import { MockMetricFactory } from "./metric/MockMetricPool.sol";
import { MockBinPool } from "./metric/MockBinPool.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
import { HostileToken } from "./Routers.sol";
import { IndexWorld, IndexToken } from "./IndexWorld.sol";

/// @dev Deploys the balancer as the deploy script does: its Metric reader and settings module
/// first, then the balancer from its artifact, so that no test contract carries its creation
/// code.
function deployBalancer(
    Vm vm,
    IPoolManager manager,
    IndexPoolFactory factory,
    IMetricFactory metricFactory
) returns (BalancerHarness) {
    IndexMetric metric = new IndexMetric(metricFactory);
    IndexSettings settings = new IndexSettings(manager, factory, metric);
    return BalancerHarness(
        payable(vm.deployCode(
                "IndexBalancerWorld.sol:BalancerHarness",
                abi.encode(manager, factory, metric, settings)
            ))
    );
}

/// @dev The balancer with its planning exposed, for tests that need the cycle it would run.
/// It adds views only.
contract BalancerHarness is IndexBalancer {
    constructor(
        IPoolManager poolManager_,
        IndexPoolFactory factory_,
        IndexMetric metric_,
        IndexSettings settings_
    ) IndexBalancer(poolManager_, factory_, metric_, settings_) { }

    function plan(address pool, address tokenA, address tokenB)
        external
        returns (Cycle memory cycle, uint256 found)
    {
        return _plan(pool, tokenA, tokenB, new address[](0));
    }

    function whole(Cycle memory cycle) external pure returns (uint256) {
        return _whole(cycle);
    }

    function mostTaken(Cycle memory cycle) external pure returns (uint256) {
        return _mostTaken(cycle);
    }
}

/// @dev A token whose balance of one account reads high by `lie`, and rises by `step` each
/// time that account is paid: the pool manager then credits more than was sent.
contract LyingToken is ERC20 {
    address public victim;
    uint256 public lie;
    uint256 public step;

    function name() public pure override returns (string memory) {
        return "Lying token";
    }

    function symbol() public pure override returns (string memory) {
        return "LIE";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setLie(address victim_, uint256 step_) external {
        victim = victim_;
        step = step_;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        uint256 real = super.balanceOf(owner);
        if (owner == victim) return real + lie;
        return real;
    }

    function _afterTokenTransfer(address, address to, uint256) internal override {
        if (to == victim) lie += step;
    }
}

/// @dev A token that refuses transfers to one address, as a blocklist would.
contract RefusingToken is ERC20 {
    address public refused;

    function name() public pure override returns (string memory) {
        return "Refusing token";
    }

    function symbol() public pure override returns (string memory) {
        return "NO";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function refuse(address who) external {
        refused = who;
    }

    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        require(to != refused, "refused");
    }
}

/// @dev Reaches an index pool from inside its own unlock of the pool manager, as a router
/// that mixes v4 pools with the index pool would. Modes: pay a token in before the call
/// (`PAY_FIRST`), mark a token and pay only after (`MARK_FIRST`), mark one and never pay
/// (`MARK_ONLY`), mark a hostile token armed with `amount` as its mode (`HOSTILE`), hold a
/// debt of its own across the call (`OUTER`), and take all of a token out across it
/// (`DRAIN`). A call that fails is re-raised as it failed.
contract IndexRouter is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    uint256 public constant PAY_FIRST = 0;
    uint256 public constant MARK_FIRST = 1;
    uint256 public constant OUTER = 2;
    uint256 public constant DRAIN = 3;
    uint256 public constant MARK_ONLY = 4;
    uint256 public constant HOSTILE = 5;

    IPoolManager internal immutable manager;
    uint256 public credited;
    uint256 public profit;
    int256 public deltaBefore;
    int256 public deltaAfter;
    uint256 public countBefore;
    uint256 public countAfter;
    address public markedAfter;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function run(uint256 mode, address marked, uint256 amount, bytes calldata call) external {
        manager.unlock(abi.encode(mode, marked, amount, call));
    }

    /// Pays a token into the locked pool manager, then makes the call: the payment is
    /// waiting, unsettled, when the call reaches the pool.
    function payLocked(address marked, uint256 amount, bytes calldata call) external {
        manager.sync(Currency.wrap(marked));
        IndexToken(marked).transfer(address(manager), amount);
        _call(call);
        markedAfter = Currency.unwrap(manager.getSyncedCurrency());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 mode, address marked, uint256 amount, bytes memory call) =
            abi.decode(data, (uint256, address, uint256, bytes));
        if (mode == HOSTILE) {
            HostileToken(marked).arm(0);
            manager.sync(Currency.wrap(marked));
            HostileToken(marked).arm(amount);
            _call(call);
            markedAfter = Currency.unwrap(manager.getSyncedCurrency());
            HostileToken(marked).arm(0);
            return "";
        }
        if (mode < OUTER) return _pay(mode, marked, amount, call);
        if (mode == MARK_ONLY) {
            manager.sync(Currency.wrap(marked));
            _call(call);
            markedAfter = Currency.unwrap(manager.getSyncedCurrency());
            return "";
        }
        Currency asset = Currency.wrap(marked);
        if (mode == DRAIN) amount = IndexToken(marked).balanceOf(address(manager));
        manager.take(asset, address(this), amount);
        deltaBefore = manager.currencyDelta(address(this), asset);
        countBefore = manager.getNonzeroDeltaCount();
        bytes memory result = _call(call);
        if (result.length >= 32) profit = abi.decode(result, (uint256));
        deltaAfter = manager.currencyDelta(address(this), asset);
        countAfter = manager.getNonzeroDeltaCount();
        manager.sync(asset);
        IndexToken(marked).transfer(address(manager), amount);
        manager.settle();
        return "";
    }

    /// The payment counts in full if, after the router's own settle, the pool manager owes
    /// the router exactly what it paid, whoever settled it.
    function _pay(uint256 mode, address marked, uint256 amount, bytes memory call)
        internal
        returns (bytes memory)
    {
        Currency asset = Currency.wrap(marked);
        manager.sync(asset);
        if (mode == PAY_FIRST) IndexToken(marked).transfer(address(manager), amount);
        _call(call);
        markedAfter = Currency.unwrap(manager.getSyncedCurrency());
        if (mode == MARK_FIRST) IndexToken(marked).transfer(address(manager), amount);
        manager.settle();
        int256 owed = manager.currencyDelta(address(this), asset);
        credited = owed > 0 ? uint256(owed) : 0;
        if (credited != 0) manager.take(asset, address(this), credited);
        return "";
    }

    function approve(address token, address spender) external {
        IndexToken(token).approve(spender, type(uint256).max);
    }

    function _call(bytes memory call) internal returns (bytes memory result) {
        (address target, bytes memory payload) = abi.decode(call, (address, bytes));
        bool ok;
        (ok, result) = target.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

/// @dev Calls the balancer as if it were a pool, claiming the balancer as its hook.
contract FakeIndexPool {
    address public hook;

    constructor(address hook_) {
        hook = hook_;
    }

    function poke(address tokenA, address tokenB) external {
        IndexBalancer(hook).beforeSwap(msg.sender, tokenA, tokenB);
    }
}

/// @dev A real pool manager and index pools hooked to the balancer, with plain v4 venues.
abstract contract BalancerWorld is IndexWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint32 internal constant HOOK_GAS = 3_000_000;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    /// Deep enough that a cycle closes most of the gap in the index pool.
    uint128 internal constant DEEP = 1e23;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal provider;
    PoolSwapTest internal swapper;
    SizingQuoter internal quoter;
    BalancerHarness internal balancer;
    MockMetricFactory internal metricFactory;
    /// The balancer, typed as its settings module, which it reaches by delegatecall.
    IndexSettings internal settings;

    function _deployBalancer(IPoolManager pm, IndexPoolFactory f, IMetricFactory m)
        internal
        returns (BalancerHarness)
    {
        return deployBalancer(vm, pm, f, m);
    }

    function setUp() public virtual override {
        super.setUp();
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        provider = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        quoter = new SizingQuoter(manager);
        metricFactory = new MockMetricFactory();
        // Deployed from its artifact so that no test contract carries its 47 KB of creation
        // code, which would put the test contracts over Foundry's size limit.
        balancer = _deployBalancer(manager, factory, IMetricFactory(address(metricFactory)));
        settings = IndexSettings(address(balancer));
    }

    /// Two new tokens of the given decimals, sorted.
    function _two(uint8 first, uint8 second) internal returns (address[] memory list) {
        list = _tokens(_pair(first, second));
        _ready(list);
    }

    function _ready(address[] memory list) internal {
        for (uint256 index; index < list.length; index++) {
            _readyToken(list[index]);
        }
    }

    function _readyToken(address token) internal {
        IndexToken(token).mint(address(this), 1e40);
        IndexToken(token).approve(address(provider), type(uint256).max);
        IndexToken(token).approve(address(swapper), type(uint256).max);
    }

    /// A started pool hooked to the balancer, holding `amounts` (raw) of `list`.
    function _hooked(address[] memory list, uint256[] memory weights, uint256[] memory amounts)
        internal
        returns (IndexPool pool)
    {
        pool = _create(list, weights, FEE, address(balancer), HOOK_GAS);
        for (uint256 index; index < list.length; index++) {
            IndexToken(list[index]).approve(address(pool), type(uint256).max);
        }
        pool.start(amounts, 1e24, FAR);
    }

    function _amounts(uint256 first, uint256 second) internal pure returns (uint256[] memory) {
        return _weights(first, second);
    }

    /// A hookless v4 pool of `token` and `unit` at `price` raw units per raw token (WAD),
    /// with `units` of liquidity over the whole range.
    function _venue(address token, address unit, uint256 price, uint128 units, uint24 fee)
        internal
        returns (PoolKey memory key)
    {
        bool tokenFirst = token < unit;
        key = PoolKey(
            Currency.wrap(tokenFirst ? token : unit),
            Currency.wrap(tokenFirst ? unit : token),
            fee,
            60,
            IHooks(address(0))
        );
        uint256 ratio = tokenFirst ? price : FixedPointMathLib.fullMulDiv(1e18, 1e18, price);
        uint256 root = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(ratio, Q192, 1e18));
        manager.initialize(key, uint160(root));
        if (units == 0) return key;
        int24 top = TickMath.maxUsableTick(60);
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-top, top, int256(uint256(units)), 0), ""
        );
    }

    function _routes(PoolKey memory key)
        internal
        pure
        returns (IndexBalancerState.Route[] memory)
    {
        IndexBalancerState.Route[] memory list = new IndexBalancerState.Route[](1);
        list[0] = IndexBalancerState.Route(false, key, address(0));
        return list;
    }

    function _attach(
        IndexPool pool,
        address unit,
        address token,
        PoolKey memory key,
        uint256 minimumGap,
        uint256 minimumProfit
    ) internal {
        if (settings.unitOf(address(pool)) == address(0)) {
            settings.setUnit(address(pool), unit);
            settings.setLimits(address(pool), minimumGap, minimumProfit);
        }
        settings.setRoutes(address(pool), token, _routes(key));
        _apply(pool, token);
    }

    /// Settings made once a pool has started wait a day: waits it, and applies whatever is
    /// announced for the pool's unit, its limits and `token`'s routes.
    function _apply(IndexPool pool, address token) internal {
        if (!pool.started()) return;
        vm.warp(block.timestamp + 1 days);
        (, uint256 unitReady) = settings.pendingUnit(address(pool));
        if (unitReady != 0) settings.applyChange(address(pool), address(pool));
        if (settings.limitsReadyAt(address(pool)) != 0) {
            settings.applyChange(address(pool), address(0));
        }
        (, uint256 routesReady) = settings.pendingRoutes(address(pool), token);
        if (routesReady != 0) settings.applyChange(address(pool), token);
    }

    /// An exact-input swap on a venue.
    function _push(PoolKey memory key, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        swapper.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// The pool's price of `token` in `other`, WAD, raw units.
    function _poolPrice(IndexPool pool, address token, address other)
        internal
        view
        returns (uint256)
    {
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        uint256[] memory weights = pool.weights();
        uint256 at = list[0] == token ? 0 : 1;
        uint256 to = list[0] == other ? 0 : 1;
        if (list.length > 2) {
            for (uint256 index; index < list.length; index++) {
                if (list[index] == token) at = index;
                if (list[index] == other) to = index;
            }
        }
        return
            FixedPointMathLib.fullMulDiv(held[to] * weights[at], 1e18, held[at] * weights[to]);
    }

    /// A venue's mid price of `token` in its other token, WAD, raw units.
    function _venuePrice(PoolKey memory key, address token) internal view returns (uint256) {
        (uint160 root,,,) = manager.getSlot0(key.toId());
        uint256 ratio = FixedPointMathLib.fullMulDiv(uint256(root) * uint256(root), 1e18, Q192);
        if (Currency.unwrap(key.currency0) == token) return ratio;
        return FixedPointMathLib.fullMulDiv(1e18, 1e18, ratio);
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 high = a > b ? a : b;
        uint256 low = a > b ? b : a;
        return FixedPointMathLib.fullMulDiv(high - low, 1e18, low);
    }

    /// Invariant 1: no tokens, no allowance to the pool, nothing at the pool manager.
    function _assertClean(IndexPool pool) internal view {
        address[] memory list = pool.tokens();
        for (uint256 index; index < list.length; index++) {
            _assertCleanToken(pool, list[index]);
        }
        address unit = settings.unitOf(address(pool));
        if (unit != address(0)) _assertCleanToken(pool, unit);
    }

    function _assertCleanToken(IndexPool pool, address token) internal view {
        assertEq(IndexToken(token).balanceOf(address(balancer)), 0, "balancer holds a token");
        assertEq(
            IndexToken(token).allowance(address(balancer), address(pool)), 0, "allowance left"
        );
        uint256 claim = manager.balanceOf(address(balancer), uint256(uint160(token)));
        assertEq(claim, 0, "claim at the pool manager");
    }

    /// Invariant 2: every swap the balancer made in a pool is matched by a donation to the
    /// same pool, from the logs recorded since `vm.recordLogs`. Returns the number of swaps.
    function _assertDonated() internal returns (uint256 swaps) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapped = IndexPool.Swapped.selector;
        bytes32 donated = IndexPool.Donated.selector;
        bytes32 donor = bytes32(uint256(uint160(address(balancer))));
        address open;
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory entry = logs[index];
            if (entry.topics.length < 2) continue;
            if (entry.topics[1] != donor) continue;
            if (entry.topics[0] == swapped) {
                assertEq(open, address(0), "a swap with no donation");
                open = entry.emitter;
                swaps++;
            }
            if (entry.topics[0] == donated) {
                assertEq(entry.emitter, open, "donation to another pool");
                open = address(0);
            }
        }
        assertEq(open, address(0), "a swap with no donation");
    }

    /// Invariants 1 to 3 after a test's calls: the third holds when the calls returned, as
    /// a pool manager left owed reverts the unlock.
    function _assertInvariants(IndexPool pool) internal returns (uint256 swaps) {
        _assertClean(pool);
        swaps = _assertDonated();
        assertFalse(TransientStateLibrary.isUnlocked(manager), "pool manager left unlocked");
    }

    /// The best cycle input for `cycle`, by golden-section search over real quotes: the venues
    /// through `SizingQuoter`, then the index pool quoted as the balancer (fee-free).
    function _reference(IndexPool pool, Cycle memory cycle, uint256 ceiling)
        internal
        returns (uint256 best, uint256 most)
    {
        uint256 low;
        uint256 high = ceiling;
        uint256 left = high - high * 618_034 / 1e6;
        uint256 right = high * 618_034 / 1e6;
        uint256 leftProfit = _cycleProfit(pool, cycle, left);
        uint256 rightProfit = _cycleProfit(pool, cycle, right);
        (best, most) = leftProfit > rightProfit ? (left, leftProfit) : (right, rightProfit);
        for (uint256 round = 2; round < 60; round++) {
            // Integer rounding drifts the points together once the interval is small.
            if (left >= right) break;
            if (leftProfit < rightProfit) {
                low = left;
                (left, leftProfit) = (right, rightProfit);
                right = low + (high - low) * 618_034 / 1e6;
                rightProfit = _cycleProfit(pool, cycle, right);
                if (rightProfit > most) (best, most) = (right, rightProfit);
            } else {
                high = right;
                (right, rightProfit) = (left, leftProfit);
                left = high - (high - low) * 618_034 / 1e6;
                leftProfit = _cycleProfit(pool, cycle, left);
                if (leftProfit > most) (best, most) = (left, leftProfit);
            }
        }
    }

    function _cycleProfit(IndexPool pool, Cycle memory cycle, uint256 size)
        internal
        returns (uint256)
    {
        if (size == 0) return 0;
        uint256 paid = size;
        if (cycle.take != cycle.unit) {
            paid = _legQuote(cycle.sellPool, cycle.sell, cycle.take, cycle.sellZero, paid);
        }
        if (cycle.pay != cycle.unit) {
            paid = _legQuote(cycle.buyPool, cycle.buy, cycle.unit, cycle.buyZero, paid);
        }
        if (paid == 0) return 0;
        uint256 back;
        vm.prank(address(balancer));
        try pool.quoteSwap(cycle.pay, cycle.take, paid, true) returns (uint256, uint256 got) {
            back = got;
        } catch {
            return 0;
        }
        return back > size ? back - size : 0;
    }

    /// One outside trade, quoted on its Metric pool or through `SizingQuoter`. A Metric
    /// trade that would not fill in full is no trade.
    function _legQuote(
        address metricPool,
        PoolKey memory key,
        address input,
        bool zero,
        uint256 amount
    ) internal returns (uint256) {
        if (metricPool != address(0)) {
            (uint256 taken, uint256 paid,) = MockBinPool(metricPool).quote(zero, amount);
            return taken == amount ? paid : 0;
        }
        PoolKey[] memory path = new PoolKey[](1);
        address[] memory inputs = new address[](1);
        (path[0], inputs[0]) = (key, input);
        return quoter.quote(path, inputs, amount);
    }

    /// A Metric pool of `token` and `unit` with one bin holding `reserve` (18-decimal) of
    /// each, its midpoint `price` whole units per whole token (WAD) and a 0.1% spread.
    /// `tokenFirst` makes the token the pool's token0.
    function _metricVenue(
        address token,
        address unit,
        uint256 price,
        uint104 reserve,
        bool tokenFirst
    ) internal returns (MockBinPool venue) {
        (address first, address second) = tokenFirst ? (token, unit) : (unit, token);
        uint256 scale0 = 10 ** (18 - IndexToken(first).decimals());
        uint256 scale1 = 10 ** (18 - IndexToken(second).decimals());
        uint256 midX64 = tokenFirst
            ? FixedPointMathLib.fullMulDiv(price, 1 << 64, 1e18)
            : FixedPointMathLib.fullMulDiv(1e18, 1 << 64, price);
        venue = new MockBinPool(
            address(metricFactory),
            first,
            second,
            scale0,
            scale1,
            midX64,
            1000,
            reserve,
            reserve
        );
        metricFactory.register(address(venue));
        IndexToken(first).mint(address(venue), reserve / scale0);
        IndexToken(second).mint(address(venue), reserve / scale1);
    }

    function _metricRoutes(address venue)
        internal
        pure
        returns (IndexBalancerState.Route[] memory list)
    {
        list = new IndexBalancerState.Route[](1);
        list[0].metric = true;
        list[0].pool = venue;
    }

    /// Sets the unit and limits if not yet set, then `token`'s routes.
    function _attachRoutes(
        IndexPool pool,
        address unit,
        address token,
        IndexBalancerState.Route[] memory routes,
        uint256 minimumGap,
        uint256 minimumProfit
    ) internal {
        if (settings.unitOf(address(pool)) == address(0)) {
            settings.setUnit(address(pool), unit);
            settings.setLimits(address(pool), minimumGap, minimumProfit);
        }
        settings.setRoutes(address(pool), token, routes);
        _apply(pool, token);
    }

    function _path(Cycle memory cycle)
        internal
        pure
        returns (PoolKey[] memory path, address[] memory inputs)
    {
        uint256 count;
        if (cycle.take != cycle.unit) count++;
        if (cycle.pay != cycle.unit) count++;
        path = new PoolKey[](count);
        inputs = new address[](count);
        uint256 next;
        if (cycle.take != cycle.unit) {
            (path[next], inputs[next]) = (cycle.sell, cycle.take);
            next++;
        }
        if (cycle.pay != cycle.unit) (path[next], inputs[next]) = (cycle.buy, cycle.unit);
    }
}
