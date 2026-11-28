// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { HookAuthority } from "../src/HookAuthority.sol";

/// @notice Deploys the `HookAuthority` the arbitrage hook runs against on a chain where SZR is
/// not launched (docs/specs/hook-authority.md). Its variables start with `AUTHORITY_` because
/// forge loads `.env` into every script, and `MANAGER`, `WETH` and `POOL_MANAGER` already
/// mean Robinhood Chain's there. Pass the printed `HOOK_AUTHORITY` to
/// `DeployArbitrageHook` as `LIQUIDITY`.
contract DeployHookAuthority is Script {
    error WrongChain();
    error MissingPoolManager();
    error MissingWeth();
    error WethDoesNotWrap();

    function run() external returns (HookAuthority authority) {
        return run(
            vm.envUint("EXPECTED_CHAIN_ID"),
            vm.envAddress("AUTHORITY_POOL_MANAGER"),
            vm.envAddress("AUTHORITY_WETH"),
            vm.envAddress("AUTHORITY_MANAGER")
        );
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(uint256 chainId, address poolManager, address weth, address manager)
        public
        returns (HookAuthority authority)
    {
        if (block.chainid != chainId) revert WrongChain();
        if (poolManager.code.length == 0) revert MissingPoolManager();
        if (weth.code.length == 0) revert MissingWeth();
        // The hook pays ETH profit as WETH, so WETH has to wrap. A deposit of nothing shows it
        // does, before anything is sent.
        (bool wraps,) = weth.call{ value: 0 }(abi.encodeWithSignature("deposit()"));
        if (!wraps) revert WethDoesNotWrap();
        vm.broadcast();
        authority = new HookAuthority(poolManager, weth, manager);
        console2.log("HOOK_AUTHORITY", address(authority));
    }
}
