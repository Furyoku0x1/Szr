// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { MetricLiquidityExtension } from "../../src/extensions/MetricLiquidityExtension.sol";
import { V4LiquidityExtension } from "../../src/extensions/V4LiquidityExtension.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
import { IndexLiquidityExtension } from "../../src/extensions/IndexLiquidityExtension.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../../src/index/IndexPositions.sol";
import { ISzrLiquidity } from "../../src/interfaces/ISzrModules.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import {
    IMetricLiquidityPool,
    IMetricPool,
    IMetricSwapCallback
} from "../../src/interfaces/metric/IMetricPool.sol";

/// @dev Answers the one question the extension asks of its hook at construction.
contract HookStub {
    address public liquidity;

    constructor(address liquidity_) {
        liquidity = liquidity_;
    }
}

/// @dev Another account that sells WETH into the pool, paying in the swap callback.
contract Trader is IMetricSwapCallback {
    function sell(IMetricLiquidityPool pool, uint256 amount) external {
        IMetricPool(address(pool)).swap(address(this), true, int128(uint128(amount)), 0, "", "");
    }

    function metricOmmSwapCallback(int256 amount0, int256, bytes calldata) external {
        IERC20(IMetricLiquidityPool(msg.sender).getImmutables().token0)
            .transfer(msg.sender, uint256(amount0));
    }
}

