// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import {
    IMetricExtension,
    IMetricPool,
    IMetricPoolAdmin,
    IMetricProvider,
    IMetricSession,
    IMetricStopLoss,
    IMetricVelocity,
    IMetricSwapCallback,
    IMetricModifyLiquidityCallback,
    LiquidityDelta,
    PoolImmutables
} from "../utils/metric/IMetric.sol";
import { MetricState } from "../utils/metric/MetricState.sol";

/// @dev Stands in for a contract that trades or provides liquidity on a Metric pool: the
/// arbitrage hook, a vault. It records what the pool did to it.
contract MetricProber is IMetricSwapCallback, IMetricModifyLiquidityCallback, IUnlockCallback {
    IMetricPool public immutable pool;
    IPoolManager public immutable manager;
    address public immutable token0;
    address public immutable token1;
    uint256 public callbackGas;

    constructor(IMetricPool metric, IPoolManager poolManager) {
        pool = metric;
        manager = poolManager;
        PoolImmutables memory imm = metric.getImmutables();
        token0 = imm.token0;
        token1 = imm.token1;
    }

    function prices() external returns (uint128 sell, uint128 buy, uint256 used) {
        uint256 start = gasleft();
        (sell, buy) = pool.getSellAndBuyPrices();
        used = start - gasleft();
    }

    function staticPrices() external view returns (bool ok, bytes memory data, uint256 used) {
        uint256 start = gasleft();
        (ok, data) =
            address(pool).staticcall(abi.encodeCall(IMetricPool.getSellAndBuyPrices, ()));
        used = start - gasleft();
    }

    error Quoted(uint128 sell, uint128 buy);

    /// What the hook's `askFrame` does: read the price by a normal call and hand the answer
    /// back in revert data, so that whatever the read did is undone.
    function frame() external {
        (uint128 sell, uint128 buy) = pool.getSellAndBuyPrices();
        revert Quoted(sell, buy);
    }

    /// The price read inside a frame that always reverts, and the gas of the whole thing.
    function framedPrices()
        external
        returns (bool ok, uint128 sell, uint128 buy, uint256 used, uint256 length)
    {
        uint256 start = gasleft();
        bytes memory data;
        (ok, data) = address(this).call(abi.encodeCall(this.frame, ()));
        used = start - gasleft();
        length = data.length;
        if (length != 68) return (ok, 0, 0, used, length);
        if (bytes4(data) != Quoted.selector) return (ok, 0, 0, used, length);
        bytes memory body = new bytes(64);
        for (uint256 i; i < 64; i++) {
            body[i] = data[i + 4];
        }
        (sell, buy) = abi.decode(body, (uint128, uint128));
    }

    /// The same, with a cap on the gas the staticcall gets, as a pricer's call would have.
    function staticPricesCapped(uint256 cap) external view returns (bool ok, uint256 used) {
        uint256 start = gasleft();
        (ok,) = address(pool).staticcall{ gas: cap }(
            abi.encodeCall(IMetricPool.getSellAndBuyPrices, ())
        );
        used = start - gasleft();
    }

    /// Two reads in one transaction, so the second one finds everything warm.
    function pricesTwice() external returns (uint256 first, uint256 second) {
        uint256 start = gasleft();
        pool.getSellAndBuyPrices();
        first = start - gasleft();
        start = gasleft();
        pool.getSellAndBuyPrices();
        second = start - gasleft();
    }

    /// The provider's own quote, asked for by a contract.
    function quote() external returns (uint128 bid, uint128 ask, uint128 refPrice) {
        return IMetricProvider(pool.getImmutables().immutablePriceProvider).getQuote();
    }

    /// A swap inside a v4 unlock. The pool pays the output here first, then asks for the
    /// input; the input is taken from the pool manager straight to the pool.
    function swapViaManager(bool zeroForOne, int128 amount, uint128 limit)
        external
        returns (int128 amount0, int128 amount1, uint256 used)
    {
        uint256 start = gasleft();
        bytes memory out = manager.unlock(abi.encode(zeroForOne, amount, limit));
        used = start - gasleft();
        (amount0, amount1) = abi.decode(out, (int128, int128));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not the pool manager");
        (bool zeroForOne, int128 amount, uint128 limit) =
            abi.decode(data, (bool, int128, uint128));
        (int128 amount0, int128 amount1) =
            pool.swap(address(this), zeroForOne, amount, limit, "", "");
        (address input, address output) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 paid = uint256(uint128(zeroForOne ? amount0 : amount1));
        uint256 got = uint256(uint128(-(zeroForOne ? amount1 : amount0)));
        // The output goes into the pool manager, the input that was taken out is paid back
        // from this contract's own funds, and the output credit is taken out again.
        manager.sync(Currency.wrap(output));
        SafeTransferLib.safeTransfer(output, address(manager), got);
        manager.settle();
        manager.sync(Currency.wrap(input));
        SafeTransferLib.safeTransfer(input, address(manager), paid);
        manager.settle();
        manager.take(Currency.wrap(output), address(this), got);
        return abi.encode(amount0, amount1);
    }

    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
    {
        require(msg.sender == address(pool), "not the pool");
        uint256 start = gasleft();
        bool zeroForOne = amount0Delta > 0;
        uint256 owed = zeroForOne ? uint256(amount0Delta) : uint256(amount1Delta);
        manager.take(Currency.wrap(zeroForOne ? token0 : token1), address(pool), owed);
        callbackGas = start - gasleft();
    }

    function add(uint80 salt, int256[] calldata bins, uint256[] calldata shares)
        external
        returns (uint256 amount0, uint256 amount1, uint256 used)
    {
        used = gasleft();
        (amount0, amount1) =
            pool.addLiquidity(address(this), salt, LiquidityDelta(bins, shares), "", "");
        used -= gasleft();
    }

    function remove(uint80 salt, int256[] calldata bins, uint256[] calldata shares)
        external
        returns (uint256 amount0, uint256 amount1, uint256 used)
    {
        used = gasleft();
        (amount0, amount1) =
            pool.removeLiquidity(address(this), salt, LiquidityDelta(bins, shares), "");
        used -= gasleft();
    }

    function metricOmmModifyLiquidityCallback(
        uint256 amount0Delta,
        uint256 amount1Delta,
        bytes calldata
    ) external {
        require(msg.sender == address(pool), "not the pool");
        if (amount0Delta > 0) SafeTransferLib.safeTransfer(token0, msg.sender, amount0Delta);
        if (amount1Delta > 0) SafeTransferLib.safeTransfer(token1, msg.sender, amount1Delta);
    }
}

