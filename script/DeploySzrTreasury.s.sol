// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { SzrTreasury } from "../src/SzrTreasury.sol";

/// @notice Deploys the SZR treasury. The treasury makes the index pool factory itself, so
/// no separate factory deploy is needed and the factory's protocol is the treasury. The
/// broadcaster has no special role.
/// @dev `CORE` is the Core the treasury donates to and `METRIC_FACTORY` is Metric's pool
/// factory. The pool manager is read from Core's Liquidity, so the treasury and the SZR pool
/// settle at the same one.
contract DeploySzrTreasury is Script {
    error MissingCore();
    error MissingLiquidity();
    error MissingMetricFactory();
    error WrongTokens();

    function run() external returns (SzrTreasury treasury) {
        return
            run(SzrCore(vm.envAddress("CORE")), IMetricFactory(vm.envAddress("METRIC_FACTORY")));
    }

    /// @notice A typed input lets rehearsals run without shared environment-variable state.
    function run(SzrCore core, IMetricFactory metricFactory)
        public
        returns (SzrTreasury treasury)
    {
        if (address(core).code.length == 0) revert MissingCore();
        if (address(metricFactory).code.length == 0) revert MissingMetricFactory();
        address liquidity = core.liquidity();
        // Without Liquidity there is no manager to run the treasury.
        if (liquidity.code.length == 0) revert MissingLiquidity();
        if (Liquidity(liquidity).manager() == address(0)) revert MissingLiquidity();
        vm.startBroadcast();
        treasury = new SzrTreasury(core, Liquidity(liquidity).poolManager(), metricFactory);
        vm.stopBroadcast();
        if (treasury.szr() != address(core.token())) revert WrongTokens();
        if (treasury.weth() != core.backingAsset()) revert WrongTokens();
        // The treasury made the factory, so its cut can only go to the treasury.
        if (treasury.indexFactory().protocol() != address(treasury)) revert WrongTokens();
        console2.log("SZR_TREASURY", address(treasury));
        // Point the balancer and positions scripts at this factory.
        console2.log("INDEX_POOL_FACTORY", address(treasury.indexFactory()));
        console2.logBytes32(address(treasury).codehash);
    }
}
