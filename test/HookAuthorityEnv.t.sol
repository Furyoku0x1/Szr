// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { HookAuthority } from "../src/HookAuthority.sol";
import { DeployHookAuthority } from "../script/DeployHookAuthority.s.sol";

/// @dev Forge loads `.env` into every script, and there `MANAGER`, `WETH` and `POOL_MANAGER`
/// already mean Robinhood Chain's. `DeployHookAuthority` reads only `AUTHORITY_*` names, so a
/// stale one cannot become a new chain's manager.
contract HookAuthorityEnvTest is Test {
    function testTheDeployScriptReadsOnlyItsOwnNames() public {
        address pool = address(new WrappingAsset());
        address weth = address(new WrappingAsset());
        address stalePool = address(new WrappingAsset());
        address staleWeth = address(new WrappingAsset());
        vm.setEnv("EXPECTED_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("MANAGER", vm.toString(address(0xBAD1)));
        vm.setEnv("WETH", vm.toString(staleWeth));
        vm.setEnv("POOL_MANAGER", vm.toString(stalePool));
        vm.setEnv("AUTHORITY_MANAGER", vm.toString(address(0xA7)));
        vm.setEnv("AUTHORITY_WETH", vm.toString(weth));
        vm.setEnv("AUTHORITY_POOL_MANAGER", vm.toString(pool));
        HookAuthority made = new DeployHookAuthority().run();
        assertEq(made.manager(), address(0xA7), "the manager is AUTHORITY_MANAGER");
        assertEq(made.backingAsset(), weth, "WETH is AUTHORITY_WETH");
        assertEq(made.poolManager(), pool, "the pool manager is AUTHORITY_POOL_MANAGER");
        vm.setEnv("MANAGER", "");
        vm.setEnv("WETH", "");
        vm.setEnv("POOL_MANAGER", "");
        vm.setEnv("AUTHORITY_MANAGER", "");
        vm.setEnv("AUTHORITY_WETH", "");
        vm.setEnv("AUTHORITY_POOL_MANAGER", "");
    }
}
