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
import { TickBitmap } from "v4-core/libraries/TickBitmap.sol";
import { BitMath } from "v4-core/libraries/BitMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { SwapMath } from "v4-core/libraries/SwapMath.sol";
import { LiquidityMath } from "v4-core/libraries/LiquidityMath.sol";
import { ProtocolFeeLibrary } from "v4-core/libraries/ProtocolFeeLibrary.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { SzrCore } from "./SzrCore.sol";
import { Liquidity } from "./Liquidity.sol";
import { IVenuePricer } from "./interfaces/IVenuePricer.sol";

/// @dev Only the WETH calls the ETH payout and the wrap link need.
interface IWrapped {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @dev Read raw by `_funded`, so a failed read can be told from a shortage.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice One hook shared by every pool created with it. Around each swap it closes
/// price gaps between that pool and the other pools of its market. SZR's market retires
/// the SZR it earns. Anyone can open a market for their own token; it counts profit in
/// tokens its owner chose from the ones Liquidity's manager approved (native ETH included,
/// which is paid out as WETH), `PROTOCOL_SHARE` percent to the protocol and the rest to the
/// market.
/// @dev "SZR" below stands for the profit token of the search being run: SZR in SZR's
/// market, one of the market's chosen tokens in every other.
/// @dev A pool on a hook that Liquidity's manager has given a pricer (a wrapped pool, one
/// that fills trades somewhere other than the pool manager) can be a venue or connecting
/// pool. Markets that use one reserve more gas, and each cycle is checked for leaving
/// nothing owed.
/// @dev `arb` searches one pool without a swap and `sweep` searches the head of every group
/// of a market, which reaches the hookless pools `arb` cannot name in outside markets.
/// @dev Pools are grouped by partner token, and each group has a few leaders. A swap's pool
/// is compared with the leaders of its own group, the first leader of every other group,
/// and Core, so the cost of a search does not grow with the number of pools tracked.
/// @dev It searches twice per swap. Before the swap trades it closes any gap already open,
/// so the swap executes at the aligned price and cannot collect that gap. After the swap it
/// closes the gap the swap itself opened.
/// @dev A cycle starts and ends in SZR: sell SZR at one venue, cross up to two connecting
/// pools, buy SZR back at another. One of the two venues is always the pool being searched.
/// Core's `redeem` is a sell-only venue paying NAV in WETH, in SZR's market only. v4 flash
/// accounting funds every cycle, so the hook holds no balance between transactions; profit
/// goes to `donateSzr` in SZR's market and is paid out in the other markets.
/// @dev In a market that counts in ETH or WETH, a cycle can also cross between the two
/// through the wrap link, a one-for-one deposit or withdraw of WETH, and a venue can be a
/// pool on the other ether token. The search reads the groups under both tokens, and a
/// cycle that ends on a venue holding the twin converts at the end so it still ends in the
/// token counted.
/// @dev A failed or unprofitable attempt reverts inside a caught self-call and does not fail
/// the swap that triggered it. Running out of gas is the exception: a swap sent with too
/// little gas for any cycle reverts as a whole, so gas estimates include the cycles. Once a
/// cycle has succeeded the search holds gas back and stops early instead. The other
/// exception is a pool manager short of a token the hook must take before a swap: whoever
/// controls the current unlock can borrow its whole balance, so the swap reverts with
/// `Drained` rather than letting that skip a gap. After a swap a shortage is not proof of a
/// drain (the swapper's own input may be owed and not yet paid), so that search is undone
/// and the swap goes on. The drain rule has a known limit. Any debit left unpaid earlier in
/// the same unlock (a multi-hop route, two swaps settled together at the end, an
/// exact-output route, adding liquidity and then swapping) can make the pool manager look
/// short before a later swap. Such a swap must pay first or be split. In that state more
/// gas can fail a swap that less gas passes, because a search with more gas reaches a
/// further cycle that meets the shortage. So "more gas never makes a swap fail" holds when
/// nothing earlier in the unlock is unpaid.
/// v4 skips hook callbacks for the hook's own swaps.
contract ArbitrageHook is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

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
    /// amount once and is then set aside. A market that uses wrapped pools gets twice this
    /// per cycle (`_plan`), since their legs cost far more.
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
    /// @dev How many failed cycles the search before a swap is given the gas to get past
    /// while it still has no profit. `_required` keeps closing a gap required through one
    /// more try than this (three in all), so that a swap with a gap open and too little gas
    /// for that fails. If one failing cycle were enough to end it, anyone able to stage one
    /// could make the search stand aside and take the gap it was about to close.
    uint256 internal constant FAILURES_COVERED = 2;
    /// @dev What the worst failed cycle costs beyond its plan: the sync slot, the cold reads of
    /// its legs, the bench and the tries' own bookkeeping. Measured at about 65k.
    uint256 internal constant OVERHEAD_GAS = 70_000;
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
    /// @dev The most boundary events (a tick crossed, or an empty word passed) one sizing
    /// walk follows, across all its legs together. Reaching it stops the walk where it is,
    /// which under-trades. See `size`.
    uint256 internal constant SIZING_STEPS = 8;
    /// @dev The gas the sizing walk is given. It lets every measured route reach
    /// `SIZING_STEPS` except dust at every tick, which stops for gas a step or two short (see
    /// `docs/specs/hook-exact-sizing.md`). The walk stops when it cannot afford another step
    /// (see `SIZING_STEP_GAS`), so a walk that would need more returns the size it has found
    /// so far instead of running out.
    uint256 internal constant SIZING_GAS = 240_000;
    /// @dev What one more step of the walk may cost per leg, and what is held back for the
    /// answer after the last one. Measured at about 20k for a step with two legs and 28k to 33k
    /// with three, and rounded up. The walk stops before a step it cannot afford.
    uint256 internal constant SIZING_STEP_GAS = 12_000;
    uint256 internal constant SIZING_TAIL_GAS = 5_000;
    /// @dev What `_size` charges beyond the gas the walk's call is given: encoding the call,
    /// making it, decoding the answer and working out the gas. Measured at about 5.4k warm, and
    /// rounded up for cold reads. It is held back from the cap on the walk's gas, so that even
    /// a walk that spends all it is given leaves the first try a full share.
    uint256 internal constant SIZING_CALL_GAS = 10_000;
    /// @dev Every size the walk answers is held back by this share of the whole cycle input
    /// plus a few wei, so that every leg really fills whatever rounding the crossings left.
    uint256 internal constant SIZING_SHAVE = 1_000_000;
    uint256 internal constant SIZING_WEI = 16;
    /// @dev How far above the smallest profit a cycle's estimate must be to be tried, in
    /// percent.
    uint256 internal constant PLAN_MARGIN = 125;
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
    /// @dev A reserved link id for converting between ETH and WETH one for one. It is no
    /// pool: it has rate `Q96`, keep `WAD` and depth `MAX_DEPTH`, and reads no storage.
    bytes32 internal constant WRAP = bytes32(uint256(1));
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;
    address internal constant UNRELEASED = address(1);
    /// @dev Where remembered venues are kept in transient storage, four words each.
    uint256 internal constant REMEMBER_SLOT = uint256(keccak256("ArbitrageHook.remembered"));
    /// @dev Gas that must be left, per venue, for remembering them to be worth starting.
    uint256 internal constant REMEMBER_GAS = 2_000;
    /// @dev `minimumEdge` is stored in these units: a thousandth of a millionth of a
    /// millionth of the price, far finer than any gap worth acting on.
    uint256 internal constant EDGE_UNIT = 1_000;
    /// @dev The gas a pricer is given for one answer is set by each market's owner, in
    /// these units, and starts at `ASK_DEFAULT` of them. Asking also costs the lookups
    /// around the call. A market that uses pools priced this way has both reserved for
    /// every place a price is asked for: once per venue when the venues are read; five
    /// times per venue when they are ranked (its own liquidity, and the price and
    /// liquidity of up to two connecting pools on the way to it); and twice after a
    /// cycle, for the two pools it moved. The sizing walk asks once per wrapped leg of the
    /// cycle too, inside gas that `_sizingGas` caps at half of what the cycle's tries share.
    uint256 internal constant ASK_UNIT = 4_000;
    uint8 internal constant ASK_DEFAULT = 5;
    uint256 internal constant ASK_OVERHEAD = 16_000;
    uint160 internal constant PERMISSION_MASK = (1 << 14) - 1;
    /// @dev The beforeSwap and afterSwap permission bits, and no others.
    uint160 internal constant SWAP_HOOKS = (1 << 7) | (1 << 6);

    /// @dev One place SZR trades, read once per search: its partner token, its square-root
    /// price in partner per SZR (Q96), and the square root of the share of a trade its fee
    /// leaves (WAD). The last entry of a book is Core redemption, with a zero `id`. `twins`
    /// is used by a book's first entry only: the place of the first venue that holds the
    /// other ether token than the one the search counts in (read last), or zero for none.
    struct Venue {
        bytes32 id;
        address partner;
        uint256 rate;
        uint256 keep;
        uint256 twins;
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
        uint256 edge;
        address[] seen;
        Route[] routes;
        uint256 known;
    }

    /// @dev `gap` is how far apart the prices were, beyond fees, when the cycle failed.
    struct Bench {
        uint64 until;
        uint192 gap;
    }

    /// @dev A pool on this hook. `origin` is the market it was created in and never
    /// changes; `market` is the market searching it now, zero while it is untracked.
    /// `home` is the token its searches count profit in, chosen when it is tracked. Zero is
    /// native ETH, so `picked` says whether there is one at all; a pool with none is never
    /// searched.
    struct Pool {
        uint32 origin;
        uint32 market;
        address home;
        bool picked;
    }

    /// @notice One owner's pools and settings. A search never looks outside the market of
    /// the pool that traded.
    /// @dev `gasLimit` is the gas given to each search; zero switches the market off.
    /// `minimumEdge` is the smallest gap worth an attempt, in square-root price terms (WAD).
    /// `pricerGas` is the gas a pricer gets for one answer, and is zero until the market
    /// uses a pool priced by one. SZR's market has no stored owner: it belongs to
    /// Liquidity's manager.
    struct Market {
        address owner;
        uint32 gasLimit;
        uint64 minimumEdge;
        address recipient;
        uint64 poolCount;
        address nominee;
        uint32 pricerGas;
    }

    /// @dev A market as it is stored. What a swap reads is in the first word: `edge` is
    /// `minimumEdge` in units of `EDGE_UNIT` and `ask` is `pricerGas` in units of
    /// `ASK_UNIT`, which lets both sit beside the gas allowance.
    struct Settings {
        address owner;
        uint32 gasLimit;
        uint56 edge;
        uint8 ask;
        address recipient;
        uint64 poolCount;
        address nominee;
    }

    /// @dev The way from a venue's partner token to the focus pool's partner token: no pool
    /// when they are the same, one connecting pool, or two that meet at WETH. A link may be
    /// `WRAP`, the free conversion between ETH and WETH, alone or beside one connecting pool.
    /// `links[0]` is the pool nearest the focus pool. `rate` and `keep` are the pools'
    /// combined; a zero `rate` means there is no way across. `depth` is the connecting
    /// pools' combined depth, read once a cycle needs it.
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

    /// @dev One leg of a cycle as the sizing walk sees it, in the order value flows. `id` is
    /// zero for Core redemption, which has no state. `rate` is the leg's marginal rate at
    /// size zero as a Q96 square root, fee included, and `depth` its depth in input units;
    /// `depthIn` is the depth of all the legs before it, and `flowIn` the most they can ever
    /// supply. `reach` is the gross
    /// input that takes the leg to `target`, the price of tick `next`, and `beyond` the
    /// liquidity past it. `limit` is the price the real trade is given as its limit (zero for
    /// none, as for Core), and `edge` marks a `target` that is that limit or the end of the
    /// tick range: the end of the leg. `broken` marks a boundary that could not be read.
    struct Leg {
        bytes32 id;
        bool zeroForOne;
        bool initialized;
        bool edge;
        bool broken;
        bool wrapped;
        int24 spacing;
        int24 tick;
        int24 next;
        uint24 fee;
        uint128 liquidity;
        uint128 beyond;
        uint160 price;
        uint160 target;
        uint160 limit;
        uint256 keep;
        uint256 rate;
        uint256 depth;
        uint256 depthIn;
        uint256 flowIn;
        uint256 reach;
    }

    /// @dev What a sizing walk has found so far: the cycle input, the input of the focus
    /// pool, and the profit it is expected to make. `stopped` is set when it stopped short
    /// of the optimum, at its cap on boundary events or for want of gas.
    struct Walk {
        uint256 total;
        uint256 focusIn;
        int256 predicted;
        uint256 steps;
        bool stopped;
    }

    IPoolManager public immutable poolManager;
    Liquidity public immutable liquidity;
    SzrCore public immutable core;
    address public immutable token;
    address public immutable backingAsset;

