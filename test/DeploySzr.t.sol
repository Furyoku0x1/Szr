// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { DeploySzr } from "../script/DeploySzr.s.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { Liquidity } from "../src/Liquidity.sol";

contract DeploySzrTest is Test {
    function testDeploymentBindsModulesWithoutReleasingOrSeedingTokens() public {
        TestAsset weth = new TestAsset();
        address poolManager =
            deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        vm.setEnv("MIGRATION_ALLOCATION", "0");
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("WETH", vm.toString(address(weth)));
        vm.setEnv("POOL_MANAGER", vm.toString(poolManager));
        vm.setEnv("TEAM_BENEFICIARY", vm.toString(address(this)));
        vm.setEnv("BOOTSTRAP_NAV", "1000000000000");
        vm.setEnv("INITIAL_MARKET_PRICE", "4000000000000");
        DeploySzr deployment = new DeploySzr();
        (SzrCore core, FeeCollector jar, Liquidity locker) = deployment.run();
        assertEq(core.token().totalSupply(), 1_000_000_000e18);
        assertEq(core.liquidity(), address(locker));
        assertEq(core.feeJar(), address(jar));
        assertEq(address(jar.core()), address(core));
        assertEq(address(locker.core()), address(core));
        assertEq(address(locker.poolManager()), poolManager);
        assertEq(locker.manager(), core.initializer());
        assertEq(core.economics().beneficiary(), address(this));
        assertTrue(core.launched());
        assertTrue(locker.started());
        assertEq(core.auctionsOpenAt(), core.startedAt()); // no migration configured
        assertEq(core.availableRelease(), 0);
        assertEq(core.activeSupply(), 0);
        assertEq(core.reserveCash(), 0);
        assertEq(core.token().balanceOf(address(core)), 1_000_000_000e18);
        assertEq(core.token().balanceOf(address(core)), core.unreleasedSupply());
        assertEq(core.publicInventory(), core.unreleasedSupply());
        assertEq(core.publicInventory(), 1_000_000_000e18);
        assertEq(locker.liquidityHeld(0), 0);
        assertEq(core.token().balanceOf(address(locker)), 0);
        assertEq(locker.heldPrincipal(address(core.token())), 0);
        assertEq(locker.position(0).partner, address(weth));
        assertEq(locker.key(0).fee, 10_000); // the main pool charges 1%
        assertEq(locker.key(0).tickSpacing, 200);
        assertEq(locker.poolCount(), 1);
        assertEq(core.releaseRatePerDay(), 1_000_000e18);
        vm.prank(core.initializer());
        vm.expectRevert(SzrCore.AlreadyLaunched.selector);
        core.launch();
    }
}
