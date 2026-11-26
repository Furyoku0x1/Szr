// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexBalancerState } from "../../src/index/IndexBalancerState.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "../../src/interfaces/metric/IMetricPool.sol";
import { IndexBalancerForkBase } from "./IndexBalancerForkBase.sol";

/// @dev The review's H-2 attack on the live NVDA Metric pool: a dust swap on Metric and,
/// inside its callback, a swap in an index pool that lists it. Records the revert data a
/// price read gets inside the callback and after the feed has gone stale.
contract MetricCallbackSwapper is IMetricSwapCallback {
    address public pool;
    bytes public call;
    bool public ok;
    bytes public result;
    bytes public readFailure;
    uint256 public readGas;

    function arm(address pool_, bytes calldata call_) external {
        (pool, call) = (pool_, call_);
    }

    function attack(address metric, bool zeroForOne, uint256 amount) external {
        IMetricPool(metric)
            .swap(
                address(this),
                zeroForOne,
                int128(uint128(amount)),
                zeroForOne ? 0 : type(uint128).max,
                "",
                ""
            );
    }

    function metricOmmSwapCallback(int256 amount0, int256 amount1, bytes calldata) external {
        uint256 before = gasleft();
        try IMetricPool(msg.sender).getSellAndBuyPrices() { }
        catch (bytes memory reason) {
            readFailure = reason;
        }
        readGas = before - gasleft();
        (ok, result) = pool.call(call);
        MetricImmutables memory imm = IMetricPool(msg.sender).getImmutables();
        if (amount0 > 0) IERC20(imm.token0).transfer(msg.sender, uint256(amount0));
        if (amount1 > 0) IERC20(imm.token1).transfer(msg.sender, uint256(amount1));
    }
}

contract IndexBalancerReviewForkTest is IndexBalancerForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant METRIC_NVDA = 0xBc6426CdBCE142dfbff33303dc0923509f61eedc;
    bool internal onMetric;

    function _routesFor(address token)
        internal
        view
        override
        returns (IndexBalancerState.Route[] memory routes)
    {
        if (!onMetric) return super._routesFor(token);
        routes = new IndexBalancerState.Route[](1);
        (routes[0].metric, routes[0].pool) = (true, METRIC_NVDA);
    }

    function _live() internal returns (bool) {
        try IMetricPool(METRIC_NVDA).getSellAndBuyPrices() returns (uint128, uint128) {
            return true;
        } catch {
            console.log("NVDA Metric feed is down: skipped");
            return false;
        }
    }

    function _nvdaPool() internal returns (IndexPool pool) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = (USDG, NVDA);
        pool = _pool(list, _equalWeights(2), 200_000, 1, 0.02e18);
    }

    /// The review's proof of concept, now refused; and the revert a read gets inside the
    /// callback, which is what the balancer reads as "locked".
    function testSwapInsideTheMetricCallbackIsBlocked() public onlyFork {
        if (!_live()) return;
        onMetric = true;
        IndexPool pool = _nvdaPool();
        MetricCallbackSwapper attacker = new MetricCallbackSwapper();
        deal(USDG, address(attacker), 10_000e6);
        vm.prank(address(attacker));
        IERC20(USDG).approve(address(pool), FAR);
        attacker.arm(
            address(pool),
            abi.encodeCall(
                IndexPool.swap, (USDG, NVDA, 2000e6, true, 0, address(attacker), FAR)
            )
        );
        MetricImmutables memory imm = IMetricPool(METRIC_NVDA).getImmutables();
        attacker.attack(METRIC_NVDA, imm.token0 == USDG, 10e6);
        console.log("price read inside the callback: revert data, gas");
        console.logBytes(attacker.readFailure());
        console.log(attacker.readGas());
        assertEq(
            bytes4(attacker.readFailure()), bytes4(0x3ee5aeb5), "ReentrancyGuardReentrantCall"
        );
        assertFalse(attacker.ok(), "the swap was refused");
        assertEq(bytes4(attacker.result()), IndexPool.HookBlocked.selector, "blocked");
    }

    /// A stalled feed: the revert a read gets once the oracle is a day old, and that a swap
    /// with that pool as a venue is not blocked.
    function testStalledFeedDoesNotBlock() public onlyFork {
        if (!_live()) return;
        onMetric = true;
        IndexPool pool = _nvdaPool();
        vm.warp(block.timestamp + 2 days);
        try IMetricPool(METRIC_NVDA).getSellAndBuyPrices() {
            console.log("the feed did not go stale");
        } catch (bytes memory reason) {
            console.log("stalled read: revert data");
            console.logBytes(reason);
        }
        deal(USDG, address(this), 1e12);
        IERC20(USDG).approve(address(pool), FAR);
        (, uint256 out) = pool.swap(USDG, NVDA, 1000e6, true, 0, address(this), FAR);
        assertGt(out, 0, "the swap goes on");
    }

    /// L-4 on the live NVDA v4 pool (tick spacing 60): dust positions across the path of a
    /// 20% gap's cycle, and the gas of one try and of a whole failing call.
    function testDustOnTheRealVenue() public onlyFork {
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(MANAGER);
        deal(NVDA, address(this), 1e24);
        deal(USDG, address(this), 1e13);
        IERC20(NVDA).approve(address(provider), FAR);
        IERC20(USDG).approve(address(provider), FAR);
        uint256[3] memory counts = [uint256(0), 10, 30];
        console.log("ticks in the path, one try (gas), whole failing call (gas)");
        for (uint256 run; run < 3; run++) {
            uint256 snapshot = vm.snapshotState();
            (, int24 tick,,) = MANAGER.getSlot0(venueOf[NVDA].toId());
            _dust(provider, tick, counts[run]);
            IndexPool pool = _nvdaPool20();
            uint256 before = gasleft();
            balancer.balance(address(pool), NVDA, USDG);
            uint256 one = before - gasleft();
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();
            _dust(provider, tick, counts[run]);
            minimumProfit = 1e30;
            pool = _nvdaPool20();
            before = gasleft();
            balancer.balance(address(pool), NVDA, USDG);
            console.log(counts[run], one, before - gasleft());
            minimumProfit = 0;
            vm.revertToState(snapshot);
        }
    }

    function _nvdaPool20() internal returns (IndexPool) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = (USDG, NVDA);
        return _pool(list, _equalWeights(2), 200_000, 1, 0.2e18);
    }

    /// `count` one-spacing dust positions just past the price, on the side a cycle selling
    /// NVDA there moves it: NVDA is token1, so its price in v4 terms rises.
    function _dust(PoolModifyLiquidityTest provider, int24 tick, uint256 count) internal {
        int24 base = (tick / 60) * 60 + 60;
        for (uint256 index; index < count / 2; index++) {
            int24 lower = base + int24(int256(index * 120));
            provider.modifyLiquidity(
                venueOf[NVDA], IPoolManager.ModifyLiquidityParams(lower, lower + 60, 1e9, 0), ""
            );
        }
    }
}
