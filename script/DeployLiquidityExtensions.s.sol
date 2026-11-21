// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";

/// @notice Deploys the v4 and Metric liquidity extensions and nothing else.
/// @dev Next, as Liquidity's manager and in separate transactions: `announceDestination` for
/// each extension, wait out the delay, then `sendFunding`. The script does neither.
/// @dev The broadcaster is whoever signs the `forge script` run; it has no special role.
contract DeployLiquidityExtensions is Script {
    /// @dev Metric's factory on Robinhood Chain, as the fork tests use it.
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;

    struct Config {
        Liquidity liquidity;
        address hook;
        IMetricFactory metricFactory;
    }

    error MissingLiquidity();
    error MissingHook();
    error MissingMetricFactory();

    function run() external returns (V4LiquidityExtension v4, MetricLiquidityExtension metric) {
        return run(
            Config(
                Liquidity(vm.envAddress("LIQUIDITY")),
                vm.envAddress("ARBITRAGE_HOOK"),
                IMetricFactory(vm.envOr("METRIC_FACTORY", METRIC_FACTORY))
            )
        );
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config)
        public
        returns (V4LiquidityExtension v4, MetricLiquidityExtension metric)
    {
        if (address(config.liquidity).code.length == 0) revert MissingLiquidity();
        if (config.hook.code.length == 0) revert MissingHook();
        if (address(config.metricFactory).code.length == 0) revert MissingMetricFactory();
        vm.startBroadcast();
        v4 = new V4LiquidityExtension(config.liquidity, config.hook);
        metric =
            new MetricLiquidityExtension(config.liquidity, config.hook, config.metricFactory);
        vm.stopBroadcast();
        console2.log("V4_LIQUIDITY_EXTENSION", address(v4));
        console2.log("METRIC_LIQUIDITY_EXTENSION", address(metric));
        console2.log("Next, as manager: announceDestination for each, then sendFunding.");
    }
}
