// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { DeployIndexBalancer } from "../script/DeployIndexBalancer.s.sol";
import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IndexBalancer } from "../src/index/IndexBalancer.sol";
import { IndexSettings } from "../src/index/IndexSettings.sol";
import { IndexMetric } from "../src/index/IndexMetric.sol";
import { IndexSizer } from "../src/index/IndexSizer.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexManager } from "./utils/IndexWorld.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";

/// @dev A rehearsal of the deployment: the balancer and its modules wired to the given
/// addresses, approvable at the printed gas, and refused inputs.
contract DeployIndexBalancerScriptTest is Test {
    IPoolManager internal manager;
    IndexPoolFactory internal factory;
    MockMetricFactory internal metricFactory;
    IndexManager internal liquidity;

    function setUp() public {
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        liquidity = new IndexManager();
        liquidity.setManager(address(this));
        factory = new IndexPoolFactory(ISzrLiquidity(address(liquidity)), makeAddr("protocol"));
        metricFactory = new MockMetricFactory();
    }

    function test_deploysTheBalancerAndItsModules() public {
        DeployIndexBalancer script = new DeployIndexBalancer();
        uint32 gas = script.HOOK_GAS();
        IndexBalancer balancer =
            script.run(manager, factory, IMetricFactory(address(metricFactory)), gas);
        assertEq(address(balancer.poolManager()), address(manager));
        assertEq(address(balancer.factory()), address(factory));
        assertEq(address(balancer.metric().factory()), address(metricFactory));
        assertEq(address(balancer.sizer().poolManager()), address(manager));
        assertGt(balancer.settings().code.length, 0, "settings module");
        // The settings answer at the balancer's own address, on its storage.
        assertEq(IndexSettings(address(balancer)).unitOf(address(1)), address(0));
        // The printed codehashes are reproducible: the same build deployed with the same
        // arguments gives the same code.
        IndexMetric metric = new IndexMetric(IMetricFactory(address(metricFactory)));
        IndexSettings settings = new IndexSettings(manager, factory, balancer.metric());
        assertEq(address(metric).codehash, address(balancer.metric()).codehash, "reader");
        assertEq(address(settings).codehash, balancer.settings().codehash, "settings");
        assertEq(
            address(new IndexSizer(manager)).codehash,
            address(balancer.sizer()).codehash,
            "sizer"
        );
        // What the manager is told to do works.
        factory.setHookApproved(address(balancer), gas);
        assertEq(factory.approvedHookGas(address(balancer)), gas);
    }

    function test_revertsOnMissingInputs() public {
        DeployIndexBalancer script = new DeployIndexBalancer();
        IMetricFactory metric = IMetricFactory(address(metricFactory));
        vm.expectRevert(DeployIndexBalancer.MissingPoolManager.selector);
        script.run(IPoolManager(address(0xdead)), factory, metric, 1);
        vm.expectRevert(DeployIndexBalancer.MissingFactory.selector);
        script.run(manager, IndexPoolFactory(address(0xdead)), metric, 1);
        vm.expectRevert(DeployIndexBalancer.MissingMetricFactory.selector);
        script.run(manager, factory, IMetricFactory(address(0xdead)), 1);
        vm.expectRevert(DeployIndexBalancer.InvalidHookGas.selector);
        script.run(manager, factory, metric, 0);
        vm.expectRevert(DeployIndexBalancer.InvalidHookGas.selector);
        script.run(manager, factory, metric, 8_000_001);
    }
}
