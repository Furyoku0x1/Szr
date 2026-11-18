// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { MetricVault } from "../src/vaults/MetricVault.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IMarketController } from "../src/interfaces/IMarketController.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { MockLiquidityPool } from "./utils/metric/MockLiquidityPool.sol";

/// @dev A Metric vault under a real controller.
contract MarketControllerMetricTest is MarketsWorld {
    /// The controller asks a vault for its market, so a Metric vault must answer it.
    function testAMetricVaultCanBeAddedToTheController() public {
        MarketController controller = MarketController(
            deployCode(
                "MarketController.sol:MarketController",
                abi.encode(hook, id, team, address(this))
            )
        );
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        controller.initialize();
        MockMetricFactory metric = new MockMetricFactory();
        (address low, address high) = address(backing) < address(coin)
            ? (address(backing), address(coin))
            : (address(coin), address(backing));
        uint256[4] memory none;
        MockLiquidityPool pool = new MockLiquidityPool(low, high, 1, 1000, 1e9, none);
        metric.register(address(pool));
        MetricVault vault = new MetricVault(
            IMetricFactory(address(metric)),
            address(pool),
            IMarketController(address(controller)),
            1_000,
            team
        );
        assertEq(vault.market(), id);
        vm.prank(team);
        controller.addVault(address(vault), 4_000);
        assertTrue(controller.isVault(address(vault)));
        assertEq(controller.weights(address(vault)), 4_000);
    }
}
