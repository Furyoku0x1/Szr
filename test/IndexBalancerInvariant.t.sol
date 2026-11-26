// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../src/index/IndexBalancerState.sol";
import { IndexSettings } from "../src/index/IndexSettings.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld, IndexRouter } from "./utils/IndexBalancerWorld.sol";
import { MockBinPool } from "./utils/metric/MockBinPool.sol";

/// @dev Everything that can happen to balanced pools, done the same way to an identical pool
/// with no hook where it applies, so that depositors' outcomes can be compared. Every call
/// is wrapped so that a refusal only skips it.
contract BalancerHandler is Test {
    IndexBalancer public immutable balancer;
    IndexSettings internal immutable settings;
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable swapper;
    IndexRouter internal immutable router;
    address internal immutable unit;
    IndexPool[] public pools;
    IndexPool[] public twins;
    address[] public tokens;
    mapping(address token => PoolKey) public v4Of;
    mapping(address token => MockBinPool) public metricOf;
    uint256 public calls;
    /// Set by a call that broke one of the balancer's invariants, with the reason.
    string public broken;

    constructor(
        IndexBalancer balancer_,
        IPoolManager manager_,
        PoolSwapTest swapper_,
        address unit_
    ) {
        balancer = balancer_;
        settings = IndexSettings(address(balancer_));
        manager = manager_;
        swapper = swapper_;
        unit = unit_;
        router = new IndexRouter(manager_);
    }

    function add(IndexPool pool, IndexPool twin) external {
        pools.push(pool);
        twins.push(twin);
        address[] memory list = pool.tokens();
        for (uint256 index; index < list.length; index++) {
            IndexToken(list[index]).approve(address(pool), type(uint256).max);
            IndexToken(list[index]).approve(address(twin), type(uint256).max);
            router.approve(list[index], address(pool));
        }
    }

    function venues(address token, PoolKey calldata key, MockBinPool metric) external {
        tokens.push(token);
        v4Of[token] = key;
        metricOf[token] = metric;
        IndexToken(token).approve(address(swapper), type(uint256).max);
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    // ------------------------------------------------------------------ holders

    function swap(uint256 which, uint256 a, uint256 b, uint256 size, bool exactIn) external {
        (IndexPool pool, IndexPool twin, address tokenIn, address tokenOut) = _pick(which, a, b);
        if (tokenIn == tokenOut) return;
        uint256 amount = _share(pool, tokenOut, size, 15);
        if (exactIn) amount = _share(pool, tokenIn, size, 15);
        uint256 limit = exactIn ? 0 : type(uint256).max;
        vm.recordLogs();
        try pool.swap(tokenIn, tokenOut, amount, exactIn, limit, address(this), _far()) { }
            catch { }
        _checkCycles();
        try twin.swap(tokenIn, tokenOut, amount, exactIn, limit, address(this), _far()) { }
            catch { }
        calls++;
    }

    function join(uint256 which, uint256 size) external {
        (IndexPool pool, IndexPool twin,,) = _pick(which, 0, 0);
        uint256 shares = bound(size, 1e18, pool.totalSupply() / 20);
        uint256[] memory most = new uint256[](pool.tokens().length);
        for (uint256 index; index < most.length; index++) {
            most[index] = type(uint256).max;
        }
        try pool.join(shares, most, _far()) {
            try twin.join(shares, most, _far()) { } catch { }
        } catch { }
        calls++;
    }

    function exit(uint256 which, uint256 size) external {
        (IndexPool pool, IndexPool twin,,) = _pick(which, 0, 0);
        uint256 held = pool.balanceOf(address(this));
        if (held < 1e18) return;
        uint256 shares = bound(size, 1e18, held / 2 + 1e18);
        if (shares > twin.balanceOf(address(this))) return;
        uint256[] memory least = new uint256[](pool.tokens().length);
        try pool.exit(shares, least, new address[](0), _far()) {
            try twin.exit(shares, least, new address[](0), _far()) { } catch { }
        } catch { }
        calls++;
    }

    function donate(uint256 which, uint256 a, uint256 size) external {
        (IndexPool pool, IndexPool twin, address token,) = _pick(which, a, 0);
        uint256 amount = _share(pool, token, size, 1);
        try pool.donate(token, amount) {
            try twin.donate(token, amount) { } catch { }
        } catch { }
        calls++;
    }

    /// A swap from a router that has marked a token, paying first or only after.
    function markedSwap(uint256 which, uint256 a, uint256 b, uint256 size, bool payFirst)
        external
    {
        (IndexPool pool,, address tokenIn, address tokenOut) = _pick(which, a, b);
        if (tokenIn == tokenOut) return;
        uint256 amount = _share(pool, tokenIn, size, 10);
        IndexToken(tokenIn).mint(address(router), amount * 2);
        bytes memory call = abi.encode(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (tokenIn, tokenOut, amount, true, 0, address(router), _far())
            )
        );
        uint256 mode = payFirst ? router.PAY_FIRST() : router.MARK_FIRST();
        vm.recordLogs();
        try router.run(mode, tokenIn, amount, call) {
            if (router.credited() != amount) broken = "a marked payment was not credited";
        } catch { }
        _checkCycles();
        calls++;
    }

    // ------------------------------------------------------------------ the balancer

    /// A keeper's call: it must never revert, and never lower the pool's value function.
    function keeper(uint256 which, uint256 a, uint256 b) external {
        (IndexPool pool,, address tokenA, address tokenB) = _pick(which, a, b);
        int256 before = _valueFunction(pool);
        vm.recordLogs();
        try balancer.balance(address(pool), tokenA, tokenB) { }
        catch {
            broken = "balance reverted";
        }
        _checkCycles();
        if (_valueFunction(pool) < before - 1e9) broken = "the value function fell";
        calls++;
    }

    /// A keeper's call from inside a router that holds the pool manager's whole balance of a
    /// token: silent, whatever it finds.
    function drainedKeeper(uint256 which, uint256 a, uint256 b, uint256 c) external {
        (IndexPool pool,, address tokenA, address tokenB) = _pick(which, a, b);
        address drained = tokens[c % tokens.length];
        // The router itself cannot move a paused token.
        if (IndexToken(drained).paused()) return;
        bytes memory call = abi.encode(
            address(balancer),
            abi.encodeCall(IndexBalancer.balance, (address(pool), tokenA, tokenB))
        );
        vm.recordLogs();
        try router.run(router.DRAIN(), drained, 0, call) { }
        catch {
            broken = "a drained keeper call reverted";
        }
        _checkCycles();
        calls++;
    }

    // ------------------------------------------------------------------ the world

    function moveV4(uint256 t, uint256 size, bool up) external {
        address token = tokens[t % tokens.length];
        PoolKey memory key = v4Of[token];
        if (key.tickSpacing == 0) return;
        address input = up ? unit : token;
        uint256 amount = bound(size, 1, 30) * 10 ** IndexToken(input).decimals();
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        try swapper.swap(key, params, PoolSwapTest.TestSettings(false, false), "") { } catch { }
        calls++;
    }

    function moveMetric(uint256 t, uint256 percent, bool up) external {
        MockBinPool venue = metricOf[tokens[t % tokens.length]];
        if (address(venue) == address(0)) return;
        uint256 step = bound(percent, 1, 8);
        venue.setMid(up ? venue.mid() * (100 + step) / 100 : venue.mid() * (100 - step) / 100);
        calls++;
    }

    function metricFailure(uint256 t, uint256 mode) external {
        MockBinPool venue = metricOf[tokens[t % tokens.length]];
        if (address(venue) == address(0)) return;
        uint256 kind = mode % 6;
        venue.setSwitches(kind == 1 ? 1 : 0, kind == 2, kind == 3, kind == 4);
        venue.setMaxFill(kind == 5 ? 1e15 : type(uint256).max);
        calls++;
    }

    function pause(uint256 t, bool on) external {
        IndexToken(tokens[t % tokens.length]).setPaused(on);
        calls++;
    }

    /// A later change of a token's routes, announced and applied after the wait: here the
    /// routes are only put back as they were, after a day.
    function reroute(uint256 which, uint256 a) external {
        (IndexPool pool,, address token,) = _pick(which, a, 0);
        if (token == unit) return;
        IndexBalancerState.Route[] memory routes = settings.routesOf(address(pool), token);
        vm.prank(pool.creator());
        settings.setRoutes(address(pool), token, routes);
        vm.warp(block.timestamp + 1 days);
        try settings.applyChange(address(pool), token) { }
        catch {
            broken = "applying an announced change reverted";
        }
        calls++;
    }

    function wait(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3 days));
        calls++;
    }

    // ------------------------------------------------------------------ helpers

    function _pick(uint256 which, uint256 a, uint256 b)
        internal
        view
        returns (IndexPool pool, IndexPool twin, address tokenA, address tokenB)
    {
        uint256 at = which % pools.length;
        (pool, twin) = (pools[at], twins[at]);
        address[] memory list = pool.tokens();
        (tokenA, tokenB) = (list[a % list.length], list[b % list.length]);
    }

    /// Up to `percent`% of the pool's balance of `token`, at least a little.
    function _share(IndexPool pool, address token, uint256 size, uint256 percent)
        internal
        view
        returns (uint256)
    {
        address[] memory list = pool.tokens();
        uint256 held;
        for (uint256 index; index < list.length; index++) {
            if (list[index] == token) held = pool.balances()[index];
        }
        uint256 least = 10 ** IndexToken(token).decimals() / 100;
        return bound(size, least, held * percent / 100 + least);
    }

    function _far() internal pure returns (uint256) {
        return type(uint256).max;
    }

    /// `Σ w ln b`, the log of the value function, at 18 decimals.
    function _valueFunction(IndexPool pool) internal view returns (int256 total) {
        uint256[] memory held = pool.balances();
        uint256[] memory weights = pool.weights();
        for (uint256 index; index < held.length; index++) {
            total += FixedPointMathLib.lnWad(int256(held[index] * 1e12))
            * int256(weights[index]) / 1e18;
        }
    }

    /// Invariant 2 on the logs recorded since the call began: every swap the balancer made
    /// in a pool is followed by a donation from it to the same pool.
    function _checkCycles() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 donor = bytes32(uint256(uint160(address(balancer))));
        address open;
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory entry = logs[index];
            if (entry.topics.length < 2) continue;
            if (entry.topics[1] != donor) continue;
            if (entry.topics[0] == IndexPool.Swapped.selector) {
                if (open != address(0)) broken = "a balancer swap with no donation";
                open = entry.emitter;
            }
            if (entry.topics[0] == IndexPool.Donated.selector) {
                if (entry.emitter != open) broken = "a donation to another pool";
                open = address(0);
            }
        }
        if (open != address(0)) broken = "a balancer swap with no donation";
    }
}

