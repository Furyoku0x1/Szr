// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Cycle } from "../../src/index/IndexSizer.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexBalancer } from "../../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../../src/index/IndexBalancerState.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "../../src/interfaces/metric/IMetricPool.sol";
import { IndexRouter } from "../utils/IndexBalancerWorld.sol";
import { IndexBalancerForkBase } from "./IndexBalancerForkBase.sol";

/// @dev Swaps on a Metric pool exact input and pays in its callback, for comparing what the
/// balancer's reading predicts with what Metric really pays.
contract MetricTrader is IMetricSwapCallback {
    function trade(address pool, bool zeroForOne, uint256 amount) external returns (uint256) {
        (int128 amount0, int128 amount1) = IMetricPool(pool)
            .swap(
                address(this),
                zeroForOne,
                int128(uint128(amount)),
                zeroForOne ? 0 : type(uint128).max,
                "",
                ""
            );
        int128 got = zeroForOne ? amount1 : amount0;
        return uint256(uint128(-got));
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        MetricImmutables memory imm = IMetricPool(msg.sender).getImmutables();
        if (amount0 > 0) IERC20(imm.token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20(imm.token1).transfer(msg.sender, uint256(amount1));
    }
}

/// @dev The balancer against live Metric stock pools (`docs/research/metric-stock-pools-
/// 2026-11-25.md`) and the live v4 pools of the same tokens, and the gas of every kind of
/// call with real tokens and venues. Reports, not gates; the Metric parts are skipped when
/// the pool's feed is down. FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test
/// --match-path "test/fork/IndexBalancerMetricFork.t.sol" -vv
contract IndexBalancerMetricForkTest is IndexBalancerForkBase {
    address internal constant METRIC_NVDA = 0xBc6426CdBCE142dfbff33303dc0923509f61eedc;
    address internal constant METRIC_TSLA = 0x99932C7660dD58cf19f0e82e97F288d88d033480;

    function _metricLive(address pool) internal returns (bool) {
        try IMetricPool(pool).getSellAndBuyPrices() returns (uint128 sell, uint128) {
            return sell != 0;
        } catch {
            console.log("Metric pool's feed is down or it is paused", pool);
            return false;
        }
    }

    function _routes(address token, bool metric, bool v4)
        internal
        view
        returns (IndexBalancerState.Route[] memory list)
    {
        list = new IndexBalancerState.Route[]((metric ? 1 : 0) + (v4 ? 1 : 0));
        uint256 next;
        if (metric) {
            list[next].metric = true;
            list[next++].pool = token == NVDA ? METRIC_NVDA : METRIC_TSLA;
        }
        if (v4) list[next].venue = venueOf[token];
    }

    /// Which venues each token's routes use when a pool is made: Metric, v4, or both. Set
    /// before the pool, since a later change waits a day and Metric's feed goes stale.
    mapping(address token => uint256) internal kinds;
    uint256 internal constant V4 = 0;
    uint256 internal constant METRIC = 1;
    uint256 internal constant BOTH = 2;

    function _routesFor(address token)
        internal
        view
        override
        returns (IndexBalancerState.Route[] memory)
    {
        uint256 kind = kinds[token];
        return _routes(token, kind != V4, kind != METRIC);
    }

    function _pair(address token, uint256 off, uint256 gap) internal returns (IndexPool pool) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = token < USDG ? (token, USDG) : (USDG, token);
        pool = _pool(list, _equalWeights(2), 200_000, off, gap);
    }

    // -------------------------------------------------------------- the reading

    /// What `MetricBook` applied to the raw pool predicts for a swap, against what the pool
    /// really pays, both ways and at three sizes; and the gas of a read, cold and warm.
    function testMetricModelAgainstRealSwaps() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        address low = NVDA < USDG ? NVDA : USDG;
        vm.cool(METRIC_NVDA);
        uint256 before = gasleft();
        uint256[5] memory book = balancer.metric().read(METRIC_NVDA, low);
        console.log("Metric read, cold", before - gasleft());
        before = gasleft();
        balancer.metric().read(METRIC_NVDA, low);
        console.log("Metric read, warm", before - gasleft());
        MetricTrader trader = new MetricTrader();
        MetricImmutables memory imm = IMetricPool(METRIC_NVDA).getImmutables();
        uint256[3] memory dollars = [uint256(1000), 10_000, 50_000];
        console.log("way (0: buy NVDA), dollars, predicted, paid, error (ppm, signed)");
        for (uint256 way; way < 2; way++) {
            for (uint256 s; s < 3; s++) {
                address input = way == 0 ? USDG : NVDA;
                uint256 amount =
                    way == 0 ? dollars[s] * 1e6 : dollars[s] * 1e6 * 1e18 / _price(NVDA);
                uint256 predicted = balancer.sizer().metricOut(book, input == low, amount);
                uint256 snapshot = vm.snapshotState();
                deal(input, address(trader), amount);
                uint256 paid;
                try trader.trade(METRIC_NVDA, input == imm.token0, amount) returns (
                    uint256 out
                ) {
                    paid = out;
                } catch {
                    console.log("Metric refused the swap");
                }
                vm.revertToState(snapshot);
                console.log(way, dollars[s], predicted, paid);
                if (paid != 0) {
                    console.logInt((int256(predicted) - int256(paid)) * 1e6 / int256(paid));
                }
            }
        }
    }

    // -------------------------------------------------------------- venues and shapes

    /// Which venue the balancer picks each way, with NVDA's Metric pool and its v4 pool.
    function testVenueChoiceEachWay() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        for (uint256 way; way < 2; way++) {
            uint256 snapshot = vm.snapshotState();
            // First NVDA cheap in the pool, then dear (USDG cheap).
            address[] memory list = new address[](2);
            (list[0], list[1]) = (USDG, NVDA);
            kinds[NVDA] = BOTH;
            IndexPool pool = _pool(list, _equalWeights(2), 200_000, way == 0 ? 1 : 0, 0.03e18);
            (Cycle memory cycle,) = balancer.plan(address(pool), NVDA, USDG);
            address chosen = way == 0 ? cycle.sellPool : cycle.buyPool;
            console.log(way == 0 ? "NVDA cheap: sold on" : "NVDA dear: bought on");
            console.log(chosen == address(0) ? "v4" : "Metric");
            uint256 profit = balancer.balance(address(pool), NVDA, USDG);
            console.log("profit (raw)", profit);
            vm.revertToState(snapshot);
        }
    }

    /// A cycle on Metric alone, with the pool manager locked and from inside another's
    /// unlock.
    function testMetricOnlyBothLockStates() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        kinds[NVDA] = METRIC;
        IndexPool pool = _pair(NVDA, NVDA < USDG ? 0 : 1, 0.02e18);
        uint256 snapshot = vm.snapshotState();
        uint256 locked = balancer.balance(address(pool), NVDA, USDG);
        console.log("Metric only, locked: profit", locked);
        vm.revertToState(snapshot);
        IndexRouter router = new IndexRouter(MANAGER);
        deal(USDG, address(router), 1e6);
        router.run(
            router.OUTER(),
            USDG,
            1e6,
            abi.encode(
                address(balancer),
                abi.encodeCall(IndexBalancer.balance, (address(pool), NVDA, USDG))
            )
        );
        console.log("Metric only, unlocked: profit", router.profit());
        assertEq(router.profit(), locked, "the same cycle");
    }

    /// Metric first and v4 second, run in the reordered way with Metric's exact output:
    /// NVDA cheap, sold on Metric, and the units bought into TSLA on v4.
    function testReorderedShapeWithRealExactOutput() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        kinds[NVDA] = METRIC;
        address[] memory list = _three(NVDA, TSLA);
        IndexPool pool = _pool(list, _equalWeights(3), 300_000, _indexOf(list, NVDA), 0.03e18);
        (Cycle memory cycle,) = balancer.plan(address(pool), NVDA, TSLA);
        console.log("sold on Metric", cycle.sellPool != address(0));
        console.log("bought on v4", cycle.buyPool == address(0));
        uint256 before = gasleft();
        uint256 profit = balancer.balance(address(pool), NVDA, TSLA);
        console.log("reordered shape: profit (raw NVDA), gas", profit, before - gasleft());
    }

    // -------------------------------------------------------------- gas

    /// Everything a hook call touches marked cold, as at the start of a transaction.
    function _cool(IndexPool pool) internal {
        vm.cool(address(MANAGER));
        vm.cool(address(balancer));
        vm.cool(address(balancer.sizer()));
        vm.cool(address(balancer.metric()));
        vm.cool(balancer.settings());
        vm.cool(address(factory));
        vm.cool(address(pool));
        vm.cool(METRIC_NVDA);
        vm.cool(METRIC_TSLA);
        address[] memory list = pool.tokens();
        for (uint256 index; index < list.length; index++) {
            vm.cool(list[index]);
        }
    }

    /// The gas of the pool's `beforeSwap` call, as the pool makes it, cold.
    function _hookCall(IndexPool pool, address tokenIn, address tokenOut)
        internal
        returns (uint256 used)
    {
        _cool(pool);
        vm.prank(address(pool));
        uint256 before = gasleft();
        balancer.beforeSwap(address(this), tokenIn, tokenOut);
        used = before - gasleft();
    }

    function testGasNoGap() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        if (!_metricLive(METRIC_TSLA)) return;
        // A minimum no real gap reaches: every price is read and nothing is traded.
        minimumGap = 0.5e18;
        address[] memory list = _three(NVDA, TSLA);
        uint256 snapshot = vm.snapshotState();
        IndexPool pool = _pool(list, _equalWeights(3), 300_000, 9, 0);
        console.log("no gap, v4 venues", _hookCall(pool, NVDA, TSLA));
        vm.revertToState(snapshot);
        kinds[NVDA] = METRIC;
        pool = _pool(list, _equalWeights(3), 300_000, 9, 0);
        console.log("no gap, one Metric venue", _hookCall(pool, NVDA, TSLA));
        vm.revertToState(snapshot);
        (kinds[NVDA], kinds[TSLA]) = (METRIC, METRIC);
        pool = _pool(list, _equalWeights(3), 300_000, 9, 0);
        console.log("no gap, two Metric venues", _hookCall(pool, NVDA, TSLA));
    }

    /// The first call that pays, for each shape: NVDA 3% cheap in the pool.
    function testGasOneCycleEachShape() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        if (!_metricLive(METRIC_TSLA)) return;
        string[5] memory names = [
            "v4, with the unit",
            "v4 then v4",
            "Metric alone, with the unit",
            "Metric then v4, reordered",
            "v4 then Metric"
        ];
        uint256[2][5] memory venues =
            [[V4, V4], [V4, V4], [METRIC, V4], [METRIC, V4], [V4, METRIC]];
        for (uint256 shape; shape < 5; shape++) {
            uint256 snapshot = vm.snapshotState();
            (kinds[NVDA], kinds[TSLA]) = (venues[shape][0], venues[shape][1]);
            bool withUnit = shape == 0 || shape == 2;
            address[] memory list = _three(NVDA, TSLA);
            IndexPool pool =
                _pool(list, _equalWeights(3), 300_000, _indexOf(list, NVDA), 0.03e18);
            uint256 used = _hookCall(pool, NVDA, withUnit ? USDG : TSLA);
            console.log(names[shape], used);
            vm.revertToState(snapshot);
        }
    }

    /// The worst failure: both tokens on Metric and v4, both Metric pools quoting but
    /// refusing to trade, and a minimum profit no cycle reaches, so each Metric venue is
    /// dropped in turn and the v4 ladder of five tries runs to the end.
    function testGasWorstFailure() public onlyFork {
        if (!_metricLive(METRIC_NVDA)) return;
        if (!_metricLive(METRIC_TSLA)) return;
        (kinds[NVDA], kinds[TSLA]) = (BOTH, BOTH);
        minimumProfit = 1e30;
        address[] memory list = _three(NVDA, TSLA);
        IndexPool pool = _pool(list, _equalWeights(3), 300_000, _indexOf(list, NVDA), 0.03e18);
        vm.mockCallRevert(METRIC_NVDA, abi.encodeWithSelector(IMetricPool.swap.selector), "no");
        vm.mockCallRevert(METRIC_TSLA, abi.encodeWithSelector(IMetricPool.swap.selector), "no");
        uint256 used = _hookCall(pool, NVDA, TSLA);
        console.log("worst failure, with both Metric venues dropped", used);
        uint256 hookGas = (used * 125 / 100 + 99_999) / 100_000 * 100_000;
        console.log("recommended hookGas (worst plus 25%, rounded up)", hookGas);
        console.log("least gas a swap must carry", 2 * hookGas * 64 / 63 + 470_000);
        assertLt(2 * hookGas * 64 / 63 + 470_000, 32_000_000, "fits the chain's 32M");
    }
}
