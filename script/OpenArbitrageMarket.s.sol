// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";

/// @notice Sets up a market of one's own in the arbitrage hook in one run: opens it (or
/// uses one already open), creates its pools on the hook, adds public pools to trade
/// against, sets connecting pools, names leaders and switches it on.
/// @dev Transactions are sent by `owner`, which must be the signer given to `forge script`.
/// Fund a new pool before it is traded: the script creates pools but adds no liquidity.
/// @dev Running it again is harmless: pools the market already tracks are skipped, and a
/// market that is switched on stays on throughout.
/// @dev A new market's number is only known once it is opened. Open it in a run of its own
/// (give a recipient and nothing else), then pass the number printed as `MARKET_ID`.
contract OpenArbitrageMarket is Script {
    using PoolIdLibrary for PoolKey;

    /// The leaders among the market's pools that pair `base`, the token profit is counted
    /// in, with `partner`: deepest first, by pool id.
    struct Group {
        address base;
        address partner;
        bytes32[] poolIds;
    }

    /// The smallest profit for cycles counted in `base`, in that token's own units.
    struct Limit {
        address base;
        uint128 profit;
    }

    struct Config {
        ArbitrageApi hook;
        address owner;
        /// Zero opens a new market paying `recipient`.
        uint256 market;
        address recipient;
        /// The tokens profit is counted in, most preferred first. Empty keeps the market's
        /// own, which is just WETH for a new market. Set before the pools are created,
        /// since a pool picks its token when it is tracked.
        address[] tokens;
        /// Pools to create on the hook, each with its starting square-root price.
        PoolKey[] pools;
        uint160[] prices;
        /// Pools that run no hook, to trade against.
        PoolKey[] venues;
        PoolKey[] connectors;
        Group[] groups;
        Limit[] limits;
        /// Zero uses the smallest allowance the market's leaders need.
        uint32 gasLimit;
        /// Zero keeps the market's current smallest gap.
        uint64 edge;
    }

    /// More than the largest set of leaders a market can have needs.
    uint32 internal constant CEILING = 9_000_000;

    error MissingHook();
    error MismatchedLists();
    error ValueTooLarge();

    function run() external returns (uint256) {
        return run(_readConfig());
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config) public returns (uint256 id) {
        if (address(config.hook).code.length == 0) revert MissingHook();
        if (config.prices.length != config.pools.length) revert MismatchedLists();
        vm.startBroadcast(config.owner);
        id = config.market;
        if (id == 0) id = config.hook.openMarket(config.recipient);
        _makeRoom(config, id);
        // A market with several tokens cannot have a zero minimum for any of them, so every
        // minimum is set before the tokens are chosen or the market is switched on.
        for (uint256 index; index < config.limits.length; index++) {
            config.hook
                .setMinimumProfit(id, config.limits[index].base, config.limits[index].profit);
        }
        if (config.tokens.length != 0) config.hook.setTokens(id, config.tokens);
        for (uint256 index; index < config.pools.length; index++) {
            if (_tracked(config, id, config.pools[index])) continue;
            config.hook.createPool(id, config.pools[index], config.prices[index]);
        }
        for (uint256 index; index < config.venues.length; index++) {
            if (_tracked(config, id, config.venues[index])) continue;
            config.hook.addVenue(id, config.venues[index]);
        }
        for (uint256 index; index < config.connectors.length; index++) {
            config.hook.setConnector(id, config.connectors[index], true);
        }
        for (uint256 index; index < config.groups.length; index++) {
            Group memory group = config.groups[index];
            config.hook.setLeaders(id, group.base, group.partner, group.poolIds);
        }
        _setLimits(config, id);
        vm.stopBroadcast();
        console2.log("MARKET", id);
        console2.log("GAS_LIMIT", config.hook.market(id).gasLimit);
        console2.log("GAS_FOR_SWAP", config.hook.gasForSwap(id));
    }

    function _tracked(Config memory config, uint256 id, PoolKey memory pool)
        internal
        view
        returns (bool)
    {
        return config.hook.tracked(id, PoolId.unwrap(pool.toId()));
    }

    /// @dev Naming more leaders, or choosing tokens whose groups are already set, needs a
    /// larger gas allowance, and is refused without it.
    /// A market that is on is given the most any leaders can need first, so that it never
    /// has to be switched off; `_setLimits` then sets what was asked for.
    function _makeRoom(Config memory config, uint256 id) internal {
        if (config.groups.length == 0) {
            if (config.tokens.length == 0) return;
        }
        ArbitrageLogic.Market memory settings = config.hook.market(id);
        if (settings.gasLimit == 0) return;
        if (settings.gasLimit >= CEILING) return;
        address base = config.tokens.length != 0 ? config.tokens[0] : config.groups[0].base;
        config.hook
            .setLimits(
                id, base, CEILING, config.hook.minimumProfit(id, base), settings.minimumEdge
            );
    }

    /// @dev Sets each profit floor given, with the allowance asked for or the least the
    /// leaders need, whichever is more. With no floor given the allowance is left alone.
    function _setLimits(Config memory config, uint256 id) internal {
        uint64 edge = config.edge;
        if (edge == 0) edge = config.hook.market(id).minimumEdge;
        uint256 needed = config.hook.minimumGasLimit(id);
        uint32 gas = config.gasLimit > needed ? config.gasLimit : uint32(needed);
        for (uint256 index; index < config.limits.length; index++) {
            Limit memory limit = config.limits[index];
            config.hook.setLimits(id, limit.base, gas, limit.profit, edge);
        }
    }

    function _narrow(uint256 value, uint256 most) internal pure returns (uint256) {
        if (value > most) revert ValueTooLarge();
        return value;
    }

    /// @dev Pools are given as parallel lists, one entry per pool. One group of leaders
    /// and one profit floor can be given per run; leave `PROFIT_TOKEN` out to set none.
    function _readConfig() internal view returns (Config memory config) {
        config.hook = ArbitrageApi(payable(vm.envAddress("ARBITRAGE_HOOK")));
        config.owner = vm.envAddress("MARKET_OWNER");
        config.market = vm.envOr("MARKET_ID", uint256(0));
        config.recipient = vm.envOr("MARKET_RECIPIENT", config.owner);
        config.tokens = vm.envOr("MARKET_TOKENS", ",", new address[](0));
        config.pools = _readPools("POOL", address(config.hook));
        uint256[] memory prices = vm.envOr("POOL_PRICE", ",", new uint256[](0));
        config.prices = new uint160[](prices.length);
        for (uint256 index; index < prices.length; index++) {
            config.prices[index] = uint160(_narrow(prices[index], type(uint160).max));
        }
        config.venues = _readPools("VENUE", address(0));
        config.connectors = _readPools("CONNECTOR", address(0));
        address base = vm.envOr("LEADER_BASE", address(0));
        if (base != address(0)) {
            config.groups = new Group[](1);
            config.groups[0] = Group(
                base, vm.envAddress("LEADER_PARTNER"), vm.envBytes32("LEADER_POOLS", ",")
            );
        }
        address profitToken = vm.envOr("PROFIT_TOKEN", address(0));
        if (profitToken != address(0)) {
            config.limits = new Limit[](1);
            config.limits[0] = Limit(
                profitToken, uint128(_narrow(vm.envUint("MINIMUM_PROFIT"), type(uint128).max))
            );
        }
        config.gasLimit =
            uint32(_narrow(vm.envOr("MARKET_GAS_LIMIT", uint256(0)), type(uint32).max));
        config.edge = uint64(_narrow(vm.envOr("MINIMUM_EDGE", uint256(0)), type(uint64).max));
    }

    /// @dev `<PREFIX>_TOKEN0`, `_TOKEN1`, `_FEE` and `_TICK_SPACING`, with `_HOOKS` where a
    /// list of connecting pools includes the market's own pools on the hook.
    function _readPools(string memory prefix, address hooks)
        internal
        view
        returns (PoolKey[] memory list)
    {
        address[] memory token0 =
            vm.envOr(string.concat(prefix, "_TOKEN0"), ",", new address[](0));
        address[] memory token1 =
            vm.envOr(string.concat(prefix, "_TOKEN1"), ",", new address[](0));
        uint256[] memory fee = vm.envOr(string.concat(prefix, "_FEE"), ",", new uint256[](0));
        uint256[] memory spacing =
            vm.envOr(string.concat(prefix, "_TICK_SPACING"), ",", new uint256[](0));
        address[] memory given =
            vm.envOr(string.concat(prefix, "_HOOKS"), ",", new address[](0));
        if (token1.length != token0.length) revert MismatchedLists();
        if (fee.length != token0.length) revert MismatchedLists();
        if (spacing.length != token0.length) revert MismatchedLists();
        if (given.length != 0) {
            if (given.length != token0.length) revert MismatchedLists();
        }
        list = new PoolKey[](token0.length);
        for (uint256 index; index < token0.length; index++) {
            address own = given.length == 0 ? hooks : given[index];
            list[index] = PoolKey(
                Currency.wrap(token0[index]),
                Currency.wrap(token1[index]),
                uint24(_narrow(fee[index], type(uint24).max)),
                int24(int256(_narrow(spacing[index], uint24(type(int24).max)))),
                IHooks(own)
            );
        }
    }
}
