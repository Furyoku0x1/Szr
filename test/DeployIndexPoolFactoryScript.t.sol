// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { DeployIndexPoolFactory } from "../script/DeployIndexPoolFactory.s.sol";
import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexManager } from "./utils/IndexWorld.sol";

contract DeployIndexPoolFactoryScriptTest is Test {
    function test_deploysTheFactoryWithTheGivenAddresses() public {
        IndexManager liquidity = new IndexManager();
        liquidity.setManager(address(this));
        address protocol = makeAddr("protocol");
        DeployIndexPoolFactory script = new DeployIndexPoolFactory();
        IndexPoolFactory factory = script.run(ISzrLiquidity(address(liquidity)), protocol);
        assertEq(address(factory.liquidity()), address(liquidity));
        assertEq(factory.protocol(), protocol);
        assertFalse(factory.openHooks());
        factory.setOpenHooks(true);
        assertTrue(factory.openHooks());
    }

    function test_revertsWithoutLiquidityOrProtocol() public {
        DeployIndexPoolFactory script = new DeployIndexPoolFactory();
        IndexManager liquidity = new IndexManager();
        vm.expectRevert(DeployIndexPoolFactory.MissingLiquidity.selector);
        script.run(ISzrLiquidity(address(0xdead)), address(1));
        // A Liquidity whose manager reads as zero would leave the hook list stuck.
        vm.expectRevert(DeployIndexPoolFactory.MissingLiquidity.selector);
        script.run(ISzrLiquidity(address(liquidity)), address(1));
        liquidity.setManager(address(this));
        vm.expectRevert(DeployIndexPoolFactory.MissingProtocol.selector);
        script.run(ISzrLiquidity(address(liquidity)), address(0));
    }
}