    /// @notice SZR's own market, the first one. Its profit token is always SZR, it alone
    /// has Core redemption as a venue, and it retires its profit instead of paying it out.
    uint256 public constant SZR_MARKET = 1;
    /// @notice The share of every other market's profit that goes to the protocol, in
    /// percent. The rest goes to the market's own recipient, in the same token.
    uint256 public constant PROTOCOL_SHARE = 30;
    uint256 public constant MAX_PROFIT_TOKENS = 8;
    /// @notice Where the protocol's share of profit counted in `asset` is sent. Zero means
    /// the token is not approved. A market's owner prices their own token, so profit is only
    /// ever counted in an approved one, which Liquidity's manager chooses.
    mapping(address asset => address recipient) public shareRecipient;
    /// @dev The tokens each market other than SZR's has chosen, most preferred first, and
    /// each one's place in that order from one (zero means not chosen).
    mapping(uint256 market => address[]) internal chosen;
    mapping(uint256 market => mapping(address asset => uint8)) internal rankIn;
    /// @notice How many markets exist. Their ids run from one.
    uint256 public marketCount = 1;
    mapping(uint256 id => Settings) internal markets;
    /// @notice The pricer for pools on a hook that fills their trades somewhere other than
    /// the pool manager. Set by Liquidity's manager; none are set at launch. A hook with a
    /// pricer is trusted to run in the middle of a cycle, so only a hook whose code cannot
    /// change, and that is known to do no more than trade, should ever be given one.
    mapping(address wrapper => address pricer) public pricers;
    /// @dev The hook of each such pool a market has added, by pool.
    mapping(bytes32 poolId => address wrapper) internal wrappers;
    /// @notice The smallest profit a cycle must return, for each token a market counts
    /// profit in, in that token's own units.
    mapping(uint256 market => mapping(address base => uint128)) public minimumProfit;
    /// @dev The market being searched, and the token this search counts profit in. Set
    /// while a search runs, so a swap made by some other hook in the middle of a cycle
    /// cannot start a second search inside the first.
    uint256 internal transient active;
    address internal transient home;
    /// @dev The pool whose venues' prices the search before its swap has left in transient
    /// storage for the search after it. Nothing else can run between the two, and the
    /// swap itself only moves that pool, so they are still right; see `_remember`.
    bytes32 internal transient remembered;
    /// @dev Set once a try at a cycle has used up its whole share of gas. For the rest of
    /// that search, cycles are tried at their smallest size only.
    bool internal transient strained;
    /// @dev The gas a pricer gets for one answer in the market being searched; zero when
    /// that market uses no pool priced by one. Written at the start of every search, so it
    /// never carries over from one to the next.
    uint256 internal transient asking;
    /// @dev For each token a market counts profit in, the partner tokens that have leaders.
    mapping(uint256 market => mapping(address base => address[] partners)) internal groups;
    /// @dev Each group's leaders: its deepest pools, in the owner's order. The first is
    /// the one other groups are compared against. A hookless pool can lead; it is then
    /// only ever a venue.
    mapping(
        uint256 market => mapping(address base => mapping(address partner => bytes32[]))
    ) internal leaders;
    /// @dev The first leader of each group again, where a search reads it in one step.
    mapping(uint256 market => mapping(address base => mapping(address partner => bytes32)))
        internal heads;
    mapping(bytes32 poolId => PoolKey) internal keys;
    mapping(bytes32 poolId => Pool) internal pools;
    /// @notice Whether a market prices a pool. A hookless pool can be in several markets.
    mapping(uint256 market => mapping(bytes32 poolId => bool)) public tracked;
    /// @dev A cycle between a focus pool and a venue that failed is not tried again until
    /// `until`, unless the gap has grown well beyond the one that failed. Keyed by the
    /// market, the profit token, the pair and the direction, so a broken pool only sets
    /// aside its own cycles and one market cannot set aside another's.
    mapping(bytes32 pair => Bench) internal benched;
    /// @dev Tokens a market can end up trading: both sides of every pool it ever tracked
    /// and of every connecting pool it ever set.
    mapping(uint256 market => mapping(address asset => bool)) internal traded;
    /// @notice The pool a market uses to convert between two partner tokens, keyed lower
    /// address first.
    mapping(uint256 market => mapping(address lower => mapping(address higher => bytes32)))
        public connector;

    error InvalidHookAddress();
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
    error Unsizable();
    error Starved();
    error InsufficientGas();
    error Drained();
    error TooManyMarkets();
    error NotTrusted();

    event MarketOpened(uint256 indexed market, address indexed owner);
    event OwnerNominated(uint256 indexed market, address indexed nominee);
    event OwnerSet(uint256 indexed market, address indexed owner);
    event RecipientSet(uint256 indexed market, address recipient);
    event ProfitTokenSet(address indexed asset, address recipient);
    event TokensSet(uint256 indexed market, address[] assets);
    event PricerSet(address indexed wrapper, address indexed pricer);
    event PricerGasSet(uint256 indexed market, uint32 gas);
    /// @notice A market earned `amount` of `asset`, of which `protocolShare` went to the
    /// protocol and the rest to the market's recipient. Profit counted in native ETH
    /// (`asset` zero) was paid as WETH.
    event ProfitPaid(
        uint256 indexed market, address indexed asset, uint256 amount, uint256 protocolShare
    );
    /// @notice The protocol's share of `asset` could not be sent and is held for `recipient`
    /// as a claim with the pool manager.
    event ShareHeld(address indexed asset, address indexed recipient, uint256 amount);
    event PoolTracked(uint256 indexed market, bytes32 indexed poolId);
    event PoolUntracked(uint256 indexed market, bytes32 indexed poolId);
    event ConnectorSet(
        uint256 indexed market, address indexed lower, address indexed higher, bytes32 poolId
    );
    event LeadersSet(
        uint256 indexed market, address indexed base, address indexed partner, bytes32[] poolIds
    );
    event LimitsSet(
        uint256 indexed market,
        address indexed base,
        uint32 gasLimit,
        uint128 minimumProfit,
        uint64 minimumEdge
    );
    /// @notice A cycle that looked profitable failed at every size tried, or was declined:
    /// no size was tried because the sizing walk showed that none could clear the smallest
    /// profit. A venue that keeps appearing here is costing swappers gas and is a candidate
    /// for `untrack`.
    event CycleFailed(bytes32 indexed poolId, bytes32 indexed venue);
    /// @notice One size of a cycle used up its whole share of gas: a try that was given half
    /// the cycle's budget and spent all but a sixteenth of it. A try on the budget left over
    /// from earlier tries is never reported. Seen often for a pair, its cycles cost more than
    /// the hook allows, usually because of very many tick ranges on the way.
    event TryRanOut(bytes32 indexed poolId, bytes32 indexed venue);
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

    /// @dev Nothing is configured while a search is running: a token or a wrapped pool's
    /// hook runs in the middle of one, and could be its market's owner.
    modifier onlyOwner(uint256 id) {
        if (active != 0) revert Busy();
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
        Settings storage own = markets[SZR_MARKET];
        own.gasLimit = 8_000_000;
        own.edge = uint56(1.0001e18 / EDGE_UNIT);
        minimumProfit[SZR_MARKET][token] = 10e18;
        // WETH is the first token profit may be counted in. Core counts the protocol's
        // share of it as backing when anyone calls `absorbBacking`.
        shareRecipient[backingAsset] = address(core);
        emit ProfitTokenSet(backingAsset, address(core));
    }

    /// @notice Approves `asset` as a token profit may be counted in, with the address the
    /// protocol's share of it is sent to, or changes that address. A zero `recipient` takes
    /// it off: it stops being paid out at once, and pools counting in it are not
    /// arbitraged until it is approved (and chosen) again; nothing needs re-tracking.
    /// @dev Core can only count WETH, so any other token needs a recipient of its own.
    /// Native ETH (`address(0)`) is the exception: its share is paid out as WETH, so Core
    /// can be its recipient. ETH and WETH are approved separately, and taking WETH off does
    /// not stop ETH profit, which is still paid as WETH.
    /// @dev Never approve a token that calls its receiver on transfer: paying it out would
    /// run that receiver's code in the middle of a search. Never approve a token whose
    /// balances can fall on their own (rebasing, fee on transfer): the pool manager would
    /// look drained, and swaps that close a gap in it would fail.
    function setProfitToken(address asset, address recipient) external onlyOwner(SZR_MARKET) {
        // SZR is counted only in its own market.
        if (asset == token) revert InvalidPool();
        if (recipient == address(this)) revert InvalidPool();
        // Credits to the pool manager itself would be surplus nobody can claim.
        if (recipient == address(poolManager)) revert InvalidPool();
        // Core can only count WETH, so any other token sent to it would be locked there.
        if (recipient == address(core)) {
            if (asset != address(0)) {
                if (asset != backingAsset) revert InvalidPool();
            }
        }
        shareRecipient[asset] = recipient;
        emit ProfitTokenSet(asset, recipient);
    }

    /// @notice Replaces the tokens a market counts profit in, most preferred first. Each
    /// must be approved now. A pool keeps the token picked when it was tracked; a token
    /// dropped here idles its pools until it is chosen again.
    function setTokens(uint256 id, address[] calldata assets) external onlyOwner(id) {
        if (id == SZR_MARKET) revert InvalidPool();
        if (assets.length > MAX_PROFIT_TOKENS) revert InvalidLimit();
        address[] storage old = chosen[id];
        for (uint256 index; index < old.length; index++) {
            delete rankIn[id][old[index]];
        }
        delete chosen[id];
        for (uint256 index; index < assets.length; index++) {
            address asset = assets[index];
            if (shareRecipient[asset] == address(0)) revert InvalidPool();
            if (rankIn[id][asset] != 0) revert InvalidPool();
            rankIn[id][asset] = uint8(index + 1);
            chosen[id].push(asset);
        }
        _requireWorkable(id, markets[id].gasLimit);
        emit TokensSet(id, assets);
    }

    function tokensOf(uint256 id) external view returns (address[] memory) {
        return chosen[id];
    }

    /// @notice Opens a market owned by the caller. Anyone can. It starts switched off;
    /// create its pools, name leaders, then call `setLimits`.
    /// @dev Every cycle in it starts and ends in a token it has chosen (WETH to begin with),
    /// so its profit is counted on balances in a token its owner cannot price, and the hook
    /// holds nothing between transactions.
    function openMarket(address recipient) external returns (uint256 id) {
        _requireRecipient(recipient);
        id = ++marketCount;
        // A pool records its market in 32 bits.
        if (id > type(uint32).max) revert TooManyMarkets();
        Settings storage own = markets[id];
        own.owner = msg.sender;
        own.recipient = recipient;
        own.edge = uint56(1.0001e18 / EDGE_UNIT);
        // Chosen whether or not WETH is approved at this moment.
        chosen[id].push(backingAsset);
        rankIn[id][backingAsset] = 1;
        emit MarketOpened(id, msg.sender);
    }

    /// @dev Anything paid to the hook itself would be stuck in it.
    function _requireRecipient(address recipient) internal view {
        if (recipient == address(0)) revert InvalidPool();
        if (recipient == address(this)) revert InvalidPool();
        if (recipient == address(poolManager)) revert InvalidPool();
    }

    function setRecipient(uint256 id, address recipient) external onlyOwner(id) {
        _requireRecipient(recipient);
        markets[id].recipient = recipient;
        emit RecipientSet(id, recipient);
    }

    /// @notice Names the address that may take a market over. SZR's market always belongs
    /// to Liquidity's manager.
    function nominateOwner(uint256 id, address nominee) external onlyOwner(id) {
        if (id == SZR_MARKET) revert InvalidPool();
        markets[id].nominee = nominee;
        emit OwnerNominated(id, nominee);
    }

    function acceptOwnership(uint256 id) external {
        if (active != 0) revert Busy();
        Settings storage own = markets[id];
        if (own.nominee == address(0)) revert NotManager();
        if (msg.sender != own.nominee) revert NotManager();
        own.owner = msg.sender;
        own.nominee = address(0);
        emit OwnerSet(id, msg.sender);
    }

    /// @notice Creates a pool on this hook and adds it to the caller's market. This is the
    /// only way a pool on this hook joins a market other than SZR's, so nobody can claim a
    /// pool someone else created.
    function createPool(uint256 id, PoolKey calldata pool, uint160 sqrtPriceX96)
        external
        onlyOwner(id)
    {
        if (id == SZR_MARKET) revert InvalidPool();
        if (address(pool.hooks) != address(this)) revert InvalidPool();
        // A dynamic-fee pool takes its fee from its hook, and this hook never sets one, so
        // such a pool on this hook would trade for nothing for ever.
        if (pool.fee >= 1e6) revert InvalidPool();
        _requireOutside(pool);
        poolManager.initialize(pool, sqrtPriceX96);
        bytes32 poolId = PoolId.unwrap(pool.toId());
        (address pick, bool picked) = _pick(id, pool);
        pools[poolId] = Pool(uint32(id), uint32(id), pick, picked);
        _track(id, pool, poolId);
    }

    /// @notice Adds a pool to trade against to the caller's market: one that runs no hook,
    /// or one on a hook that has a pricer. Any market can add the same one; it is never
    /// searched on its own swaps.
    /// @dev SZR's own pools come from Liquidity. The one kind added here is a pool holding
    /// SZR on a hook with a pricer, for SZR that trades on another exchange.
    function addVenue(uint256 id, PoolKey calldata pool) external onlyOwner(id) {
        bool priced = pricers[address(pool.hooks)] != address(0);
        if (id == SZR_MARKET) {
            if (!priced) revert InvalidPool();
            if (_other(pool, token) == Currency.unwrap(pool.currency0)) {
                if (Currency.unwrap(pool.currency1) != token) revert InvalidPool();
            }
        }
        if (id != SZR_MARKET) {
            _requireOutside(pool);
            if (address(pool.hooks) != address(0)) {
                if (!priced) revert NotTrusted();
            }
        }
        bytes32 poolId = PoolId.unwrap(pool.toId());
        _track(id, pool, poolId);
        if (priced) _wrap(id, address(pool.hooks), poolId);
    }

    /// @notice Tracks again a pool that was created in a market and then untracked.
    function retrack(bytes32 poolId) external {
        if (active != 0) revert Busy();
        uint256 id = pools[poolId].origin;
        if (id <= SZR_MARKET) revert UnknownPool();
        if (msg.sender != _owner(id)) revert NotManager();
        PoolKey memory pool = keys[poolId];
        (address pick, bool picked) = _pick(id, pool);
        pools[poolId] = Pool(uint32(id), uint32(id), pick, picked);
        _track(id, pool, poolId);
    }

    /// @dev Pools of a market other than SZR's cannot hold SZR. Native ETH is a token like
    /// any other, with currency zero.
    function _requireOutside(PoolKey memory pool) internal view {
        if (Currency.unwrap(pool.currency0) == token) revert InvalidPool();
        if (Currency.unwrap(pool.currency1) == token) revert InvalidPool();
    }

    /// @dev The token a pool's searches count profit in: whichever of its two the market
    /// has chosen, the more preferred when both are. `picked` is false when neither is.
    function _pick(uint256 id, PoolKey memory pool)
        internal
        view
        returns (address pick, bool picked)
    {
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        // A pool of ETH and WETH is pointless beside the wrap link, and its partner would
        // be an ether token while profit is counted in the other.
        if (_isEther(lower)) {
            if (_isEther(higher)) return (address(0), false);
        }
        uint256 first = rankIn[id][lower];
        uint256 second = rankIn[id][higher];
        if (first == 0) return second == 0 ? (address(0), false) : (higher, true);
        if (second == 0) return (lower, true);
        return first < second ? (lower, true) : (higher, true);
    }

    function _owner(uint256 id) internal view returns (address) {
        if (id == SZR_MARKET) return liquidity.manager();
        return markets[id].owner;
    }

    /// @notice A market's settings.
    function market(uint256 id) external view returns (Market memory) {
        Settings memory own = markets[id];
        return Market(
            own.owner,
            own.gasLimit,
            uint64(own.edge * EDGE_UNIT),
            own.recipient,
            own.poolCount,
            own.nominee,
            uint32(own.ask * ASK_UNIT)
        );
    }

