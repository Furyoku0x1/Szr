// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { IndexLiquidityExtension } from "../src/extensions/IndexLiquidityExtension.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";

/// @notice Deploys `IndexPositions` on Liquidity's pool manager and the index factory, and
/// the protocol's `IndexLiquidityExtension` that owns positions in it.
/// @dev Next, as Liquidity's manager and in separate transactions: `announceDestination` for
/// the extension, wait out the delay, then `sendFunding`. The script does neither.
/// @dev The broadcaster is whoever signs the `forge script` run; it has no special role.
contract DeployIndexPositions is Script {
    /// @dev Metric's factory on Robinhood Chain, as the fork tests use it.
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;

    struct Config {
        Liquidity liquidity;
        address hook;
        IMetricFactory metricFactory;
        IndexPoolFactory indexFactory;
    }

    error MissingLiquidity();
    error MissingHook();
    error MissingMetricFactory();
    error MissingIndexFactory();

    function run()
        external
        returns (IndexPositions positions, IndexLiquidityExtension extension)
    {
        return run(
            Config(
                Liquidity(vm.envAddress("LIQUIDITY")),
                vm.envAddress("ARBITRAGE_HOOK"),
                IMetricFactory(vm.envOr("METRIC_FACTORY", METRIC_FACTORY)),
                IndexPoolFactory(vm.envAddress("INDEX_FACTORY"))
            )
        );
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config)
        public
        returns (IndexPositions positions, IndexLiquidityExtension extension)
    {
        if (address(config.liquidity).code.length == 0) revert MissingLiquidity();
        if (config.hook.code.length == 0) revert MissingHook();
        if (address(config.metricFactory).code.length == 0) revert MissingMetricFactory();
        if (address(config.indexFactory).code.length == 0) revert MissingIndexFactory();
        vm.startBroadcast();
        positions =
            new IndexPositions(config.liquidity.poolManager(), address(config.indexFactory));
        extension = new IndexLiquidityExtension(
            config.liquidity, config.hook, config.metricFactory, positions, config.indexFactory
        );
        vm.stopBroadcast();
        console2.log("INDEX_POSITIONS", address(positions));
        console2.log("INDEX_LIQUIDITY_EXTENSION", address(extension));
        console2.log(
            "Next, as manager: announceDestination for the extension, then sendFunding."
        );
    }
}
