// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexMetric } from "../src/index/IndexMetric.sol";
import { IndexSettings } from "../src/index/IndexSettings.sol";

/// @notice Deploys the index balancer and its modules: `IndexMetric` and `IndexSettings` first,
/// then the balancer, which deploys `IndexSizer` itself. Prints what Liquidity's manager must
/// then do: approve it on the index pool factory with the measured gas.
/// @dev `POOL_MANAGER`, `INDEX_POOL_FACTORY` and `METRIC_FACTORY` are required. `HOOK_GAS`
/// defaults to the figure the fork tests measured. The broadcaster has no special role.
contract DeployIndexBalancer is Script {
    /// The worst hook call measured on Robinhood Chain, 3,297,047 (both Metric venues
    /// dropped and five v4 tries failing, `test/fork/IndexBalancerMetricFork.t.sol`), plus
    /// 25%, rounded up. A swap must then carry 2 * 4.2M * 64/63 + 470,000 = 9,003,333.
    uint32 public constant HOOK_GAS = 4_200_000;

    error MissingPoolManager();
    error MissingFactory();
    error MissingMetricFactory();
    error InvalidHookGas();

    function run() external returns (IndexBalancer balancer) {
        return run(
            IPoolManager(vm.envAddress("POOL_MANAGER")),
            IndexPoolFactory(vm.envAddress("INDEX_POOL_FACTORY")),
            IMetricFactory(vm.envAddress("METRIC_FACTORY")),
            uint32(vm.envOr("HOOK_GAS", uint256(HOOK_GAS)))
        );
    }

    /// @notice Typed inputs let rehearsals run without shared environment-variable state.
    function run(
        IPoolManager poolManager,
        IndexPoolFactory factory,
        IMetricFactory metricFactory,
        uint32 hookGas
    ) public returns (IndexBalancer balancer) {
        if (address(poolManager).code.length == 0) revert MissingPoolManager();
        if (address(factory).code.length == 0) revert MissingFactory();
        if (address(metricFactory).code.length == 0) revert MissingMetricFactory();
        if (hookGas == 0) revert InvalidHookGas();
        if (hookGas > factory.MAX_HOOK_GAS()) revert InvalidHookGas();
        vm.startBroadcast();
        // The reader and the settings module first: inside the balancer's own creation code
        // they would take it past the 49,152-byte limit.
        IndexMetric metric = new IndexMetric(metricFactory);
        IndexSettings settings = new IndexSettings(poolManager, factory, metric);
        balancer = new IndexBalancer(poolManager, factory, metric, settings);
        vm.stopBroadcast();
        console2.log("INDEX_BALANCER", address(balancer));
        console2.log("INDEX_SIZER", address(balancer.sizer()));
        console2.log("INDEX_METRIC", address(balancer.metric()));
        console2.log("INDEX_SETTINGS", balancer.settings());
        // An approver checks these against their own build deployed with the same arguments.
        // A check inside this script would compare the build with itself, so none is made.
        console2.log("codehashes: balancer, settings, reader, sizer");
        console2.logBytes32(address(balancer).codehash);
        console2.logBytes32(address(settings).codehash);
        console2.logBytes32(address(metric).codehash);
        console2.logBytes32(address(balancer.sizer()).codehash);
        console2.log("Liquidity's manager must now call, on INDEX_POOL_FACTORY:");
        console2.log("  setHookApproved(INDEX_BALANCER, HOOK_GAS) with HOOK_GAS", hookGas);
    }
}