/// @dev A hook whose beforeSwap fails in the way `mode` says, for P7.
contract FailingHook {
    error Boom(uint256 code);

    IPoolManager internal constant MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    uint256 public mode;

    function setMode(uint256 value) external {
        mode = value;
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (mode == 1) revert Boom(42);
        if (mode == 2) revert();
        if (mode == 3) revert("plain string");
        if (mode == 4) return (bytes4(0xdeadbeef), BeforeSwapDelta.wrap(0), 0);
        // Takes more WETH than the pool manager holds, as a hook paying a venue would.
        if (mode == 5) {
            MANAGER.take(
                Currency.wrap(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73), address(this), 1e30
            );
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

/// @notice Step 0 of docs/specs/metric.md: what a contract can do with the WETH/USDG Metric
/// pool on Robinhood Chain. Skipped unless FORK_RPC_URL is set. Every probe logs its numbers.
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path "test/fork/MetricProbe.t.sol" -vv
contract MetricProbeTest is Test {
    IMetricPool internal constant POOL =
        IMetricPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant PROVIDER = 0xCafFcc296115b2a12e190Be9735ac6aAAb23bC69;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    IPoolManager internal constant MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant ORACLE = 0x30a88bf894D1b806125a23ebf23D715496fD7102;
    address internal constant EOA = address(0xE0A);
    uint256 internal constant Q64 = 1 << 64;

    bool internal live;
    uint256 internal forkTime;
    MetricProber internal prober;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        forkTime = block.timestamp;
        prober = new MetricProber(POOL, MANAGER);
    }

    modifier onlyFork() {
        if (!live) vm.skip(true);
        _;
    }

    /// Whole USDG per WETH from a Q64.64 price, in millionths.
    function _micro(uint256 priceX64) internal pure returns (uint256) {
        return priceX64 * 1e6 / Q64;
    }

    /// The first four bytes of revert data, then of the reason inside `PriceProviderFailed`.
    function _selectors(bytes memory data) internal pure returns (bytes4 outer, bytes4 inner) {
        if (data.length < 4) return (bytes4(0), bytes4(0));
        assembly ("memory-safe") {
            outer := mload(add(data, 32))
        }
        if (outer != IMetricPool.PriceProviderFailed.selector) return (outer, bytes4(0));
        bytes memory body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; i++) {
            body[i] = data[i + 4];
        }
        bytes memory reason = abi.decode(body, (bytes));
        if (reason.length < 4) return (outer, bytes4(0));
        assembly ("memory-safe") {
            inner := mload(add(reason, 32))
        }
    }

    function _fund(address who, uint256 weth, uint256 usdg) internal {
        deal(WETH, who, weth);
        deal(USDG, who, usdg);
    }

    /// Asks for the pool's marginal prices from the prober, as a contract inside a
    /// transaction sent by `EOA`. If the feed is stale it moves the clock back to the fork
    /// block's time and asks once more, and says so.
    function _prices() internal returns (uint128 sell, uint128 buy, uint256 used) {
        bool ok;
        bytes memory ret;
        vm.prank(EOA, EOA);
        (ok, ret) = address(prober).call(abi.encodeCall(MetricProber.prices, ()));
        if (!ok) {
            (bytes4 outer, bytes4 inner) = _selectors(ret);
            console.log("prices() failed; outer, inner selector:");
            console.logBytes4(outer);
            console.logBytes4(inner);
            vm.warp(forkTime);
            vm.prank(EOA, EOA);
            (ok, ret) = address(prober).call(abi.encodeCall(MetricProber.prices, ()));
        }
        require(ok, "prices() failed even at the fork block time");
        (sell, buy, used) = abi.decode(ret, (uint128, uint128, uint256));
    }

    /// bid, ask and reference as an off-chain simulation reads them: with a zero origin.
    function _quote() internal returns (uint128 bid, uint128 ask, uint128 refPrice, bool ok) {
        vm.prank(EOA, address(0));
        bytes memory ret;
        (ok, ret) = address(prober).call(abi.encodeCall(MetricProber.quote, ()));
        if (ok) (bid, ask, refPrice) = abi.decode(ret, (uint128, uint128, uint128));
    }

    // ---------------------------------------------------------------------------------
    // P1: the marginal price from a contract, by a normal call, with a non-zero origin
    // ---------------------------------------------------------------------------------

    function testP1PricesByCallFromAContract() public onlyFork {
        console.log("P1 fork block", block.number, "timestamp", block.timestamp);
        vm.cool(address(POOL));
        vm.cool(PROVIDER);
        vm.cool(ORACLE);
        (uint128 sell, uint128 buy, uint256 cold) = _prices();
        (uint128 sell2, uint128 buy2, uint256 warm) = _prices();
        console.log("P1 tx.origin is non-zero:", EOA != address(0));
        console.log("P1 sell price, millionths USDG per WETH", _micro(sell));
        console.log("P1 buy price, millionths USDG per WETH", _micro(buy));
        console.log("P1 spread, parts per million", (uint256(buy) - sell) * 1e6 / sell);
        console.log("P1 gas of one call, first in its transaction", cold);
        console.log("P1 gas of the same call asked again, new transaction", warm);
        vm.prank(EOA, EOA);
        (uint256 first, uint256 second) = prober.pricesTwice();
        console.log("P1 gas, two reads in one transaction, first", first);
        console.log("P1 gas, two reads in one transaction, second (warm)", second);
        assertGt(sell, 0);
        assertGt(buy, sell);
        assertEq(sell2, sell);
        assertEq(buy2, buy);
    }

    /// The premise of docs/specs/hook-live-pricers.md: the price read by a normal call inside
    /// a frame that always reverts, with the answer in the revert data. Every such read is
    /// cold, because the revert drops the warm access list, so it is made twice to show it.
    function testLivePricersReadInsideARevertingFrame() public onlyFork {
        vm.cool(address(POOL));
        vm.cool(PROVIDER);
        vm.cool(ORACLE);
        (uint128 sell, uint128 buy,) = _prices();
        vm.cool(address(POOL));
        vm.cool(PROVIDER);
        vm.cool(ORACLE);
        vm.prank(EOA, EOA);
        (bool ok, uint128 sell2, uint128 buy2, uint256 used, uint256 length) =
            prober.framedPrices();
        vm.prank(EOA, EOA);
        (,,, uint256 again,) = prober.framedPrices();
        console.log("LIVE frame reverted:", !ok);
        console.log("LIVE revert data length", length);
        console.log("LIVE gas of the framed read, cold", used);
        console.log("LIVE gas of the framed read, asked again in a new transaction", again);
        assertFalse(ok, "the frame always reverts");
        assertEq(length, 68, "Quoted(uint128,uint128)");
        assertEq(sell2, sell);
        assertEq(buy2, buy);
        assertLt(used, 100_000, "the 100k pricer estimate holds");
    }

    /// The provider itself, asked by a contract, refuses unless the origin is zero.
    function testP1ProviderQuoteByAContract() public onlyFork {
        vm.prank(EOA, EOA);
        (bool ok, bytes memory ret) =
            address(prober).call(abi.encodeCall(MetricProber.quote, ()));
        console.log("P1 provider.getQuote() from a contract, non-zero origin, ok:", ok);
        console.log("P1 revert data length", ret.length);
        assertFalse(ok);
        (uint128 bid, uint128 ask, uint128 refPrice, bool free) = _quote();
        console.log("P1 provider.getQuote() with a zero origin, ok:", free);
        if (free) {
            console.log("P1 bid, millionths", _micro(bid));
            console.log("P1 ask, millionths", _micro(ask));
            console.log("P1 reference, millionths", _micro(refPrice));
        }
    }

    // ---------------------------------------------------------------------------------
    // P2: the same through STATICCALL
    // ---------------------------------------------------------------------------------

    function testP2PricesByStaticcall() public onlyFork {
        vm.prank(EOA, EOA);
        (bool ok, bytes memory ret, uint256 used) = prober.staticPrices();
        console.log("P2 staticcall succeeded:", ok);
        console.log("P2 gas used", used);
        console.log("P2 revert data length", ret.length);
        console.logBytes(ret);
        assertFalse(ok, "a staticcall to getSellAndBuyPrices must fail");
        vm.prank(EOA, EOA);
        (bool capped, uint256 burnt) = prober.staticPricesCapped(150_000);
        console.log("P2 with the gas capped at 150000, succeeded:", capped);
        console.log("P2 gas the failed capped call burnt", burnt);
        assertFalse(capped);
    }

    // ---------------------------------------------------------------------------------
    // P3: the pool's state read with extsload, and the amounts to the current bin's edge
    // ---------------------------------------------------------------------------------

    struct Edges {
        uint256 lower;
        uint256 upper;
        uint256 marginal;
        uint256 scale0;
        uint256 scale1;
    }

    /// Price at the bin's two edges and at the position in it, with `ref` as the reference.
    function _edges(MetricState.Slot0 memory s, MetricState.Bin memory b, uint256 ref)
        internal
        view
        returns (Edges memory e)
    {
        PoolImmutables memory imm = POOL.getImmutables();
        e.scale0 = imm.token0ScaleMultiplier;
        e.scale1 = imm.token1ScaleMultiplier;
        e.lower = ref * uint256(1e6 + int256(s.curBinDistE6)) / 1e6;
        e.upper =
            ref * uint256(1e6 + int256(s.curBinDistE6) + int256(uint256(b.lengthE6))) / 1e6;
        uint256 top = type(uint104).max;
        e.marginal = (e.lower * (top - s.curPosInBin) + e.upper * s.curPosInBin) / top;
    }

    function _simulate(bool zeroForOne, int128 amount, uint128 limit, uint128[3] memory quoted)
        internal
        returns (bool ok, int256 amount0, int256 amount1)
    {
        try POOL.simulateSwapAndRevert(
            address(prober),
            address(prober),
            zeroForOne,
            amount,
            limit,
            quoted[0],
            quoted[1],
            quoted[2],
            ""
        ) {
            return (false, 0, 0);
        } catch (bytes memory reason) {
            if (reason.length != 68) return (false, 0, 0);
            bytes memory body = new bytes(64);
            for (uint256 i; i < 64; i++) {
                body[i] = reason[i + 4];
            }
            (amount0, amount1) = abi.decode(body, (int256, int256));
            ok = bytes4(reason) == IMetricPool.SimulateSwap.selector;
        }
    }

    function testP3ExtsloadStateAndEdgeAmounts() public onlyFork {
        MetricState.Slot0 memory s = MetricState.slot0(POOL);
        MetricState.Bin memory b = MetricState.bin(POOL, s.curBinIdx);
        PoolImmutables memory imm = POOL.getImmutables();
        console.log("P3 pauseLevel", s.pauseLevel);
        console.log("P3 curBinIdx", int256(s.curBinIdx));
        console.log(
            "P3 curPosInBin (of 2^104-1), parts per million",
            uint256(s.curPosInBin) * 1e6 / type(uint104).max
        );
        console.log("P3 curBinDistFromProvidedPriceE6", int256(s.curBinDistE6));
        console.log(
            "P3 spreadFeeE6, notionalFeeE8, asymmetryX8",
            s.spreadFeeE6,
            s.notionalFeeE8,
            s.asymmetryX8
        );
        console.log("P3 bin lengthE6", b.lengthE6);
        console.log("P3 bin token0 (scaled)", b.token0Scaled);
        console.log("P3 bin token1 (scaled)", b.token1Scaled);
        console.log("P3 bin addFeeBuyE6, addFeeSellE6", b.addFeeBuyE6, b.addFeeSellE6);
        console.log("P3 lowestBin", imm.lowestBin);
        console.log("P3 highestBin", imm.highestBin);
        assertLe(int256(s.curBinIdx), imm.highestBin, "bin index is in the pool's range");
        assertGe(int256(s.curBinIdx), imm.lowestBin, "bin index is in the pool's range");
        assertGt(b.lengthE6, 0, "the current bin has a width");
        assertLe(s.pauseLevel, 2);
        assertEq(imm.immutablePriceProvider, PROVIDER);
        _edgeAmounts(s, b);
    }

    function _edgeAmounts(MetricState.Slot0 memory s, MetricState.Bin memory b) internal {
        (uint128 sell, uint128 buy,) = _prices();
        (uint128 bid, uint128 ask, uint128 ref, bool ok) = _quote();
        require(ok, "no reference price");
        Edges memory e = _edges(s, b, ref);
        console.log(
            "P3 marginal mid price, millionths (from the reference and slot 0)",
            _micro(e.marginal)
        );
        console.log("P3 lower edge, upper edge, millionths", _micro(e.lower), _micro(e.upper));
        assertLe(sell, e.marginal, "sell price is at or under the marginal price");
        assertGe(buy, e.marginal, "buy price is at or over the marginal price");
        uint128[3] memory quoted = [bid, ask, ref];
        _edgeDown(b, e, sell, quoted);
        _edgeUp(b, e, buy, quoted);
        _tinySwap(e, sell, quoted);
    }

    /// Selling token0 moves the price down to the bin's lower edge and takes all its token1.
    function _edgeDown(
        MetricState.Bin memory b,
        Edges memory e,
        uint128 sell,
        uint128[3] memory quoted
    ) internal {
        uint256 out1 = b.token1Scaled / e.scale1;
        uint256 lowSell = e.lower * sell / e.marginal;
        uint256 estimate = uint256(b.token1Scaled) * Q64 / ((sell + lowSell) / 2) / e.scale0;
        console.log("P3 down: token1 out to the lower edge (raw)", out1);
        console.log("P3 down: estimated token0 in (raw)", estimate);
        (bool ok, int256 a0, int256 a1) = _simulate(true, -int128(uint128(out1)), 0, quoted);
        console.log("P3 down: exact-output simulation ok:", ok);
        if (!ok) return;
        console.log("P3 down: simulated token0 in", uint256(a0));
        console.log("P3 down: simulated token1 out", uint256(-a1));
        console.log("P3 down: estimate off by, parts per million", _off(estimate, uint256(a0)));
        uint256 more = out1 + out1 / 100;
        (ok, a0, a1) = _simulate(true, -int128(uint128(more)), 0, quoted);
        console.log("P3 down: 1% more than the edge, ok / token0 in", ok, uint256(a0));
    }

    function _edgeUp(
        MetricState.Bin memory b,
        Edges memory e,
        uint128 buy,
        uint128[3] memory quoted
    ) internal {
        uint256 out0 = b.token0Scaled / e.scale0;
        uint256 highBuy = e.upper * buy / e.marginal;
        uint256 estimate = uint256(b.token0Scaled) * ((buy + highBuy) / 2) / Q64 / e.scale1;
        console.log("P3 up: token0 out to the upper edge (raw)", out0);
        console.log("P3 up: estimated token1 in (raw)", estimate);
        (bool ok, int256 a0, int256 a1) =
            _simulate(false, -int128(uint128(out0)), type(uint128).max, quoted);
        console.log("P3 up: exact-output simulation ok:", ok);
        if (!ok) return;
        console.log("P3 up: simulated token1 in", uint256(a1));
        console.log("P3 up: simulated token0 out", uint256(-a0));
        console.log("P3 up: estimate off by, parts per million", _off(estimate, uint256(a1)));
        uint256 more = out0 + out0 / 100;
        (ok, a0, a1) = _simulate(false, -int128(uint128(more)), type(uint128).max, quoted);
        console.log("P3 up: 1% more than the edge, ok / token1 in", ok, uint256(a1));
    }

    /// A small exact-input sale, simulated: its average price against P1's marginal one.
    function _tinySwap(Edges memory e, uint128 sell, uint128[3] memory quoted) internal {
        (bool ok, int256 a0, int256 a1) = _simulate(true, 1e13, 0, quoted);
        require(ok, "tiny simulation failed");
        uint256 average = uint256(-a1) * e.scale1 * Q64 / (uint256(a0) * e.scale0);
        console.log("P3 tiny sale: in, out", uint256(a0), uint256(-a1));
        console.log(
            "P3 tiny sale average price vs P1 sell price, off by ppm", _off(average, sell)
        );
    }

    function _off(uint256 estimate, uint256 exact) internal pure returns (uint256) {
        uint256 gap = estimate > exact ? estimate - exact : exact - estimate;
        return gap * 1e6 / exact;
    }

    // ---------------------------------------------------------------------------------
    // P4: a swap from a contract, inside a v4 unlock, paying with the pool manager's funds
    // ---------------------------------------------------------------------------------

    /// Adds `amount` to `who`'s balance by a transfer from a new account. USDG packs other
    /// data into a used account's balance word (the pool manager's, for one), so `deal`
    /// can't find the slot there; a new account's word holds only its balance.
    function _topUp(address token, address who, uint256 amount) internal {
        address donor = vm.randomAddress();
        deal(token, donor, amount);
        vm.prank(donor);
        assertTrue(IERC20(token).transfer(who, amount));
    }

    /// The prober holds enough of both tokens to repay what it takes from the pool manager,
    /// and the pool manager holds enough to be taken from.
    function _readySwap() internal {
        _topUp(WETH, address(prober), 3_000e18);
        _topUp(USDG, address(prober), 5_000_000e6);
        _topUp(WETH, address(MANAGER), 3_000e18);
        _topUp(USDG, address(MANAGER), 5_000_000e6);
    }

    function _swap(bool zeroForOne, int128 amount, uint128 limit)
        internal
        returns (bool ok, int128 amount0, int128 amount1, uint256 used)
    {
        vm.prank(EOA, EOA);
        bytes memory ret;
        (ok, ret) = address(prober)
            .call(abi.encodeCall(MetricProber.swapViaManager, (zeroForOne, amount, limit)));
        if (ok) {
            (amount0, amount1, used) = abi.decode(ret, (int128, int128, uint256));
            return (ok, amount0, amount1, used);
        }
        (bytes4 outer, bytes4 inner) = _selectors(ret);
        console.log("swap reverted, selector, inner:");
        console.logBytes4(outer);
        console.logBytes4(inner);
        console.logBytes(ret);
    }

    /// USDG per WETH in millionths, from the raw amounts of a fill.
    function _average(int128 amount0, int128 amount1) internal pure returns (uint256) {
        uint256 weth = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
        uint256 usdg = amount1 < 0 ? uint256(uint128(-amount1)) : uint256(uint128(amount1));
        return usdg * 1e18 / weth;
    }

    function testP4SmallSwapsFromAContract() public onlyFork {
        _readySwap();
        (uint128 sell, uint128 buy,) = _prices();
        (bool ok, int128 a0, int128 a1, uint256 used) = _swap(true, 1e16, 0);
        assertTrue(ok, "a contract could not sell WETH: see the revert data above");
        console.log(
            "P4 WETH->USDG exact input 0.01 WETH: in, out (raw)", uint128(a0), uint128(-a1)
        );
        console.log("P4 average price, millionths USDG per WETH", _average(a0, a1));
        console.log("P4 P1 sell price, millionths", _micro(sell));
        console.log("P4 gas of the whole unlock (swap, take, settle, take)", used);
        console.log("P4 gas of the callback's take", prober.callbackGas());
        (ok, a0, a1, used) = _swap(false, 20e6, type(uint128).max);
        assertTrue(ok, "a contract could not buy WETH: see the revert data above");
        console.log(
            "P4 USDG->WETH exact input 20 USDG: in, out (raw)", uint128(a1), uint128(-a0)
        );
        console.log("P4 average price, millionths USDG per WETH", _average(a0, a1));
        console.log("P4 P1 buy price, millionths", _micro(buy));
        console.log("P4 gas of the whole unlock", used);
        console.log("P4 gas of the callback's take", prober.callbackGas());
    }

    /// A price limit just under the sell price lets only a part of a large sale through.
    function testP4PartialFillAtAPriceLimit() public onlyFork {
        _readySwap();
        (uint128 sell,,) = _prices();
        MetricState.Slot0 memory before = MetricState.slot0(POOL);
        uint128 limit = sell - sell / 50_000;
        (bool ok, int128 a0, int128 a1, uint256 used) = _swap(true, 100e18, limit);
        assertTrue(ok, "swap with a limit reverted");
        MetricState.Slot0 memory later = MetricState.slot0(POOL);
        console.log("P4 asked 100 WETH with the limit 0.002% under the sell price");
        console.log("P4 filled (raw WETH in)", uint128(a0));
        console.log("P4 received (raw USDG out)", uint128(-a1));
        console.log(
            "P4 bin position before, after, parts per million",
            uint256(before.curPosInBin) * 1e6 / type(uint104).max,
            uint256(later.curPosInBin) * 1e6 / type(uint104).max
        );
        console.log("P4 gas of the whole unlock", used);
        assertLt(uint128(a0), 100e18, "the limit should stop it short");
        assertGt(a0, 0);
        _openLimitSale();
    }

    function _openLimitSale() internal {
        (bool ok, int128 a0, int128 a1, uint256 used) = _swap(true, 100e18, 0);
        assertTrue(ok, "open-limit sale reverted");
        MetricState.Slot0 memory later = MetricState.slot0(POOL);
        console.log("P4 asked 100 WETH with no limit, filled (raw WETH in)", uint128(a0));
        console.log("P4 received (raw USDG out)", uint128(-a1));
        console.log("P4 average price, millionths", _average(a0, a1));
        console.log("P4 bin index after", int256(later.curBinIdx));
        console.log("P4 gas of the whole unlock", used);
        (ok, a0, a1, used) = _swap(true, 5_000e18, 0);
        console.log("P4 asked 5000 WETH with no limit, ok:", ok);
        if (!ok) return;
        console.log("P4 filled (raw WETH in)", uint128(a0));
        console.log("P4 received (raw USDG out)", uint128(-a1));
        console.log("P4 bin index after", int256(MetricState.slot0(POOL).curBinIdx));
        console.log("P4 gas of the whole unlock", used);
    }

    // ---------------------------------------------------------------------------------
    // P5: the extensions on this pool, and whether any of them can reach removeLiquidity
    // ---------------------------------------------------------------------------------

    function _extensionAt(PoolImmutables memory imm, uint256 index)
        internal
        pure
        returns (address)
    {
        if (index == 1) return imm.extension1;
        if (index == 2) return imm.extension2;
        if (index == 3) return imm.extension3;
        if (index == 4) return imm.extension4;
        if (index == 5) return imm.extension5;
        if (index == 6) return imm.extension6;
        return imm.extension7;
    }

    function _logOrder(string memory action, PoolImmutables memory imm, uint256 order)
        internal
    {
        console.log(action, "order word", order);
        for (uint256 index = order; index != 0; index >>= 3) {
            console.log("   runs extension slot", index & 7, _extensionAt(imm, index & 7));
        }
    }

    function testP5ExtensionsOnThePool() public onlyFork {
        PoolImmutables memory imm = POOL.getImmutables();
        console.log("P5 extension1", imm.extension1);
        console.log("P5 extension2", imm.extension2);
        console.log("P5 extension3", imm.extension3);
        console.log("P5 extension4..7 are zero:", imm.extension4 == address(0));
        _logOrder("P5 beforeAddLiquidity", imm, imm.beforeAddLiquidityOrder);
        _logOrder("P5 afterAddLiquidity", imm, imm.afterAddLiquidityOrder);
        _logOrder("P5 beforeRemoveLiquidity", imm, imm.beforeRemoveLiquidityOrder);
        _logOrder("P5 afterRemoveLiquidity", imm, imm.afterRemoveLiquidityOrder);
        _logOrder("P5 beforeSwap", imm, imm.beforeSwapOrder);
        _logOrder("P5 afterSwap", imm, imm.afterSwapOrder);
        assertEq(imm.beforeAddLiquidityOrder, 0, "an extension runs before addLiquidity");
        assertEq(imm.afterAddLiquidityOrder, 0, "an extension runs after addLiquidity");
        assertEq(imm.beforeRemoveLiquidityOrder, 0, "an extension runs before removeLiquidity");
        assertEq(imm.afterRemoveLiquidityOrder, 0, "an extension runs after removeLiquidity");
        (uint32 drawdown, uint64 decay, uint40 timelock, bool initialized) =
            IMetricStopLoss(imm.extension2).oracleStopLossConfig(address(POOL));
        console.log("P5 stop-loss (extension2): drawdownE6", drawdown);
        console.log("P5 stop-loss: decayPerSecondE18", decay);
        console.log("P5 stop-loss: timelock seconds", timelock);
        console.log("P5 stop-loss: initialized", initialized);
        (uint128 anchor,,,, uint64 maxChange) =
            IMetricVelocity(imm.extension3).priceVelocityState(address(POOL));
        console.log("P5 velocity guard (extension3): anchor mid X64", anchor);
        console.log("P5 velocity guard: maxChangePerBlockE18", maxChange);
        console.log(
            "P5 extension1 isTradingPaused:",
            IMetricSession(imm.extension1).isTradingPaused(address(POOL))
        );
    }

    /// Run as the pool, the guards' liquidity hooks are not implemented, so wiring one to a
    /// liquidity action would revert it. This pool wires none (the orders above are zero),
    /// and the orders are immutables, so that cannot change.
    function testP5GuardsAsThePoolWouldCallThem() public onlyFork {
        PoolImmutables memory imm = POOL.getImmutables();
        int256[] memory bins = new int256[](1);
        uint256[] memory shares = new uint256[](1);
        LiquidityDelta memory delta = LiquidityDelta(bins, shares);
        vm.prank(address(POOL));
        try IMetricExtension(imm.extension2)
            .beforeRemoveLiquidity(address(this), address(this), 0, delta, "") returns (
            bytes4
        ) {
            console.log("P5 stop-loss accepted beforeRemoveLiquidity");
        } catch (bytes memory why) {
            console.log("P5 stop-loss beforeRemoveLiquidity, if wired, reverts with:");
            console.logBytes(why);
        }
        (uint128 anchor,,,, uint64 maxChange) =
            IMetricVelocity(imm.extension3).priceVelocityState(address(POOL));
        vm.prank(address(POOL));
        bytes4 fine = IMetricExtension(imm.extension3)
            .beforeSwap(address(this), address(this), true, 1e16, 0, 0, 0, 0, anchor, "");
        console.log("P5 velocity guard lets a mid price equal to the anchor through:");
        console.logBytes4(fine);
        vm.prank(address(POOL));
        (bool ok, bytes memory reason) = imm.extension3
            .call(
                abi.encodeCall(
                    IMetricExtension.beforeSwap,
                    (
                        address(this),
                        address(this),
                        true,
                        1e16,
                        0,
                        0,
                        0,
                        0,
                        anchor + anchor / 10,
                        ""
                    )
                )
            );
        console.log("P5 velocity guard, a mid price 10% off the anchor, ok:", ok);
        console.logBytes(reason);
        // A limit of zero turns the guard off; this pool's was set to zero on 2026-11-23
        // (`MaxChangePerBlockSet`, block 121511483).
        if (maxChange == 0) {
            assertTrue(ok, "a guard that is off should let 10% through");
            return;
        }
        assertFalse(ok, "10% in one block should trip the guard");
    }

    // ---------------------------------------------------------------------------------
    // P6: adding and removing liquidity from a contract that owns the position
    // ---------------------------------------------------------------------------------

    uint80 internal constant SALT = 7;

    struct Plan {
        int256[] bins;
        uint256[] shares;
        uint256 expected0;
        uint256 expected1;
    }

    /// Two bins, the current one and the one above it, at 1e19 shares each (a few dollars).
    /// The expected amounts are the pool's pro-rata rule applied to each bin's balances.
    function _plan() internal view returns (Plan memory plan) {
        PoolImmutables memory imm = POOL.getImmutables();
        int16 current = MetricState.slot0(POOL).curBinIdx;
        plan.bins = new int256[](2);
        plan.shares = new uint256[](2);
        plan.bins[0] = current;
        plan.bins[1] = int256(current) + 1;
        for (uint256 i; i < 2; i++) {
            int16 idx = int16(plan.bins[i]);
            plan.shares[i] = 1e19;
            MetricState.Bin memory b = MetricState.bin(POOL, idx);
            uint256 total = MetricState.totalShares(POOL, idx);
            plan.expected0 += uint256(b.token0Scaled) * plan.shares[i] / total
            / imm.token0ScaleMultiplier;
            plan.expected1 += uint256(b.token1Scaled) * plan.shares[i] / total
            / imm.token1ScaleMultiplier;
        }
    }

    function testP6AddAndRemoveLiquidityAsOwner() public onlyFork {
        _topUp(WETH, address(prober), 100e18);
        _topUp(USDG, address(prober), 1_000_000e6);
        PoolImmutables memory imm = POOL.getImmutables();
        console.log("P6 minimalOperationalLiquidity", imm.minimalOperationalLiquidity);
        console.log("P6 initialScaledToken0PerShareE18", imm.initialScaledToken0PerShareE18);
        console.log("P6 initialScaledToken1PerShareE18", imm.initialScaledToken1PerShareE18);
        Plan memory plan = _plan();
        console.log("P6 first bin", plan.bins[0]);
        console.log("P6 second bin", plan.bins[1]);
        console.log("P6 shares per bin", plan.shares[0]);
        assertGe(plan.shares[0], imm.minimalOperationalLiquidity);
        console.log(
            "P6 expected token0, token1 (pro rata, raw)", plan.expected0, plan.expected1
        );
        uint256 weth = IERC20(WETH).balanceOf(address(prober));
        uint256 usdg = IERC20(USDG).balanceOf(address(prober));
        (uint256 a0, uint256 a1, uint256 used) = prober.add(SALT, plan.bins, plan.shares);
        console.log("P6 addLiquidity paid token0, token1 (raw)", a0, a1);
        console.log("P6 addLiquidity gas", used);
        assertEq(
            weth - IERC20(WETH).balanceOf(address(prober)),
            a0,
            "token0 paid is what it reported"
        );
        assertEq(
            usdg - IERC20(USDG).balanceOf(address(prober)),
            a1,
            "token1 paid is what it reported"
        );
        _readShares(plan);
        _removeAll(plan, a0, a1);
    }

    function _readShares(Plan memory plan) internal view {
        for (uint256 i; i < 2; i++) {
            uint256 held =
                MetricState.positionShares(POOL, address(prober), SALT, int16(plan.bins[i]));
            console.log("P6 position shares read by extsload, bin", plan.bins[i]);
            console.log("P6    shares", held);
            assertEq(held, plan.shares[i], "extsload reads the shares added");
        }
        uint256 other =
            MetricState.positionShares(POOL, address(this), SALT, int16(plan.bins[0]));
        assertEq(other, 0, "another owner holds none");
    }

    function _removeAll(Plan memory plan, uint256 added0, uint256 added1) internal {
        (uint256 r0, uint256 r1, uint256 used) = prober.remove(SALT, plan.bins, plan.shares);
        console.log("P6 removeLiquidity returned token0, token1 (raw)", r0, r1);
        console.log("P6 removeLiquidity gas", used);
        console.log("P6 lost to rounding, token0 and token1 (raw)", added0 - r0, added1 - r1);
        for (uint256 i; i < 2; i++) {
            assertEq(
                MetricState.positionShares(POOL, address(prober), SALT, int16(plan.bins[i])), 0
            );
        }
        assertLe(r0, added0);
        assertLe(r1, added1);
    }

    /// Only the owner may remove: a different caller is refused whatever the extensions say.
    function testP6OnlyTheOwnerMayRemove() public onlyFork {
        Plan memory plan = _plan();
        vm.expectRevert();
        POOL.removeLiquidity(address(prober), SALT, LiquidityDelta(plan.bins, plan.shares), "");
    }

    // ---------------------------------------------------------------------------------
    // P5, continued: what a blocked swap does to removeLiquidity
    // ---------------------------------------------------------------------------------

    /// Puts the stop-loss's high watermark for a bin far above any real value, so the
    /// next swap that crosses the bin is judged to have lost more than the drawdown.
    function _tripStopLoss(int16 binIdx) internal {
        address ext = POOL.getImmutables().extension2;
        bytes32 outer = keccak256(abi.encode(address(POOL), uint256(3)));
        bytes32 slot = keccak256(abi.encode(int256(binIdx), outer));
        uint256 high = uint256(1) << 100;
        vm.store(ext, slot, bytes32(high | (high << 104) | (uint256(block.timestamp) << 208)));
        (uint256 hwm0, uint256 hwm1) =
            IMetricStopLoss(ext).currentHighWatermarks(address(POOL), binIdx);
        assertEq(hwm0, high, "the watermark slot guess is right");
        assertEq(hwm1, high);
    }

    function testP5StopLossBlocksSwapsButNotRemoval() public onlyFork {
        _readySwap();
        Plan memory plan = _plan();
        prober.add(SALT, plan.bins, plan.shares);
        (bool ok,,,) = _swap(true, 1e16, 0);
        assertTrue(ok, "the swap works before the trip");
        _tripStopLoss(MetricState.slot0(POOL).curBinIdx);
        (ok,,,) = _swap(true, 1e16, 0);
        console.log("P5 swap with the stop-loss tripped, ok:", ok);
        assertFalse(ok, "the stop-loss should block the sale");
        (uint256 r0, uint256 r1,) = prober.remove(SALT, plan.bins, plan.shares);
        console.log("P5 removeLiquidity with the stop-loss tripped, returned", r0, r1);
        assertGt(r0, 0);
    }

    function testP5PauseBlocksSwapsButNotRemoval() public onlyFork {
        _readySwap();
        Plan memory plan = _plan();
        prober.add(SALT, plan.bins, plan.shares);
        for (uint8 level = 1; level <= 2; level++) {
            vm.prank(FACTORY);
            IMetricPoolAdmin(address(POOL)).setPause(level);
            (bool ok,,,) = _swap(true, 1e16, 0);
            console.log("P5 pause level", level);
            console.log("P5    swap ok:", ok);
            assertFalse(ok, "a paused pool should refuse swaps");
            vm.prank(FACTORY);
            IMetricPoolAdmin(address(POOL)).setPause(0);
        }
        vm.prank(FACTORY);
        IMetricPoolAdmin(address(POOL)).setPause(2);
        (uint256 r0, uint256 r1,) = prober.remove(SALT, plan.bins, plan.shares);
        console.log("P5 removeLiquidity at pause level 2, returned", r0, r1);
        assertGt(r0, 0);
    }

    // ---------------------------------------------------------------------------------
    // P7: what the caller sees when a hook reverts inside a swap
    // ---------------------------------------------------------------------------------

    /// The hook sits where `beforeSwap` is its only permission, as v4 requires of the address.
    address internal constant HOOK = address(uint160(0xBEEF << 24 | Hooks.BEFORE_SWAP_FLAG));

    function _failingPool() internal returns (PoolKey memory key, PoolSwapTest router) {
        vm.etch(HOOK, address(new FailingHook()).code);
        key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 3_000, 60, IHooks(HOOK));
        MANAGER.initialize(key, uint160(1 << 96));
        router = new PoolSwapTest(MANAGER);
    }

    function _swapThrough(PoolSwapTest router, PoolKey memory key, uint256 mode)
        internal
        returns (bytes memory ret)
    {
        FailingHook(HOOK).setMode(mode);
        bool ok;
        PoolSwapTest.TestSettings memory settings;
        (ok, ret) = address(router)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (key, IPoolManager.SwapParams(true, -1e15, 4295128740), settings, "")
                )
            );
        assertFalse(ok, "the swap should have reverted");
    }

    /// `WrappedError(address target, bytes4 selector, bytes reason, bytes details)`: ERC-7751.
    function _logWrapped(string memory label, bytes memory ret) internal {
        console.log(label);
        console.log("   total revert data length", ret.length);
        console.logBytes4(bytes4(ret));
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; i++) {
            body[i] = ret[i + 4];
        }
        (address target, bytes4 selector, bytes memory reason, bytes memory details) =
            abi.decode(body, (address, bytes4, bytes, bytes));
        console.log("   target (the hook):", target);
        console.log("   failing function selector:");
        console.logBytes4(selector);
        console.log("   reason length", reason.length);
        console.logBytes(reason);
        console.log("   details:");
        console.logBytes(details);
    }

    function testP7HookRevertSeenByTheCaller() public onlyFork {
        (PoolKey memory key, PoolSwapTest router) = _failingPool();
        console.log("P7 WrappedError selector:");
        console.logBytes4(bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")));
        console.log("P7 HookCallFailed selector:");
        console.logBytes4(bytes4(keccak256("HookCallFailed()")));
        console.log("P7 hook address", HOOK);
        _logWrapped("P7 hook reverts with Boom(42):", _swapThrough(router, key, 1));
        _logWrapped("P7 hook reverts with no data:", _swapThrough(router, key, 2));
        _logWrapped("P7 hook reverts with a string:", _swapThrough(router, key, 3));
        bytes memory wrong = _swapThrough(router, key, 4);
        console.log("P7 hook returns the wrong selector, revert data:");
        console.logBytes(wrong);
        _logWrapped(
            "P7 hook's take of more than the manager holds:", _swapThrough(router, key, 5)
        );
    }

    // ---------------------------------------------------------------------------------
    // P8, the chain's part: the most gas one transaction may use (the local part is in
    // test/MetricProbeGas.t.sol)
    // ---------------------------------------------------------------------------------

    /// Calls an ArbGasInfo precompile (0x6c) through the fork's RPC. The forked EVM has no
    /// code there, so the node is asked directly.
    function _arbGasInfo(string memory signature) internal returns (bytes memory) {
        string memory selector =
            vm.toString(abi.encodePacked(bytes4(keccak256(bytes(signature)))));
        string memory call = string.concat(
            '[{"to":"0x000000000000000000000000000000000000006c","data":"',
            selector,
            '"},"latest"]'
        );
        return vm.rpc("eth_call", call);
    }

    function testP8ChainPerTransactionGasCap() public onlyFork {
        uint256 cap = abi.decode(_arbGasInfo("getMaxTxGasLimit()"), (uint256));
        uint256 blockCap = abi.decode(_arbGasInfo("getMaxBlockGasLimit()"), (uint256));
        (uint256 speed, uint256 pool, uint256 txCap) =
            abi.decode(_arbGasInfo("getGasAccountingParams()"), (uint256, uint256, uint256));
        console.log("P8 ArbGasInfo.getMaxTxGasLimit()", cap);
        console.log("P8 ArbGasInfo.getMaxBlockGasLimit()", blockCap);
        console.log("P8 ArbGasInfo.getGasAccountingParams(): speed limit per second", speed);
        console.log("P8    gas pool max", pool);
        console.log("P8    max tx gas limit", txCap);
        console.log(
            "P8 the fork block's reported gas limit (Nitro's placeholder)", block.gaslimit
        );
        assertEq(cap, txCap, "the two precompile reads agree");
        assertGt(cap, 0);
    }
}