/// @dev The Metric liquidity extension on the live WETH/USDG Metric pool of Robinhood Chain,
/// run against the deployed Liquidity and Core: the manager is read from Liquidity. The suite
/// runs only with a `FORK_RPC_URL`, at the latest block, and spends nothing real:
///     FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///         forge test --match-path test/fork/LiquidityExtensionsFork.t.sol -vv
contract LiquidityExtensionsForkTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    IMetricLiquidityPool internal constant POOL =
        IMetricLiquidityPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    Liquidity internal constant LIQUIDITY =
        Liquidity(0x8c1261C469E83E93aa19Af8f07FD939078Dd1344);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    bool internal live;
    MetricLiquidityExtension internal ext;
    address internal manager;
    int256 internal cur;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        // The hook is never called here, so a stub that names Liquidity stands in for it.
        address hook = address(new HookStub(address(LIQUIDITY)));
        ext = new MetricLiquidityExtension(LIQUIDITY, hook, IMetricFactory(FACTORY));
        manager = LIQUIDITY.manager();
        deal(WETH, address(ext), 100e18);
        // The current bin is word 0 of slot 0 above the pause level: bits 8..23.
        cur = int256(int16(uint16(uint256(POOL.extsload(bytes32(uint256(0)))) >> 8)));
    }

    modifier onlyFork() {
        if (!live) vm.skip(true);
        _;
    }

    function _bins() internal view returns (int256[] memory list) {
        list = new int256[](2);
        list[0] = cur;
        list[1] = cur + 1;
    }

    function _shares() internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = 1e22;
        list[1] = 1e21;
    }

    function testSwapAddRemoveSwapBackAndToCore() public onlyFork {
        assertEq(address(ext.core()), address(LIQUIDITY.core()), "Core comes from Liquidity");
        assertEq(ext.weth(), WETH, "the pool's WETH is Core's backing");
        vm.startPrank(manager);
        ext.addPool(address(POOL));
        // Part of the WETH to USDG on Metric.
        (uint256 spent, uint256 got) =
            ext.swapMetric(address(POOL), true, 10e18, 1, 0, block.timestamp);
        assertEq(spent, 10e18, "all of the input was filled");
        assertGt(got, 0, "USDG received");
        assertEq(IERC20(USDG).balanceOf(address(ext)), got);
        console.log("10 WETH sold for USDG units", got);
        // Add bins, then remove them.
        uint256 weth = IERC20(WETH).balanceOf(address(ext));
        (uint256 paid0, uint256 paid1) =
            ext.addLiquidity(address(POOL), 1, _bins(), _shares(), MAX, MAX, block.timestamp);
        assertGt(paid0 + paid1, 0, "the pool took tokens");
        assertEq(IERC20(WETH).balanceOf(address(ext)), weth - paid0, "WETH measured");
        console.log("added: WETH wei, USDG units", paid0, paid1);
        (uint256 out0, uint256 out1) =
            ext.removeLiquidity(address(POOL), 1, _bins(), _shares(), 0, 0, block.timestamp);
        console.log("removed: WETH wei, USDG units", out0, out1);
        assertLe(out0, paid0, "rounding is against the extension");
        assertLe(out1, paid1);
        assertLe(paid0 - out0, 100, "and costs a few wei");
        assertLe(paid1 - out1, 100);
        assertEq(IERC20(WETH).balanceOf(address(ext)), weth - paid0 + out0, "tokens came back");
        // The USDG back to WETH.
        uint256 usdg = IERC20(USDG).balanceOf(address(ext));
        (spent, got) =
            ext.swapMetric(address(POOL), false, usdg, 1, type(uint128).max, block.timestamp);
        assertEq(spent, usdg, "all of the USDG was filled");
        assertEq(IERC20(USDG).balanceOf(address(ext)), 0);
        assertGt(got, 0, "WETH received");
        // WETH to Core as backing.
        uint256 give = IERC20(WETH).balanceOf(address(ext));
        uint256 cash = ext.core().reserveCash();
        ext.toCore(WETH, give);
        assertEq(IERC20(WETH).balanceOf(address(ext)), 0, "sent to Core");
        assertEq(ext.core().reserveCash(), cash + give, "backing raised");
        vm.stopPrank();
    }

    /// The v4 extension trades on the live Metric pool directly, with no v4 wrapper.
    function testTheV4ExtensionSwapsOnTheLiveMetricPool() public onlyFork {
        V4LiquidityExtension v4 =
            new V4LiquidityExtension(LIQUIDITY, address(ext.hook()), IMetricFactory(FACTORY));
        deal(WETH, address(v4), 10e18);
        vm.startPrank(manager);
        v4.addPool(address(POOL));
        (uint256 spent, uint256 got) =
            v4.swapMetric(address(POOL), true, 10e18, 1, 0, block.timestamp);
        assertEq(spent, 10e18, "all of the WETH was filled");
        assertEq(IERC20(WETH).balanceOf(address(v4)), 0, "WETH paid");
        assertEq(IERC20(USDG).balanceOf(address(v4)), got, "USDG received");
        (spent,) =
            v4.swapMetric(address(POOL), false, got, 1, type(uint128).max, block.timestamp);
        assertEq(spent, got, "all of the USDG was filled");
        assertGt(IERC20(WETH).balanceOf(address(v4)), 0, "WETH back");
        vm.stopPrank();
    }

    function testPositionValueMatchesAFullRemoval() public onlyFork {
        deal(USDG, address(ext), 100_000e6);
        vm.startPrank(manager);
        ext.addPool(address(POOL));
        ext.addLiquidity(address(POOL), 7, _bins(), _shares(), MAX, MAX, block.timestamp);
        (uint256 value0, uint256 value1) = ext.positionValue(address(POOL), 7, _bins());
        (uint256 out0, uint256 out1) =
            ext.removeLiquidity(address(POOL), 7, _bins(), _shares(), 0, 0, block.timestamp);
        vm.stopPrank();
        console.log("value: WETH wei, USDG units", value0, value1);
        // The tolerance covers per-bin rounding: one unit per bin per token.
        assertApproxEqAbs(value0, out0, 2, "token0 value");
        assertApproxEqAbs(value1, out1, 2, "token1 value");
    }

    function testLedgerShowsInAgainstOutAcrossASwap() public onlyFork {
        deal(USDG, address(ext), 100_000e6);
        vm.startPrank(manager);
        ext.addPool(address(POOL));
        (uint256 paid0, uint256 paid1) =
            ext.addLiquidity(address(POOL), 3, _bins(), _shares(), MAX, MAX, block.timestamp);
        vm.stopPrank();
        // Another account trades through the pool, then the extension takes its bins out.
        Trader trader = new Trader();
        deal(WETH, address(trader), 5e18);
        trader.sell(POOL, 1e18);
        vm.prank(manager);
        (uint256 got0, uint256 got1) =
            ext.removeLiquidity(address(POOL), 3, _bins(), _shares(), 0, 0, block.timestamp);
        (uint256 in0, uint256 in1, uint256 out0, uint256 out1) = ext.ledger(address(POOL), 3);
        assertEq(in0, paid0, "in0");
        assertEq(in1, paid1, "in1");
        assertEq(out0, got0, "out0");
        assertEq(out1, got1, "out1");
        console.log("in: WETH wei, USDG units", in0, in1);
        console.log("out: WETH wei, USDG units", out0, out1);
    }

    /// A bin below zero keeps its sign through the extension's storage reads: its value
    /// matches what a removal returns, and the ledger matches too.
    function testNegativeBinValueAndLedgerMatchRemoval() public onlyFork {
        deal(USDG, address(ext), 100_000e6);
        int256[] memory bins = new int256[](2);
        bins[0] = -3;
        bins[1] = -2;
        vm.startPrank(manager);
        ext.addPool(address(POOL));
        (uint256 paid0, uint256 paid1) =
            ext.addLiquidity(address(POOL), 9, bins, _shares(), MAX, MAX, block.timestamp);
        assertGt(paid0 + paid1, 0, "the negative bins took tokens");
        (uint256 value0, uint256 value1) = ext.positionValue(address(POOL), 9, bins);
        (uint256 out0, uint256 out1) =
            ext.removeLiquidity(address(POOL), 9, bins, _shares(), 0, 0, block.timestamp);
        vm.stopPrank();
        console.log("negative bins value: WETH wei, USDG units", value0, value1);
        assertGt(value0 + value1, 0, "the bins hold value");
        assertApproxEqAbs(value0, out0, 2, "token0 value");
        assertApproxEqAbs(value1, out1, 2, "token1 value");
        (uint256 in0, uint256 in1, uint256 ledgerOut0, uint256 ledgerOut1) =
            ext.ledger(address(POOL), 9);
        assertEq(in0, paid0, "in0");
        assertEq(in1, paid1, "in1");
        assertEq(ledgerOut0, out0, "out0");
        assertEq(ledgerOut1, out1, "out1");
    }
}