/// @dev The balancer's invariant suite: pools of 2, 5 and 8 tokens with mixed decimals and
/// mixed venues, each beside an identical pool with no hook.
contract IndexBalancerInvariantTest is BalancerWorld {
    BalancerHandler internal handler;
    address internal unit;
    address[] internal all;

    function setUp() public override {
        super.setUp();
        unit = address(new IndexToken(18));
        _readyToken(unit);
        handler = new BalancerHandler(balancer, manager, swapper, unit);
        uint8[8] memory places = [6, 18, 18, 6, 18, 8, 18, 6];
        for (uint256 index; index < 8; index++) {
            address token = address(new IndexToken(places[index]));
            _readyToken(token);
            IndexToken(token).mint(address(handler), 1e40);
            all.push(token);
            _venuesFor(token, index);
        }
        IndexToken(unit).mint(address(handler), 1e40);
        _pools();
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](14);
        actions[0] = BalancerHandler.swap.selector;
        actions[1] = BalancerHandler.join.selector;
        actions[2] = BalancerHandler.exit.selector;
        actions[3] = BalancerHandler.donate.selector;
        actions[4] = BalancerHandler.markedSwap.selector;
        actions[5] = BalancerHandler.keeper.selector;
        actions[6] = BalancerHandler.drainedKeeper.selector;
        actions[7] = BalancerHandler.moveV4.selector;
        actions[8] = BalancerHandler.moveMetric.selector;
        actions[9] = BalancerHandler.metricFailure.selector;
        actions[10] = BalancerHandler.pause.selector;
        actions[11] = BalancerHandler.reroute.selector;
        actions[12] = BalancerHandler.wait.selector;
        actions[13] = BalancerHandler.swap.selector;
        targetSelector(FuzzSelector(address(handler), actions));
    }

    /// Every third token on v4 only, every third on Metric only, the rest on both.
    function _venuesFor(address token, uint256 index) internal {
        uint256 price = 10 ** 18 * 1e18 / 10 ** IndexToken(token).decimals();
        PoolKey memory key;
        MockBinPool metric;
        if (index % 3 != 1) key = _venue(token, unit, price, 1e24, 3000);
        if (index % 3 != 0) metric = _metricVenue(token, unit, 1e18, 1e24, index % 2 == 0);
        handler.venues(token, key, metric);
        IndexToken(token).setPaused(false);
    }

    function _pools() internal {
        address[] memory two = new address[](2);
        (two[0], two[1]) = (all[0], unit);
        _pair(two);
        address[] memory five = new address[](5);
        for (uint256 index; index < 5; index++) {
            five[index] = all[index + 1];
        }
        _pair(five);
        address[] memory eight = new address[](8);
        for (uint256 index; index < 7; index++) {
            eight[index] = all[index];
        }
        eight[7] = unit;
        _pair(eight);
    }

    /// A balanced pool and its twin with no hook, the same tokens, weights and start.
    function _pair(address[] memory list) internal {
        _sortList(list);
        uint256[] memory weights = _equal(list.length);
        uint256[] memory amounts = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            amounts[index] = 10_000 * 10 ** IndexToken(list[index]).decimals();
            IndexToken(list[index]).approve(address(factory), type(uint256).max);
        }
        // The balanced pool's settings are made before it starts, so they apply at once.
        IndexPool pool = _create(list, weights, FEE, address(balancer), HOOK_GAS);
        for (uint256 index; index < list.length; index++) {
            IndexToken(list[index]).approve(address(pool), type(uint256).max);
        }
        settings.setUnit(address(pool), unit);
        settings.setLimits(address(pool), 1e15, 0);
        for (uint256 index; index < list.length; index++) {
            if (list[index] == unit) continue;
            settings.setRoutes(address(pool), list[index], _routesOf(list[index]));
        }
        pool.start(amounts, 1e24, FAR);
        IndexPool twin =
            IndexPool(factory.create("Twin", "TWN", list, weights, FEE, address(0), 0));
        for (uint256 index; index < list.length; index++) {
            IndexToken(list[index]).approve(address(twin), type(uint256).max);
        }
        twin.start(amounts, 1e24, FAR);
        pool.transfer(address(handler), 1e23);
        twin.transfer(address(handler), 1e23);
        handler.add(pool, twin);
    }

    function _routesOf(address token)
        internal
        view
        returns (IndexBalancerState.Route[] memory)
    {
        (PoolKey memory key) = _keyOf(token);
        MockBinPool metric = handler.metricOf(token);
        uint256 count = (key.tickSpacing == 0 ? 0 : 1) + (address(metric) == address(0) ? 0 : 1);
        IndexBalancerState.Route[] memory routes = new IndexBalancerState.Route[](count);
        uint256 next;
        if (key.tickSpacing != 0) routes[next++].venue = key;
        if (address(metric) != address(0)) {
            (routes[next].metric, routes[next].pool) = (true, address(metric));
        }
        return routes;
    }

    function _keyOf(address token) internal view returns (PoolKey memory key) {
        (key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks) =
            handler.v4Of(token);
    }

    function _sortList(address[] memory list) internal pure {
        for (uint256 index = 1; index < list.length; index++) {
            address moving = list[index];
            uint256 at = index;
            while (at > 0) {
                if (list[at - 1] < moving) break;
                list[at] = list[at - 1];
                at--;
            }
            list[at] = moving;
        }
    }

    // ------------------------------------------------------------------ invariants

    /// Invariants 1 and 3 to 5 after every call, and 2, 4 and 6 as the handler saw them.
    function invariant_balancer() public view {
        assertEq(handler.broken(), "", "a balancer invariant broke");
        assertFalse(TransientStateLibrary.isUnlocked(manager), "pool manager left unlocked");
        for (uint256 index; index < handler.poolCount(); index++) {
            IndexPool pool = handler.pools(index);
            _assertClean(pool);
            _assertSolvent(pool, _holders());
            _assertSolvent(handler.twins(index), _holders());
        }
    }

    function _holders() internal view returns (address[] memory list) {
        list = new address[](2);
        (list[0], list[1]) = (address(this), address(handler));
    }

    /// Depositors of each balanced pool against its twin, each valued after outside arbitrage
    /// would have brought it to the venues' prices: the difference per share, in parts of a
    /// million, is logged for every run.
    function afterInvariant() public {
        for (uint256 index; index < handler.poolCount(); index++) {
            IndexPool pool = handler.pools(index);
            IndexPool twin = handler.twins(index);
            uint256 balanced = _perShare(pool);
            uint256 plain = _perShare(twin);
            int256 ppm = (int256(balanced) - int256(plain)) * 1e6 / int256(plain);
            console.log("pool of", pool.tokens().length, "tokens, calls", handler.calls());
            console.log("  balanced minus no hook, per share (ppm):");
            console.logInt(ppm);
            // The stated tolerance: 0.1%. Swaps the balancer moved to the market's price can
            // pay the pool less slippage than the same swaps against a stale price.
            assertGe(ppm, -1000, "depositors worse off than with no hook");
        }
    }

    /// What one share is worth once outside arbitrage has brought the pool to the venues'
    /// prices, as it would with or without a hook: `Π (b_i p_i / w_i) ^ w_i`, the value at
    /// the same invariant, plus donations still to be released. Valued in units.
    function _perShare(IndexPool pool) internal returns (uint256) {
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        uint256[] memory weights = pool.weights();
        int256 log;
        uint256 pending;
        for (uint256 index; index < list.length; index++) {
            uint256 price = _priceOf(list[index]);
            uint256 value = FixedPointMathLib.fullMulDiv(held[index], price, 1e18);
            int256 term = FixedPointMathLib.lnWad(int256(value * 1e18 / weights[index] * 1e18));
            log += term * int256(weights[index]) / 1e18;
            pending += FixedPointMathLib.fullMulDiv(pool.unreleased(list[index]), price, 1e18);
        }
        uint256 settled = uint256(FixedPointMathLib.expWad(log)) / 1e18;
        return FixedPointMathLib.fullMulDiv(settled + pending, 1e18, pool.totalSupply());
    }

    /// Units per raw token, WAD: the v4 venue's mid price, or the Metric one's.
    function _priceOf(address token) internal returns (uint256) {
        if (token == unit) return 1e18;
        PoolKey memory key = _keyOf(token);
        if (key.tickSpacing != 0) return _venuePrice(key, token);
        MockBinPool metric = handler.metricOf(token);
        uint256 mid = metric.mid();
        uint256 whole = metric.token0() == token
            ? FixedPointMathLib.fullMulDiv(mid, 1e18, 1 << 64)
            : FixedPointMathLib.fullMulDiv(1 << 64, 1e18, mid);
        return whole * 10 ** 18 / 10 ** IndexToken(token).decimals();
    }
}
