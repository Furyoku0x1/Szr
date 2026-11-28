// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";

/// @dev Production factories are created by `SzrTreasury`, whose constructor makes one that
/// pays its cut to the treasury. A factory from this script pays whatever `protocol` it is
/// given, and the treasury cannot route through its pools.
/// @notice Deploys the index pool factory, and nothing else. Pools are created later through
/// `create`, by anyone; hooks are approved later by Liquidity's manager.
/// @dev `LIQUIDITY` is the Liquidity whose manager runs the hook list. `PROTOCOL` receives
/// every pool's cut. The broadcaster has no special role.
contract DeployIndexPoolFactory is Script {
    error MissingLiquidity();
    error MissingProtocol();

    function run() external returns (IndexPoolFactory factory) {
        return run(ISzrLiquidity(vm.envAddress("LIQUIDITY")), vm.envAddress("PROTOCOL"));
    }

    /// @notice Typed inputs let rehearsals run without shared environment-variable state.
    function run(ISzrLiquidity liquidity, address protocol)
        public
        returns (IndexPoolFactory factory)
    {
        if (address(liquidity).code.length == 0) revert MissingLiquidity();
        // A manager that cannot be read would leave the hook list stuck forever.
        if (liquidity.manager() == address(0)) revert MissingLiquidity();
        if (protocol == address(0)) revert MissingProtocol();
        vm.startBroadcast();
        factory = new IndexPoolFactory(liquidity, protocol);
        vm.stopBroadcast();
        console2.log("INDEX_POOL_FACTORY", address(factory));
        console2.logBytes32(address(factory).codehash);
    }
}
