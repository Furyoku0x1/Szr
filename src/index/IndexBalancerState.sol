// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "./IndexPool.sol";
import { IndexPoolFactory } from "./IndexPoolFactory.sol";
import { IndexMetric } from "./IndexMetric.sol";

/// @notice Everything the index balancer keeps, shared by the balancer and its settings
/// module, which the balancer reaches by delegatecall. Only this contract declares storage,
/// so both read the same slots; never add state to either of the others.
abstract contract IndexBalancerState {
    struct Route {
        bool metric; // false: a Uniswap v4 pool. true: a Metric pool.
        PoolKey venue; // v4: the pool of the token and the unit, with no hook
        address pool; // Metric: the pool of the token and the unit
    }

    struct Limits {
        uint128 minimumGap;
        uint128 minimumProfit;
    }

    struct Bench {
        uint64 until;
        uint192 gap;
    }

    uint256 public constant MAX_VENUES = 3;
    uint256 public constant CHANGE_DELAY = 24 hours;
    /// @dev A route is kept in one word. A v4 route holds its fee and tick spacing: its
    /// tokens are the route's token and the unit, and it has no hook, so the rest of its key
    /// is known. A Metric route holds its pool in the low 160 bits, the Metric flag, and
    /// whether the route's token is the Metric pool's token0.
    uint256 internal constant FEE_SHIFT = 160;
    uint256 internal constant SPACING_SHIFT = 184;
    uint256 internal constant METRIC_FLAG = 1 << 208;
    uint256 internal constant TOKEN_FIRST = 1 << 209;

    IPoolManager public immutable poolManager;
    IndexPoolFactory public immutable factory;
    IndexMetric public immutable metric;

    mapping(address pool => address) internal units;
    mapping(address pool => mapping(address token => uint256[])) internal live;
    mapping(address pool => mapping(address token => uint256[])) internal pending;
    mapping(address pool => mapping(address token => uint256)) internal routesReadyAt;
    mapping(address pool => Limits) internal limitSet;
    mapping(address pool => Limits) internal limitPending;
    mapping(address pool => uint256) internal limitReadyAt;
    /// A unit announced once the pool had started, and when it may be applied.
    mapping(address pool => address) internal unitPending;
    mapping(address pool => uint256) internal unitReadyAt;
    mapping(bytes32 pair => Bench) internal benches;

    error ZeroAddress();
    error UnknownPool();
    error NotCreator();
    error UnitAlreadySet();
    error UnitNotSet();
    error UnknownToken();
    error TooManyVenues();
    error MetricFailed(address pool);
    error Lost(bytes32 tag);
    error WrongModule();
    error NotMetric();
    error HookedVenue();
    error WrongPair();
    error NotInitialised();
    error NothingPending();
    error NotReady();
    error InvalidIndex();
    error TooLarge();
    error NotSelf();
    error NotPoolManager();
    error Unprofitable();
    error Incomplete();

    event UnitSet(address indexed pool, address unit);
    event UnitAnnounced(address indexed pool, address unit, uint256 readyAt);
    event RoutesSet(address indexed pool, address indexed token);
    event RoutesAnnounced(address indexed pool, address indexed token, uint256 readyAt);
    event RouteRemoved(address indexed pool, address indexed token, uint256 index);
    event LimitsSet(address indexed pool, uint256 minimumGap, uint256 minimumProfit);
    event LimitsAnnounced(
        address indexed pool, uint256 minimumGap, uint256 minimumProfit, uint256 readyAt
    );

    constructor(IPoolManager poolManager_, IndexPoolFactory factory_, IndexMetric metric_) {
        poolManager = poolManager_;
        factory = factory_;
        metric = metric_;
    }

    function _holds(address pool, address token) internal view returns (bool) {
        address[] memory list = IndexPool(pool).tokens();
        for (uint256 index; index < list.length; index++) {
            if (list[index] == token) return true;
        }
        return false;
    }

    function _key(address token, address unit, uint256 word)
        internal
        pure
        returns (PoolKey memory key)
    {
        (address low, address high) = token < unit ? (token, unit) : (unit, token);
        key = PoolKey(
            Currency.wrap(low),
            Currency.wrap(high),
            uint24(word >> FEE_SHIFT),
            int24(uint24(word >> SPACING_SHIFT)),
            IHooks(address(0))
        );
    }
}
