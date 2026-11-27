// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { DeployIndexPositions } from "../script/DeployIndexPositions.s.sol";
import { IndexLiquidityExtension } from "../src/extensions/IndexLiquidityExtension.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";

contract DeployIndexLiquidityExtensionScriptTest is MarketsWorld {
    function test_deploysPositionsAndTheExtension() public {
        MockMetricFactory metric = new MockMetricFactory();
        IndexPoolFactory indexFactory = _indexFactory();
        // From the artifact, so this test does not carry both contracts' creation code.
        DeployIndexPositions script =
            DeployIndexPositions(deployCode("DeployIndexPositions.s.sol:DeployIndexPositions"));
        (IndexPositions positions, IndexLiquidityExtension extension) = script.run(
            DeployIndexPositions.Config(
                locker, address(hook), IMetricFactory(address(metric)), indexFactory
            )
        );
        assertEq(address(positions.poolManager()), address(manager));
        assertEq(positions.indexFactory(), address(indexFactory));
        assertEq(address(extension.liquidity()), address(locker));
        assertEq(extension.hook(), address(hook));
        assertEq(address(extension.factory()), address(metric));
        assertEq(address(extension.positions()), address(positions));
        assertEq(address(extension.indexFactory()), address(indexFactory));
    }

    function test_revertsWithoutCodeAtAnAddress() public {
        DeployIndexPositions script =
            DeployIndexPositions(deployCode("DeployIndexPositions.s.sol:DeployIndexPositions"));
        IMetricFactory metric = IMetricFactory(address(new MockMetricFactory()));
        vm.expectRevert(DeployIndexPositions.MissingIndexFactory.selector);
        script.run(
            DeployIndexPositions.Config(
                locker, address(hook), metric, IndexPoolFactory(address(0xdead))
            )
        );
    }

    function _indexFactory() internal returns (IndexPoolFactory) {
        return IndexPoolFactory(
            deployCode("IndexPoolFactory.sol:IndexPoolFactory", abi.encode(locker, desk))
        );
    }
}