    /// @notice Pairs a hook that fills trades somewhere other than the pool manager with
    /// the contract that prices its pools, or takes the pairing away with a zero pricer.
    /// Taking it away stops every pool on that hook being traded at once.
    /// @dev A pool a market took in before its hook was given a pricer (only a connecting
    /// pool in SZR's market can be, since the other ways in refuse such a hook) is not priced
    /// by this pricer and is not sized by the walk, though it is already traded as a wrapped
    /// pool, with no price limit. Set it again once the pricer is in place.
    function setPricer(address wrapper, address pricer) external onlyOwner(SZR_MARKET) {
        if (wrapper == address(0)) revert InvalidPool();
        if (wrapper == address(this)) revert InvalidPool();
        pricers[wrapper] = pricer;
        emit PricerSet(wrapper, pricer);
    }

    /// @dev Notes that a market now uses a pool priced by a pricer. Searches in it reserve
    /// more gas from here on, so its allowance is checked again.
    function _wrap(uint256 id, address wrapper, bytes32 poolId) internal {
        wrappers[poolId] = wrapper;
        if (markets[id].ask == 0) markets[id].ask = ASK_DEFAULT;
        _requireWorkable(id, markets[id].gasLimit);
    }

    /// @notice Sets the gas a pricer gets for one answer in a market that uses pools
    /// priced by one. More lets a pricer do more work, and has more reserved for every
    /// search, so the gas allowance is checked again.
    function setPricerGas(uint256 id, uint32 gas) external onlyOwner(id) {
        if (markets[id].ask == 0) revert InvalidLimit();
        uint256 units = (uint256(gas) + ASK_UNIT - 1) / ASK_UNIT;
        if (units == 0) revert InvalidLimit();
        if (units > type(uint8).max) revert InvalidLimit();
        markets[id].ask = uint8(units);
        _requireWorkable(id, markets[id].gasLimit);
        emit PricerGasSet(id, uint32(units * ASK_UNIT));
    }

    /// @notice Starts pricing the pool behind one of Liquidity's positions, in SZR's market.
    function track(uint256 id) external onlyOwner(SZR_MARKET) {
        Liquidity.Position memory entry = liquidity.position(id);
        bytes32 poolId = PoolId.unwrap(entry.key.toId());
        address wrapper = address(entry.key.hooks);
        // Another hook could do anything in the middle of a cycle, so a pool on one is only
        // priced once Liquidity's manager has given that hook a pricer.
        if (wrapper != address(0)) {
            if (wrapper != address(this)) {
                if (pricers[wrapper] == address(0)) revert NotTrusted();
            }
        }
        if (wrapper == address(this)) {
            if (entry.key.fee >= 1e6) revert InvalidPool();
            pools[poolId] = Pool(uint32(SZR_MARKET), uint32(SZR_MARKET), token, true);
        }
        _track(SZR_MARKET, entry.key, poolId);
        if (pricers[wrapper] != address(0)) _wrap(SZR_MARKET, wrapper, poolId);
    }

    function _track(uint256 id, PoolKey memory pool, bytes32 poolId) internal {
        if (tracked[id][poolId]) revert AlreadyTracked();
        tracked[id][poolId] = true;
        markets[id].poolCount++;
        keys[poolId] = pool;
        traded[id][Currency.unwrap(pool.currency0)] = true;
        traded[id][Currency.unwrap(pool.currency1)] = true;
        emit PoolTracked(id, poolId);
    }

    /// @notice Stops a market pricing a pool. A leader has to be replaced first.
    function untrack(uint256 id, bytes32 poolId) external onlyOwner(id) {
        if (!tracked[id][poolId]) revert UnknownPool();
        PoolKey memory pool = keys[poolId];
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        // It can lead with either of its tokens as the one profit is counted in.
        if (_leads(id, lower, higher, poolId)) revert StillLeader();
        if (_leads(id, higher, lower, poolId)) revert StillLeader();
        tracked[id][poolId] = false;
        markets[id].poolCount--;
        if (pools[poolId].market == id) pools[poolId].market = 0;
        emit PoolUntracked(id, poolId);
    }

    /// @notice Names the leaders among a market's pools that pair `base`, a token profit is
    /// counted in, with `partner`: its deepest such pools, deepest first. The first is what
    /// every other group is compared against, so it should be the pool hardest to move. An
    /// empty list removes the group.
    function setLeaders(uint256 id, address base, address partner, bytes32[] calldata poolIds)
        external
        onlyOwner(id)
    {
        if (poolIds.length > MAX_LEADERS) revert TooManyLeaders();
        // The gas allowance is checked against the tokens on the list, so leaders can only
        // be named for one of those. A group can always be emptied.
        if (poolIds.length != 0) {
            if (!_countable(id, base)) revert InvalidPool();
            if (_isEther(base)) {
                if (_isEther(partner)) revert InvalidPool();
            }
        }
        address lower = base < partner ? base : partner;
        address higher = base < partner ? partner : base;
        for (uint256 index; index < poolIds.length; index++) {
            if (!tracked[id][poolIds[index]]) revert InvalidPool();
            PoolKey storage pool = keys[poolIds[index]];
            if (Currency.unwrap(pool.currency0) != lower) revert InvalidPool();
            if (Currency.unwrap(pool.currency1) != higher) revert InvalidPool();
            for (uint256 earlier; earlier < index; earlier++) {
                if (poolIds[earlier] == poolIds[index]) revert InvalidPool();
            }
        }
        _setGroup(groups[id][base], partner, poolIds.length != 0);
        leaders[id][base][partner] = poolIds;
        heads[id][base][partner] = poolIds.length == 0 ? bytes32(0) : poolIds[0];
        _requireWorkable(id, markets[id].gasLimit);
        emit LeadersSet(id, base, partner, poolIds);
    }

    /// @dev Whether a market may count profit in `base`.
    function _countable(uint256 id, address base) internal view returns (bool) {
        if (id == SZR_MARKET) return base == token;
        if (rankIn[id][base] == 0) return false;
        return shareRecipient[base] != address(0);
    }

    /// @dev An allowance too small for the venues a search prices would leave it idle.
    function _requireWorkable(uint256 id, uint256 gas) internal view {
        if (gas == 0) return;
        if (gas < minimumGasLimit(id)) revert InvalidLimit();
    }

    /// @dev Adds the partner to the list of groups, or removes it, as its leaders require.
    function _setGroup(address[] storage list, address partner, bool wanted) internal {
        uint256 count = list.length;
        uint256 index;
        while (index < count) {
            if (list[index] == partner) break;
            index++;
        }
        if (wanted) {
            if (index != count) return;
            if (count == MAX_GROUPS) revert TooManyGroups();
            list.push(partner);
            return;
        }
        if (index == count) return;
        list[index] = list[count - 1];
        list.pop();
    }

    function _leads(uint256 id, address base, address partner, bytes32 poolId)
        internal
        view
        returns (bool)
    {
        bytes32[] storage list = leaders[id][base][partner];
        for (uint256 index; index < list.length; index++) {
            if (list[index] == poolId) return true;
        }
        return false;
    }

    function leadersOf(uint256 id, address base, address partner)
        external
        view
        returns (bytes32[] memory)
    {
        return leaders[id][base][partner];
    }

    function groupsOf(uint256 id, address base) external view returns (address[] memory) {
        return groups[id][base];
    }

    /// @notice Sets or clears the pool a market uses to convert between its two tokens.
    /// It must not contain SZR. In SZR's market it must be on Liquidity's list of
    /// registered pools.
    /// @dev Anyone can open a market, so its connecting pools may run no hook but this one
    /// (and then only as a pool of that same market) or one that has a pricer. Another hook
    /// could do anything in the middle of a cycle, and this hook's own swaps skip its
    /// searches, so trading through another market's pool would move it without that
    /// market's search.
    function setConnector(uint256 id, PoolKey calldata pool, bool enabled)
        external
        onlyOwner(id)
    {
        bytes32 poolId = PoolId.unwrap(pool.toId());
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        if (lower == token) revert InvalidPool();
        if (higher == token) revert InvalidPool();
        if (id == SZR_MARKET) {
            if (!liquidity.poolRegistered(poolId)) revert PoolNotRegistered();
            // Never another market's pool: trading it would skip that market's search.
            if (pools[poolId].origin > SZR_MARKET) revert InvalidPool();
        }
        if (id != SZR_MARKET) _requireLink(id, pool, poolId);
        // Clearing has to name the pool that is set, not just any pool on the same pair.
        if (!enabled) {
            if (connector[id][lower][higher] != poolId) revert InvalidPool();
        }
        keys[poolId] = pool;
        traded[id][lower] = true;
        traded[id][higher] = true;
        connector[id][lower][higher] = enabled ? poolId : bytes32(0);
        emit ConnectorSet(id, lower, higher, connector[id][lower][higher]);
        if (enabled) {
            if (pricers[address(pool.hooks)] != address(0)) {
                _wrap(id, address(pool.hooks), poolId);
            }
        }
    }

    function _requireLink(uint256 id, PoolKey calldata pool, bytes32 poolId) internal view {
        if (address(pool.hooks) == address(0)) return;
        // A hook with a pricer is one Liquidity's manager trusts to run in a cycle.
        if (pricers[address(pool.hooks)] != address(0)) return;
        if (address(pool.hooks) != address(this)) revert NotTrusted();
        if (pools[poolId].origin != id) revert InvalidPool();
    }

    /// @notice Sets a market's gas allowance and smallest gap, and the smallest profit for
    /// cycles counted in `base`. `gas` zero switches the market off; otherwise it must
    /// cover at least one cycle. `edge` below 1.0 would chase losing cycles.
    function setLimits(uint256 id, address base, uint32 gas, uint128 profit, uint64 edge)
        external
        onlyOwner(id)
    {
        if (edge < WAD) revert InvalidLimit();
        if (edge > MAX_EDGE) revert InvalidLimit();
        _requireWorkable(id, gas);
        Settings storage own = markets[id];
        own.gasLimit = gas;
        own.edge = uint56(edge / EDGE_UNIT);
        minimumProfit[id][base] = profit;
        emit LimitsSet(id, base, gas, profit, uint64(own.edge * EDGE_UNIT));
    }

    /// @notice Sets the smallest profit for cycles counted in `base`, and nothing else.
    function setMinimumProfit(uint256 id, address base, uint128 profit) external onlyOwner(id) {
        Settings storage own = markets[id];
        minimumProfit[id][base] = profit;
        emit LimitsSet(id, base, own.gasLimit, profit, uint64(own.edge * EDGE_UNIT));
    }

    /// @notice The smallest gas allowance with which a search can always start its first
    /// cycle, for the groups and leaders set now. It does not depend on how many pools are
    /// tracked, only on how many venues one search can price.
    function minimumGasLimit(uint256 id) public view returns (uint256) {
        uint256 venues = _mostVenues(id);
        uint256 ask = markets[id].ask * ASK_UNIT;
        (uint256 book, uint256 scan, uint256 overhead) = _reserves(venues, ask);
        // What the search before a swap needs to start, reading the prices and the first
        // ranking, and enough to get past the failed cycles it must be able to absorb.
        return _floor(venues, true, ask) + book + scan + FAILURES_COVERED
            * (_plan(ask) + overhead + scan);
    }

    /// @dev The gas held back for reading every venue's price, for ranking them, and for
    /// what a cycle costs beyond its own budget. `ask` is what a pricer gets for one
    /// answer, zero in a market that uses none; see `ASK_UNIT`.
    function _reserves(uint256 venues, uint256 ask)
        internal
        pure
        returns (uint256 book, uint256 scan, uint256 overhead)
    {
        if (ask == 0) {
            return (BOOK_GAS_PER_VENUE * venues, SCAN_GAS_PER_VENUE * venues, OVERHEAD_GAS);
        }
        uint256 each = ask + ASK_OVERHEAD;
        book = (BOOK_GAS_PER_VENUE + each) * venues;
        scan = (SCAN_GAS_PER_VENUE + 5 * each) * venues;
        overhead = OVERHEAD_GAS + 2 * each;
    }

    /// @dev The gas all the tries at one cycle may use between them. A leg through a
    /// wrapped pool trades on another exchange and moves the tokens, which costs far more
    /// than a leg inside the pool manager, so a market that uses them is given twice.
    function _plan(uint256 ask) internal pure returns (uint256) {
        return ask == 0 ? PLAN_GAS : 2 * PLAN_GAS;
    }

    /// @notice The gas the pool manager must still have when it calls this hook before a
    /// swap in this market, for the swap never to fail with `InsufficientGas`, whatever
    /// gaps are open. Set a swap's gas limit from this, not from an estimate: an estimate
    /// made while no gap was open is far too low for a swap that meets one.
    /// @dev Add what the router and the pool manager use before that point, and allow for
    /// each call on the way down keeping back one 64th of the gas it is given. The two
    /// factors here are for the two calls from the pool manager to the search.
    /// @dev A swap that itself costs more than `SWAP_GAS` (800k) needs that much more.
    /// @dev This holds as long as the gas reserved per step in this contract is no less
    /// than those steps really cost.
    function gasForSwap(uint256 id) external view returns (uint256) {
        return (minimumGasLimit(id) + OVERHEAD_GAS) * 64 / 63 * 64 / 63;
    }

    /// @dev The most venues any search in a market prices, over every token it can count
    /// profit in.
    function _mostVenues(uint256 id) internal view returns (uint256 most) {
        if (id == SZR_MARKET) return _venueCount(id, token);
        most = 2;
        address[] storage list = chosen[id];
        for (uint256 index; index < list.length; index++) {
            uint256 count = _venueCount(id, list[index]);
            if (count > most) most = count;
        }
    }

    /// @dev The pool itself, the leaders of the largest group, the first leader of each
    /// other group, and Core. For an ether token the twin's groups are read as well, whether
    /// or not the market chooses the twin, so the count is never below what `_venues` reads.
    function _venueCount(uint256 id, address base) internal view returns (uint256) {
        (uint256 most, uint256 count) = _extent(id, base);
        if (_isEther(base)) {
            (uint256 more, uint256 many) = _extent(id, _twin(base));
            most += more;
            count += many;
        }
        if (count == 0) return 2;
        return most + count + 1;
    }

    /// @dev The size of the largest group under `base`, and how many groups it has.
    function _extent(uint256 id, address base)
        internal
        view
        returns (uint256 most, uint256 count)
    {
        address[] storage list = groups[id][base];
        count = list.length;
        for (uint256 index; index < count; index++) {
            uint256 length = leaders[id][base][list[index]].length;
            if (length > most) most = length;
        }
    }

    /// @notice The other token of a pool a market is searching, beside the one its profit
    /// is counted in. Zero means either that the pool is not tracked or is never searched,
    /// or that the other token is native ETH.
    function partnerOf(bytes32 poolId) external view returns (address) {
        Pool memory entry = pools[poolId];
        if (entry.market != 0) {
            if (!entry.picked) return address(0);
            return _other(keys[poolId], entry.home);
        }
        if (tracked[SZR_MARKET][poolId]) return _other(keys[poolId], token);
        return address(0);
    }

