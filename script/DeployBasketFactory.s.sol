// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Basket } from "../src/basket/Basket.sol";
import { BasketFactory } from "../src/basket/BasketFactory.sol";

/// @notice Deploys the basket factory and nothing else.
/// @dev `PROTOCOL` is the v4 liquidity extension that receives every basket's cut. Baskets
/// themselves are created later through `create`, by anyone.
/// @dev The broadcaster is whoever signs the `forge script` run; it has no special role.
contract DeployBasketFactory is Script {
    struct Config {
        IPoolManager poolManager;
        address arbitrageHook;
        address protocol;
    }

    error MissingPoolManager();
    error MissingHook();
    error MissingProtocol();

    function run() external returns (BasketFactory factory) {
        return run(
            Config(
                IPoolManager(vm.envAddress("POOL_MANAGER")),
                vm.envOr("ARBITRAGE_HOOK", address(0)),
                vm.envAddress("PROTOCOL")
            )
        );
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config) public returns (BasketFactory factory) {
        if (address(config.poolManager).code.length == 0) revert MissingPoolManager();
        // Zero is allowed and means baskets may hold hookless pools only.
        if (config.arbitrageHook != address(0)) {
            if (config.arbitrageHook.code.length == 0) revert MissingHook();
        }
        if (config.protocol.code.length == 0) revert MissingProtocol();
        vm.startBroadcast();
        factory = new BasketFactory(
            config.poolManager, config.arbitrageHook, config.protocol, type(Basket).creationCode
        );
        vm.stopBroadcast();
        console2.log("BASKET_FACTORY", address(factory));
        console2.logBytes32(factory.codeHash());
    }
}
