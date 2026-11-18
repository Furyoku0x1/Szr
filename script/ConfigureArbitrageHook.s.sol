// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { Liquidity } from "../src/Liquidity.sol";

/// @notice The manager's setup steps for the arbitrage hook in one run: raise the gas
/// allowance, set the connecting pools, track the pools, then name each group's leaders.
/// Transactions are sent as Liquidity's manager, so the signer supplied to `forge script`
/// must be that address.
/// @dev Running it again is harmless: pools already tracked are skipped, and leaders are
/// simply set to the same lists.
contract ConfigureArbitrageHook is Script {
    using PoolIdLibrary for PoolKey;

    struct Config {
        ArbitrageApi hook;
        /// Zero leaves the hook's limits as they are.
        uint32 gasLimit;
        /// Connecting pools, each already registered with `Liquidity.registerRoute`.
        PoolKey[] connectors;
        /// Liquidity position ids whose pools should be tracked. Fund a pool before
        /// tracking it.
        uint256[] positions;
        /// The leaders of each partner token's group, deepest pool first.
        Group[] groups;
        /// Tokens to approve as profit tokens, other than WETH and native ETH.
        address[] profitTokens;
        /// Receives the protocol's share of each of `profitTokens`.
        address treasury;
    }

    struct Group {
        address partner;
        /// Liquidity position ids of the group's leaders, deepest first.
        uint256[] positions;
    }

    error MissingHook();
    error MismatchedConnectors();
    error MissingTreasury();
    error TreasuryIsHook();
    error ProfitTokenRefused(address token);

    function run() external {
        run(_readConfig());
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config) public {
        if (address(config.hook).code.length == 0) revert MissingHook();
        _checkProfitTokens(config);
        Liquidity liquidity = config.hook.liquidity();
        vm.startBroadcast(liquidity.manager());
        // The allowance has to cover the leaders set below, so it goes up before they are.
        address token = config.hook.token();
        if (config.gasLimit != 0) {
            config.hook
                .setLimits(
                    1,
                    token,
                    config.gasLimit,
                    config.hook.minimumProfit(1, token),
                    config.hook.market(1).minimumEdge
                );
        }
        for (uint256 index; index < config.connectors.length; index++) {
            config.hook.setConnector(1, config.connectors[index], true);
        }
        for (uint256 index; index < config.positions.length; index++) {
            bytes32 poolId = PoolId.unwrap(liquidity.key(config.positions[index]).toId());
            if (config.hook.partnerOf(poolId) != address(0)) continue;
            config.hook.track(config.positions[index]);
        }
        for (uint256 index; index < config.groups.length; index++) {
            Group memory group = config.groups[index];
            bytes32[] memory poolIds = new bytes32[](group.positions.length);
            for (uint256 place; place < poolIds.length; place++) {
                poolIds[place] = PoolId.unwrap(liquidity.key(group.positions[place]).toId());
            }
            config.hook.setLeaders(1, token, group.partner, poolIds);
        }
        _approveProfitTokens(config);
        vm.stopBroadcast();
        console2.log("TRACKED_POOLS", config.hook.market(1).poolCount);
        console2.log("GROUPS", config.hook.groupsOf(1, token).length);
        console2.log("GAS_LIMIT", config.hook.market(1).gasLimit);
        console2.log("MINIMUM_GAS_LIMIT", config.hook.minimumGasLimit(1));
    }

    /// @dev Checked before anything is sent, so a bad list changes nothing.
    function _checkProfitTokens(Config memory config) internal view {
        if (config.profitTokens.length == 0) return;
        if (config.treasury == address(0)) revert MissingTreasury();
        if (config.treasury == address(config.hook)) revert TreasuryIsHook();
        for (uint256 index; index < config.profitTokens.length; index++) {
            address asset = config.profitTokens[index];
            if (asset == address(0)) revert ProfitTokenRefused(asset);
            if (asset == config.hook.backingAsset()) revert ProfitTokenRefused(asset);
            if (asset == config.hook.token()) revert ProfitTokenRefused(asset);
        }
    }

    /// @dev Native ETH's share goes to Core, which counts it as WETH. The listed tokens go to
    /// the treasury. Calls that would change nothing are skipped so the script can be re-run.
    /// Tokens approved earlier but absent from the list keep their old recipient, so rotating
    /// the treasury means listing every token again.
    function _approveProfitTokens(Config memory config) internal {
        if (config.hook.shareRecipient(address(0)) != address(config.hook.core())) {
            config.hook.setProfitToken(address(0), address(config.hook.core()));
        }
        for (uint256 index; index < config.profitTokens.length; index++) {
            address asset = config.profitTokens[index];
            if (config.hook.shareRecipient(asset) == config.treasury) continue;
            config.hook.setProfitToken(asset, config.treasury);
        }
    }

    /// @dev Connecting pools are given as five parallel lists, one entry per pool. One
    /// group's leaders can be given per run, as its partner token and its position ids.
    function _readConfig() internal view returns (Config memory config) {
        config.hook = ArbitrageApi(payable(vm.envAddress("ARBITRAGE_HOOK")));
        address partner = vm.envOr("LEADER_PARTNER", address(0));
        if (partner != address(0)) {
            config.groups = new Group[](1);
            config.groups[0] = Group(partner, vm.envUint("LEADER_POSITIONS", ","));
        }
        config.profitTokens = vm.envOr("PROFIT_TOKENS", ",", new address[](0));
        config.treasury = vm.envOr("TREASURY", address(0));
        config.gasLimit = uint32(vm.envOr("HOOK_GAS_LIMIT", uint256(0)));
        config.positions = vm.envOr("TRACK_POSITIONS", ",", new uint256[](0));
        address[] memory token0 = vm.envOr("CONNECTOR_TOKEN0", ",", new address[](0));
        address[] memory token1 = vm.envOr("CONNECTOR_TOKEN1", ",", new address[](0));
        uint256[] memory fee = vm.envOr("CONNECTOR_FEE", ",", new uint256[](0));
        uint256[] memory spacing = vm.envOr("CONNECTOR_TICK_SPACING", ",", new uint256[](0));
        address[] memory hooks = vm.envOr("CONNECTOR_HOOKS", ",", new address[](0));
        if (token1.length != token0.length) revert MismatchedConnectors();
        if (fee.length != token0.length) revert MismatchedConnectors();
        if (spacing.length != token0.length) revert MismatchedConnectors();
        if (hooks.length != token0.length) revert MismatchedConnectors();
        config.connectors = new PoolKey[](token0.length);
        for (uint256 index; index < token0.length; index++) {
            config.connectors[index] = PoolKey(
                Currency.wrap(token0[index]),
                Currency.wrap(token1[index]),
                uint24(fee[index]),
                int24(int256(spacing[index])),
                IHooks(hooks[index])
            );
        }
    }
}
