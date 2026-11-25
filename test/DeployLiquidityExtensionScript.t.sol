// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { DeployLiquidityExtensions } from "../script/DeployLiquidityExtensions.s.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";

contract DeployLiquidityExtensionScriptTest is MarketsWorld {
    function test_deploysBothExtensionsWithTheGivenAddresses() public {
        MockMetricFactory factory = new MockMetricFactory();
        DeployLiquidityExtensions script = new DeployLiquidityExtensions();
        (V4LiquidityExtension v4, MetricLiquidityExtension metric) = script.run(
            DeployLiquidityExtensions.Config(
                locker, address(hook), IMetricFactory(address(factory))
            )
        );
        assertEq(address(v4.liquidity()), address(locker));
        assertEq(v4.hook(), address(hook));
        assertEq(address(metric.liquidity()), address(locker));
        assertEq(metric.hook(), address(hook));
        assertEq(address(metric.factory()), address(factory));
        assertEq(address(v4.factory()), address(factory));
    }

    function test_revertsWithoutCodeAtAnAddress() public {
        DeployLiquidityExtensions script = new DeployLiquidityExtensions();
        IMetricFactory none = IMetricFactory(address(0xdead));
        vm.expectRevert(DeployLiquidityExtensions.MissingMetricFactory.selector);
        script.run(DeployLiquidityExtensions.Config(locker, address(hook), none));
    }
}