/// @dev The index extension on the live Liquidity and Core: funded with real sale WETH
/// through `sendFunding`, it buys SZR on the live SZR/WETH pool, joins a real index pool of
/// two stock tokens and USDG, holds an INDEX/SZR position, harvests it after fee-paying
/// swaps, sells the shares for SZR and retires the SZR through Core. The stock tokens and
/// USDG for the join are dealt, as there is no live route from WETH to them. Runs only with
/// a `FORK_RPC_URL`, at the latest block.
contract IndexLiquidityExtensionForkTest is Test {
    uint256 internal constant FAR = type(uint256).max;
    address internal constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    Liquidity internal constant LIQUIDITY =
        Liquidity(0x8c1261C469E83E93aa19Af8f07FD939078Dd1344);
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    uint128 internal constant UNITS = 1e21;

    bool internal live;
    address internal manager;
    address internal szr;
    address internal trader = makeAddr("trader");
    IndexPool internal index;
    IndexLiquidityExtension internal ext;
    PoolKey internal key;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        manager = LIQUIDITY.manager();
        szr = LIQUIDITY.token();
        IndexPoolFactory indexFactory =
            new IndexPoolFactory(ISzrLiquidity(address(LIQUIDITY)), makeAddr("cut"));
        IndexPositions positions =
            new IndexPositions(LIQUIDITY.poolManager(), address(indexFactory));
        address hook = address(new HookStub(address(LIQUIDITY)));
        ext = new IndexLiquidityExtension(
            LIQUIDITY, hook, IMetricFactory(FACTORY), positions, indexFactory
        );
        index = _index(indexFactory);
    }

    function _index(IndexPoolFactory indexFactory) internal returns (IndexPool pool) {
        // Sorted by address: TSLA (0x32...), USDG (0x5f...), NVDA (0xd0...).
        address[] memory list = new address[](3);
        list[0] = TSLA;
        list[1] = USDG;
        list[2] = NVDA;
        uint256[] memory weights = new uint256[](3);
        weights[0] = 333_333_333_333_333_334;
        weights[1] = 333_333_333_333_333_333;
        weights[2] = 333_333_333_333_333_333;
        pool =
            IndexPool(indexFactory.create("Index", "IDX", list, weights, 3e15, address(0), 0));
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1000e18;
        amounts[1] = 300_000e6;
        amounts[2] = 1000e18;
        _fund(address(this), address(pool), 10);
        pool.start(amounts, 1e24, FAR);
        _fund(trader, address(pool), 10);
        _fund(address(ext), address(0), 1);
    }

    /// Deals `times` the pool's starting amounts and approves `pool` when one is given.
    function _fund(address who, address pool, uint256 times) internal {
        deal(TSLA, who, 1000e18 * times);
        deal(USDG, who, 300_000e6 * times);
        deal(NVDA, who, 1000e18 * times);
        if (pool == address(0)) return;
        vm.startPrank(who);
        IERC20(TSLA).approve(pool, FAR);
        IERC20(USDG).approve(pool, FAR);
        IERC20(NVDA).approve(pool, FAR);
        vm.stopPrank();
    }

    function testHarvestSellAndRetireOnTheLiveCore() public {
        if (!live) return vm.skip(true);
        uint256 funded = LIQUIDITY.unallocatedFunding() / 2;
        vm.startPrank(manager);
        LIQUIDITY.announceDestination(address(ext));
        vm.warp(block.timestamp + LIQUIDITY.DESTINATION_DELAY());
        LIQUIDITY.sendFunding(address(ext), funded);
        assertEq(IERC20(WETH).balanceOf(address(ext)), funded, "funded with sale WETH");
        _buySzr(funded);
        _joinAndOpen();
        vm.stopPrank();
        uint256 f = _payFees();
        vm.startPrank(manager);
        uint256 retired = _harvestSellRetire();
        vm.stopPrank();
        // The growth is f of the share's half of the position, about f × UNITS in SZR at a
        // price of one; selling the shares costs the 0.3% fee and a little price impact.
        uint256 expected = uint256(UNITS) * f / 1e18;
        console.log("growth fraction, WAD", f);
        console.log("SZR retired, expected", retired, expected);
        assertApproxEqRel(retired, expected, 1e16, "retired against growth");
        assertLe(retired, expected, "never more than the growth");
    }

    function _buySzr(uint256 funded) internal {
        PoolKey memory main = LIQUIDITY.key(0);
        ext.registerRoute(main);
        bool zeroForOne = Currency.unwrap(main.currency0) == WETH;
        ext.swap(
            main,
            zeroForOne,
            funded,
            1,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        assertGt(IERC20(szr).balanceOf(address(ext)), UNITS, "SZR bought");
    }

    function _joinAndOpen() internal {
        uint256[] memory maxIn = new uint256[](3);
        maxIn[0] = FAR;
        maxIn[1] = FAR;
        maxIn[2] = FAR;
        ext.joinIndex(address(index), 1e23, maxIn, block.timestamp);
        bool shareFirst = address(index) < szr;
        key = PoolKey(
            Currency.wrap(shareFirst ? address(index) : szr),
            Currency.wrap(shareFirst ? szr : address(index)),
            3000,
            60,
            IHooks(address(0))
        );
        LIQUIDITY.poolManager().initialize(key, uint160(1 << 96));
        ext.openIndexPosition(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), UNITS, FAR, FAR, FAR
        );
        ext.registerRoute(key);
    }

    /// Fee-paying swaps in the index pool by someone else.
    function _payFees() internal returns (uint256 f) {
        uint256 before = index.growthIndex();
        vm.startPrank(trader);
        for (uint256 round; round < 10; round++) {
            (, uint256 got) = index.swap(TSLA, NVDA, 50e18, true, 1, trader, FAR);
            index.swap(NVDA, TSLA, got, true, 1, trader, FAR);
        }
        vm.stopPrank();
        uint256 current = index.growthIndex();
        f = (current - before) * 1e18 / current;
    }

    function _harvestSellRetire() internal returns (uint256 retired) {
        uint256 shares = index.balanceOf(address(ext));
        uint256 held = IERC20(szr).balanceOf(address(ext));
        assertGt(ext.harvestIndexPosition(1, 0, 0, block.timestamp), 0, "harvested");
        uint256 harvested = index.balanceOf(address(ext)) - shares;
        bool zeroForOne = Currency.unwrap(key.currency0) == address(index);
        ext.swap(
            key,
            zeroForOne,
            harvested,
            1,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        retired = IERC20(szr).balanceOf(address(ext)) - held;
        uint256 active = ext.core().activeSupply();
        ext.toCore(szr, retired);
        assertEq(active - ext.core().activeSupply(), retired, "retired from active supply");
    }
}
