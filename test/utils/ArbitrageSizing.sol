// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TestAsset } from "./TestAsset.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { WrapWorld } from "../ArbitrageWrap.t.sol";
import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { ArbitrageProbe } from "./ArbitrageProbe.sol";
import { IVenuePricer } from "../../src/interfaces/IVenuePricer.sol";
import { WrappedPool, WrappedPricer } from "./WrappedPool.sol";

/// @dev Prices a cycle without the hook's maths. Inside one pool-manager `unlock` it runs a
/// list of pools in the order value flows as exact-input swaps, then reverts with the
/// output, so nothing is kept. A pool with tick spacing zero is the wrap link: it changes
/// nothing. Run it with the market switched off, so its swaps start no search of their own.
contract SizingQuoter is IUnlockCallback {
    error Quoted(uint256 output);

    uint256 internal constant EVALUATIONS = 40;
    /// 0.618034 of a unit, for the golden-section search.
    uint256 internal constant GOLDEN = 618_034;

    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    /// What `amount` of `inputs[0]` becomes after the whole list.
    function quote(PoolKey[] memory path, address[] memory inputs, uint256 amount)
        public
        returns (uint256 output)
    {
        try manager.unlock(abi.encode(path, inputs, amount)) {
            revert("quote did not revert");
        } catch (bytes memory reason) {
            if (bytes4(reason) != Quoted.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
            assembly ("memory-safe") {
                output := mload(add(reason, 0x24))
            }
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey[] memory path, address[] memory inputs, uint256 amount) =
            abi.decode(data, (PoolKey[], address[], uint256));
        for (uint256 index; index < path.length; index++) {
            if (path[index].tickSpacing == 0) continue;
            if (amount == 0) break;
            bool zeroForOne = Currency.unwrap(path[index].currency0) == inputs[index];
            BalanceDelta delta = manager.swap(
                path[index],
                IPoolManager.SwapParams(
                    zeroForOne,
                    -int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                ""
            );
            amount = zeroForOne ? uint128(delta.amount1()) : uint128(delta.amount0());
        }
        revert Quoted(amount);
    }

    /// The same list the other way round, with the tokens each leg takes in to match.
    function reversed(PoolKey[] memory path, address[] memory inputs)
        public
        pure
        returns (PoolKey[] memory flipped, address[] memory taken)
    {
        uint256 count = path.length;
        flipped = new PoolKey[](count);
        taken = new address[](count);
        for (uint256 index; index < count; index++) {
            uint256 source = count - 1 - index;
            flipped[index] = path[source];
            if (path[source].tickSpacing == 0) continue;
            bool zeroIn = Currency.unwrap(path[source].currency0) == inputs[source];
            taken[index] =
                Currency.unwrap(zeroIn ? path[source].currency1 : path[source].currency0);
        }
    }

    /// The cycle size, and the profit at it, that earns most, searching sizes from zero to
    /// `ceiling` of the first token. Profit is concave in the size, so a golden-section
    /// search finds it. The best size seen is returned.
    function best(PoolKey[] memory path, address[] memory inputs, uint256 ceiling)
        public
        returns (uint256 size, uint256 profit)
    {
        uint256 low;
        uint256 high = ceiling;
        uint256 left = high - (high - low) * GOLDEN / 1e6;
        uint256 right = low + (high - low) * GOLDEN / 1e6;
        uint256 leftProfit = _profit(path, inputs, left);
        uint256 rightProfit = _profit(path, inputs, right);
        (size, profit) = leftProfit > rightProfit ? (left, leftProfit) : (right, rightProfit);
        for (uint256 round = 2; round < EVALUATIONS; round++) {
            if (leftProfit < rightProfit) {
                low = left;
                left = right;
                leftProfit = rightProfit;
                right = low + (high - low) * GOLDEN / 1e6;
                rightProfit = _profit(path, inputs, right);
                if (rightProfit > profit) (size, profit) = (right, rightProfit);
            } else {
                high = right;
                right = left;
                rightProfit = leftProfit;
                left = high - (high - low) * GOLDEN / 1e6;
                leftProfit = _profit(path, inputs, left);
                if (leftProfit > profit) (size, profit) = (left, leftProfit);
            }
        }
    }

    /// The better of the two directions round the same list.
    function bestEither(PoolKey[] memory path, address[] memory inputs, uint256 ceiling)
        external
        returns (uint256 size, uint256 profit)
    {
        (size, profit) = best(path, inputs, ceiling);
        (PoolKey[] memory flipped, address[] memory taken) = reversed(path, inputs);
        (uint256 otherSize, uint256 other) = best(flipped, taken, ceiling);
        if (other > profit) (size, profit) = (otherSize, other);
    }

    function _profit(PoolKey[] memory path, address[] memory inputs, uint256 size)
        internal
        returns (uint256)
    {
        uint256 output = quote(path, inputs, size);
        return output > size ? output - size : 0;
    }
}

/// @dev Runs tries at a cycle inside an unlocked pool manager, against the probe, and keeps
/// the gas each one used and the error it failed with.
contract TryMeter is IUnlockCallback {
    IPoolManager internal immutable manager;
    ArbitrageProbe internal immutable probe;
    uint256 public used;
    bytes4 public reason;

    constructor(IPoolManager poolManager, ArbitrageProbe tried) {
        manager = poolManager;
        probe = tried;
    }

    function measure(
        uint256 market,
        address base,
        bytes32 poolId,
        ArbitrageHook.Plan memory plan
    ) external returns (uint256, bytes4) {
        manager.unlock(abi.encode(market, base, poolId, plan));
        return (used, reason);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint256 market, address base, bytes32 poolId, ArbitrageHook.Plan memory plan) =
            abi.decode(data, (uint256, address, bytes32, ArbitrageHook.Plan));
        (used, reason) = probe.tryCost(market, base, poolId, plan);
        return "";
    }
}

/// @dev SZR's market in the world with the wrap link, and what it takes to build a
/// scenario, open a gap, measure the hook against the independent optimum, and log a row.
abstract contract SizingWorld is WrapWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// The most gas a search is given, as at launch (the hook's own default).
    uint32 internal constant SEARCH_GAS = 8_000_000;
    /// Small enough that every profitable cycle counts, so sizing is what is measured.
    uint128 internal constant MIN_PROFIT = 1e15;
    uint64 internal constant EDGE = 1.0001e18;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    SizingQuoter internal quoter;
    /// The smallest profit a cycle must clear. The sizing tables are run at the tiny
    /// `MIN_PROFIT` and again at SZR's real default.
    uint128 internal minProfit = MIN_PROFIT;
    /// Set when the scenario has a wrapped pool, so its price is read from the pricer.
    address internal wrapped;
    address internal wrappedPricer;

    /// What one scenario is: the pool the swap starts in, the cycle in the order value
    /// flows when SZR is cheap in that pool (the quoter also tries the other direction),
    /// and a ceiling on cycle sizes, in SZR, for the independent search.
    struct Spec {
        string name;
        PoolKey focus;
        /// The pool whose tick movement is logged, when it is not the focus pool.
        PoolKey probe;
        PoolKey[] path;
        address[] inputs;
        uint256 ceiling;
        bool viaArb;
        /// Extra room, in hundredths of a percent, over the independent optimum before a
        /// search is called better than it. For pairs whose raw price is so low that a unit of
        /// SZR is a handful of the partner's wei, where rounding is a share of a percent.
        uint256 slack;
        /// When set, the watched pool's final tick must be past `boundary` (above it for
        /// `dir` up, below it for `dir` down), or the row was built wrong.
        bool crossing;
        int24 boundary;
        int24 dir;
        /// When nonzero, the watched pool's final liquidity must be this: the tail's.
        uint128 tail;
    }

    /// What was seen when the hook ran against a scenario.
    struct Result {
        uint256 gas;
        uint256 tries;
        uint256 cycles;
        uint256 failed;
        uint256 ranOut;
        uint256 undone;
        uint256 first;
        uint256 total;
        int256 left;
        int24 start;
        int24 end;
        uint128 liquidity;
        uint256 quiet;
        /// The sizing walk run alone on the first plan the search would try: its gas, the
        /// boundaries it followed, whether it answered with its own size (`sized`) or gave the
        /// estimate back (`fell`). `ranked` is false when no cycle was worth sizing.
        bool ranked;
        bool sized;
        /// The independent optimum, and whether the very first try reverted.
        uint256 optimum;
        bool firstTryFailed;
        uint256 walkGas;
        uint256 walkSteps;
        /// The real walk was cut short for gas: a second, warm run answered differently.
        bool walkCut;
        bool walkReverted;
        /// The plan of every try, in order.
        ArbitrageHook.Plan[] plans;
    }

    function setUp() public virtual override {
        super.setUp();
        quoter = new SizingQuoter(manager);
        _off();
    }

    /// An SZR/USD pool on the wrapping hook that holds a million of each token elsewhere,
    /// with SZR `ppm` dearer than at one, and the pricer Liquidity's manager pairs it with.
    function _wrappedVenue(uint256 ppm) internal returns (PoolKey memory pool) {
        WrappedPool wrapper =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        WrappedPricer pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        wrapped = address(wrapper);
        wrappedPricer = address(pricer);
        pool = _pair(address(szr), address(usd), 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        uint256 held = 1_000_000e18;
        uint256 dear = held * (1e6 + ppm) / 1e6;
        szr.transfer(address(wrapper), held);
        usd.mint(address(wrapper), dear);
        wrapper.seed(pool, _szrFirst(pool) ? held : dear, _szrFirst(pool) ? dear : held);
        hook.addVenue(1, pool);
        bytes32[] memory leaders = new bytes32[](2);
        leaders[0] = _id(usdPool);
        leaders[1] = _id(pool);
        _setLeaders(address(usd), leaders);
    }

    /// A new SZR/USD pool whose liquidity is only in ranges, going the way a cycle pushes
    /// it, starting in the middle of a range at `start`. A pool with `backstop` units also
    /// has that much over its whole range, so a swap that overshoots finds liquidity
    /// instead of walking the empty ticks to the price limit.
    function _shaped(
        uint24 fee,
        uint160 start,
        address pushed,
        uint256[] memory units,
        uint256 backstop
    ) internal returns (PoolKey memory pool) {
        pool = _register(address(usd), fee, start);
        if (backstop != 0) _provide(pool, backstop);
        _bands(pool, _push(pool, pushed), units);
    }

    function _tailed(Spec memory spec, PoolKey memory pool, uint256 tail) internal pure {
        spec.probe = pool;
        spec.tail = uint128(tail);
    }

    /// The tail is the last range's units, or the backstop when there is one.
    function _tailOf(uint256[] memory units, uint256 backstop) internal pure returns (uint256) {
        return backstop != 0 ? backstop : units[units.length - 1];
    }

    function _linkSpec(
        string memory name,
        uint256[] memory units,
        uint256 back,
        uint256 gap,
        bool sell
    ) internal returns (Spec memory spec) {
        TestAsset eur = new TestAsset();
        _approve(eur);
        PoolKey memory venue = _addHooked(address(eur), 500);
        PoolKey memory link = _pair(address(usd), address(eur), 3_000, address(0));
        manager.initialize(link, TickMath.getSqrtPriceAtTick(30));
        if (back != 0) _provide(link, back);
        locker.registerRoute(link);
        hook.setConnector(1, link, true);
        _untrack(mainPool);
        if (sell) {
            _moveTo(usdPool, _szrPrice(usdPool, _priceOf(usdPool), gap, false));
        } else {
            _cheapen(usdPool, gap);
        }
        _bands(link, _push(link, sell ? address(usd) : address(eur)), units);
        spec.name = name;
        spec.focus = usdPool;
        spec.path = _keys(venue, link, usdPool);
        spec.inputs = _tokens(address(szr), address(eur), address(usd));
        spec.ceiling = 1e24;
        _tailed(spec, link, _tailOf(units, back));
    }

    // ----- limits -----

    function _off() internal {
        hook.setLimits(1, address(szr), 0, MIN_PROFIT, EDGE);
    }

    function _on() internal {
        uint256 needed = hook.minimumGasLimit(1);
        uint32 gas = needed > SEARCH_GAS ? uint32(needed) : SEARCH_GAS;
        hook.setLimits(1, address(szr), gas, minProfit, EDGE);
    }

    // ----- builders -----

    function _szrFirst(PoolKey memory pool) internal view returns (bool) {
        return Currency.unwrap(pool.currency0) == address(szr);
    }

    /// Which way a pool's square-root price moves when `input` is sold into it.
    function _push(PoolKey memory pool, address input) internal pure returns (int24) {
        return Currency.unwrap(pool.currency0) == input ? int24(-1) : int24(1);
    }

    function _tickOf(PoolKey memory pool) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(pool.toId());
    }

    function _priceOf(PoolKey memory pool) internal view returns (uint160 price) {
        (price,,,) = manager.getSlot0(pool.toId());
    }

    function _floor(int24 tick) internal pure returns (int24 floored) {
        floored = tick / 60 * 60;
        if (floored > tick) floored -= 60;
    }

    /// A square-root price changed so that the price moves by `ppm` parts per million.
    function _scaled(uint160 price, uint256 ppm, bool lower) internal pure returns (uint160) {
        uint256 factor = FixedPointMathLib.sqrt((lower ? 1e6 - ppm : 1e6 + ppm) * 1e6);
        return uint160(uint256(price) * factor / 1e6);
    }

    /// The square-root price at which SZR costs `ppm` less (or more) than at `price`. A
    /// pool's price is token1 per token0, so SZR is cheaper when it falls for SZR as token0
    /// and when it rises for SZR as token1.
    function _szrPrice(PoolKey memory pool, uint160 price, uint256 ppm, bool cheaper)
        internal
        view
        returns (uint160)
    {
        return _scaled(price, ppm, _szrFirst(pool) == cheaper);
    }

    /// Moves a pool's price by trading, with the market switched off.
    function _moveTo(PoolKey memory pool, uint160 target) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            pool, IPoolManager.SwapParams(target < _priceOf(pool), -1e30, target), settings, ""
        );
    }

    /// Makes SZR cheaper in `pool` by `ppm` of its price, by trading.
    function _cheapen(PoolKey memory pool, uint256 ppm) internal {
        _moveTo(pool, _szrPrice(pool, _priceOf(pool), ppm, true));
    }

    function _band(PoolKey memory pool, int24 lower, uint256 units) internal {
        provider.modifyLiquidity(
            pool, IPoolManager.ModifyLiquidityParams(lower, lower + 60, int256(units), 0), ""
        );
    }

    /// The middle of the 60-tick range that `price` is in.
    function _mid(uint160 price) internal pure returns (uint160) {
        int24 floored = _floor(TickMath.getTickAtSqrtPrice(price));
        return TickMath.getSqrtPriceAtTick(floored + 30);
    }

    /// Moves a price that sits near the edge of its 60-tick range to the middle of it, so
    /// the first boundary a cycle meets is a real distance away.
    function _centre(PoolKey memory pool) internal {
        int24 tick = _tickOf(pool);
        int24 floored = _floor(tick);
        int24 into = tick - floored;
        if (into >= 20) {
            if (into <= 40) return;
        }
        _moveTo(pool, TickMath.getSqrtPriceAtTick(floored + 30));
    }

    /// Makes the row fail unless the watched pool ends past the `count`th boundary that
    /// `_bands` made from `base`.
    function _expect(
        Spec memory spec,
        PoolKey memory pool,
        int24 dir,
        int24 base,
        uint256 count
    ) internal pure {
        spec.probe = pool;
        spec.crossing = true;
        spec.dir = dir;
        int24 steps = int24(uint24(dir > 0 ? count : count - 1));
        spec.boundary = base + dir * steps * 60;
    }

    /// Adds one 60-tick range of liquidity per entry, starting in the range the price is in
    /// and going the way `dir` says. Where a range's units differ from the next one's, the
    /// boundary between them is an initialised tick that changes the liquidity.
    function _bands(PoolKey memory pool, int24 dir, uint256[] memory units)
        internal
        returns (int24 base)
    {
        _centre(pool);
        base = _floor(_tickOf(pool));
        for (uint256 index; index < units.length; index++) {
            if (units[index] == 0) continue;
            _band(pool, base + dir * int24(uint24(index)) * 60, units[index]);
        }
    }

    /// `count` ranges whose units alternate between `even` and `odd`.
    function _alternating(uint256 count, uint256 even, uint256 odd)
        internal
        pure
        returns (uint256[] memory units)
    {
        units = new uint256[](count);
        for (uint256 index; index < count; index++) {
            units[index] = index % 2 == 0 ? even : odd;
        }
    }

    /// `head` ranges of `headUnits` followed by `tail` ranges of `tailUnits`.
    function _stepped(uint256 head, uint256 headUnits, uint256 tail, uint256 tailUnits)
        internal
        pure
        returns (uint256[] memory units)
    {
        units = new uint256[](head + tail);
        for (uint256 index; index < head + tail; index++) {
            units[index] = index < head ? headUnits : tailUnits;
        }
    }

    /// Dust liquidity in `count` narrow ranges either side of the price: next to nothing,
    /// but every swap through them crosses that many initialised ticks.
    function _dust(PoolKey memory pool, int24 count) internal {
        int24 base = _floor(_tickOf(pool));
        for (int24 step = -count; step < count; step++) {
            _band(pool, base + step * 60, 1e12);
        }
    }

    // ----- specs -----

    function _keys(PoolKey memory a, PoolKey memory b)
        internal
        pure
        returns (PoolKey[] memory list)
    {
        list = new PoolKey[](2);
        list[0] = a;
        list[1] = b;
    }

    function _keys(PoolKey memory a, PoolKey memory b, PoolKey memory c)
        internal
        pure
        returns (PoolKey[] memory list)
    {
        list = new PoolKey[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function _keys(PoolKey memory a, PoolKey memory b, PoolKey memory c, PoolKey memory d)
        internal
        pure
        returns (PoolKey[] memory list)
    {
        list = new PoolKey[](4);
        list[0] = a;
        list[1] = b;
        list[2] = c;
        list[3] = d;
    }

    function _tokens(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _tokens(address a, address b, address c)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }

    function _tokens(address a, address b, address c, address d)
        internal
        pure
        returns (address[] memory list)
    {
        list = new address[](4);
        list[0] = a;
        list[1] = b;
        list[2] = c;
        list[3] = d;
    }

    /// The wrap link as a leg of a list: a pool with no tick spacing.
    function _wrapLeg() internal pure returns (PoolKey memory leg) {
        return leg;
    }

    /// Two pools of the same partner token, SZR cheap in `focus`: the cycle sells SZR at
    /// `venue` and buys it back at `focus`.
    function _direct(string memory name, PoolKey memory venue, PoolKey memory focus)
        internal
        view
        returns (Spec memory spec)
    {
        address partner = _partnerOf(focus);
        spec.name = name;
        spec.focus = focus;
        spec.path = _keys(venue, focus);
        spec.inputs = _tokens(address(szr), partner);
        spec.ceiling = 1e24;
    }

    // ----- measuring -----

    function _isWrapped(PoolKey memory pool) internal view returns (bool) {
        if (wrapped == address(0)) return false;
        return address(pool.hooks) == wrapped;
    }

    /// A leg's square-root rate in the direction of `input`, net of its fee, in Q96, as the
    /// hook reads it.
    function _rate(PoolKey memory pool, address input) internal view returns (uint256) {
        uint160 price;
        uint24 fee;
        if (_isWrapped(pool)) {
            (price, fee,,,) = IVenuePricer(wrappedPricer).price(pool);
        } else {
            (price,,, fee) = manager.getSlot0(pool.toId());
        }
        bool zeroIn = Currency.unwrap(pool.currency0) == input;
        uint256 rate = zeroIn ? uint256(price) : Q192 / price;
        uint256 keep = FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
        return FixedPointMathLib.fullMulDiv(rate, keep, 1e18);
    }

    /// What one unit of the first token becomes along the list at the margin, in WAD.
    function _along(PoolKey[] memory path, address[] memory inputs)
        internal
        view
        returns (uint256 ratio)
    {
        uint256 rate = Q96;
        for (uint256 index; index < path.length; index++) {
            if (path[index].tickSpacing == 0) continue;
            rate = FixedPointMathLib.fullMulDiv(rate, _rate(path[index], inputs[index]), Q96);
        }
        return FixedPointMathLib.fullMulDiv(rate, 1e18, Q96);
    }

    /// The gap still open between the focus pool and the venue, in the better direction,
    /// in hundredths of the hook's `minimumEdge` (the part of the ratio above one).
    function _left(Spec memory spec) internal view returns (int256) {
        if (spec.path.length == 0) return _navLeft();
        return _units(_along(spec.path, spec.inputs));
    }

    /// How far the main pool is still from Core's NAV, as `_left` counts it: the pool is
    /// compared at its fee, Core takes none.
    function _navLeft() internal view returns (int256) {
        uint160 root = _priceOf(mainPool);
        uint256 wethPerSzr = _szrFirst(mainPool) ? root : Q192 / root;
        uint256 navRoot =
            FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(core.NAV(), Q192, 1e18));
        (,,, uint24 fee) = manager.getSlot0(mainPool.toId());
        uint256 keep = FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
        uint256 target = FixedPointMathLib.fullMulDiv(navRoot, keep, 1e18);
        return _units(FixedPointMathLib.fullMulDiv(target, 1e18, wethPerSzr));
    }

    function _units(uint256 ratio) internal view returns (int256) {
        int256 edge = int256(uint256(hook.market(1).minimumEdge)) - 1e18;
        return (int256(ratio) - 1e18) * 100 / edge;
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        if (wrapped != address(0)) vm.cool(wrapped);
        if (wrappedPricer != address(0)) vm.cool(wrappedPricer);
    }

    /// The swap that starts a search: a small sale of SZR into the focus pool, or `arb` for
    /// a pool with no hook.
    function _start(Spec memory spec) internal {
        if (spec.viaArb) {
            hook.arb(_id(spec.focus));
        } else {
            _trade(spec.focus, address(szr), 1e15);
        }
    }

    function _timed(Spec memory spec) internal returns (uint256 spent) {
        _cool();
        spent = gasleft();
        _start(spec);
        spent -= gasleft();
    }

    /// Runs the search again from the same state, recording what it did: every call to
    /// `execute` is one try, successful or not.
    function _observe(Spec memory spec) internal returns (Result memory result) {
        vm.recordLogs();
        vm.startStateDiffRecording();
        _start(spec);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _collect(result, accesses);
        for (uint256 index; index < logs.length; index++) {
            _count(result, logs[index]);
        }
    }

    function _collect(Result memory result, Vm.AccountAccess[] memory accesses) internal view {
        for (uint256 index; index < accesses.length; index++) {
            if (_isTry(accesses[index])) result.tries++;
        }
        result.plans = new ArbitrageHook.Plan[](result.tries);
        uint256 seen;
        for (uint256 index; index < accesses.length; index++) {
            if (!_isTry(accesses[index])) continue;
            if (seen == 0) result.firstTryFailed = accesses[index].reverted;
            result.plans[seen++] = _planOf(accesses[index].data);
        }
    }

    function _isTry(Vm.AccountAccess memory access) internal view returns (bool) {
        if (access.account != address(hook)) return false;
        if (access.data.length < 4) return false;
        return bytes4(access.data) == ArbitrageHook.execute.selector;
    }

    function _planOf(bytes memory data) internal pure returns (ArbitrageHook.Plan memory plan) {
        bytes memory body = new bytes(data.length - 4);
        for (uint256 index; index < body.length; index++) {
            body[index] = data[index + 4];
        }
        (, plan) = abi.decode(body, (bytes32, ArbitrageHook.Plan));
    }

    function _count(Result memory result, Vm.Log memory entry) internal pure {
        bytes32 topic = entry.topics[0];
        if (topic == ArbitrageHook.CycleFailed.selector) result.failed++;
        if (topic == ArbitrageHook.TryRanOut.selector) result.ranOut++;
        if (topic == ArbitrageHook.SearchUndone.selector) result.undone++;
        if (topic != ArbitrageHook.Arbitraged.selector) return;
        (, uint256 profit) = abi.decode(entry.data, (bool, uint256));
        if (result.cycles == 0) result.first = profit;
        result.cycles++;
        result.total += profit;
    }

    /// Prices the scenario independently, runs the hook against it with the limits on, and
    /// logs one row. The gap must already be open.
    function _measure(Spec memory spec) internal returns (Result memory result) {
        uint256 optimum;
        if (spec.path.length != 0) {
            (, optimum) = quoter.bestEither(spec.path, spec.inputs, spec.ceiling);
        }
        _on();
        PoolKey memory watched = spec.probe.tickSpacing == 0 ? spec.focus : spec.probe;
        int24 before = _tickOf(watched);
        uint256 snapshot = vm.snapshotState();
        uint256 spent = _timed(spec);
        vm.revertToState(snapshot);
        Result memory walked;
        _walked(spec, walked);
        result = _observe(spec);
        (result.ranked, result.sized) = (walked.ranked, walked.sized);
        (result.walkGas, result.walkSteps) = (walked.walkGas, walked.walkSteps);
        result.walkCut = walked.walkCut;
        result.walkReverted = walked.walkReverted;
        result.optimum = optimum;
        result.gas = spent;
        result.start = before;
        result.end = _tickOf(watched);
        result.liquidity = manager.getLiquidity(watched.toId());
        result.left = _left(spec);
        // The search can never earn more than the best single cycle, beyond rounding.
        if (spec.path.length != 0) {
            assertLe(
                result.total,
                optimum + optimum / 10_000 + 1e6 + optimum * spec.slack / 10_000,
                "beyond the optimum"
            );
        }
        _premise(spec, result);
        // The same swap again, with the gap closed, is what the search itself added to.
        result.quiet = _timed(spec);
        _log(spec.name, optimum, result);
    }

    /// Runs the search once more from the state it began in, with the probe in the hook's
    /// place, and records the first sizing walk as `_attempt` runs it inside the real swap:
    /// its gas, the boundaries it followed, and whether the first try used its size. The
    /// state and the hook's code are put back. Call it with the state as the search found it.
    function _walked(Spec memory spec, Result memory result) internal {
        uint256 snapshot = vm.snapshotState();
        ArbitrageProbe probe = _probeInHook();
        _cool();
        _start(spec);
        result.ranked = probe.sizingCalls() != 0;
        result.sized = probe.sizingUsed();
        result.walkGas = probe.sizingGas();
        result.walkSteps = probe.sizingSteps();
        result.walkCut = probe.sizingCut();
        result.walkReverted = probe.sizingReverted();
        vm.revertToState(snapshot);
    }

    /// A row built to cross ticks, or to end in a tail, fails if it did not. Only checked
    /// when cycles of any size count; at SZR's default minimum profit small ones do not.
    function _premise(Spec memory spec, Result memory result) internal view {
        if (minProfit != MIN_PROFIT) return;
        if (spec.crossing) {
            if (spec.dir > 0) {
                assertGe(int256(result.end), int256(spec.boundary), "boundary not crossed");
            } else {
                assertLt(int256(result.end), int256(spec.boundary), "boundary not crossed");
            }
        }
        if (spec.tail != 0) assertEq(result.liquidity, spec.tail, "did not end in the tail");
    }

    /// Runs each try again, alone, from the state the search began in, and says what it
    /// cost and how it failed. The probe replaces the hook's code, so call it after any
    /// state is restored and not before `_measure`.
    function _retry(bytes32 poolId, ArbitrageHook.Plan[] memory plans)
        internal
        returns (uint256[] memory used, bytes4[] memory reasons)
    {
        TryMeter meter = new TryMeter(manager, _probeInHook());
        used = new uint256[](plans.length);
        reasons = new bytes4[](plans.length);
        for (uint256 index; index < plans.length; index++) {
            (used[index], reasons[index]) = meter.measure(1, address(szr), poolId, plans[index]);
            console.log("  try", index, "gas", used[index]);
        }
    }

    /// Every try of the search fails with `Incomplete` for no more than `most` gas.
    function _assertFailFast(bytes32 poolId, ArbitrageHook.Plan[] memory plans, uint256 most)
        internal
    {
        assertGt(plans.length, 0, "there was a try");
        (uint256[] memory used, bytes4[] memory reasons) = _retry(poolId, plans);
        for (uint256 index; index < plans.length; index++) {
            assertEq(reasons[index], ArbitrageHook.Incomplete.selector, "leg could not fill");
            assertLt(used[index], most, "and failed cheaply");
        }
    }

    // ----- logging -----

    function _fixed(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 unit = 10 ** places;
        bytes memory fraction = bytes(vm.toString(value % unit));
        bytes memory zeros = new bytes(places - fraction.length);
        for (uint256 index; index < zeros.length; index++) {
            zeros[index] = "0";
        }
        return string.concat(vm.toString(value / unit), ".", string(zeros), string(fraction));
    }

    function _percent(uint256 value, uint256 optimum) internal pure returns (string memory) {
        if (optimum == 0) return "n/a";
        return string.concat(_fixed(value * 10_000 / optimum, 2), "%");
    }

    /// Gas at 0.020 gwei and ETH at $1,850, in dollars.
    function _dollars(uint256 gas) internal pure returns (string memory) {
        return string.concat("$", _fixed(gas * 37 / 1e5, 4));
    }

    function _signed(int256 value) internal pure returns (string memory) {
        if (value < 0) return string.concat("-", _fixed(uint256(-value), 2));
        return _fixed(uint256(value), 2);
    }

    function _log(string memory name, uint256 optimum, Result memory result) internal view {
        string memory work = string.concat(
            " | tries ",
            vm.toString(result.tries),
            " | cycles ",
            vm.toString(result.cycles),
            " | failed ",
            vm.toString(result.failed),
            " | ranOut ",
            vm.toString(result.ranOut),
            " | undone ",
            vm.toString(result.undone)
        );
        uint256 extra = result.gas > result.quiet ? result.gas - result.quiet : 0;
        uint256 added = result.cycles == 0 ? 0 : extra / result.cycles;
        string memory profit = string.concat(
            " | optimum ",
            optimum == 0 ? "n/a" : _fixed(optimum / 1e14, 4),
            " | first ",
            _percent(result.first, optimum),
            " (",
            _fixed(result.first / 1e14, 4),
            ") | total ",
            _percent(result.total, optimum),
            " (",
            _fixed(result.total / 1e14, 4),
            ") | left ",
            _signed(result.left),
            " edge | tick ",
            vm.toString(int256(result.start)),
            ">",
            vm.toString(int256(result.end)),
            " liq ",
            vm.toString(uint256(result.liquidity)),
            " | added/cycle ",
            vm.toString(added)
        );
        string memory walk = string.concat(
            " | walk ",
            result.ranked ? vm.toString(result.walkGas) : "n/a",
            " steps ",
            vm.toString(result.walkSteps),
            result.walkCut ? "* (real walk cut for gas)" : "",
            result.walkReverted ? "* (walk gave up: Unsizable)" : "",
            result.sized ? " sized" : " estimate"
        );
        console.log(
            string.concat(
                "ROW [",
                vm.toString(uint256(minProfit)),
                "] ",
                name,
                " | gas ",
                vm.toString(result.gas),
                " (",
                _dollars(result.gas),
                ")",
                work,
                profit,
                walk
            )
        );
    }
}
