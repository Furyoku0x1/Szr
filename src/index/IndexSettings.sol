// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "./IndexPool.sol";
import { IndexPoolFactory } from "./IndexPoolFactory.sol";
import { IndexMetric } from "./IndexMetric.sol";
import { IndexBalancerState } from "./IndexBalancerState.sol";

/// @notice The index balancer's settings: each pool's unit, venues and limits, set by the
/// pool's creator, and the views of them. The balancer reaches this code by delegatecall,
/// so it runs on the balancer's own storage; called directly it changes only its own,
/// which nothing reads. Kept apart so the balancer fits in 24,576 bytes.
contract IndexSettings is IndexBalancerState {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager poolManager_, IndexPoolFactory factory_, IndexMetric metric_)
        IndexBalancerState(poolManager_, factory_, metric_)
    { }

    function unitOf(address pool) external view returns (address) {
        return units[pool];
    }

    function limitsOf(address pool)
        external
        view
        returns (uint128 minimumGap, uint128 minimumProfit)
    {
        Limits memory limits = limitSet[pool];
        return (limits.minimumGap, limits.minimumProfit);
    }

    function pendingLimits(address pool)
        external
        view
        returns (uint128 minimumGap, uint128 minimumProfit)
    {
        Limits memory limits = limitPending[pool];
        return (limits.minimumGap, limits.minimumProfit);
    }

    function limitsReadyAt(address pool) external view returns (uint256) {
        return limitReadyAt[pool];
    }

    /// Until when a pair, keyed by pool, token paid in and token taken out, is set aside,
    /// and the gap it failed at.
    function benched(bytes32 pair) external view returns (uint64 until, uint192 gap) {
        Bench memory bench = benches[pair];
        return (bench.until, bench.gap);
    }

    /// The pool's creator only. `unit` is set once and never changes.
    function setUnit(address pool, address unit) external {
        _onlyCreator(pool);
        if (unit == address(0)) revert ZeroAddress();
        if (units[pool] != address(0)) revert UnitAlreadySet();
        if (!IndexPool(pool).started()) {
            units[pool] = unit;
            emit UnitSet(pool, unit);
            return;
        }
        unitPending[pool] = unit;
        uint256 ready = block.timestamp + CHANGE_DELAY;
        unitReadyAt[pool] = ready;
        emit UnitAnnounced(pool, unit, ready);
    }

    /// The pool's creator only. Before the pool has started a setting applies at once. Once it
    /// has started every setting, a first one included, is announced and applies after
    /// `CHANGE_DELAY`, so a depositor who dislikes it can leave first.
    function setRoutes(address pool, address token, Route[] calldata routes) external {
        _onlyCreator(pool);
        // A unit still waiting to apply is the one these routes are checked against; they
        // are checked again against the unit in effect when they apply.
        address unit = units[pool];
        if (unit == address(0)) unit = unitPending[pool];
        if (unit == address(0)) revert UnitNotSet();
        if (token == unit) revert UnknownToken();
        if (!_holds(pool, token)) revert UnknownToken();
        if (routes.length > MAX_VENUES) revert TooManyVenues();
        uint256[] memory words = new uint256[](routes.length);
        for (uint256 index; index < routes.length; index++) {
            words[index] = _encode(token, unit, routes[index]);
        }
        if (!IndexPool(pool).started()) {
            _store(live[pool][token], words);
            emit RoutesSet(pool, token);
            return;
        }
        _store(pending[pool][token], words);
        uint256 ready = block.timestamp + CHANGE_DELAY;
        routesReadyAt[pool][token] = ready;
        emit RoutesAnnounced(pool, token, ready);
    }

    /// The pool's creator only, under the same rule as `setRoutes`.
    function setLimits(address pool, uint256 minimumGap, uint256 minimumProfit) external {
        _onlyCreator(pool);
        if (minimumGap > type(uint128).max) revert TooLarge();
        if (minimumProfit > type(uint128).max) revert TooLarge();
        Limits memory limits = Limits(uint128(minimumGap), uint128(minimumProfit));
        if (!IndexPool(pool).started()) {
            limitSet[pool] = limits;
            emit LimitsSet(pool, minimumGap, minimumProfit);
            return;
        }
        limitPending[pool] = limits;
        uint256 ready = block.timestamp + CHANGE_DELAY;
        limitReadyAt[pool] = ready;
        emit LimitsAnnounced(pool, minimumGap, minimumProfit, ready);
    }

    /// Anyone may call it once the delay has passed. `token` zero applies the limits.
    function applyChange(address pool, address token) external {
        if (token == address(0)) {
            _applyLimits(pool);
            return;
        }
        if (token == pool) {
            _applyUnit(pool);
            return;
        }
        uint256 ready = routesReadyAt[pool][token];
        if (ready == 0) revert NothingPending();
        if (block.timestamp < ready) revert NotReady();
        uint256[] memory words = pending[pool][token];
        address unit = units[pool];
        if (unit == address(0)) revert UnitNotSet();
        for (uint256 index; index < words.length; index++) {
            _check(token, unit, words[index]);
        }
        _store(live[pool][token], words);
        delete pending[pool][token];
        routesReadyAt[pool][token] = 0;
        emit RoutesSet(pool, token);
    }

    /// The creator only; immediate, since it can only make the hook do less.
    function removeRoute(address pool, address token, uint256 index) external {
        _onlyCreator(pool);
        uint256[] storage list = live[pool][token];
        if (index >= list.length) revert InvalidIndex();
        list[index] = list[list.length - 1];
        list.pop();
        emit RouteRemoved(pool, token, index);
    }

    function pendingRoutes(address pool, address token)
        external
        view
        returns (Route[] memory routes, uint256 readyAt)
    {
        return (_routes(pool, token, pending[pool][token]), routesReadyAt[pool][token]);
    }

    function routesOf(address pool, address token) external view returns (Route[] memory) {
        return _routes(pool, token, live[pool][token]);
    }

    function _applyUnit(address pool) internal {
        uint256 ready = unitReadyAt[pool];
        if (ready == 0) revert NothingPending();
        if (block.timestamp < ready) revert NotReady();
        address unit = unitPending[pool];
        units[pool] = unit;
        delete unitPending[pool];
        unitReadyAt[pool] = 0;
        emit UnitSet(pool, unit);
    }

    /// The unit announced for a pool that has started, and when it may be applied.
    function pendingUnit(address pool) external view returns (address unit, uint256 readyAt) {
        return (unitPending[pool], unitReadyAt[pool]);
    }

    function _applyLimits(address pool) internal {
        uint256 ready = limitReadyAt[pool];
        if (ready == 0) revert NothingPending();
        if (block.timestamp < ready) revert NotReady();
        Limits memory limits = limitPending[pool];
        limitSet[pool] = limits;
        delete limitPending[pool];
        limitReadyAt[pool] = 0;
        emit LimitsSet(pool, limits.minimumGap, limits.minimumProfit);
    }

    function _onlyCreator(address pool) internal view {
        if (!factory.isPool(pool)) revert UnknownPool();
        if (IndexPool(pool).creator() != msg.sender) revert NotCreator();
    }

    /// @dev A route as one word, once it has passed the venue checks.
    function _encode(address token, address unit, Route calldata route)
        internal
        view
        returns (uint256 word)
    {
        if (route.metric) {
            bool first = metric.check(route.pool, token, unit);
            return uint256(uint160(route.pool)) | METRIC_FLAG | (first ? TOKEN_FIRST : 0);
        }
        if (address(route.venue.hooks) != address(0)) revert HookedVenue();
        word = uint256(route.venue.fee) << FEE_SHIFT | uint256(uint24(route.venue.tickSpacing))
            << SPACING_SHIFT;
        PoolKey memory key = _key(token, unit, word);
        if (Currency.unwrap(route.venue.currency0) != Currency.unwrap(key.currency0)) {
            revert WrongPair();
        }
        if (Currency.unwrap(route.venue.currency1) != Currency.unwrap(key.currency1)) {
            revert WrongPair();
        }
        _check(token, unit, word);
    }

    /// @dev The checks a stored route must still pass when it is applied.
    function _check(address token, address unit, uint256 word) internal view {
        if (word & METRIC_FLAG != 0) {
            metric.check(address(uint160(word)), token, unit);
            return;
        }
        (uint160 price,,,) = poolManager.getSlot0(_key(token, unit, word).toId());
        if (price == 0) revert NotInitialised();
    }

    function _routes(address pool, address token, uint256[] storage words)
        internal
        view
        returns (Route[] memory routes)
    {
        address unit = units[pool];
        routes = new Route[](words.length);
        for (uint256 index; index < words.length; index++) {
            uint256 word = words[index];
            if (word & METRIC_FLAG != 0) {
                (routes[index].metric, routes[index].pool) = (true, address(uint160(word)));
                continue;
            }
            routes[index].venue = _key(token, unit, word);
        }
    }

    function _store(uint256[] storage list, uint256[] memory words) internal {
        while (list.length != 0) {
            list.pop();
        }
        for (uint256 index; index < words.length; index++) {
            list.push(words[index]);
        }
    }
}