    /// @notice Until when the cycle between `poolId` (the pool searched) and `venue` (zero
    /// for Core redemption) is set aside after failing, in market `id` with profit counted
    /// in `base`. `buying` is its direction: whether the hook buys `base` in `poolId`.
    function benchedUntil(uint256 id, address base, bytes32 poolId, bytes32 venue, bool buying)
        external
        view
        returns (uint256)
    {
        return benched[_pair(id, base, poolId, venue, buying)].until;
    }

    function _pair(uint256 id, address base, bytes32 poolId, bytes32 venue, bool buying)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(id, base, poolId, venue, buying));
    }

    /// @notice Runs the same search without a swap, for gaps that opened on a hookless
    /// pool of SZR's market or through a change in NAV. The caller receives nothing. An
    /// outside market's hookless pool cannot be named here; see `sweep`.
    function arb(bytes32 poolId) external returns (uint256 profit) {
        Pool memory entry = pools[poolId];
        uint256 id = entry.market;
        address base = entry.home;
        bool picked = entry.picked;
        // A pool that runs no hook can only be named in SZR's market.
        if (id == 0) {
            if (!tracked[SZR_MARKET][poolId]) revert UnknownPool();
            id = SZR_MARKET;
            base = token;
            picked = true;
        }
        if (!picked) revert UnknownPool();
        if (active != 0) revert Busy();
        if (markets[id].gasLimit == 0) return 0;
        active = id;
        home = base;
        _begin(id);
        bytes memory data = abi.encode(poolId, _other(keys[poolId], base));
        profit = abi.decode(poolManager.unlock(data), (uint256));
        active = 0;
    }

    /// @notice Searches every group of market `id` that counts profit in `base`, centred
    /// on each group's first leader in turn, without a swap. This reaches the hookless heads
    /// of outside markets, which `arb` cannot name. It takes no pool, so the caller cannot
    /// steer it, and the caller receives nothing.
    function sweep(uint256 id, address base) external returns (uint256 profit) {
        if (active != 0) revert Busy();
        if (markets[id].gasLimit == 0) return 0;
        if (!_countable(id, base)) return 0;
        active = id;
        home = base;
        profit = abi.decode(poolManager.unlock(abi.encode(bytes32(0), address(0))), (uint256));
        active = 0;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (bytes32 poolId, address partner) = abi.decode(data, (bytes32, address));
        if (poolId == bytes32(0)) return abi.encode(_sweep());
        return abi.encode(_search(poolId, partner, true, false, address(0)));
    }

    /// @dev Like `arb`, it sets nothing aside. Each head gets a fresh start so that `strained`
    /// does not carry from one to the next.
    function _sweep() internal returns (uint256 profit) {
        address[] memory list = groups[active][home];
        // A search reads and ranks its venues before its first gas check, so a head is
        // only started with that much to spare. Otherwise running out between heads would
        // undo the earlier heads' profit.
        _begin(active);
        (uint256 book, uint256 scan,) = _reserves(_venueCount(active, home), asking);
        for (uint256 index; index < list.length; index++) {
            bytes32 head = heads[active][home][list[index]];
            if (gasleft() < book + scan) {
                emit SearchCutShort(head);
                break;
            }
            _begin(active);
            profit += _search(head, list[index], true, false, address(0));
        }
    }

    /// @notice Closes any gap that is already open before the swap trades, so the swap
    /// executes at the aligned price and the gap's value goes to the protocol (and, outside
    /// SZR's market, to the market) instead of the swapper.
    function beforeSwap(
        address sender,
        PoolKey calldata pool,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _run(sender, pool, true);
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
        _run(sender, pool, false);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @dev Liquidity's own trades are left alone: its bounds assume the price it just set.
    function _run(address sender, PoolKey calldata pool, bool before) internal {
        if (sender == address(liquidity)) return;
        if (active != 0) {
            // A search is running. Where it can only reach code this hook's manager
            // chose, a swap inside it is let through unsearched. Where it runs a wrapped
            // pool's hook and tokens' own code, no swap in any pool on this hook is
            // allowed until it is done: otherwise that code could trade another market's
            // pool while its search stood aside.
            if (asking != 0) revert Busy();
            return;
        }
        bytes32 poolId = PoolId.unwrap(pool.toId());
        Pool memory entry = pools[poolId];
        if (entry.market == 0) return;
        // Neither of its tokens is one profit may be counted in.
        if (!entry.picked) return;
        address partner = Currency.unwrap(pool.currency0) == entry.home
            ? Currency.unwrap(pool.currency1)
            : Currency.unwrap(pool.currency0);
        _guard(poolId, entry, partner, before, sender);
    }

    /// @dev Runs the search within the market's gas allowance, and decides what a search
    /// that was undone means for the swap. A swap fails in two cases only: it brought too
    /// little gas to look for or close a gap (`InsufficientGas`), or the pool manager is
    /// short of a token the hook had to take before the swap (`Drained`). After a swap
    /// the same shortage only undoes the search: routers pay after swapping, so the
    /// swapper's own input can be owed and missing, and failing then would punish an honest
    /// swap. Anything else leaves the swap as it would have been. WETH is trusted not to
    /// revert with the `Drained` selector, which would fail every swap before it.
    function _guard(
        bytes32 poolId,
        Pool memory entry,
        address partner,
        bool before,
        address sender
    ) internal {
        // Whatever an earlier swap left remembered is out of date by now. Cleared here,
        // outside the search, so that it is cleared even if the search is undone.
        if (before) remembered = bytes32(0);
        uint256 stipend = markets[entry.market].gasLimit;
        if (stipend == 0) return;
        // Whether the search is bounded by the hook's own allowance or by the swap's gas.
        uint256 available = gasleft();
        bool capped = available - available / 64 >= stipend;
        try this.search{ gas: stipend }(
            poolId, entry.market, entry.home, partner, capped, before, sender
        ) { }
        catch (bytes memory reason) {
            // Before a swap the swapper's own input is not yet owed, so a shortage is read
            // as a drain and fails the swap whether or not the search was capped. That
            // reading is wrong when something earlier in the same unlock is still unpaid:
            // the pool manager can look short without a drain, and a search with more gas
            // can reach a further cycle that meets it, so more gas can fail a swap that
            // less gas passes. This is accepted; such a swap must pay first or be split.
            // After a swap, the search is undone like any other and the next swap, `arb`
            // or `sweep` closes the gap.
            if (before) {
                if (bytes4(reason) == Drained.selector) revert Drained();
            }
            // If the swap, not the hook's own allowance, was what ran short, it brought
            // too little gas either to look for a gap (no revert data) or to close the one
            // that is open. It fails as a whole, so that gas estimates include the hook and
            // nobody can skip it by sending less.
            if (!capped) {
                if (reason.length == 0) revert InsufficientGas();
                if (bytes4(reason) == Starved.selector) revert InsufficientGas();
            }
            // Anything else undid the search and leaves the swap as it would have been,
            // including what it would have cleared.
            emit SearchUndone(poolId, bytes4(reason));
        }
    }

    /// @dev Sets what lasts for one search only.
    function _begin(uint256 id) internal {
        if (strained) strained = false;
        asking = markets[id].ask * ASK_UNIT;
    }

    function search(
        bytes32 poolId,
        uint256 id,
        address base,
        address partner,
        bool capped,
        bool before,
        address payer
    ) external onlySelf returns (uint256 profit) {
        active = id;
        home = base;
        _begin(id);
        profit = _search(poolId, partner, capped, before, payer);
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
    /// @dev `payer` is whoever is swapping (zero for `arb` and `sweep`). If they have marked
    /// a token as synced with the pool manager, that is dealt with before the first cycle;
    /// see `_release`.
    function _search(bytes32 poolId, address partner, bool capped, bool before, address payer)
        internal
        returns (uint256 profit)
    {
        // `UNRELEASED` until the pool manager's sync slot has been dealt with.
        address resync = UNRELEASED;
        // The pool being searched is always the first entry of its book.
        Venue[] memory book = _open(poolId, partner, payer);
        uint256 next = book.length;
        uint256 floor = _floor(book.length, before, asking);
        uint256 failures;
        for (uint256 number; number < MAX_ROUNDS; number++) {
            // Once something is earned, stop while there is still gas to keep it.
            if (profit != 0) {
                if (gasleft() < floor) break;
            }
            // Pricing every venue again must not run out of gas. The first cycle is only
            // started with this much to spare, so it is always there after one failure.
            if (number != 0) {
                if (gasleft() < _rescan(book.length)) break;
            }
            Plan memory plan = _best(book);
            if (plan.score == 0) {
                // Nothing left here. The venue last traded against has moved, which may
                // have opened a gap between it and the pools it is compared with, so look
                // from there next.
                if (next == book.length) break;
                book = _book(book[next].id, book[next].partner);
                next = book.length;
                // Never lowered: before a swap it also holds back gas for the search
                // after it, which prices the first pool's venues, not this one's.
                uint256 again = _floor(book.length, before, asking);
                if (again > floor) floor = again;
                continue;
            }
            // A token taken off the list is no longer paid out, so nothing is tried, and
            // no swap is failed for bringing too little gas to try it.
            if (!_listedAtStart(number)) break;
            // A cycle is only started with its whole budget available, and enough beyond
            // it to look again if it fails. Before a swap that also means enough for the
            // swap and the search after it. Closing a gap is required until one cycle has
            // worked or more than `FAILURES_COVERED` have failed: with a gap open and too
            // little gas for that, the swap fails. After that the search just stops.
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
                _fail(book, plan, payer);
                continue;
            }
            profit += gained;
            _requote(book[0]);
            _requoteAt(book, plan.index);
            // A venue on the twin is no longer a pool of this search's token.
            if (plan.venue != bytes32(0)) {
                if (!_onTwin(book, plan.index)) next = plan.index;
            }
        }
        if (profit != 0) return _settle(profit, resync);
        _resync(resync);
        if (before) _remember(book);
    }

    /// @dev Pays out what a search earned, then marks the swapper's token again if the
    /// search had to clear it.
    function _settle(uint256 profit, address resync) internal returns (uint256) {
        _retire(profit);
        _resync(resync);
        return profit;
    }

    /// @dev Puts the pool manager's sync slot back as the swapper needs it: on their token
    /// if the search had to clear that, and otherwise empty if a wrapped pool's hook may
    /// have used it. Nothing is done if no cycle was tried.
    function _resync(address resync) internal {
        if (resync == UNRELEASED) return;
        if (resync != address(0)) return poolManager.sync(Currency.wrap(resync));
        if (asking != 0) poolManager.sync(Currency.wrap(address(0)));
    }

    /// @dev The venues a search prices. The search after a swap takes them from what the
    /// search before it remembered, when there is something, and reads only the pool's
    /// own new price. `arb` and `sweep` always read everything.
    function _open(bytes32 poolId, address partner, address payer)
        internal
        returns (Venue[] memory book)
    {
        if (payer == address(0)) return _book(poolId, partner);
        if (remembered != poolId) return _book(poolId, partner);
        remembered = bytes32(0);
        uint256 slot = REMEMBER_SLOT;
        uint256 head = _recall(slot);
        book = new Venue[](uint128(head));
        Venue memory focus = book[0];
        focus.id = poolId;
        focus.partner = partner;
        focus.twins = head >> 128;
        _requote(focus);
        for (uint256 index = 1; index < book.length; index++) {
            slot += 4;
            book[index].id = bytes32(_recall(slot));
            book[index].partner = address(uint160(_recall(slot + 1)));
            book[index].rate = _recall(slot + 2);
            book[index].keep = _recall(slot + 3);
        }
    }

    /// @dev Leaves the other venues' prices for the search after the swap. Only called
    /// when the search before it traded nothing: then no pool has moved since they were
    /// read, the swap between the two searches moves only its own pool, and nothing else
    /// can run in between. The first word is the number of venues, the pool included, with
    /// the place of the first venue on the twin above it (twins are read last).
    function _remember(Venue[] memory book) internal {
        if (gasleft() < REMEMBER_GAS * book.length) return;
        uint256 slot = REMEMBER_SLOT;
        Venue memory focus = book[0];
        _keepInMind(slot, book.length | focus.twins << 128);
        for (uint256 index = 1; index < book.length; index++) {
            slot += 4;
            _keepInMind(slot, uint256(book[index].id));
            _keepInMind(slot + 1, uint256(uint160(book[index].partner)));
            _keepInMind(slot + 2, book[index].rate);
            _keepInMind(slot + 3, book[index].keep);
        }
        remembered = focus.id;
    }

    function _keepInMind(uint256 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _recall(uint256 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @dev What must be left to price every venue again and still pay out.
    function _rescan(uint256 venues) internal view returns (uint256) {
        (, uint256 scan,) = _reserves(venues, asking);
        return RETIRE_GAS + scan;
    }

    /// @dev The gas a cycle needs before it may start: its own budget, retiring, and pricing
    /// the venues again if it fails. The search before a swap must also leave enough for
    /// the swap itself and for the search after it to read the prices, rank them and run
    /// its own first cycle.
    function _floor(uint256 venues, bool before, uint256 ask)
        internal
        pure
        returns (uint256 floor)
    {
        (uint256 book, uint256 scan, uint256 overhead) = _reserves(venues, ask);
        floor = RETIRE_GAS + _plan(ask) + overhead + scan;
        if (before) floor = floor * 2 + SWAP_GAS + scan + book;
    }

    /// @dev The pool manager has one slot recording a token someone has marked as synced
    /// ahead of paying it in, and anyone can set it. The hook's own cycles take the profit
    /// token out and, for Core, pay WETH in through that same slot, so the slot is dealt
    /// with first.
    /// If a payment is already waiting it is credited to `payer`, exactly as their own
    /// settlement would have credited it; their later settlement then finds nothing more to
    /// add. If nothing has been paid in, the token is returned so it can be marked again
    /// once the search is done. Either way the hook runs as usual: marking a token is not
    /// a way to make it stand aside.
    /// @dev That care is only for tokens the hook trades. Any other token is left completely
    /// alone, and never called: it could be written to revert, burn gas or misreport its
    /// balance. Its mark survives unless a cycle redeems through Core, which uses the slot
    /// for WETH and leaves it empty, or the market uses wrapped pools (see
    /// `_clear`). A router that marked such a token for an earlier hop and settles it after
    /// this swap then has its transaction revert; nothing is lost. The same goes for a cycle
    /// that unwraps WETH, which clears the slot to settle ETH (see `_convert`), in every
    /// market: an untraded token's mark is lost, a traded one is marked again afterwards.
    function _release(address payer) internal returns (address resync) {
        address synced = Currency.unwrap(poolManager.getSyncedCurrency());
        if (synced == address(0)) return address(0);
        if (!_traded(synced)) return _clear(address(0));
        uint256 held = SafeTransferLib.balanceOf(synced, address(poolManager));
        if (held <= poolManager.getSyncedReserves()) return _clear(synced);
        // `arb` and `sweep` have no swapper to credit; a caller who paid in before calling
        // them is misusing them.
        if (payer == address(0)) revert Busy();
        poolManager.settleFor(payer);
        // Marked again afterwards, so that anything more they pay in is counted as well.
        return synced;
    }

    /// @dev A wrapped pool's hook pays ETH with `settle{ value }`, which the pool manager
    /// refuses while its sync slot holds a token. Anyone can mark one for free, so in a
    /// market with wrapped pools the slot is emptied when nothing has been paid in. The
    /// token itself is not called.
    function _clear(address resync) internal returns (address) {
        if (asking != 0) poolManager.sync(Currency.wrap(address(0)));
        return resync;
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
        return failures < (before ? FAILURES_COVERED + 1 : 1);
    }

    /// @dev A swap's failed cycle is set aside. `arb` and `sweep` set nothing aside, so that
    /// calling them cannot switch a pair off for swappers; the venue is passed over for the
    /// rest of that search instead.
    function _fail(Venue[] memory book, Plan memory plan, address payer) internal {
        _bench(book[0].id, plan, payer != address(0));
        if (payer == address(0)) book[plan.index].rate = 0;
    }

    function _bench(bytes32 poolId, Plan memory plan, bool aside) internal {
        emit CycleFailed(poolId, plan.venue);
        if (!aside) return;
        benched[_pair(active, home, poolId, plan.venue, plan.buying)] =
            Bench(uint64(block.timestamp + BENCH_TIME), uint192(plan.gap));
    }

    function _traded(address asset) internal view returns (bool) {
        if (asset == home) return true;
        if (asset == backingAsset) return true;
        return traded[active][asset];
    }

    /// @dev Whether profit may be counted in this search's token.
    function _listed() internal view returns (bool) {
        return _countable(active, home);
    }

    /// @dev Listing is read in a search's first round only. It cannot change in the middle of
    /// a search (`setProfitToken` and `setTokens` revert `Busy`), and the first cycle worth
    /// trying is always in the first round, since the book is only read again after a cycle
    /// has worked.
    function _listedAtStart(uint256 round) internal view returns (bool) {
        if (round != 0) return true;
        return _listed();
    }

    /// @dev SZR's market retires its profit at Core. Every other market's is paid out.
    function _retire(uint256 profit) internal {
        if (active != SZR_MARKET) return _payOut(profit);
        _take(Currency.wrap(token), address(this), profit);
        _requireSettled(token);
        core.donateSzr(profit);
    }

    /// @dev Splits a market's profit between the protocol and the market, in the token it
    /// was counted in. If the protocol's recipient cannot receive the token (a blocklist, for
    /// instance), its share is minted as a pool-manager claim instead, so one recipient cannot
    /// stop every market counting in that token. The recipient redeems a claim by calling
    /// `unlock` on the pool manager and, inside it, `burn` then `take`, or by transferring
    /// the claim to something that can. The market's own share has no such fallback, and
    /// neither does a share owed to Core, which could never redeem the claim.
    function _payOut(uint256 profit) internal {
        // Rounded up, so that no profit is too small for the protocol to share in.
        uint256 share = (profit * PROTOCOL_SHARE + 99) / 100;
        if (home == address(0)) {
            _payNative(profit, share);
        } else {
            Currency asset = Currency.wrap(home);
            address protocol = shareRecipient[home];
            // Checked for the whole profit before the try below, so that a drain is never
            // turned into a claim.
            _funded(asset, profit);
            if (protocol == address(core)) {
                // Core cannot redeem a claim, so one minted to it would be stuck.
                poolManager.take(asset, protocol, share);
            } else {
                try poolManager.take(asset, protocol, share) { }
                catch {
                    poolManager.mint(protocol, asset.toId(), share);
                    emit ShareHeld(home, protocol, share);
                }
            }
            // Some tokens refuse a transfer of nothing.
            if (profit != share) {
                poolManager.take(asset, markets[active].recipient, profit - share);
            }
        }
        _requireSettled(home);
        emit ProfitPaid(active, home, profit, share);
    }

    /// @dev Native ETH profit leaves only as WETH, so no recipient's code runs in the middle
    /// of a search. Unlike `_payOut` it has no claim fallback: the ETH is already taken by the
    /// hook, so none can be minted. WETH has no blocklist in its current implementation, but
    /// it is an upgradeable proxy, so that is not a promise.
    function _payNative(uint256 profit, uint256 share) internal {
        _take(Currency.wrap(address(0)), address(this), profit);
        // A failed wrap is a named error: an empty revert would be read as too little gas.
        try IWrapped(backingAsset).deposit{ value: profit }() { }
        catch {
            revert Unsettled();
        }
        SafeTransferLib.safeTransfer(backingAsset, shareRecipient[address(0)], share);
        if (profit != share) {
            SafeTransferLib.safeTransfer(
                backingAsset, markets[active].recipient, profit - share
            );
        }
    }

    /// @dev The hook takes ETH from the pool manager and wraps it at once, and WETH sends
    /// it ETH when it unwraps. Anyone can have the pool manager send ETH here from their
    /// own unlock; that ETH is theirs to lose, and nothing reads the hook's balance.
    receive() external payable {
        if (msg.sender == address(poolManager)) return;
        if (msg.sender != backingAsset) revert NotPoolManager();
    }

    function _isEther(address asset) internal view returns (bool) {
        if (asset == address(0)) return true;
        return asset == backingAsset;
    }

    function _twin(address asset) internal view returns (address) {
        return asset == address(0) ? backingAsset : address(0);
    }

    /// @dev Turns `amount` of ether token `from`, taken out of the pool manager, into the
    /// same amount of its twin and pays that in. The slot is cleared before ETH is settled
    /// because the pool manager refuses ETH while it holds a token, and anyone can mark one.
    /// It runs inside a cycle, where `_attempt` catches a failed wrap or unwrap whatever its
    /// shape.
    function _convert(address from, uint256 amount) internal {
        _take(Currency.wrap(from), address(this), amount);
        if (from == address(0)) {
            IWrapped(backingAsset).deposit{ value: amount }();
            poolManager.sync(Currency.wrap(backingAsset));
            SafeTransferLib.safeTransfer(backingAsset, address(poolManager), amount);
            if (poolManager.settle() != amount) revert InvalidDelta();
            return;
        }
        IWrapped(backingAsset).withdraw(amount);
        poolManager.sync(Currency.wrap(address(0)));
        if (poolManager.settle{ value: amount }() != amount) revert InvalidDelta();
    }

    /// @dev The takes a cycle makes go through here, so that a pool manager short of the
    /// token is reported as `Drained` and not as a failed cycle. `_payOut` is the exception:
    /// it checks `_funded` once for the whole profit and then calls `poolManager.take`
    /// directly. Whether `Drained` fails the swap depends on when the search runs: before a
    /// swap it does, and after a swap it only undoes that search (see `_guard`). Only the
    /// controller of the current unlock can cause a shortage, by taking the balance out and
    /// repaying it at the end. Each take is of something the hook already holds a credit
    /// for, so an honest pool manager always has it. Only the profit token, SZR, ETH and
    /// WETH are ever asked about.
    function _take(Currency asset, address to, uint256 amount) internal {
        _funded(asset, amount);
        poolManager.take(asset, to, amount);
    }

    function _funded(Currency asset, uint256 amount) internal view {
        address id = Currency.unwrap(asset);
        uint256 held;
        if (id == address(0)) {
            held = address(poolManager).balance;
        } else {
            // A failed read must not look like a shortage: it reverts empty, which reads as
            // too little gas.
            (bool ok, bytes memory data) =
                id.staticcall(abi.encodeCall(IERC20Balance.balanceOf, (address(poolManager))));
            if (!ok) revert();
            if (data.length < 32) revert();
            held = abi.decode(data, (uint256));
        }
        if (held < amount) revert Drained();
    }

    /// @dev Re-raises `Drained` from a failed try. Only the first four bytes of what the
    /// try returned are read, since a leg could make the payload large. Both searches
    /// re-raise it; `_guard` then fails the swap only for the search before it. Must be called
    /// straight after the catch, before anything else overwrites the return data.
    function _raiseDrained() internal pure {
        bytes32 word;
        assembly ("memory-safe") {
            if gt(returndatasize(), 3) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, 4)
                word := mload(ptr)
            }
        }
        if (bytes4(word) == Drained.selector) revert Drained();
    }

    /// @dev The first try is sized by `size`, which walks the legs' ticks, when the cycle is
    /// one it can read and the search is not strained; otherwise it stops where the depths of
    /// the legs say their prices meet. That assumes the liquidity read at the current price
    /// is what the trade will meet, which is wrong when a leg crosses into a different range
    /// and can be made wrong on purpose. So the next try closes the whole gap, and each one
    /// after goes half as far. All the tries and the walk share `_plan(asking)`; when it runs out
    /// the cycle has failed.
    function _attempt(bytes32 poolId, Plan memory plan) internal returns (uint256) {
        // The pool's price, read only if a third size is reached.
        uint160 current;
        uint256 whole = _plan(asking);
        uint256 budget = whole;
        // Once a try has run out of gas, here or earlier in this search, only the smallest
        // size is tried: an eighth of the whole gap, which crosses the fewest ticks of the
        // sizes that close a set share of it.
        bool smallest = strained;
        if (!smallest) {
            if (_sizeable(plan)) {
                bool declined;
                (budget, declined) = _size(poolId, plan, budget);
                // The walk found the best size there is and it cannot earn enough: no
                // tries, and the cycle fails as one whose tries all failed.
                if (declined) return 0;
            }
        }
        for (uint256 number; number < TRIES; number++) {
            if (budget < ATTEMPT_GAS) break;
            if (number == 1) {
                plan.limit = plan.full;
                plan.spend = plan.fullSpend;
            }
            if (number == 2) (current,,,) = poolManager.getSlot0(PoolId.wrap(poolId));
            if (number > 1) {
                plan.limit = uint160((uint256(current) + plan.limit) / 2);
                plan.spend = plan.spend / 2 + 1;
            }
            if (smallest) {
                if (number != TRIES - 1) continue;
            }
            // No try may use more than half the budget, so one that runs out of gas leaves
            // a full share for the next size.
            uint256 stipend = budget < whole / 2 ? budget : whole / 2;
            uint256 available = gasleft();
            try this.execute{ gas: stipend }(poolId, plan) returns (uint256 profit) {
                return profit;
            } catch {
                _raiseDrained();
            }
            uint256 used = available - gasleft();
            budget = used < budget ? budget - used : 0;
            // Running out of gas below `execute`, in the pool manager or a pool's hook, leaves
            // each frame above it the 1/64 that a call holds back, so `used` falls short of
            // `stipend`. Four levels of that is a sixteenth; a try that left less unused than
            // that is counted as having run out, but only if it had a full share. A try on
            // what the others left over is cut short by the budget, not by the cycle, and
            // its cycle has no budget left for another size anyway.
            if (stipend != whole / 2) continue;
            if (used >= stipend - stipend / 16) {
                if (!smallest) emit TryRanOut(poolId, plan.venue);
                smallest = true;
                strained = true;
            }
        }
        return 0;
    }

    /// @dev The first try's size, from `size`. Its gas comes out of the budget, not out of
    /// the try's stipend, so the first try still gets a full share. If the walk fails or
    /// runs out of gas the first try keeps the estimate.
    function _size(bytes32 poolId, Plan memory plan, uint256 budget)
        internal
        virtual
        returns (uint256, bool declined)
    {
        uint256 available = gasleft();
        try this.size{ gas: _sizingGas(plan) }(poolId, plan) returns (
            uint160 limit, uint256 spend, bool decline
        ) {
            plan.limit = limit;
            plan.spend = spend;
            declined = decline;
        } catch { }
        uint256 used = available - gasleft();
        return (used < budget ? budget - used : 0, declined);
    }

    /// @notice One whole cycle. It either nets at least `minimumProfit` SZR with no other
    /// token left owing, or reverts. The SZR stays as a credit until the search retires it.
    function execute(bytes32 poolId, Plan calldata plan)
        external
        onlySelf
        returns (uint256 profit)
    {
        (uint256 open, int256 held) = _tally();
        profit = plan.buying ? _buyCycle(poolId, plan) : _sellCycle(poolId, plan);
        if (profit == 0) revert Unprofitable();
        if (profit < minimumProfit[active][home]) revert Unprofitable();
        if (asking != 0) _requireTidy(open, held, profit);
        emit Arbitraged(poolId, plan.venue, plan.buying, profit);
    }

    /// @dev How many balances the pool manager has open across everyone, and the hook's
    /// own in the token profit is counted in. Only needed where a cycle can run a wrapped
    /// pool's hook.
    function _tally() internal view returns (uint256 open, int256 held) {
        if (asking == 0) return (0, 0);
        open = poolManager.getNonzeroDeltaCount();
        held = poolManager.currencyDelta(address(this), Currency.wrap(home));
    }

    /// @dev A cycle may change one balance only: the hook's own, by exactly its profit.
    /// A wrapped pool's hook that ends owing or owed anything, or anything credited to
    /// this hook on the side, would otherwise only come to light when the swapper's whole
    /// transaction was refused at the end. Here it fails the cycle, and the swap goes on.
    function _requireTidy(uint256 open, int256 held, uint256 profit) internal view {
        int256 holding = poolManager.currencyDelta(address(this), Currency.wrap(home));
        if (holding != held + int256(profit)) revert Unsettled();
        if (held == 0) open++;
        if (poolManager.getNonzeroDeltaCount() > open) revert Unsettled();
    }

    /// @dev Buys SZR in the pool up to the price limit, then works backwards with exact
    /// outputs: each connecting pool supplies the token owed to the pool before it, and the
    /// venue supplies what the last one is owed. Every token but SZR must net to nothing.
    /// A wrap link only switches the token owed to its twin: the conversion waits until the
    /// later legs have supplied that twin, so no take is ever of something the hook does
    /// not yet hold.
    function _buyCycle(bytes32 poolId, Plan calldata plan) internal returns (uint256 profit) {
        PoolKey memory own = keys[poolId];
        address base = home;
        address asset = _other(own, base);
        (uint256 owed, uint256 bought) = _trade(own, asset, -int256(plan.spend), plan.limit);
        // The ether token to convert once it is held, and how much; `UNRELEASED` for none.
        address later = UNRELEASED;
        uint256 amount;
        for (uint256 hop; hop < 2; hop++) {
            if (plan.links[hop] == bytes32(0)) break;
            if (plan.links[hop] == WRAP) {
                later = _twin(asset);
                amount = owed;
                asset = later;
                continue;
            }
            PoolKey memory link = keys[plan.links[hop]];
            owed = _exactOutput(link, asset, owed, plan.gap);
            // The converted token is checked once it has been.
            if (asset != later) _requireSettled(asset);
            asset = _other(link, asset);
        }
        uint256 sold;
        // What Core returned beyond `owed`, when it has to wait for the conversion.
        uint256 excess;
        if (plan.venue == bytes32(0)) {
            (sold, excess) = _redeem(owed, bought, later != UNRELEASED);
        } else {
            sold = _exactOutput(keys[plan.venue], asset, owed, plan.gap);
        }
        _outOfHome(plan.venue, sold, bought, base);
        if (later != UNRELEASED) {
            _convert(later, amount);
            // Only now is Core's extra WETH a credit, as the debt has been paid in WETH.
            if (excess != 0) poolManager.clear(Currency.wrap(backingAsset), excess);
            _requireSettled(later);
            _requireSettled(_twin(later));
        }
        // The converted token was checked above.
        if (asset != later) _requireSettled(asset);
        profit = bought - sold;
    }

    /// @dev Sells SZR in the pool down to the price limit, then carries the proceeds forward
    /// with exact inputs until they are SZR again.
    function _sellCycle(bytes32 poolId, Plan calldata plan) internal returns (uint256 profit) {
        PoolKey memory own = keys[poolId];
        address base = home;
        address asset = _other(own, base);
        (uint256 sold, uint256 held) = _trade(own, base, -int256(plan.spend), plan.limit);
        for (uint256 hop; hop < 2; hop++) {
            if (plan.links[hop] == bytes32(0)) break;
            address next;
            if (plan.links[hop] == WRAP) {
                _convert(asset, held);
                next = _twin(asset);
            } else {
                PoolKey memory link = keys[plan.links[hop]];
                held = _exactInput(link, asset, held, plan.gap);
                next = _other(link, asset);
            }
            _requireSettled(asset);
            asset = next;
        }
        uint256 bought = _exactInput(keys[plan.venue], asset, held, plan.gap);
        _requireSettled(asset);
        _intoHome(plan.venue, bought, base);
        profit = bought - sold;
    }

    /// @dev Whether a venue's pool holds the twin of this search's ether token. It shares
    /// the partner token with the pool searched, so the test is that it does not hold the
    /// search's profit token.
    function _holdsTwin(bytes32 venue, address base) internal view returns (bool) {
        if (!_isEther(base)) return false;
        if (venue == bytes32(0)) return false;
        PoolKey storage pool = keys[venue];
        if (Currency.unwrap(pool.currency0) == base) return false;
        return Currency.unwrap(pool.currency1) != base;
    }

    /// @dev A sell cycle's venue paid the twin: it becomes the token the search counts in.
    function _intoHome(bytes32 venue, uint256 amount, address base) internal {
        if (!_holdsTwin(venue, base)) return;
        address twin = _twin(base);
        _convert(twin, amount);
        // Defensive: `amount` is what the venue paid and exactly that is converted, so the
        // twin is always settled here. Kept so a change to the conversion cannot leave it
        // owed unnoticed. No test reaches it.
        _requireSettled(twin);
    }

    /// @dev A buy cycle's venue was paid in the twin: exactly that much of the token the
    /// search counts in, which the hook holds from the pool it bought in, becomes the twin.
    /// The take is of what the hook is owed only if it bought more than that.
    function _outOfHome(bytes32 venue, uint256 sold, uint256 bought, address base) internal {
        if (!_holdsTwin(venue, base)) return;
        if (sold >= bought) revert Unprofitable();
        _convert(base, sold);
        // Defensive: `sold` is what the venue was paid in the twin and exactly that is
        // converted, so the twin is always settled here. Kept so a change to the conversion
        // cannot leave it owed unnoticed. No test reaches it.
        _requireSettled(_twin(base));
    }

    function _other(PoolKey memory pool, address asset) internal pure returns (address) {
        bool first = Currency.unwrap(pool.currency0) == asset;
        return Currency.unwrap(first ? pool.currency1 : pool.currency0);
    }

    /// @dev Redeems just enough SZR at NAV to cover the WETH owed. Rounding can return a
    /// few wei more than owed; that excess is given up to the pool manager. When the debt is
    /// in ETH (`wrapped`) the WETH delta is all of `received` until the conversion, so the
    /// excess is returned for `_buyCycle` to give up then, and exactly that is cleared: any
    /// other credit left to the hook still fails the cycle.
    /// It reverts before the take if that is not less than the SZR the cycle bought, so the
    /// hook never takes SZR it is not owed.
    function _redeem(uint256 owed, uint256 bought, bool wrapped)
        internal
        returns (uint256 amount, uint256 excess)
    {
        amount = FixedPointMathLib.fullMulDivUp(owed, core.activeSupply(), core.backingAmount());
        if (amount >= bought) revert Unprofitable();
        _take(Currency.wrap(token), address(this), amount);
        uint256 received = core.redeem(amount, owed);
        poolManager.sync(Currency.wrap(backingAsset));
        SafeTransferLib.safeTransfer(backingAsset, address(poolManager), received);
        if (poolManager.settle() != received) revert InvalidDelta();
        excess = received - owed;
        if (wrapped) return (amount, excess);
        if (excess != 0) poolManager.clear(Currency.wrap(backingAsset), excess);
    }

    function _exactInput(PoolKey memory pool, address input, uint256 amount, uint256 gap)
        internal
        returns (uint256 received)
    {
        uint256 spent;
        (spent, received) = _trade(pool, input, -int256(amount), _legLimit(pool, input, gap));
        if (spent != amount) revert Incomplete();
    }

    function _exactOutput(PoolKey memory pool, address output, uint256 amount, uint256 gap)
        internal
        returns (uint256 spent)
    {
        uint256 received;
        address input = _other(pool, output);
        (spent, received) = _trade(pool, input, int256(amount), _legLimit(pool, input, gap));
        if (received != amount) revert Incomplete();
    }

    /// @dev The price limit for a venue or connecting leg that is a plain pool: its
    /// square-root price moved against the trade by `(1 + gap)²`, `gap` being the cycle's
    /// square-root gap. A leg that has moved that far has moved its price about twice the
    /// whole cycle's gap, so the optimum never reaches it. Without a limit a leg that cannot
    /// fill walks every empty bitmap word to the extreme price first, whatever the try's size.
    /// A wrapped pool ignores price limits, so it keeps none (zero).
    function _legLimit(PoolKey memory pool, address input, uint256 gap)
        internal
        view
        returns (uint160)
    {
        if (pricers[address(pool.hooks)] != address(0)) return 0;
        (uint160 price,,,) = poolManager.getSlot0(pool.toId());
        return _limitFrom(price, Currency.unwrap(pool.currency0) == input, gap);
    }

    /// @dev `price` moved against a trade by `(1 + gap)²`, inside `TickMath`'s range.
    function _limitFrom(uint160 price, bool zeroForOne, uint256 gap)
        internal
        pure
        returns (uint160)
    {
        uint256 wide = WAD + gap;
        uint256 factor = FixedPointMathLib.fullMulDiv(wide, wide, WAD);
        if (zeroForOne) {
            uint256 low = FixedPointMathLib.fullMulDiv(price, WAD, factor);
            return low > TickMath.MIN_SQRT_PRICE ? uint160(low) : TickMath.MIN_SQRT_PRICE + 1;
        }
        uint256 high = FixedPointMathLib.fullMulDiv(price, factor, WAD);
        return high < TickMath.MAX_SQRT_PRICE ? uint160(high) : TickMath.MAX_SQRT_PRICE - 1;
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
    /// other group, and Core last. Connecting pools are read when used. When the search
    /// counts in an ether token, the same from the twin's lists follows the others.
    function _book(bytes32 poolId, address partner)
        internal
        view
        returns (Venue[] memory book)
    {
        (bytes32[] memory ids, address[] memory partners, uint256 count) =
            _venues(poolId, partner);
        uint256 split = count;
        // Only SZR's market can redeem at Core. It is never one that counts in an ether
        // token, so it skips that check, which reads no storage.
        bool redeemable = active == SZR_MARKET;
        address base = home;
        if (!redeemable) {
            if (_isEther(base)) {
                (ids, partners) = _grow(ids, partners, count);
                count = _twinVenues(ids, partners, count, partner);
            }
        }
        book = new Venue[](redeemable ? count + 1 : count);
        bytes32[] memory slots = new bytes32[](count);
        for (uint256 index; index < count; index++) {
            book[index].id = ids[index];
            book[index].partner = partners[index];
            slots[index] = StateLibrary._getPoolStateSlot(PoolId.wrap(ids[index]));
        }
        bytes32[] memory words = poolManager.extsload(slots);
        bool wraps = asking != 0;
        for (uint256 index; index < split; index++) {
            if (wraps) words[index] = _wrapped(ids[index], words[index]);
            _price(book[index], words[index], base);
        }
        // Venues from the twin's lists come last. A pool and its twin's pool differ in the
        // ether token that sets which way their price runs.
        if (split < count) book[0].twins = split;
        for (uint256 index = split; index < count; index++) {
            if (wraps) words[index] = _wrapped(ids[index], words[index]);
            _price(book[index], words[index], _twin(base));
        }
        // A wrapped pool keeps no price of its own and ignores a price limit, so a search
        // is never centred on one.
        if (wraps) {
            if (wrappers[poolId] != address(0)) book[0].rate = 0;
        }
        if (!redeemable) return book;
        book[count].partner = backingAsset;
        _requote(book[count]);
    }

    /// @dev Which pools a search prices and the partner token of each: the pool itself,
    /// the other leaders of its group, and the first leader of every other group.
    function _venues(bytes32 poolId, address partner)
        internal
        view
        returns (bytes32[] memory ids, address[] memory partners, uint256 count)
    {
        ids = new bytes32[](MAX_LEADERS + MAX_GROUPS);
        partners = new address[](MAX_LEADERS + MAX_GROUPS);
        uint256 id = active;
        address base = home;
        ids[0] = poolId;
        partners[0] = partner;
        count = 1;
        bytes32[] storage own = leaders[id][base][partner];
        uint256 length = own.length;
        for (uint256 index; index < length; index++) {
            bytes32 leader = own[index];
            if (leader == poolId) continue;
            ids[count] = leader;
            partners[count] = partner;
            count++;
        }
        address[] storage list = groups[id][base];
        mapping(address => bytes32) storage firsts = heads[id][base];
        length = list.length;
        for (uint256 index; index < length; index++) {
            address other = list[index];
            if (other == partner) continue;
            ids[count] = firsts[other];
            partners[count] = other;
            count++;
        }
    }

    /// @dev The venues read so far, in arrays with room for the twin's as well.
    function _grow(bytes32[] memory ids, address[] memory partners, uint256 count)
        internal
        pure
        returns (bytes32[] memory allIds, address[] memory allPartners)
    {
        allIds = new bytes32[](ids.length * 2);
        allPartners = new address[](ids.length * 2);
        for (uint256 index; index < count; index++) {
            allIds[index] = ids[index];
            allPartners[index] = partners[index];
        }
    }

    /// @dev The same lists under the other ether token, after the venues already read: the
    /// leaders of the same partner's group, then the first leader of every other group.
    function _twinVenues(
        bytes32[] memory ids,
        address[] memory partners,
        uint256 count,
        address partner
    ) internal view returns (uint256) {
        address base = _twin(home);
        bytes32[] storage own = leaders[active][base][partner];
        for (uint256 index; index < own.length; index++) {
            ids[count] = own[index];
            partners[count] = partner;
            count++;
        }
        address[] storage list = groups[active][base];
        for (uint256 index; index < list.length; index++) {
            if (list[index] == partner) continue;
            ids[count] = heads[active][base][list[index]];
            partners[count] = list[index];
            count++;
        }
        return count;
    }

    function _requote(Venue memory venue) internal view {
        if (venue.id == bytes32(0)) {
            (venue.rate, venue.keep) = _redeemQuote();
            return;
        }
        _price(venue, _word(venue.id), home);
    }

    /// @dev Whether the venue at `index` of a book holds the twin.
    function _onTwin(Venue[] memory book, uint256 index) internal pure returns (bool) {
        uint256 first = book[0].twins;
        if (first == 0) return false;
        return index >= first;
    }

    /// @dev Prices a venue again, in the direction of the ether token its pool holds.
    function _requoteAt(Venue[] memory book, uint256 index) internal view {
        if (_onTwin(book, index)) {
            Venue memory venue = book[index];
            return _price(venue, _word(venue.id), _twin(home));
        }
        _requote(book[index]);
    }

    /// @dev A pool's price and fee in the form of the first storage word of a v4 pool. For
    /// a pool on a hook with a pricer these come from the pricer; for any other, from the
    /// pool manager.
    function _word(bytes32 poolId) internal view returns (bytes32 word) {
        word = poolManager.extsload(StateLibrary._getPoolStateSlot(PoolId.wrap(poolId)));
        if (asking != 0) return _wrapped(poolId, word);
    }

    /// @dev What `word` should be if the pool is on a hook with a pricer: the pricer's
    /// answer, or nothing at all when it has none to give. Any other pool keeps its own.
    function _wrapped(bytes32 poolId, bytes32 word) internal view returns (bytes32) {
        address wrapper = wrappers[poolId];
        if (wrapper == address(0)) return word;
        address pricer = pricers[wrapper];
        if (pricer == address(0)) return bytes32(0);
        uint256[5] memory answer = _ask(pricer, poolId);
        return bytes32(answer[0] | (answer[1] << 208));
    }

    /// @dev A pool's liquidity: the pricer's figure for a pool on a hook that has one, the
    /// pool manager's for any other.
    function _units(bytes32 poolId) internal view returns (uint256 units) {
        if (asking == 0) return poolManager.getLiquidity(PoolId.wrap(poolId));
        address wrapper = wrappers[poolId];
        if (wrapper == address(0)) return poolManager.getLiquidity(PoolId.wrap(poolId));
        address pricer = pricers[wrapper];
        if (pricer == address(0)) return 0;
        units = _ask(pricer, poolId)[2];
    }

    /// @dev Asks a pricer about a pool. The call is read-only, gets the market's `asking`
    /// gas, and has exactly five words copied back: price, fee, liquidity, and the range
    /// the answer holds over. A failure, a different length or a value out of range all give
    /// zeros, which reads as no price. The book uses the first three words; the sizing walk
    /// also uses the range.
    function _ask(address pricer, bytes32 poolId)
        internal
        view
        returns (uint256[5] memory answer)
    {
        bytes memory question = abi.encodeCall(IVenuePricer.price, (keys[poolId]));
        uint256 allowance = asking;
        bool heard;
        assembly ("memory-safe") {
            heard := staticcall(
                allowance,
                pricer,
                add(question, 0x20),
                mload(question),
                answer,
                0xa0
            )
            if iszero(eq(returndatasize(), 0xa0)) { heard := 0 }
        }
        if (!heard) return _none();
        if (answer[0] > type(uint160).max) return _none();
        if (answer[1] >= 1e6) return _none();
        if (answer[2] > type(uint128).max) return _none();
        if (answer[3] > answer[0]) return _none();
        if (answer[4] < answer[0]) return _none();
        if (answer[3] < TickMath.MIN_SQRT_PRICE) return _none();
        if (answer[4] > TickMath.MAX_SQRT_PRICE) return _none();
        return answer;
    }

    function _none() internal pure returns (uint256[5] memory none) { }

    /// @dev Fills in a venue's price and fee factor from its pool's first storage word.
    /// `base` is the ether token the venue's pool holds, which is not always the token the
    /// search counts in.
    function _price(Venue memory venue, bytes32 word, address base) internal pure {
        uint24 fee;
        uint24 levy;
        (venue.rate, fee, levy) = _unpack(word, base < venue.partner);
        venue.keep = _keep(_swapFee(fee, levy));
    }

    /// @dev Prices every other venue against the focus pool and keeps the cycle expected
    /// to return the most. The profit check in `execute` decides.
    function _best(Venue[] memory book) internal view returns (Plan memory best) {
        // The pool searched is always the first entry.
        Venue memory own = book[0];
        if (own.rate == 0) return best;
        Focus memory focus;
        focus.id = own.id;
        focus.partner = own.partner;
        focus.rate = own.rate;
        focus.keep = own.keep;
        focus.edge = markets[active].edge * EDGE_UNIT;
        focus.seen = new address[](book.length);
        focus.routes = new Route[](book.length);
        for (uint256 other = 1; other < book.length; other++) {
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
        if (edge < focus.edge) return;
        if (edge > MAX_EDGE) return;
        if (venue.id == bytes32(0)) {
            // Core only buys SZR back; it is never a place to buy it.
            if (!buying) return;
        }
        // A venue that is also a link of its own route would be traded twice, which the
        // walk would model as two independent legs. Core has no pool, and its id is the
        // same as an unused link's, so it is not compared. Placed after the gap tests so
        // that a search with no gap does not pay for it.
        if (venue.id != bytes32(0)) {
            if (route.links[0] == venue.id) return;
            if (route.links[1] == venue.id) return;
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

    /// @dev In order: no link for the same token; the wrap link between the two ether
    /// tokens; one connecting pool; a connecting pool to the twin of an ether end, plus the
    /// wrap link; two pools that meet at WETH.
    function _route(address from, address to) internal view returns (Route memory route) {
        route.rate = Q96;
        route.keep = WAD;
        if (from == to) return route;
        // ETH and WETH together have bits that OR to WETH's address. This runs for every
        // partner of every search, so that is tested first and the rest only when it holds.
        address weth = backingAsset;
        bool possible;
        assembly ("memory-safe") {
            possible := eq(or(from, to), weth)
        }
        if (possible) {
            if (_isEther(from)) {
                if (_isEther(to)) {
                    _wrapHop(route, 0);
                    return route;
                }
            }
        }
        bytes32 direct = _connector(from, to);
        if (direct != bytes32(0)) {
            _hop(route, 0, direct, from < to);
            return route;
        }
        if (_viaTwin(route, from, to)) return route;
        // Two pools that meet at WETH would pass through the token profit is counted in.
        if (home == backingAsset) {
            route.rate = 0;
            return route;
        }
        bytes32 near = _connector(backingAsset, to);
        bytes32 far = _connector(from, backingAsset);
        // A missing pool has no price, which leaves the route's rate at zero.
        _hop(route, 0, near, backingAsset < to);
        _hop(route, 1, far, from < backingAsset);
    }

    /// @dev Exactly one end an ether token and a connecting pool between the other end and
    /// its twin: that pool and the wrap link, the pool nearest the focus pool.
    function _viaTwin(Route memory route, address from, address to)
        internal
        view
        returns (bool)
    {
        if (_isEther(from)) {
            address twin = _twin(from);
            bytes32 pool = _connector(twin, to);
            if (pool == bytes32(0)) return false;
            _hop(route, 0, pool, twin < to);
            _wrapHop(route, 1);
            return true;
        }
        if (_isEther(to)) {
            address twin = _twin(to);
            bytes32 pool = _connector(from, twin);
            if (pool == bytes32(0)) return false;
            _wrapHop(route, 0);
            _hop(route, 1, pool, from < twin);
            return true;
        }
        return false;
    }

    /// @dev The wrap link changes neither the rate nor the fees.
    function _wrapHop(Route memory route, uint256 slot) internal pure {
        route.links[slot] = WRAP;
        route.rates[slot] = Q96;
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
        // The route's rate is still `Q96` at the first slot, so the product is `rate`; the
        // multiplication is skipped because this runs for every partner of every search.
        route.rate = slot == 0 ? rate : FixedPointMathLib.fullMulDiv(route.rate, rate, Q96);
        route.keep = route.keep * keep / WAD;
    }

    /// @dev The SZR that closes a gap of 100% across every leg of the cycle together.
    function _cycleDepth(Focus memory focus, Venue memory venue, Route memory route)
        internal
        view
        returns (uint256 depth)
    {
        if (focus.depth == 0) {
            focus.depth = _depth(focus.id, focus.rate, focus.rate);
        }
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
        depth = _linkDepth(route.links[0], route.rates[0], flow);
        if (route.links[1] == bytes32(0)) return depth;
        flow = FixedPointMathLib.fullMulDiv(flow, Q96, route.rates[0]);
        depth = _harmonic(depth, _linkDepth(route.links[1], route.rates[1], flow));
    }

    /// @dev `candidate.gap` is how far the square-root prices are apart beyond fees, as a
    /// share (WAD). `depth` is the SZR that closes a gap of 100%
    /// across every leg together, so the gap times the depth is the SZR to trade and the
    /// gap times that again is the profit. The focus pool is moved only its own share of
    /// the way to `target`; the other legs move the rest.
    /// The estimate is a straight line from each pool's liquidity at its current price.
    /// It is wrong once a leg crosses into a different range, and `_attempt` goes on to
    /// other sizes: the whole gap, then halves of it.
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
        // The estimate has to clear the smallest profit with room to spare. A cycle
        // estimated just above it mostly returns just below, and fails at every size.
        if (score < uint256(minimumProfit[active][home]) * PLAN_MARGIN / 100) return;
        if (score <= best.score) return;
        Bench memory bench =
            benched[_pair(active, home, focus.id, candidate.venue, candidate.buying)];
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
        uint256 units = _units(poolId);
        uint256 scaled = FixedPointMathLib.fullMulDiv(units, rate, flow);
        if (scaled >= FixedPointMathLib.fullMulDiv(MAX_DEPTH, flow, Q96)) return MAX_DEPTH;
        return FixedPointMathLib.fullMulDiv(scaled, Q96, flow);
    }

    /// @dev The wrap link has no limit to how much it converts.
    function _linkDepth(bytes32 poolId, uint256 rate, uint256 flow)
        internal
        view
        returns (uint256)
    {
        if (poolId == WRAP) return MAX_DEPTH;
        return _depth(poolId, rate, flow);
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
        (rate, fee, levy) = _unpack(_word(poolId), baseFirst);
        keep = _keep(_swapFee(fee, levy));
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

    /// @notice The size of a cycle's first try, found by walking its legs across the
    /// initialised ticks they meet, up to `SIZING_STEPS` boundary events in all. Within one
    /// range the legs compose into one constant-product curve, whose best size has a closed
    /// form; when a leg reaches the edge of its range first, the walk moves every leg that
    /// far, crosses the tick, and solves again. It returns the focus pool's price limit and
    /// what it may pay in, or the plan's own estimate when the walk finds nothing to improve
    /// on. It only estimates: moves nothing, and a wrong answer is a worse size, caught by
    /// the profit check and the other sizes. A guard that trips reverts, and the first try
    /// then uses the estimate. Only cycles whose every leg is a plain pool, a wrapped pool, the
    /// wrap link or Core are sized; see `_sizeable`. A wrapped pool is asked its price and
    /// the range that holds over, and reaching the end of that range is the end of its leg. It
    /// is an under-trade, not a dead end: a cycle with a wrapped leg is never declined.
    /// `declined` is true when the walk reached its natural end and the best size there is
    /// cannot earn the smallest profit; `_attempt` then tries no size at all.
    function size(bytes32 poolId, Plan calldata plan)
        external
        view
        onlySelf
        returns (uint160 limit, uint256 spend, bool declined)
    {
        (limit, spend,, declined) = _walk(poolId, plan);
    }

    /// @dev Whether every leg of a cycle is one the walk can read: a plain pool, a wrapped
    /// pool, the wrap link or Core. A leg is wrapped if its pool was added as one or if its
    /// hook now has a pricer, the test `_legLimit` makes, so a pool added before its hook was
    /// given a pricer is not walked as plain and traded as wrapped. A wrapped pool whose pricer
    /// gives no range is read here, and the walk then gives up on it and uses the estimate.
    /// Virtual so that a test can switch the walk off and exercise the other sizes alone.
    function _sizeable(Plan memory plan) internal view virtual returns (bool) {
        if (!_readable(plan.venue)) return false;
        if (!_readable(plan.links[0])) return false;
        return _readable(plan.links[1]);
    }

    function _readable(bytes32 poolId) internal view returns (bool) {
        if (poolId == bytes32(0)) return true;
        if (poolId == WRAP) return true;
        address wrapper = wrappers[poolId];
        if (wrapper != address(0)) {
            // `wrappers` is global but `asking` is one market's. A pool another market added
            // as wrapped is traded as wrapped here, but this search cannot ask its pricer.
            if (asking == 0) return false;
            return pricers[wrapper] != address(0);
        }
        return pricers[address(keys[poolId].hooks)] == address(0);
    }

    /// @dev The gas the walk is given: its own, and what a pricer gets for each wrapped leg
    /// it asks.
    function _sizingGas(Plan memory plan) internal view returns (uint256 gas) {
        uint256 each = asking;
        if (each == 0) return SIZING_GAS;
        uint256 wrapped;
        if (_asked(true, plan.venue)) wrapped++;
        if (_asked(true, plan.links[0])) wrapped++;
        if (_asked(true, plan.links[1])) wrapped++;
        gas = SIZING_GAS + wrapped * each;
        // A large pricer allowance must not let the walk eat the gas held back for the tries
        // after it, the swap and the search that follows.
        uint256 most = _plan(each) / 2 - SIZING_CALL_GAS;
        if (gas > most) gas = most;
    }

    /// @dev Whether the walk asks a pricer about this pool. A market with no wrapped pool
    /// has `asking` zero, and nothing to look up.
    function _asked(bool asks, bytes32 poolId) internal view returns (bool) {
        if (!asks) return false;
        return wrappers[poolId] != address(0);
    }

    function _walk(bytes32 poolId, Plan calldata plan)
        internal
        view
        returns (uint160 limit, uint256 spend, uint256 steps, bool declined)
    {
        (Leg[] memory legs, uint256 focus) = _legs(poolId, plan);
        _load(legs, plan.gap, plan.full, focus);
        Walk memory walk;
        // Reaching a wrapped leg's range end is an under-trade, never a dead end: the venue
        // may hold deep liquidity past what its pricer reports, so the walk never declines.
        for (uint256 index; index < legs.length; index++) {
            if (legs[index].wrapped) walk.stopped = true;
        }
        for (uint256 round; round <= SIZING_STEPS; round++) {
            if (!_round(legs, walk, focus, round)) break;
        }
        steps = walk.steps;
        return _answer(walk, plan, steps);
    }

    /// @dev One round of the walk: crosses a hole, or solves the legs within their ranges and
    /// moves them to the nearest boundary. False when the walk is over. Whatever the walk
    /// could not carry on with after it has found a size is a stop, never a decline.
    function _round(Leg[] memory legs, Walk memory walk, uint256 focus, uint256 round)
        internal
        view
        returns (bool)
    {
        // Short of gas for another step: what has been found is an under-trade.
        if (gasleft() < legs.length * SIZING_STEP_GAS + SIZING_TAIL_GAS) {
            walk.stopped = true;
            return false;
        }
        uint256 empty = _shapeAll(legs);
        if (empty != legs.length) return _pass(legs[empty], walk, round);
        (uint256 rate, uint256 depth, bool fits) = _compose(legs);
        if (!fits) {
            walk.stopped = true;
            return false;
        }
        if (rate <= Q96) return false;
        uint256 cycle = FixedPointMathLib.fullMulDiv(depth, rate - Q96, Q96);
        uint256 hit;
        // A best size of zero, or of no more than the few wei that rounding is worth, with the
        // rate still above break-even is a range too thin to matter, not the optimum: go to
        // its nearest boundary, and across it if that is zero too.
        bool thin = cycle <= SIZING_WEI;
        (cycle, hit) = _bounded(legs, thin ? type(uint256).max : cycle);
        bool crossing = hit != legs.length;
        if (!crossing) {
            if (thin) return false;
        }
        // The next boundary is further than the few wei that rounding is worth: this is the
        // optimum, not a range to skip.
        if (thin) {
            if (cycle > SIZING_WEI) return false;
        }
        if (crossing) {
            if (_ends(legs[hit])) crossing = false;
        }
        _step(legs, walk, cycle, hit, focus, crossing);
        if (!crossing) return false;
        return _carryOn(legs[hit], walk, round);
    }

    /// @dev A leg in a hole, or in a range too thin to shape, crosses to its next boundary
    /// for nothing, as in v4. The end of the leg is the only dead end.
    function _pass(Leg memory leg, Walk memory walk, uint256 round)
        internal
        view
        returns (bool)
    {
        if (_ends(leg)) return false;
        return _carryOn(leg, walk, round);
    }

    function _carryOn(Leg memory leg, Walk memory walk, uint256 round)
        internal
        view
        returns (bool)
    {
        if (round == SIZING_STEPS) {
            walk.stopped = true;
            return false;
        }
        _cross(leg);
        walk.steps++;
        if (leg.broken) {
            walk.stopped = true;
            return false;
        }
        return true;
    }

    /// @dev What the walk answers. A walk that ran to its natural end, the optimum within
    /// range or the end of a leg, and found too little is final: profit is concave in size,
    /// so no size can earn what this one cannot. One that stopped short answers only if what
    /// it found is enough. Every size is held back by a millionth and a few wei, so that
    /// every leg still fills whatever rounding the crossings left.
    function _answer(Walk memory walk, Plan calldata plan, uint256 steps)
        internal
        view
        returns (uint160, uint256, uint256, bool)
    {
        if (walk.total == 0) return (plan.limit, plan.spend, steps, false);
        bool poor = walk.predicted < int256(uint256(minimumProfit[active][home]));
        if (poor) {
            return (plan.limit, plan.spend, steps, !walk.stopped);
        }
        uint256 spend = _shaved(plan.buying ? walk.focusIn : walk.total);
        uint256 most = uint256(uint128(type(int128).max));
        if (spend > most) spend = most;
        if (spend == 0) return (plan.limit, plan.spend, steps, false);
        return (plan.full, spend, steps, false);
    }

    function _shaved(uint256 spend) internal pure returns (uint256) {
        uint256 cut = spend / SIZING_SHAVE + SIZING_WEI;
        return spend > cut ? spend - cut : 0;
    }

    /// @dev Moves every leg by `cycle` of cycle input and books the result.
    function _step(
        Leg[] memory legs,
        Walk memory walk,
        uint256 cycle,
        uint256 hit,
        uint256 focus,
        bool force
    ) internal pure {
        uint256 out;
        uint256 focusIn;
        (out, focusIn) = _advance(legs, cycle, force ? hit : legs.length, focus);
        walk.total += cycle;
        walk.focusIn += focusIn;
        walk.predicted += int256(out) - int256(cycle);
    }

    /// @dev The legs of a cycle in the order value flows, and the focus pool's place in it.
    /// A selling cycle runs the focus pool first and the venue last; a buying cycle the
    /// other way round, so its legs are found in the order `_buyCycle` trades them and
    /// turned over.
    function _legs(bytes32 poolId, Plan calldata plan)
        internal
        view
        returns (Leg[] memory legs, uint256 focus)
    {
        Leg[] memory found = new Leg[](4);
        uint256 count;
        bool buying = plan.buying;
        PoolKey memory key = keys[poolId];
        address asset = _other(key, home);
        found[count++] = _leg(poolId, key, buying ? asset : home);
        for (uint256 hop; hop < 2; hop++) {
            bytes32 link = plan.links[hop];
            if (link == bytes32(0)) break;
            if (link == WRAP) {
                asset = _twin(asset);
                continue;
            }
            key = keys[link];
            found[count++] = _leg(link, key, buying ? _other(key, asset) : asset);
            asset = _other(key, asset);
        }
        if (plan.venue == bytes32(0)) {
            found[count].rate = _coreRate();
            found[count++].depth = MAX_DEPTH;
        } else {
            key = keys[plan.venue];
            found[count++] = _leg(plan.venue, key, buying ? _other(key, asset) : asset);
        }
        legs = new Leg[](count);
        for (uint256 index; index < count; index++) {
            legs[buying ? count - 1 - index : index] = found[index];
        }
        focus = buying ? count - 1 : 0;
    }

    function _coreRate() internal view returns (uint256 rate) {
        (rate,) = _redeemQuote();
        if (rate == 0) revert Unsizable();
    }

    /// @dev A pool as a leg whose input is `input`.
    function _leg(bytes32 poolId, PoolKey memory key, address input)
        internal
        pure
        returns (Leg memory leg)
    {
        leg.id = poolId;
        leg.zeroForOne = Currency.unwrap(key.currency0) == input;
        leg.spacing = key.tickSpacing;
    }

    /// @dev Reads every leg's price, fee and liquidity in one call to the pool manager, and
    /// finds each one's first boundary. A wrapped pool is asked instead, and its boundary is
    /// the end of the range it reports. Whatever is out of bounds reverts.
    function _load(Leg[] memory legs, uint256 gap, uint160 full, uint256 focus) internal view {
        uint256 count = legs.length;
        bool asks = asking != 0;
        bytes32[] memory slots = new bytes32[](count * 2);
        uint256 read;
        for (uint256 index; index < count; index++) {
            if (legs[index].id == bytes32(0)) continue;
            if (_asked(asks, legs[index].id)) continue;
            bytes32 slot = StateLibrary._getPoolStateSlot(PoolId.wrap(legs[index].id));
            slots[read++] = slot;
            slots[read++] = bytes32(uint256(slot) + 3);
        }
        assembly ("memory-safe") {
            mstore(slots, read)
        }
        bytes32[] memory words = poolManager.extsload(slots);
        read = 0;
        for (uint256 index; index < count; index++) {
            Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) continue;
            if (_asked(asks, leg.id)) {
                _loadWrapped(leg, gap);
                continue;
            }
            // Read into locals: the order arguments are evaluated in is not specified.
            uint256 first = uint256(words[read++]);
            uint256 second = uint256(words[read++]);
            _read(leg, first, second, gap);
            if (index == focus) leg.limit = full;
            _bound(leg);
            // Nothing is found yet, so a boundary that cannot be read is a guard.
            if (leg.broken) revert Unsizable();
        }
    }

    /// @dev A wrapped pool as a leg: its pricer's price, fee and liquidity, as the book reads
    /// them. It has no ticks and ignores a price limit, so the end of the range the pricer
    /// reports, in the direction the leg trades, is where it ends. Without a price, or with
    /// no room before that end, the walk gives up and the estimate is used.
    function _loadWrapped(Leg memory leg, uint256 gap) internal view {
        uint256[5] memory answer = _ask(pricers[wrappers[leg.id]], leg.id);
        _read(leg, answer[0] | (answer[1] << 208), answer[2], gap);
        leg.target = uint160(leg.zeroForOne ? answer[3] : answer[4]);
        leg.edge = true;
        leg.wrapped = true;
        if (leg.target == leg.price) revert Unsizable();
    }

    /// @dev Fills in a leg from the first word of its pool's state, as `Pool.swap` reads it:
    /// the fee is the one for the leg's direction.
    function _read(Leg memory leg, uint256 packed, uint256 units, uint256 gap) internal pure {
        leg.price = uint160(packed);
        leg.tick = int24(uint24(packed >> 160));
        uint16 levy = uint16(leg.zeroForOne ? (packed >> 184) & 0xfff : (packed >> 196) & 0xfff);
        uint24 lpFee = uint24(packed >> 208);
        leg.fee = levy == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(levy, lpFee);
        leg.liquidity = uint128(units);
        if (leg.price == 0) revert Unsizable();
        if (leg.fee >= 1e6) revert Unsizable();
        uint256 rate = leg.zeroForOne ? leg.price : Q192 / leg.price;
        if (rate < MIN_RATE) revert Unsizable();
        if (rate > MAX_RATE) revert Unsizable();
        leg.keep = _keep(leg.fee);
        // The limit the real trade is given, `_legLimit`; the focus leg's is set by the caller.
        leg.limit = _limitFrom(leg.price, leg.zeroForOne, gap);
    }

    /// @dev The next tick `Pool.swap` would stop at going the leg's way: the next
    /// initialised one within a bitmap word, or the word's edge when it has none. Reaching
    /// the end of the tick range is the end of liquidity.
    function _bound(Leg memory leg) internal view {
        int24 compressed = TickBitmap.compress(leg.tick, leg.spacing);
        PoolId pool = PoolId.wrap(leg.id);
        int24 next;
        unchecked {
            if (leg.zeroForOne) {
                (int16 word, uint8 bit) = TickBitmap.position(compressed);
                uint256 masked =
                    poolManager.getTickBitmap(pool, word) & (type(uint256).max >> (255 - bit));
                leg.initialized = masked != 0;
                uint8 back = leg.initialized ? bit - BitMath.mostSignificantBit(masked) : bit;
                next = (compressed - int24(uint24(back))) * leg.spacing;
            } else {
                (int16 word, uint8 bit) = TickBitmap.position(++compressed);
                uint256 masked =
                    poolManager.getTickBitmap(pool, word) & ~((uint256(1) << bit) - 1);
                leg.initialized = masked != 0;
                uint8 ahead = leg.initialized
                    ? BitMath.leastSignificantBit(masked) - bit
                    : type(uint8).max - bit;
                next = (compressed + int24(uint24(ahead))) * leg.spacing;
            }
        }
        leg.edge = next <= TickMath.MIN_TICK || next >= TickMath.MAX_TICK;
        if (next <= TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        if (next >= TickMath.MAX_TICK) next = TickMath.MAX_TICK;
        leg.next = next;
        leg.target = TickMath.getSqrtPriceAtTick(next);
        // The real trade is stopped at its limit, so that is where the leg ends if nearer.
        if (leg.zeroForOne) {
            if (leg.target <= leg.limit) (leg.target, leg.edge) = (leg.limit, true);
            if (leg.target > leg.price) leg.broken = true;
        } else {
            if (leg.target >= leg.limit) (leg.target, leg.edge) = (leg.limit, true);
            if (leg.target < leg.price) leg.broken = true;
        }
    }

    /// @dev The cycle's whole chain of legs, at their current prices, as one curve:
    /// its marginal rate at size zero (a Q96 square root) and its depth in input units. Each
    /// leg also keeps the same for the legs before it. See `docs/specs/hook-exact-sizing.md`.
    function _compose(Leg[] memory legs)
        internal
        pure
        returns (uint256 rate, uint256 depth, bool fits)
    {
        rate = Q96;
        depth = MAX_DEPTH;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            leg.depthIn = depth;
            uint256 flow = FixedPointMathLib.fullMulDiv(
                FixedPointMathLib.fullMulDiv(depth, rate, Q96), rate, Q96
            );
            leg.flowIn = flow;
            depth = FixedPointMathLib.fullMulDiv(depth, leg.depth, leg.depth + flow);
            rate = FixedPointMathLib.fullMulDiv(rate, leg.rate, Q96);
            if (rate > MAX_CYCLE_RATE) return (0, 0, false);
        }
        return (rate, depth, true);
    }

    /// @dev Shapes every leg, and says which is the first with no depth to compose: in a hole,
    /// or in a range so thin that its depth rounds to zero. Such a leg is crossed for
    /// nothing. `legs.length` if there is none.
    function _shapeAll(Leg[] memory legs) internal pure returns (uint256 empty) {
        empty = legs.length;
        for (uint256 index; index < legs.length; index++) {
            if (legs[index].id == bytes32(0)) continue;
            _shape(legs[index]);
            if (empty == legs.length) {
                if (legs[index].depth == 0) empty = index;
            }
        }
    }

    /// @dev A leg's rate and depth from its price and liquidity: the input token's side of
    /// its virtual reserves, with the fee taken from the input.
    function _shape(Leg memory leg) internal pure {
        uint256 price = leg.price;
        uint256 reserve;
        if (leg.liquidity == 0) {
            leg.depth = 0;
            return;
        }
        if (leg.zeroForOne) {
            leg.rate = FixedPointMathLib.fullMulDiv(price, leg.keep, WAD);
            reserve = FixedPointMathLib.fullMulDiv(leg.liquidity, Q96, price);
        } else {
            leg.rate = FixedPointMathLib.fullMulDiv(Q192, leg.keep, price * WAD);
            reserve = FixedPointMathLib.fullMulDiv(leg.liquidity, price, Q96);
        }
        uint256 depth = FixedPointMathLib.fullMulDiv(reserve, 1e6, 1e6 - leg.fee);
        leg.depth = depth > MAX_DEPTH ? MAX_DEPTH : depth;
    }

    /// @dev The cycle input at which the first leg to reach its boundary does, if that is
    /// less than `cycle`, and which leg it is (`legs.length` for none). A leg gets `x` of
    /// its own input from the legs before it when the cycle puts in `x * P / (M * P - x)`,
    /// `M` and `P` being their price and depth; if they can never supply `x` the leg never
    /// gets there.
    function _bounded(Leg[] memory legs, uint256 cycle)
        internal
        pure
        returns (uint256, uint256 hit)
    {
        hit = legs.length;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) continue;
            leg.reach = _reach(leg);
            uint256 input = leg.reach;
            if (index != 0) {
                if (input >= leg.flowIn) continue;
                input = FixedPointMathLib.fullMulDiv(input, leg.depthIn, leg.flowIn - input);
            }
            if (input < cycle) {
                cycle = input;
                hit = index;
            }
        }
        return (cycle, hit);
    }

    /// @dev The gross input, fee included, that takes a leg from its price to its boundary.
    function _reach(Leg memory leg) internal pure returns (uint256 amount) {
        amount = leg.zeroForOne
            ? SqrtPriceMath.getAmount0Delta(leg.target, leg.price, leg.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(leg.price, leg.target, leg.liquidity, true);
        amount += FullMath.mulDivRoundingUp(amount, leg.fee, 1e6 - leg.fee);
    }

    /// @dev Whether the leg's boundary is the end of the leg, its price limit or the end of the
    /// tick range. If not, it also finds the liquidity past it, for `_cross`. Zero liquidity
    /// past it is a hole, which is crossed, not an end.
    function _ends(Leg memory leg) internal view returns (bool) {
        if (leg.edge) return true;
        leg.beyond = leg.liquidity;
        if (!leg.initialized) return false;
        (, int128 net) = poolManager.getTickLiquidity(PoolId.wrap(leg.id), leg.next);
        leg.beyond = LiquidityMath.addDelta(leg.liquidity, leg.zeroForOne ? -net : net);
        return false;
    }

    /// @dev Moves a leg across its boundary, as `Pool.swap` does, and finds the next one.
    function _cross(Leg memory leg) internal view {
        leg.price = leg.target;
        leg.liquidity = leg.beyond;
        leg.tick = leg.zeroForOne ? leg.next - 1 : leg.next;
        _bound(leg);
    }

    /// @dev Trades `cycle` through every leg in turn, as `SwapMath` would, and returns what
    /// the last one pays out and what went into the focus pool. The leg at `hit` is taken to
    /// its boundary whatever rounding says, since it is the one the walk is stopping at.
    function _advance(Leg[] memory legs, uint256 cycle, uint256 hit, uint256 focus)
        internal
        pure
        returns (uint256 amount, uint256 focusIn)
    {
        amount = cycle;
        for (uint256 index; index < legs.length; index++) {
            Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) {
                amount = FixedPointMathLib.fullMulDiv(
                    FixedPointMathLib.fullMulDiv(amount, leg.rate, Q96), leg.rate, Q96
                );
                continue;
            }
            if (index == hit) {
                if (amount < leg.reach) amount = leg.reach;
            }
            if (index == focus) focusIn = amount;
            if (amount == 0) continue;
            (leg.price,, amount,) = SwapMath.computeSwapStep(
                leg.price, leg.target, leg.liquidity, -int256(amount), leg.fee
            );
        }
    }
}
