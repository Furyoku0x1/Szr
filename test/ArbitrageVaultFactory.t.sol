// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { FactoryDeploy } from "./utils/FactoryDeploy.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { MockLiquidityPool } from "./utils/metric/MockLiquidityPool.sol";
import { ArbitrageVaultFactory } from "../src/factories/ArbitrageVaultFactory.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { MetricVault } from "../src/vaults/MetricVault.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Who may create what, what the registry lists, and that the vaults it deploys are
/// the real ones.
contract ArbitrageVaultFactoryTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;

    ArbitrageVaultFactory internal factory;
    address internal curator = address(0xC0A7);
    address internal stranger = address(0x57A9);
    MockMetricFactory internal metricFactory;
    MockLiquidityPool internal metricPool;
    address internal token0;
    address internal token1;

    function setUp() public override {
        super.setUp();
        metricFactory = new MockMetricFactory();
        factory = FactoryDeploy.build(hook, address(metricFactory));
        token0 = address(backing) < address(coin) ? address(backing) : address(coin);
        token1 = address(backing) < address(coin) ? address(coin) : address(backing);
        uint256[4] memory none;
        metricPool = new MockLiquidityPool(token0, token1, 1, 1000, 1e9, none);
        metricFactory.register(address(metricPool));
    }

    function _controller() internal returns (address made) {
        vm.prank(team);
        made = factory.createController(id, curator);
    }

    function testOnlyTheMarketsOwnerCreatesAController() public {
        vm.prank(stranger);
        vm.expectRevert(ArbitrageVaultFactory.NotMarketOwner.selector);
        factory.createController(id, stranger);
        address made = _controller();
        assertTrue(factory.isController(made));
        assertEq(factory.controllerCount(), 1);
        assertEq(factory.controllers(0), made);
        assertEq(MarketController(made).curator(), curator);
        assertEq(MarketController(made).market(), id);
        assertEq(MarketController(made).factory(), address(factory));
    }

    function testAControllerIsCreatedOncePerMarketAndCurator() public {
        _controller();
        vm.prank(team);
        uint256 before = gasleft();
        vm.expectRevert(ArbitrageVaultFactory.ControllerExists.selector);
        factory.createController(id, curator);
        assertLt(before - gasleft(), 100_000, "refused before any code is deployed");
        vm.prank(team);
        factory.createController(id, team);
        assertEq(factory.controllerCount(), 2);
    }

    function testOnlyTheCuratorCreatesVaultsUnderAController() public {
        address made = _controller();
        vm.prank(team);
        vm.expectRevert(ArbitrageVaultFactory.NotCurator.selector);
        factory.createArbitrageVault(made, first, 1_000);
        vm.prank(stranger);
        vm.expectRevert(ArbitrageVaultFactory.NotCurator.selector);
        factory.createMetricVault(made, address(metricPool), 1_000, stranger);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVaultFactory.UnknownController.selector);
        factory.createArbitrageVault(address(0xBAD), first, 1_000);
    }

    function testArbitrageVaultIsTheRealOneAndListed() public {
        address made = _controller();
        vm.prank(curator);
        address vault = factory.createArbitrageVault(made, first, 1_000);
        ArbitrageVault created = ArbitrageVault(vault);
        assertTrue(factory.isVault(vault));
        assertEq(factory.vaults(0), vault);
        assertEq(created.curator(), curator);
        assertEq(address(created.controller()), made);
        assertEq(created.market(), id);
        assertEq(created.token0(), token0);
        assertEq(created.token1(), token1);
        assertEq(created.homeId(), PoolId.unwrap(first.toId()));
        assertEq(created.feeBps(), 1_000);
        assertEq(created.primaryHook(), address(hook));
        // The vault's own check on the controller's market holds, and so does its fee cap.
        vm.prank(curator);
        vm.expectRevert();
        factory.createArbitrageVault(made, first, 2_001);
    }

    function testMetricVaultWithAndWithoutAController() public {
        address made = _controller();
        vm.prank(curator);
        address tied = factory.createMetricVault(made, address(metricPool), 500, stranger);
        assertEq(address(MetricVault(tied).controller()), made);
        assertEq(MetricVault(tied).curator(), stranger);
        // With none, anyone may, for any curator.
        vm.prank(stranger);
        address loose =
            factory.createMetricVault(address(0), address(metricPool), 500, stranger);
        assertEq(address(MetricVault(loose).controller()), address(0));
        assertEq(MetricVault(loose).primaryHook(), address(metricFactory));
        assertEq(address(MetricVault(loose).pool()), address(metricPool));
        assertEq(factory.vaultCount(), 2);
        assertTrue(factory.isVault(loose));
    }

    function testEventsNameWhatWasMade() public {
        vm.expectEmit(false, true, true, false);
        emit ArbitrageVaultFactory.ControllerCreated(address(0), id, curator);
        address made = _controller();
        vm.expectEmit(false, true, false, false);
        emit ArbitrageVaultFactory.VaultCreated(
            address(0), made, ArbitrageVaultFactory.Kind.Arbitrage, token0, token1, curator
        );
        vm.prank(curator);
        factory.createArbitrageVault(made, first, 1_000);
    }
}
