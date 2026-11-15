// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { DeployArbitrageHook } from "../script/DeployArbitrageHook.s.sol";
import { ConfigureArbitrageHook } from "../script/ConfigureArbitrageHook.s.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The two scripts for the hook: deploying it at an address with the right permission
/// bits, and the manager's setup steps.
contract ArbitrageScriptsTest is ArbitrageWorld {
    /// The deploy script finds a salt that puts the hook at an address with only the two
    /// swap permissions, and that hook then backruns a pool created with it.
    function testScriptDeploysAtASwapHooksOnlyAddress() public {
        // Deployed from its artifact so that this contract does not carry the hook's code.
        DeployArbitrageHook deployment =
            DeployArbitrageHook(deployCode("DeployArbitrageHook.s.sol:DeployArbitrageHook"));
        vm.expectRevert(DeployArbitrageHook.MissingFactory.selector);
        deployment.run(block.chainid, locker);
        // Runtime code of the Safe singleton factory, as deployed on Robinhood Chain.
        vm.etch(
            deployment.FACTORY(),
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0"
            hex"3601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        vm.expectRevert(DeployArbitrageHook.WrongChain.selector);
        deployment.run(block.chainid + 1, locker);
        hook = deployment.run(block.chainid, locker);
        assertEq(uint160(address(hook)) & 0x3FFF, 1 << 7 | 1 << 6, "swap hooks only");
        assertEq(address(hook.liquidity()), address(locker));
        assertEq(address(deployment.run(block.chainid, locker)), address(hook), "idempotent");
        hook.track(0);
        _lead(mainPool);
        _assertSaleBackrun(_addHooked(address(backing), 500));
    }

    /// The setup script does the manager's steps in one run: it raises the allowance, sets
    /// the connecting pool, tracks the pools and names the new group's leader, and running
    /// it again changes nothing.
    function testSetupScriptConfiguresTheHook() public {
        TestAsset eur = new TestAsset();
        _approve(eur);
        backing.mint(address(this), 60_000_000e18);
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(eur);
        config.hooks = IHooks(address(hook));
        uint256 id = locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
        _provide(locker.key(id), 1_000_000e18);
        bool wethFirst = address(backing) < address(eur);
        PoolKey memory route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(eur)),
            Currency.wrap(wethFirst ? address(eur) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 50_000_000e18);
        locker.registerRoute(route);
        ConfigureArbitrageHook setup = new ConfigureArbitrageHook();
        ConfigureArbitrageHook.Config memory plan;
        plan.hook = hook;
        plan.gasLimit = 9_000_000;
        plan.connectors = new PoolKey[](1);
        plan.connectors[0] = route;
        plan.positions = new uint256[](3);
        plan.positions[1] = 1;
        plan.positions[2] = id;
        plan.groups = new ConfigureArbitrageHook.Group[](1);
        plan.groups[0].partner = address(eur);
        plan.groups[0].positions = new uint256[](1);
        plan.groups[0].positions[0] = id;
        setup.run(plan);
        assertEq(hook.market(1).gasLimit, 9_000_000);
        assertEq(hook.market(1).poolCount, 3);
        assertEq(hook.partnerOf(_id(locker.key(id))), address(eur));
        assertEq(
            hook.leadersOf(1, address(szr), address(eur))[0],
            _id(locker.key(id)),
            "leads its group"
        );
        setup.run(plan);
        assertEq(hook.market(1).poolCount, 3, "running again changes nothing");
        // The pool it set up is searched like any other.
        uint256 inventory = core.unreleasedSupply();
        _trade(locker.key(id), address(szr), 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "new pool backrun through its route");
    }
}
