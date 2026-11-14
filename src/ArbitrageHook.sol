// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { SzrCore } from "./SzrCore.sol";
import { Liquidity } from "./Liquidity.sol";

/// @notice One hook shared by every pool created with it. Around each swap it closes
/// price gaps between that pool and the other pools of its market. SZR's market retires
/// the SZR it earns. Anyone can open a market for their own token; its profit is paid in
/// WETH, `PROTOCOL_SHARE` percent to the protocol and the rest to the market.
/// @dev "SZR" below stands for the home token of whichever market is being searched: SZR
/// in SZR's market, WETH in every other.
/// @dev Pools are grouped by partner token, and each group has a few leaders. A swap's pool
/// is compared with the leaders of its own group, the first leader of every other group,
/// and Core, so the cost of a search does not grow with the number of pools tracked.
/// @dev It searches twice per swap. Before the swap trades it closes any gap already open,
/// so the swap executes at the aligned price and cannot collect that gap. After the swap it
/// closes the gap the swap itself opened.
/// @dev A cycle starts and ends in SZR: sell SZR at one venue, cross up to two connecting
/// pools, buy SZR back at another. One of the two venues is always the pool being searched.
/// Core's `redeem` is a sell-only venue paying NAV in WETH. v4 flash accounting funds every
/// cycle, so the hook holds no balance between transactions; profit goes to `donateSzr`.
/// @dev A failed or unprofitable attempt reverts inside a caught self-call and does not fail
/// the swap that triggered it. Running out of gas is the exception: a swap sent with too
/// little gas for any cycle reverts as a whole, so gas estimates include the cycles. Once a
/// cycle has succeeded the search holds gas back and stops early instead.
/// v4 skips hook callbacks for the hook's own swaps.
contract ArbitrageHook is IHooks, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Pools are grouped by their partner token. A search does not price every pool:
    /// it prices the leaders of the searched pool's own group, the first leader of every
    /// other group, and Core. So what a swap costs depends on these two bounds and not on
    /// how many pools are tracked.
    uint256 public constant MAX_GROUPS = 8;
    uint256 public constant MAX_LEADERS = 3;
    /// @notice Cycles tried per search, counting failed ones.
    uint256 public constant MAX_ROUNDS = 6;
    /// @notice The most gas all the tries at one cycle may use between them. A cycle that
    /// needs more is treated as failed, so a leg made expensive on purpose costs a bounded
    /// amount once and is then set aside.
    uint256 public constant PLAN_GAS = 1_000_000;
    /// @dev A cycle is only started with `PLAN_GAS` available on top of what retiring the
    /// profit needs, so whether it runs never depends on guessing why a try failed. A try
    /// is only started with `ATTEMPT_GAS` of the budget left. Pricing every venue costs up
    /// to `SCAN_GAS_PER_VENUE` each, and `SWAP_GAS` is what the swap itself needs between
    /// the search before it and the search after it.
    uint256 internal constant RETIRE_GAS = 250_000;
    uint256 internal constant ATTEMPT_GAS = 150_000;
    uint256 internal constant SCAN_GAS_PER_VENUE = 40_000;
    uint256 internal constant SWAP_GAS = 800_000;
    /// @dev How many failed cycles a search still has to be given the gas to get past. If
    /// one failing cycle were enough to end it, anyone able to stage one could make the
    /// search stand aside and take the gap it was about to close.
    uint256 internal constant FAILURES_COVERED = 2;
    /// @dev What the tries and a bench cost beyond the budget itself.
    uint256 internal constant OVERHEAD_GAS = 60_000;
    uint256 internal constant BOOK_GAS_PER_VENUE = 15_000;
    /// @notice How long a cycle between two venues is set aside after it fails.
    uint256 public constant BENCH_TIME = 3 minutes;
    /// @dev A gap this many times the one that failed is tried even while the cycle is set
    /// aside. Without it, forcing one failure at a small gap would switch a real pair off
    /// for the whole period, however wide the gap then grew.
    uint256 internal constant BENCH_ESCAPE = 2;
    /// @dev Sizes tried for one cycle: the estimate, then the whole gap, then a half, a
    /// quarter and an eighth of it. The estimate reads liquidity at the current price,
    /// which can be made to mislead in either direction.
    uint256 internal constant TRIES = 5;
    /// @dev A square-root price gap beyond this (a 16x price difference) is a broken or
    /// manipulated venue, not something to arbitrage.
    uint256 internal constant MAX_EDGE = 4e18;
    /// @dev Bounds that keep the pricing arithmetic from overflowing whatever a pool's state.
    /// An empty pool's price can be pushed anywhere for free, and one overflow would stop
    /// the search for every pool. A square-root price outside the band (a price ratio beyond
    /// about 5e33 either way) is treated as no price at all.
    uint256 internal constant MIN_RATE = 1 << 40;
    uint256 internal constant MAX_RATE = 1 << 152;
    uint256 internal constant MAX_ROUTE_RATE = 1 << 192;
    uint256 internal constant MAX_CYCLE_RATE = 1 << 180;
    uint256 internal constant MIN_CYCLE_KEEP = 1e12;
    uint256 internal constant MAX_DEPTH = 1 << 160;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    address internal constant UNRELEASED = address(1);
    uint160 internal constant PERMISSION_MASK = (1 << 14) - 1;
    /// @dev The beforeSwap and afterSwap permission bits, and no others.
    uint160 internal constant SWAP_HOOKS = (1 << 7) | (1 << 6);

    /// @dev One place SZR trades, read once per search: its partner token, its square-root
    /// price in partner per SZR (Q96), and the square root of the share of a trade its fee
    /// leaves (WAD). The last entry of a book is Core redemption, with a zero `id`.
    struct Venue {
        bytes32 id;
        address partner;
        uint64 fixedKeep;
        uint256 rate;
        uint256 keep;
    }

    /// @dev The venue a search is centred on. `depth` is the SZR it takes to move that
    /// pool's square-root price by its own size, read only once a gap is found. Many venues
    /// share a partner token, so the route to each partner is worked out once per scan and
    /// kept in `seen` and `routes`.
    struct Focus {
        bytes32 id;
        address partner;
        uint256 rate;
        uint256 keep;
        uint256 depth;
        address[] seen;
        Route[] routes;
        uint256 known;
    }

    /// @dev `gap` is how far apart the prices were, beyond fees, when the cycle failed.
    struct Bench {
        uint64 until;
        uint192 gap;
    }

    /// @dev `market` is kept when a pool is untracked; `partner` is then zero.
    struct Tracked {
        address partner;
        uint64 keep;
        uint32 market;
    }

    /// @notice One owner's pools and settings. Every pool in a market shares its `home`
    /// token, and a search never looks outside the market of the pool that traded.
    /// @dev `gasLimit` is the gas given to each search; zero switches the market off.
    /// `minimumProfit` is the smallest profit a cycle must return, in the home token (SZR
    /// for SZR's market, WETH for every other).
    /// `minimumEdge` is the smallest gap worth an attempt, in square-root price terms (WAD).
    /// `groups` are the partner tokens that have leaders. The SZR market has no stored
    /// owner: it belongs to Liquidity's manager.
    struct Market {
        address home;
        uint32 gasLimit;
        uint64 minimumEdge;
        uint128 minimumProfit;
        uint64 poolCount;
        address owner;
        address recipient;
        address[] groups;
    }

    /// @dev The way from a venue's partner token to the focus pool's partner token: no pool
    /// when they are the same, one connecting pool, or two that meet at WETH. `links[0]`
    /// is the pool nearest the focus pool. `rate` and `keep` are the pools' combined; a zero
    /// `rate` means there is no way across. `depth` is the connecting pools' combined depth,
    /// read once a cycle needs it.
    struct Route {
        bytes32[2] links;
        uint256[2] rates;
        uint256 rate;
        uint256 keep;
        uint256 depth;
        bool sized;
    }

    /// @dev `venue` zero means Core redemption. Unused `links` are zero.
    /// `buying` means the hook buys SZR in the focus pool and sells it at the venue.
    /// `gap` is how far apart the square-root prices are beyond fees, as a share (WAD);
    /// `score` is the SZR profit the cycle is expected to return. `limit` is where the
    /// focus pool's price is expected to stop and `full` where the whole gap would take it.
    /// `spend` and `fullSpend` are the most the first leg may pay in to get there, in the
    /// token it pays with: a price limit alone would let liquidity parked just ahead of the
    /// price turn a small trade into a huge one.
    struct Plan {
        uint256 gap;
        uint256 index;
        bytes32 venue;
        bytes32[2] links;
        uint160 limit;
        uint160 full;
        uint256 spend;
        uint256 fullSpend;
        bool buying;
        uint256 score;
    }

    IPoolManager public immutable poolManager;
    Liquidity public immutable liquidity;
    SzrCore public immutable core;
    address public immutable token;
    address public immutable backingAsset;

    /// @notice SZR's own market, the first one. It alone has Core redemption as a venue,
    /// and retires its profit instead of paying it out.
    uint256 public constant SZR_MARKET = 1;
    /// @notice The share of every other market's profit that goes to `protocolRecipient`,
    /// in percent. The rest goes to the market's own recipient. Both are paid in WETH.
    uint256 public constant PROTOCOL_SHARE = 30;
    /// @notice Where the protocol's share is sent. Core by default, where it waits to be
    /// counted as backing by `absorbBacking`. Liquidity's manager can change it.
    address public protocolRecipient;
    /// @notice How many markets exist. Their ids run from one.
    uint256 public marketCount = 1;
    mapping(uint256 id => Market) internal markets;
    /// @dev The market being searched, and its home token. Set while a search runs, so a
    /// swap made by some other hook in the middle of a cycle cannot start a second search
    /// inside the first.
    uint256 internal transient active;
    address internal transient home;
    /// @dev Each group's leaders: its deepest pools, in the owner's order. The first is
    /// the one other groups are compared against. A hookless pool can lead; it is then
    /// only ever a venue.
    mapping(uint256 market => mapping(address partner => bytes32[] poolIds)) internal leaders;
    mapping(bytes32 poolId => PoolKey) internal keys;
    /// @dev A tracked pool's market, its token other than the home token, and the fee
    /// factor of a fixed-fee pool worked out once (zero for a dynamic-fee pool, whose fee
    /// is read each time).
    mapping(bytes32 poolId => Tracked) internal tracked;
    /// @dev A cycle between a focus pool and a venue that failed is not tried again until
    /// `until`, unless the gap has grown well beyond the one that failed. Keyed by the
    /// pair and the direction, so a broken pool only sets aside its own cycles.
    mapping(bytes32 pair => Bench) internal benched;
    /// @dev Tokens a market can end up trading besides its home token and WETH: the partner
    /// of every pool it ever tracked and both sides of every connecting pool it ever set.
    mapping(uint256 market => mapping(address asset => bool)) internal traded;
    /// @notice The pool a market uses to convert between two partner tokens, keyed lower
    /// address first.
    mapping(uint256 market => mapping(address lower => mapping(address higher => bytes32)))
        public connector;

    error InvalidHookAddress();
    error HookNotImplemented();
    error NotManager();
    error NotPoolManager();
    error NotSelf();
    error Busy();
    error UnknownPool();
    error AlreadyTracked();
    error TooManyGroups();
    error TooManyLeaders();
    error StillLeader();
    error InvalidPool();
    error InvalidLimit();
    error PoolNotRegistered();
    error InvalidDelta();
    error Incomplete();
    error Unprofitable();
    error Unsettled();
    error Starved();
    error InsufficientGas();
    error TooManyMarkets();

    event MarketOpened(uint256 indexed market, address indexed owner);
    event RecipientSet(uint256 indexed market, address recipient);
    /// @notice A market earned `amount` WETH, of which `protocolShare` went to the protocol
    /// and the rest to the market's recipient.
    event ProfitPaid(uint256 indexed market, uint256 amount, uint256 protocolShare);
    event PoolTracked(bytes32 indexed poolId, address indexed partner);
    event PoolUntracked(bytes32 indexed poolId);
    event ConnectorSet(
        uint256 indexed market, address indexed lower, address indexed higher, bytes32 poolId
    );
    event LeadersSet(uint256 indexed market, address indexed partner, bytes32[] poolIds);
    event LimitsSet(
        uint256 indexed market, uint32 gasLimit, uint128 minimumProfit, uint64 minimumEdge
    );
    /// @notice A cycle that looked profitable failed at every size tried. A venue that keeps
    /// appearing here is costing swappers gas and is a candidate for `untrack`.
    event CycleFailed(bytes32 indexed poolId, bytes32 indexed venue);
    /// @notice A search ended with a cycle still to try because it ran short of gas. Seen
    /// often, it means the gas allowance is too small for the venues a search prices.
    event SearchCutShort(bytes32 indexed poolId);
    /// @notice A search was undone as a whole, for instance because Core refused the
    /// donation or the hook's gas allowance ran out. `reason` is the first four bytes of
    /// what undid it (the error's selector), or zero when it ran out of gas. Seen often,
    /// something needs attention.
    event SearchUndone(bytes32 indexed poolId, bytes4 reason);
    event Arbitraged(
        bytes32 indexed poolId, bytes32 indexed venue, bool buying, uint256 profit
    );

    modifier onlyOwner(uint256 id) {
        if (msg.sender != _owner(id)) revert NotManager();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    constructor(Liquidity treasury) {
        if (uint160(address(this)) & PERMISSION_MASK != SWAP_HOOKS) {
            revert InvalidHookAddress();
        }
        liquidity = treasury;
        core = treasury.core();
        poolManager = treasury.poolManager();
        token = treasury.token();
        backingAsset = treasury.backingAsset();
        // Core pulls SZR for both `redeem` and `donateSzr`. The hook holds none in between.
        SafeTransferLib.safeApprove(token, address(core), type(uint256).max);
        // The profit default is roughly what a cycle's gas cost the swapper at launch
        // prices. The edge default is about 0.02% of price beyond fees; smaller gaps cost
        // more gas than they return.
        Market storage own = markets[SZR_MARKET];
        own.home = token;
        own.gasLimit = 8_000_000;
        own.minimumProfit = 10e18;
        own.minimumEdge = 1.0001e18;
        protocolRecipient = address(core);
    }

    /// @notice Opens a market owned by the caller. Anyone can. It starts switched off;
    /// create its pools, name leaders, then call `setLimits`.
    /// @dev Its home token is WETH: every pool in it pairs WETH with some other token, and
    /// every cycle starts and ends in WETH. So its profit is WETH proven on balances, with
    /// no price to trust, and the hook never holds or sends any other token for it.
    function openMarket(address recipient) external returns (uint256 id) {
        if (recipient == address(0)) revert InvalidPool();
        id = ++marketCount;
        // A pool records its market in 32 bits.
        if (id > type(uint32).max) revert TooManyMarkets();
        Market storage own = markets[id];
        own.home = backingAsset;
        own.owner = msg.sender;
        own.recipient = recipient;
        own.minimumEdge = 1.0001e18;
        emit MarketOpened(id, msg.sender);
    }

    function setRecipient(uint256 id, address recipient) external onlyOwner(id) {
        if (recipient == address(0)) revert InvalidPool();
        markets[id].recipient = recipient;
        emit RecipientSet(id, recipient);
    }

    function setProtocolRecipient(address recipient) external onlyOwner(SZR_MARKET) {
        if (recipient == address(0)) revert InvalidPool();
        protocolRecipient = recipient;
        emit RecipientSet(SZR_MARKET, recipient);
    }

    /// @notice Creates a pool on this hook and adds it to the caller's market. This is the
    /// only way a pool joins a market other than SZR's, so nobody can claim a pool someone
    /// else created, and every venue in such a market runs this hook's code and no other.
    /// @dev The pool must pair WETH with a token other than SZR.
    function createPool(uint256 id, PoolKey calldata pool, uint160 sqrtPriceX96)
        external
        onlyOwner(id)
    {
        if (id == SZR_MARKET) revert InvalidPool();
        if (address(pool.hooks) != address(this)) revert InvalidPool();
        address partner = _partner(id, pool);
        if (partner == token) revert InvalidPool();
        poolManager.initialize(pool, sqrtPriceX96);
        _track(id, pool, partner);
    }

    /// @notice Tracks again a pool that was created in a market and then untracked.
    function retrack(bytes32 poolId) external {
        uint256 id = tracked[poolId].market;
        if (id <= SZR_MARKET) revert UnknownPool();
        if (msg.sender != _owner(id)) revert NotManager();
        PoolKey memory pool = keys[poolId];
        _track(id, pool, _partner(id, pool));
    }

    /// @dev The token a pool pairs with the market's home token. Native ETH cannot be one.
    function _partner(uint256 id, PoolKey memory pool) internal view returns (address partner) {
        address base = markets[id].home;
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        partner = lower == base ? higher : lower;
        if (partner == lower) {
            if (higher != base) revert InvalidPool();
        }
        if (partner == address(0)) revert InvalidPool();
    }

    function _owner(uint256 id) internal view returns (address) {
        if (id == SZR_MARKET) return liquidity.manager();
        return markets[id].owner;
    }

    /// @notice A market's settings and the partner tokens that have leaders in it.
    function market(uint256 id) external view returns (Market memory) {
        return markets[id];
    }

    /// @notice Starts pricing the pool behind one of Liquidity's positions, in SZR's market.
    function track(uint256 id) external onlyOwner(SZR_MARKET) {
        Liquidity.Position memory entry = liquidity.position(id);
        _track(SZR_MARKET, entry.key, entry.partner);
    }

    function _track(uint256 id, PoolKey memory pool, address partner) internal {
        bytes32 poolId = PoolId.unwrap(pool.toId());
        if (tracked[poolId].partner != address(0)) revert AlreadyTracked();
        markets[id].poolCount++;
        keys[poolId] = pool;
        uint24 fee = pool.fee;
        // A dynamic-fee pool takes its fee from its hook, and this hook never sets one, so
        // such a pool on this hook would trade for nothing for ever.
        if (fee >= 1e6) {
            if (address(pool.hooks) == address(this)) revert InvalidPool();
        }
        tracked[poolId] = Tracked(partner, fee < 1e6 ? uint64(_keep(fee)) : 0, uint32(id));
        traded[id][partner] = true;
        emit PoolTracked(poolId, partner);
    }

    /// @notice Stops searching a pool. A leader has to be replaced first.
    function untrack(bytes32 poolId) external {
        Tracked memory entry = tracked[poolId];
        if (entry.partner == address(0)) revert UnknownPool();
        if (msg.sender != _owner(entry.market)) revert NotManager();
        if (_leads(entry.market, entry.partner, poolId)) revert StillLeader();
        markets[entry.market].poolCount--;
        tracked[poolId].partner = address(0);
        emit PoolUntracked(poolId);
    }

    /// @notice Names a partner token's leaders: its deepest tracked pools, deepest first.
    /// The first is what every other group is compared against, so it should be the pool
    /// hardest to move. An empty list removes the group.
    function setLeaders(uint256 id, address partner, bytes32[] calldata poolIds)
        external
        onlyOwner(id)
    {
        if (poolIds.length > MAX_LEADERS) revert TooManyLeaders();
        // An untracked pool has no partner, which must not pass for this one.
        if (partner == address(0)) revert InvalidPool();
        for (uint256 index; index < poolIds.length; index++) {
            Tracked memory entry = tracked[poolIds[index]];
            if (entry.partner != partner) revert InvalidPool();
            if (entry.market != id) revert InvalidPool();
            for (uint256 earlier; earlier < index; earlier++) {
                if (poolIds[earlier] == poolIds[index]) revert InvalidPool();
            }
        }
        _setGroup(markets[id].groups, partner, poolIds.length != 0);
        leaders[id][partner] = poolIds;
        _requireWorkable(id, markets[id].gasLimit);
        emit LeadersSet(id, partner, poolIds);
    }

    /// @dev An allowance too small for the venues a search prices would leave it idle.
    function _requireWorkable(uint256 id, uint256 gas) internal view {
        if (gas == 0) return;
        if (gas < minimumGasLimit(id)) revert InvalidLimit();
    }

    /// @dev Adds the partner to the list of groups, or removes it, as its leaders require.
    function _setGroup(address[] storage groups, address partner, bool wanted) internal {
        uint256 count = groups.length;
        uint256 index;
        while (index < count) {
            if (groups[index] == partner) break;
            index++;
        }
        if (wanted) {
            if (index != count) return;
            if (count == MAX_GROUPS) revert TooManyGroups();
            groups.push(partner);
            return;
        }
        if (index == count) return;
        groups[index] = groups[count - 1];
        groups.pop();
    }

    function _leads(uint256 id, address partner, bytes32 poolId) internal view returns (bool) {
        bytes32[] storage list = leaders[id][partner];
        for (uint256 index; index < list.length; index++) {
            if (list[index] == poolId) return true;
        }
        return false;
    }

    function leadersOf(uint256 id, address partner) external view returns (bytes32[] memory) {
        return leaders[id][partner];
    }

    /// @notice Sets or clears the pool used to convert between its two tokens. It must be
    /// on Liquidity's list of registered pools and must not contain SZR.
    function setConnector(uint256 id, PoolKey calldata pool, bool enabled)
        external
        onlyOwner(id)
    {
        bytes32 poolId = PoolId.unwrap(pool.toId());
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        if (lower == markets[id].home) revert InvalidPool();
        if (higher == markets[id].home) revert InvalidPool();
        if (id == SZR_MARKET) {
            if (!liquidity.poolRegistered(poolId)) revert PoolNotRegistered();
        }
        // Anyone can open a market, so its connecting pools may not run a hook: one could
        // do anything in the middle of a cycle, including trade in another market's pool
        // while this hook stands aside.
        if (id != SZR_MARKET) {
            if (address(pool.hooks) != address(0)) revert InvalidPool();
            if (lower == address(0)) revert InvalidPool();
        }
        // Clearing has to name the pool that is set, not just any pool on the same pair.
        if (!enabled) {
            if (connector[id][lower][higher] != poolId) revert InvalidPool();
        }
        keys[poolId] = pool;
        traded[id][lower] = true;
        traded[id][higher] = true;
        connector[id][lower][higher] = enabled ? poolId : bytes32(0);
        emit ConnectorSet(id, lower, higher, connector[id][lower][higher]);
    }

    /// @notice `gas` zero switches the hook off; otherwise it must cover at least one cycle.
    /// `edge` below 1.0 would chase losing cycles.
    function setLimits(uint256 id, uint32 gas, uint128 profit, uint64 edge)
        external
        onlyOwner(id)
    {
        if (edge < WAD) revert InvalidLimit();
        if (edge > MAX_EDGE) revert InvalidLimit();
        _requireWorkable(id, gas);
        Market storage own = markets[id];
        own.gasLimit = gas;
        own.minimumProfit = profit;
        own.minimumEdge = edge;
        emit LimitsSet(id, gas, profit, edge);
    }

    /// @notice The smallest gas allowance with which a search can always start its first
    /// cycle, for the groups and leaders set now. It does not depend on how many pools are
    /// tracked, only on how many venues one search can price.
    function minimumGasLimit(uint256 id) public view returns (uint256) {
        uint256 venues = _mostVenues(id);
        uint256 scan = SCAN_GAS_PER_VENUE * venues;
        // What the search before a swap needs to start, reading the prices and the first
        // ranking, and enough to get past the failed cycles it must be able to absorb.
        return _floor(venues, true) + BOOK_GAS_PER_VENUE * venues + scan + FAILURES_COVERED
            * (PLAN_GAS + OVERHEAD_GAS + scan);
    }

    /// @dev The most venues any search prices: the pool itself, the leaders of the largest
    /// group, the first leader of each other group, and Core.
    function _mostVenues(uint256 id) internal view returns (uint256) {
        address[] storage groups = markets[id].groups;
        uint256 count = groups.length;
        if (count == 0) return 2;
        uint256 most;
        for (uint256 index; index < count; index++) {
            uint256 size = leaders[id][groups[index]].length;
            if (size > most) most = size;
        }
        return most + count + 1;
    }

    /// @notice A tracked pool's token other than its market's home token; zero when the
    /// pool is not tracked.
    function partnerOf(bytes32 poolId) external view returns (address) {
        return tracked[poolId].partner;
    }

    /// @notice Until when the cycle between `poolId` (the pool searched) and `venue` (zero
    /// for Core redemption) is set aside after failing. `buying` is its direction: whether
    /// the hook buys SZR in `poolId`.
    function benchedUntil(bytes32 poolId, bytes32 venue, bool buying)
        external
        view
        returns (uint256)
    {
        return benched[_pair(poolId, venue, buying)].until;
    }

    function _pair(bytes32 poolId, bytes32 venue, bool buying) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, venue, buying));
    }

    /// @notice Runs the same search without a swap, for gaps that opened on a hookless
    /// pool or through a change in NAV. The caller receives nothing.
    function arb(bytes32 poolId) external returns (uint256 profit) {
        Tracked memory entry = tracked[poolId];
        if (entry.partner == address(0)) revert UnknownPool();
        if (active != 0) revert Busy();
        if (markets[entry.market].gasLimit == 0) return 0;
        _enter(entry.market);
        profit = abi.decode(poolManager.unlock(abi.encode(poolId)), (uint256));
        active = 0;
    }

    function _enter(uint256 id) internal {
        active = id;
        home = markets[id].home;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        return abi.encode(_search(abi.decode(data, (bytes32)), true, false, address(0)));
    }

    /// @notice Closes any gap that is already open before the swap trades, so the swap
    /// executes at the aligned price and the gap's value goes to the protocol.
    function beforeSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _run(sender, PoolId.unwrap(pool.toId()), true);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Closes the gap the swap itself just opened.
    function afterSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, int128) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _run(sender, PoolId.unwrap(pool.toId()), false);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Liquidity's own trades are left alone: its bounds assume the price it just set.
    function _run(address sender, bytes32 poolId, bool before) internal {
        if (sender == address(liquidity)) return;
        if (active != 0) return;
        Tracked memory entry = tracked[poolId];
        if (entry.partner == address(0)) return;
        uint256 stipend = markets[entry.market].gasLimit;
        if (stipend == 0) return;
        // Whether the search is bounded by the hook's own allowance or by the swap's gas.
        uint256 available = gasleft();
        bool capped = available - available / 64 >= stipend;
        try this.search{ gas: stipend }(poolId, capped, before, sender) { }
        catch (bytes memory reason) {
            // If the swap, not the hook's own allowance, was what ran short, it brought
            // too little gas either to look for a gap (no revert data) or to close the one
            // that is open. It fails as a whole, so that gas estimates include the hook and
            // nobody can skip it by sending less.
            if (!capped) {
                if (reason.length == 0) revert InsufficientGas();
                if (bytes4(reason) == Starved.selector) revert InsufficientGas();
            }
            // Anything else undid the search and leaves the swap as it would have been.
            emit SearchUndone(poolId, bytes4(reason));
        }
    }

    function search(bytes32 poolId, bool capped, bool before, address payer)
        external
        onlySelf
        returns (uint256 profit)
    {
        _enter(tracked[poolId].market);
        profit = _search(poolId, capped, before, payer);
        active = 0;
    }

    /// @dev Takes the most profitable cycle first. A cycle that fails is set aside for
    /// `BENCH_TIME`, so a broken venue costs one failure and cannot starve the others.
    /// Profit stays as a credit with the pool manager and is retired once.
    /// @dev `capped` means the search is bounded by the hook's own gas allowance, not by
    /// the swap's gas. Lacking the gas to start its first cycle then just ends the search;
    /// otherwise it reverts with `Starved`, which fails the swap.
    /// @dev `before` marks the search that runs ahead of a swap. Once it has earned
    /// something it only goes on while enough gas would be left for the swap and for the
    /// search after it, so that giving a swap more gas can never make it fail.
    /// @dev `payer` is whoever is swapping (zero for `arb`). If they have marked a token
    /// as synced with the pool manager, that is dealt with before the first cycle; see
    /// `_release`.
    function _search(bytes32 poolId, bool capped, bool before, address payer)
        internal
        returns (uint256 profit)
    {
        // `UNRELEASED` until the pool manager's sync slot has been dealt with.
        address resync = UNRELEASED;
        // The pool being searched is always the first entry of its book.
        Venue[] memory book = _book(poolId);
        uint256 next = book.length;
        uint256 floor = _floor(book.length, before);
        uint256 failures;
        for (uint256 number; number < MAX_ROUNDS; number++) {
            // Once something is earned, stop while there is still gas to keep it.
            if (profit != 0) {
                if (gasleft() < floor) break;
            }
            // Pricing every venue again must not run out of gas. The first cycle is only
            // started with this much to spare, so it is always there after one failure.
            if (number != 0) {
                if (gasleft() < RETIRE_GAS + SCAN_GAS_PER_VENUE * book.length) break;
            }
            Plan memory plan = _best(book, 0);
            if (plan.score == 0) {
                // Nothing left here. The venue last traded against has moved, which may
                // have opened a gap between it and the pools it is compared with, so look
                // from there next.
                if (next == book.length) break;
                book = _book(book[next].id);
                next = book.length;
                // Never lowered: before a swap it also holds back gas for the search
                // after it, which prices the first pool's venues, not this one's.
                uint256 again = _floor(book.length, before);
                if (again > floor) floor = again;
                continue;
            }
            // A cycle is only started with its whole budget available, and enough beyond
            // it to look again if it fails. Before a swap that also means enough for the
            // swap and the search after it, so no cycle here, working or not, can leave
            // them short. Closing a gap is required until one cycle has worked or
            // `FAILURES_COVERED` have failed: with a gap open and too little gas for that,
            // the swap fails. After that it is not: the search stops, and keeps what it
            // has earned and what it has learned about failures.
            if (gasleft() < floor) {
                if (_required(profit, failures, before)) {
                    if (!capped) revert Starved();
                }
                emit SearchCutShort(book[0].id);
                break;
            }
            if (resync == UNRELEASED) resync = _release(payer);
            uint256 gained = _attempt(book[0].id, plan);
            if (gained == 0) {
                failures++;
                _bench(book[0].id, plan);
                continue;
            }
            profit += gained;
            _requote(book[0]);
            _requote(book[plan.index]);
            if (plan.venue != bytes32(0)) next = plan.index;
        }
        if (profit != 0) _retire(profit);
        if (resync > UNRELEASED) poolManager.sync(Currency.wrap(resync));
    }

    /// @dev The gas a cycle needs before it may start: its own budget, retiring, and pricing
    /// the venues again if it fails. The search before a swap must also leave enough for
    /// the swap itself and for the search after it to read the prices, rank them and run
    /// its own first cycle.
    function _floor(uint256 venues, bool before) internal pure returns (uint256 floor) {
        uint256 scan = SCAN_GAS_PER_VENUE * venues;
        floor = RETIRE_GAS + PLAN_GAS + OVERHEAD_GAS + scan;
        if (before) floor = floor * 2 + SWAP_GAS + scan + BOOK_GAS_PER_VENUE * venues;
    }

    /// @dev The pool manager has one slot recording a token someone has marked as synced
    /// ahead of paying it in, and anyone can set it. The hook's own cycles take SZR out and,
    /// for Core, pay WETH in through that same slot, so the slot is cleared first.
    /// If a payment is already waiting it is credited to `payer`, exactly as their own
    /// settlement would have credited it; their later settlement then finds nothing more to
    /// add. If nothing has been paid in, the token is returned so it can be marked again
    /// once the search is done. Either way the hook runs as usual: marking a token is not
    /// a way to make it stand aside.
    /// @dev That care is only for tokens the hook trades. Any other token is left completely
    /// alone, and never called: it could be written to revert, burn gas or misreport its
    /// balance. Its mark survives unless a cycle redeems through Core, which uses the slot
    /// for WETH and leaves it empty. A router that marked such a token for an earlier hop
    /// and settles it after this swap then has its transaction revert; nothing is lost.
    function _release(address payer) internal returns (address resync) {
        address synced = Currency.unwrap(poolManager.getSyncedCurrency());
        if (synced == address(0)) return address(0);
        if (!_traded(synced)) return address(0);
        uint256 held = SafeTransferLib.balanceOf(synced, address(poolManager));
        if (held <= poolManager.getSyncedReserves()) return synced;
        // `arb` has no swapper to credit; a caller who paid in before calling it is misusing it.
        if (payer == address(0)) revert Busy();
        poolManager.settleFor(payer);
        // Marked again afterwards, so that anything more they pay in is counted as well.
        return synced;
    }

    /// @dev The search before a swap must get past `FAILURES_COVERED` failed cycles, since
    /// the swapper would gain from it standing aside and chooses the gas. The search after
    /// it only has to make its first attempt: gas for more is not reserved, and requiring
    /// it could make more gas fail where less succeeded.
    function _required(uint256 profit, uint256 failures, bool before)
        internal
        pure
        returns (bool)
    {
        if (profit != 0) return false;
        return failures < (before ? FAILURES_COVERED : 1);
    }

    function _bench(bytes32 poolId, Plan memory plan) internal {
        benched[_pair(poolId, plan.venue, plan.buying)] =
            Bench(uint64(block.timestamp + BENCH_TIME), uint192(plan.gap));
        emit CycleFailed(poolId, plan.venue);
    }

    function _traded(address asset) internal view returns (bool) {
        if (asset == home) return true;
        if (asset == backingAsset) return true;
        return traded[active][asset];
    }

    /// @dev SZR's market retires its profit at Core. Every other market's is paid out.
    function _retire(uint256 profit) internal {
        if (active != SZR_MARKET) return _payOut(profit);
        poolManager.take(Currency.wrap(token), address(this), profit);
        _requireSettled(token);
        core.donateSzr(profit);
    }

    /// @dev Splits a market's WETH profit between the protocol and the market.
    function _payOut(uint256 profit) internal {
        uint256 share = profit * PROTOCOL_SHARE / 100;
        Currency weth = Currency.wrap(backingAsset);
        poolManager.take(weth, protocolRecipient, share);
        poolManager.take(weth, markets[active].recipient, profit - share);
        emit ProfitPaid(active, profit, share);
    }

    /// @dev The first try stops where the depths of the legs say their prices meet. That
    /// assumes the liquidity read at the current price is what the trade will meet, which
    /// is wrong when a leg crosses into a different range and can be made wrong on purpose.
    /// So the next try closes the whole gap, and each one after goes half as far. All the
    /// tries share `PLAN_GAS`; when it runs out the cycle has failed.
    function _attempt(bytes32 poolId, Plan memory plan) internal returns (uint256) {
        (uint160 current,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
        uint256 budget = PLAN_GAS;
        for (uint256 number; number < TRIES; number++) {
            if (budget < ATTEMPT_GAS) break;
            if (number == 1) {
                plan.limit = plan.full;
                plan.spend = plan.fullSpend;
            }
            if (number > 1) {
                plan.limit = uint160((uint256(current) + plan.limit) / 2);
                plan.spend = plan.spend / 2 + 1;
            }
            // No try may use more than half the budget, so one that runs out of gas leaves
            // a full share for the next size.
            uint256 stipend = budget < PLAN_GAS / 2 ? budget : PLAN_GAS / 2;
            uint256 available = gasleft();
            try this.execute{ gas: stipend }(poolId, plan) returns (uint256 profit) {
                return profit;
            } catch { }
            uint256 used = available - gasleft();
            budget = used < budget ? budget - used : 0;
        }
        return 0;
    }

    /// @notice One whole cycle. It either nets at least `minimumProfit` SZR with no other
    /// token left owing, or reverts. The SZR stays as a credit until the search retires it.
    function execute(bytes32 poolId, Plan calldata plan)
        external
        onlySelf
        returns (uint256 profit)
    {
        profit = plan.buying ? _buyCycle(poolId, plan) : _sellCycle(poolId, plan);
        if (profit == 0) revert Unprofitable();
        if (profit < markets[active].minimumProfit) revert Unprofitable();
        emit Arbitraged(poolId, plan.venue, plan.buying, profit);
    }

    /// @dev Buys SZR in the pool up to the price limit, then works backwards with exact
    /// outputs: each connecting pool supplies the token owed to the pool before it, and the
    /// venue supplies what the last one is owed. Every token but SZR must net to nothing.
    function _buyCycle(bytes32 poolId, Plan calldata plan) internal returns (uint256 profit) {
        address asset = tracked[poolId].partner;
        (uint256 owed, uint256 bought) =
            _trade(keys[poolId], asset, -int256(plan.spend), plan.limit);
        for (uint256 hop; hop < 2; hop++) {
            if (plan.links[hop] == bytes32(0)) break;
            PoolKey memory link = keys[plan.links[hop]];
            owed = _exactOutput(link, asset, owed);
            _requireSettled(asset);
            asset = _other(link, asset);
        }
        uint256 sold = plan.venue == bytes32(0)
            ? _redeem(owed)
            : _exactOutput(keys[plan.venue], asset, owed);
        _requireSettled(asset);
        profit = bought - sold;
    }

    /// @dev Sells SZR in the pool down to the price limit, then carries the proceeds forward
    /// with exact inputs until they are SZR again.
    function _sellCycle(bytes32 poolId, Plan calldata plan) internal returns (uint256 profit) {
        address asset = tracked[poolId].partner;
        (uint256 sold, uint256 held) =
            _trade(keys[poolId], home, -int256(plan.spend), plan.limit);
        for (uint256 hop; hop < 2; hop++) {
            if (plan.links[hop] == bytes32(0)) break;
            PoolKey memory link = keys[plan.links[hop]];
            held = _exactInput(link, asset, held);
            _requireSettled(asset);
            asset = _other(link, asset);
        }
        uint256 bought = _exactInput(keys[plan.venue], asset, held);
        _requireSettled(asset);
        profit = bought - sold;
    }

    function _other(PoolKey memory pool, address asset) internal pure returns (address) {
        bool first = Currency.unwrap(pool.currency0) == asset;
        return Currency.unwrap(first ? pool.currency1 : pool.currency0);
    }

    /// @dev Redeems just enough SZR at NAV to cover the WETH owed. Rounding can return a
    /// few wei more than owed; that excess is given up to the pool manager.
    function _redeem(uint256 owed) internal returns (uint256 amount) {
        amount = FixedPointMathLib.fullMulDivUp(owed, core.activeSupply(), core.backingAmount());
        poolManager.take(Currency.wrap(token), address(this), amount);
        uint256 received = core.redeem(amount, owed);
        poolManager.sync(Currency.wrap(backingAsset));
        SafeTransferLib.safeTransfer(backingAsset, address(poolManager), received);
        if (poolManager.settle() != received) revert InvalidDelta();
        if (received != owed) poolManager.clear(Currency.wrap(backingAsset), received - owed);
    }

    function _exactInput(PoolKey memory pool, address input, uint256 amount)
        internal
        returns (uint256 received)
    {
        uint256 spent;
        (spent, received) = _trade(pool, input, -int256(amount), 0);
        if (spent != amount) revert Incomplete();
    }

    function _exactOutput(PoolKey memory pool, address output, uint256 amount)
        internal
        returns (uint256 spent)
    {
        uint256 received;
        (spent, received) = _trade(pool, _other(pool, output), int256(amount), 0);
        if (received != amount) revert Incomplete();
    }

    /// @dev `amount` follows v4: negative is an exact input, positive an exact output.
    /// A zero `limit` means no price limit.
    function _trade(PoolKey memory pool, address input, int256 amount, uint160 limit)
        internal
        returns (uint256 spent, uint256 received)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        if (limit == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        BalanceDelta delta =
            poolManager.swap(pool, IPoolManager.SwapParams(zeroForOne, amount, limit), "");
        int128 paid = zeroForOne ? delta.amount0() : delta.amount1();
        int128 got = zeroForOne ? delta.amount1() : delta.amount0();
        if (paid > 0) revert InvalidDelta();
        if (got < 0) revert InvalidDelta();
        spent = uint256(-int256(paid));
        received = uint256(int256(got));
    }

    function _requireSettled(address asset) internal view {
        if (poolManager.currencyDelta(address(this), Currency.wrap(asset)) != 0) {
            revert Unsettled();
        }
    }

    /// @dev The venues one search prices, read in one call to the pool manager: the pool
    /// itself first, then the other leaders of its group, then the first leader of every
    /// other group, and Core last. Connecting pools are read when used.
    function _book(bytes32 poolId) internal view returns (Venue[] memory book) {
        bytes32[] memory ids = _venues(poolId, tracked[poolId].partner);
        uint256 count = ids.length;
        // Only SZR's market can redeem at Core.
        bool redeemable = active == SZR_MARKET;
        book = new Venue[](redeemable ? count + 1 : count);
        bytes32[] memory slots = new bytes32[](count);
        for (uint256 index; index < count; index++) {
            Tracked memory entry = tracked[ids[index]];
            book[index].id = ids[index];
            book[index].partner = entry.partner;
            book[index].fixedKeep = entry.keep;
            slots[index] = StateLibrary._getPoolStateSlot(PoolId.wrap(ids[index]));
        }
        bytes32[] memory words = poolManager.extsload(slots);
        for (uint256 index; index < count; index++) {
            _price(book[index], words[index]);
        }
        if (!redeemable) return book;
        book[count].partner = backingAsset;
        _requote(book[count]);
    }

    function _venues(bytes32 poolId, address partner)
        internal
        view
        returns (bytes32[] memory ids)
    {
        bytes32[] memory found = new bytes32[](MAX_LEADERS + MAX_GROUPS);
        found[0] = poolId;
        uint256 count = 1;
        bytes32[] storage own = leaders[active][partner];
        address[] storage groups = markets[active].groups;
        for (uint256 index; index < own.length; index++) {
            if (own[index] == poolId) continue;
            found[count++] = own[index];
        }
        for (uint256 index; index < groups.length; index++) {
            if (groups[index] == partner) continue;
            found[count++] = leaders[active][groups[index]][0];
        }
        ids = new bytes32[](count);
        for (uint256 index; index < count; index++) {
            ids[index] = found[index];
        }
    }

    function _requote(Venue memory venue) internal view {
        if (venue.id == bytes32(0)) {
            (venue.rate, venue.keep) = _redeemQuote();
            return;
        }
        _price(
            venue, poolManager.extsload(StateLibrary._getPoolStateSlot(PoolId.wrap(venue.id)))
        );
    }

    /// @dev Fills in a venue's price and fee factor from its pool's first storage word.
    function _price(Venue memory venue, bytes32 word) internal view {
        uint24 fee;
        uint24 levy;
        (venue.rate, fee, levy) = _unpack(word, home < venue.partner);
        // The stored factor covers the pool's own fee only.
        if (levy == 0) {
            if (venue.fixedKeep != 0) {
                venue.keep = venue.fixedKeep;
                return;
            }
        }
        venue.keep = _keep(_swapFee(fee, levy));
    }

    /// @dev Prices every other venue against the focus pool and keeps the cycle expected
    /// to return the most. The profit check in `execute` decides.
    function _best(Venue[] memory book, uint256 index)
        internal
        view
        returns (Plan memory best)
    {
        Venue memory own = book[index];
        if (own.rate == 0) return best;
        Focus memory focus;
        focus.id = own.id;
        focus.partner = own.partner;
        focus.rate = own.rate;
        focus.keep = own.keep;
        focus.seen = new address[](book.length);
        focus.routes = new Route[](book.length);
        for (uint256 other; other < book.length; other++) {
            if (other == index) continue;
            _consider(best, focus, book[other], other);
        }
    }

    function _consider(Plan memory best, Focus memory focus, Venue memory venue, uint256 index)
        internal
        view
    {
        Route memory route = _routeFrom(focus, venue.partner);
        // No way across between the two partner tokens.
        if (route.rate == 0) return;
        if (route.rate > MAX_ROUTE_RATE) return;
        uint256 rate = venue.rate;
        if (route.links[0] != bytes32(0)) {
            rate = FixedPointMathLib.fullMulDiv(rate, route.rate, Q96);
        }
        uint256 keep = venue.keep * focus.keep / WAD * route.keep / WAD;
        if (rate == 0) return;
        if (rate > MAX_CYCLE_RATE) return;
        if (keep < MIN_CYCLE_KEEP) return;
        // Buying pays until the pool's price reaches what the venue pays, net of fees.
        // Selling pays until it falls to what the venue charges. At most one applies, and
        // usually neither does.
        uint256 target = FixedPointMathLib.fullMulDiv(rate, keep, WAD);
        bool buying = target > focus.rate;
        if (!buying) {
            target = FixedPointMathLib.fullMulDiv(rate, WAD, keep);
            if (target >= focus.rate) return;
        }
        uint256 edge = buying
            ? FixedPointMathLib.fullMulDiv(target, WAD, focus.rate)
            : FixedPointMathLib.fullMulDiv(focus.rate, WAD, target);
        if (edge < markets[active].minimumEdge) return;
        if (edge > MAX_EDGE) return;
        if (venue.id == bytes32(0)) {
            // Core only buys SZR back; it is never a place to buy it.
            if (!buying) return;
        }
        Plan memory candidate =
            Plan(edge - WAD, index, venue.id, route.links, 0, 0, 0, 0, buying, 0);
        _offer(best, focus, candidate, target, _cycleDepth(focus, venue, route));
    }

    function _routeFrom(Focus memory focus, address partner)
        internal
        view
        returns (Route memory route)
    {
        for (uint256 index; index < focus.known; index++) {
            if (focus.seen[index] == partner) return focus.routes[index];
        }
        route = _route(partner, focus.partner);
        focus.seen[focus.known] = partner;
        focus.routes[focus.known] = route;
        focus.known++;
    }

    /// @dev One connecting pool when there is one; otherwise two that meet at WETH.
    function _route(address from, address to) internal view returns (Route memory route) {
        route.rate = Q96;
        route.keep = WAD;
        if (from == to) return route;
        bytes32 direct = _connector(from, to);
        if (direct != bytes32(0)) {
            _hop(route, 0, direct, from < to);
            return route;
        }
        bytes32 near = _connector(backingAsset, to);
        bytes32 far = _connector(from, backingAsset);
        // A missing pool has no price, which leaves the route's rate at zero.
        _hop(route, 0, near, backingAsset < to);
        _hop(route, 1, far, from < backingAsset);
    }

    function _connector(address a, address b) internal view returns (bytes32) {
        return a < b ? connector[active][a][b] : connector[active][b][a];
    }

    function _hop(Route memory route, uint256 slot, bytes32 poolId, bool baseFirst)
        internal
        view
    {
        (uint256 rate, uint256 keep) = _quote(poolId, baseFirst);
        route.links[slot] = poolId;
        route.rates[slot] = rate;
        route.rate = FixedPointMathLib.fullMulDiv(route.rate, rate, Q96);
        route.keep = route.keep * keep / WAD;
    }

    /// @dev The SZR that closes a gap of 100% across every leg of the cycle together.
    function _cycleDepth(Focus memory focus, Venue memory venue, Route memory route)
        internal
        view
        returns (uint256 depth)
    {
        if (focus.depth == 0) focus.depth = _depth(focus.id, focus.rate, focus.rate);
        depth = focus.depth;
        if (venue.id != bytes32(0)) {
            depth = _harmonic(depth, _depth(venue.id, venue.rate, venue.rate));
        }
        if (route.links[0] == bytes32(0)) return depth;
        if (!route.sized) {
            route.depth = _routeDepth(focus.rate, route);
            route.sized = true;
        }
        depth = _harmonic(depth, route.depth);
    }

    function _routeDepth(uint256 flow, Route memory route)
        internal
        view
        returns (uint256 depth)
    {
        // `flow` is the price of SZR in each connecting pool's quote token, nearest first.
        depth = _depth(route.links[0], route.rates[0], flow);
        if (route.links[1] == bytes32(0)) return depth;
        flow = FixedPointMathLib.fullMulDiv(flow, Q96, route.rates[0]);
        depth = _harmonic(depth, _depth(route.links[1], route.rates[1], flow));
    }

    /// @dev `candidate.gap` is how far the square-root prices are apart beyond fees, as a
    /// share (WAD). `depth` is the SZR that closes a gap of 100%
    /// across every leg together, so the gap times the depth is the SZR to trade and the
    /// gap times that again is the profit. The focus pool is moved only its own share of
    /// the way to `target`; the other legs move the rest.
    /// ponytail: straight-line estimate from each pool's liquidity at its current price.
    /// It is wrong once a leg crosses into a different range; `_attempt` retries halfway.
    function _offer(
        Plan memory best,
        Focus memory focus,
        Plan memory candidate,
        uint256 target,
        uint256 depth
    ) internal view {
        if (depth == 0) return;
        uint256 gap = candidate.gap;
        uint256 score = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(gap, gap, WAD), depth, WAD
        );
        if (score == 0) return;
        if (score < markets[active].minimumProfit) return;
        if (score <= best.score) return;
        Bench memory bench = benched[_pair(focus.id, candidate.venue, candidate.buying)];
        if (block.timestamp < bench.until) {
            if (gap / BENCH_ESCAPE < bench.gap) return;
        }
        uint256 share = FixedPointMathLib.fullMulDiv(depth, WAD, focus.depth);
        uint256 stop = candidate.buying
            ? focus.rate + FixedPointMathLib.fullMulDiv(target - focus.rate, share, WAD)
            : focus.rate - FixedPointMathLib.fullMulDiv(focus.rate - target, share, WAD);
        best.gap = gap;
        best.index = candidate.index;
        best.venue = candidate.venue;
        best.links = candidate.links;
        best.limit = _limit(focus, stop);
        best.full = _limit(focus, target);
        // What the trade should take: the gap times the depth of the whole cycle for the
        // estimate, and times the focus pool's own depth for closing the gap there alone.
        best.spend =
            _spend(focus, candidate.buying, FixedPointMathLib.fullMulDiv(gap, depth, WAD));
        best.fullSpend = _spend(
            focus, candidate.buying, FixedPointMathLib.fullMulDiv(gap, focus.depth, WAD)
        );
        best.buying = candidate.buying;
        best.score = score;
    }

    /// @dev The most the first leg may pay in for a trade of `amount` SZR, with a quarter
    /// to spare, in the token it pays with: SZR when selling, the partner token (at the
    /// pool's current price) when buying.
    function _spend(Focus memory focus, bool buying, uint256 amount)
        internal
        pure
        returns (uint256 spend)
    {
        uint256 most = uint256(uint128(type(int128).max));
        spend = amount > most ? most : amount + amount / 4 + 1;
        if (!buying) return spend > most ? most : spend;
        spend = FixedPointMathLib.fullMulDiv(spend, focus.rate, Q96);
        spend = spend > most ? most : FixedPointMathLib.fullMulDiv(spend, focus.rate, Q96) + 1;
        if (spend > most) spend = most;
    }

    /// @dev The focus pool's price limit for a square-root price in partner per SZR.
    function _limit(Focus memory focus, uint256 rate) internal view returns (uint160) {
        uint256 limit = home < focus.partner ? rate : Q192 / rate;
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit >= TickMath.MAX_SQRT_PRICE) limit = TickMath.MAX_SQRT_PRICE - 1;
        return uint160(limit);
    }

    /// @dev The amount of SZR that moves a pool's square-root price by its own size, capped
    /// at `MAX_DEPTH`. `rate` is the pool's square-root price (quote per base). `flow` is
    /// the square-root price of SZR in the pool's quote token; for an SZR pool the two are
    /// the same. A `flow` outside the band means the route has no usable price.
    function _depth(bytes32 poolId, uint256 rate, uint256 flow)
        internal
        view
        returns (uint256)
    {
        if (flow < MIN_RATE) return 0;
        if (flow > MAX_RATE) return 0;
        uint256 units = poolManager.getLiquidity(PoolId.wrap(poolId));
        uint256 scaled = FixedPointMathLib.fullMulDiv(units, rate, flow);
        if (scaled >= FixedPointMathLib.fullMulDiv(MAX_DEPTH, flow, Q96)) return MAX_DEPTH;
        return FixedPointMathLib.fullMulDiv(scaled, Q96, flow);
    }

    /// @dev Depths in a chain combine like resistors in parallel. An empty leg gives zero.
    function _harmonic(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        if (b == 0) return 0;
        return FixedPointMathLib.fullMulDiv(a, b, a + b);
    }

    /// @dev Square-root price of the quote token per base token, and the square root of the
    /// share of a trade the pool's fees leave. Zero for a pool that does not exist.
    function _quote(bytes32 poolId, bool baseFirst)
        internal
        view
        returns (uint256 rate, uint256 keep)
    {
        uint24 fee;
        uint24 levy;
        (rate, fee, levy) = _rate(poolId, baseFirst);
        keep = _keep(_swapFee(fee, levy));
    }

    /// @dev `fee` is the pool's own fee and `levy` the pool manager's protocol fee, both as
    /// the pool manager stores them.
    function _rate(bytes32 poolId, bool baseFirst)
        internal
        view
        returns (uint256 rate, uint24 fee, uint24 levy)
    {
        bytes32 slot = StateLibrary._getPoolStateSlot(PoolId.wrap(poolId));
        return _unpack(poolManager.extsload(slot), baseFirst);
    }

    /// @dev A pool's first storage word holds, from the low end: the square-root price (160
    /// bits), the tick (24), the protocol fee (24) and the pool's own fee (24).
    function _unpack(bytes32 word, bool baseFirst)
        internal
        pure
        returns (uint256 rate, uint24 fee, uint24 levy)
    {
        uint256 packed = uint256(word);
        uint256 price = uint160(packed);
        levy = uint24(packed >> 184);
        fee = uint24(packed >> 208);
        if (price == 0) return (0, fee, levy);
        rate = baseFirst ? price : Q192 / price;
        if (rate < MIN_RATE) return (0, fee, levy);
        if (rate > MAX_RATE) return (0, fee, levy);
    }

    /// @dev What a swap pays in all, as v4 combines the two fees. The protocol fee is set
    /// separately for each direction; the larger is used for both, which can only make a
    /// cycle look slightly less profitable than it is.
    function _swapFee(uint24 fee, uint24 levy) internal pure returns (uint24) {
        if (levy == 0) return fee;
        uint256 forward = levy & 0xFFF;
        uint256 backward = levy >> 12;
        uint256 larger = forward > backward ? forward : backward;
        return uint24(larger + fee - larger * fee / 1e6);
    }

    function _keep(uint24 fee) internal pure returns (uint256) {
        if (fee >= 1e6) return 0;
        return FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
    }

    /// @dev Core pays exactly NAV in WETH per SZR and takes no fee.
    function _redeemQuote() internal view returns (uint256 rate, uint256 keep) {
        uint256 nav = core.NAV();
        // Beyond this the conversion below would overflow; no real NAV comes close.
        if (nav > type(uint64).max) return (0, 0);
        rate = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(nav, Q192, WAD));
        keep = WAD;
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
