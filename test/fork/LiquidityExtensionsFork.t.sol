// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { MetricLiquidityExtension } from "../../src/extensions/MetricLiquidityExtension.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
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
        if (!live) return;
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
        (uint128 in0, uint128 in1, uint128 out0, uint128 out1) = ext.ledger(address(POOL), 3);
        assertEq(in0, paid0, "in0");
        assertEq(in1, paid1, "in1");
        assertEq(out0, got0, "out0");
        assertEq(out1, got1, "out1");
        console.log("in: WETH wei, USDG units", in0, in1);
        console.log("out: WETH wei, USDG units", out0, out1);
    }
}
