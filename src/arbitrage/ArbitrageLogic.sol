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
import { SzrCore } from "../SzrCore.sol";
import { Liquidity } from "../Liquidity.sol";
import { IVenuePricer } from "../interfaces/IVenuePricer.sol";
import { SizingWalk } from "./lib/SizingWalk.sol";
import { V4Read } from "./lib/V4Read.sol";

/// @dev Only the WETH calls the ETH payout and the wrap link need.
interface IWrapped {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @dev `SZR_MARKET`, readable without a call to the hook by contracts that only name it.
uint256 constant SZR_MARKET_ID = 1;

/// @dev What the hook calls on itself. Each call is a real call back into the hook, so its gas
/// cap and its revert frame hold, and its `fallback` sends it on to the module that has the
/// code. Declared here because the logic contract has none of these functions. `askFrame` is
/// the exception: the hook runs it itself, so its self-call has no hop to a module.
interface IArbitrageSelf {
    function search(
        bytes32 poolId,
        uint256 id,
        address base,
        address partner,
        bool capped,
        bool before,
        address payer
    ) external returns (uint256 profit);

    function searchMany(
        bytes32[] calldata centres,
        uint256 id,
        address[] calldata bases,
        address[] calldata partners,
        bool capped,
        bool before,
        address payer
    ) external;

    function execute(bytes32 poolId, ArbitrageLogic.Plan calldata plan)
        external
        returns (uint256 profit);

    function size(bytes32 poolId, ArbitrageLogic.Plan calldata plan)
        external
        view
        returns (uint160 limit, uint256 spend, bool declined, bool short);

    function askFrame(address pricer, bytes32 poolId) external;

    function retire(uint256 profit) external;
}

/// @notice Everything the arbitrage hook is made of except its entry points: the constants, the
/// storage, the events and every internal function. The hook and its modules all inherit it,
/// so they share one storage layout, and only this contract declares storage.
/// @dev The hook's code is split over several contracts so that each fits the 24,576-byte
/// limit that many chains have. The hook keeps the state and reaches the modules by
/// delegatecall; see `docs/specs/hook-split.md`.
abstract contract ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice Pools are grouped by their partner token. A search does not price every pool:
    /// it prices the leaders of the searched pool's own group, the first leader of every
    /// other group, and Core. So what a swap costs depends on these two bounds and not on
    /// how many pools are tracked.
    /// @dev How long a nominee may take a market after being named, so an old nomination
    /// cannot be accepted long after the people who rely on the market last looked.
    uint256 public constant NOMINATION_WINDOW = 7 days;
    uint256 public constant MAX_GROUPS = 8;
    uint256 public constant MAX_LEADERS = 3;
    /// @notice The most searches one wrapped venue can start, across all markets.
    uint256 public constant MAX_TRIGGERS = 2;
    /// @notice The most gas one trigger's searches may use, set by the wrapper per trigger,
    /// so a registered market cannot make every swap through the wrapper spend almost all
    /// its gas by raising its own allowance. A search only starts with its whole floor
    /// available, so the bound cannot be much lower. Measured since the live-pricer change
    /// (`docs/specs/hook-live-pricers.md`), for a market with one pricer-priced pool and one
    /// group, the floors are about 2.8M for the search after a swap and 6.5M for the one
    /// before it at the old default pricer allowance, or 3.1M and 7.2M with an allowance of
    /// 100k. A heavy market of 23 venues with seven or more wrapped pools needs more than
    /// 12M for its before-fill search; 16M covers about 22 wrapped pools. Both triggers
    /// (`MAX_TRIGGERS`) together come to 32M, which is the chain's whole transaction cap,
    /// so the swap relies on a trigger spending less than its cap.
    uint256 public constant MAX_TRIGGER_GAS = 16_000_000;
    /// @notice The gas a trigger's searches always leave for what follows: before a fill,
    /// the fill and the rest of the route (on top of the floor's own allowance for the swap);
    /// after it, the router's later work.
    uint256 public constant VENUE_RESERVE = 1_000_000;
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
    /// @dev What the hook's own call to one of its modules costs beyond the module's work: the
    /// first touch of a cold module (2,600), the routing and the copying of the call. A self-call
    /// is given its cap raised by a 64th and this, so the module gets the cap and not less.
    uint256 internal constant HOP_GAS = 4_000;
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
    /// @dev The walk's constants live with its engine, `SizingWalk`; see `size`.
    uint256 internal constant SIZING_STEPS = SizingWalk.SIZING_STEPS;
    /// @dev The gas the sizing walk is given. It lets every measured route reach
    /// `SIZING_STEPS` except dust at every tick, which stops for gas a step or two short (see
    /// `docs/specs/hook-exact-sizing.md`). The walk stops when it cannot afford another step
    /// (see `SIZING_STEP_GAS`), so a walk that would need more returns the size it has found
    /// so far instead of running out.
    uint256 internal constant SIZING_GAS = 240_000;
    uint256 internal constant SIZING_STEP_GAS = SizingWalk.SIZING_STEP_GAS;
    uint256 internal constant SIZING_TAIL_GAS = SizingWalk.SIZING_TAIL_GAS;
    uint256 internal constant SIZING_SHAVE = SizingWalk.SIZING_SHAVE;
    uint256 internal constant SIZING_WEI = SizingWalk.SIZING_WEI;
    /// @dev How far above the smallest profit a cycle's estimate must be to be tried, in
    /// percent.
    uint256 internal constant PLAN_MARGIN = 125;
    /// @dev A stand-in plan is made only for a focus pool with less than one in this many
    /// of the rest of the cycle's depth. Pools of ordinary depth stay clear of it: at
    /// a tenth, the real estimate is at least an eleventh of the stand-in's, so only a gap
    /// worth under about eleven times the gate can hide.
    uint256 internal constant STANDIN_RATIO = 10;
    /// @dev A square-root price gap beyond this (a 16x price difference) is a broken or
    /// manipulated venue, not something to arbitrage.
    uint256 internal constant MAX_EDGE = 4e18;
    /// @dev Bounds that keep the pricing arithmetic from overflowing whatever a pool's state
    /// (see `V4Read`). The ones the walk and the pool reads share are declared there.
    uint256 internal constant MIN_RATE = V4Read.MIN_RATE;
    uint256 internal constant MAX_RATE = V4Read.MAX_RATE;
    uint256 internal constant MAX_ROUTE_RATE = 1 << 192;
    uint256 internal constant MAX_CYCLE_RATE = SizingWalk.MAX_CYCLE_RATE;
    uint256 internal constant MIN_CYCLE_KEEP = 1e12;
    uint256 internal constant MAX_DEPTH = SizingWalk.MAX_DEPTH;
    uint256 internal constant WAD = V4Read.WAD;
    /// @dev A reserved link id for converting between ETH and WETH one for one. It is no
    /// pool: it has rate `Q96`, keep `WAD` and depth `MAX_DEPTH`, and reads no storage.
    bytes32 internal constant WRAP = bytes32(uint256(1));
    uint256 internal constant Q96 = V4Read.Q96;
    uint256 internal constant Q192 = V4Read.Q192;
    address internal constant UNRELEASED = address(1);
    /// @dev While a sweep or a trigger runs its heads, `REUSE_SLOT` is set, and `ANSWERED_SLOT`
    /// holds the market whose pricers the run has asked, or zero.
    uint256 internal constant REUSE_SLOT = uint256(keccak256("ArbitrageHook.reuse"));
    uint256 internal constant ANSWERED_SLOT = uint256(keccak256("ArbitrageHook.answered"));
    /// @dev Where a swap's books are kept for the search after it (see `_keepCentres`).
    uint256 internal constant CENTRES_SLOT = uint256(keccak256("ArbitrageHook.centres"));
    /// @dev Where remembered venues are kept in transient storage, three words each.
    uint256 internal constant REMEMBER_SLOT = uint256(keccak256("ArbitrageHook.remembered"));
    /// @dev Where, in transient storage, a search over several books keeps what each book
    /// has earned and not yet been paid out, per token (`_credited`).
    uint256 internal constant CREDIT_SLOT = uint256(keccak256("ArbitrageHook.credited"));
    /// @dev What `_centres` reads for each chosen token before a swap's search starts (the
    /// token's place in the list, its approval, then a leader for each of the pool's tokens),
    /// cold, outside the search's own allowance. The worst case, a token with no leader, was
    /// measured at about 13,500 by `testCentresCostWithinReserve`, and is rounded up.
    uint256 internal constant CENTRE_GAS = 15_000;
    /// @dev What `_centres` costs before its first token, cold: the connector read. A market
    /// with one token was measured at about 18,900 in all, two at about 32,400.
    uint256 internal constant CENTRE_BASE = 6_000;
    /// @dev Gas that must be left, per venue, for remembering them to be worth starting.
    uint256 internal constant REMEMBER_GAS = 2_000;
    /// @dev `minimumEdge` is stored in these units: a thousandth of a millionth of a
    /// millionth of the price, far finer than any gap worth acting on.
    uint256 internal constant EDGE_UNIT = 1_000;
    /// @dev The gas a pricer is given for one answer is set by each market's owner, in
    /// these units, and starts at `ASK_DEFAULT` of them. Asking also costs the frame around
    /// the call (`ASK_OVERHEAD`). A search asks every wrapped pool of its market once when it
    /// starts, and keeps the answers (`_fill`); everything after reads them. A market that
    /// uses such pools reserves one ask per wrapped pool to read the venues, three more for
    /// a cycle that goes through three of them, and `CACHE_READ_GAS` for each of the five
    /// words read per venue when they are ranked. The sizing walk reads the answers too.
    /// @dev The default is 12 units (48,000 gas): the live aggregator pool measured about
    /// 40,000 cold, so it has room. A Metric pool costs about 84,000 and needs its owner to
    /// call `setPricerGas` with about 100,000; until then it has no price.
    uint256 internal constant ASK_UNIT = 4_000;
    uint8 internal constant ASK_DEFAULT = 12;
    /// @dev What one ask costs beyond the pricer's own gas: the self-call, the frame's cold
    /// reads of the pool's key and its call to a cold pricer, the revert and its decode, and
    /// five transient writes. Measured at 19,462 and rounded up by about a fifth. The
    /// holdbacks of a 64th are not in it: `_refresh` starts an ask only with them covered.
    uint256 internal constant ASK_OVERHEAD = 24_000;
    /// @dev What reading one answer from the cache costs. Measured at 1,914, with margin.
    uint256 internal constant CACHE_READ_GAS = 2_500;
    /// @dev Where a search's answers are kept in transient storage, five words each, under
    /// the search's number and the pool.
    uint256 internal constant ANSWER_SLOT = uint256(keccak256("ArbitrageHook.answers"));
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

    /// @dev The pool a cycle is centred on, the end that carries the price limit. In an
    /// ordinary plan that is the search's start pool. When the start pool is wrapped the
    /// ends are exchanged and this is built from each plain candidate instead, so `id` is
    /// never a wrapped pool. `depth` is the SZR it takes to move that
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
        // Whether the search started from this pool, the only one a stand-in is made for.
        bool start;
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
        uint40 nominatedAt;
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
        // A plan made against an empty focus pool, sized by the rest of the cycle alone.
        bool standin;
    }

    /// @dev The books a swap opens (`_centres`): where each is centred, its token, and its
    /// partner token, in step. `count` of them are used.
    struct Centres {
        bytes32[] centres;
        address[] bases;
        address[] partners;
        uint256 count;
        bool sawEther;
    }

    /// @dev A search over several books (`searchMany`). `books`, `bases`, `nexts` and
    /// `profits` run in step: each book's token, the venue it would be looked at from
    /// next (its length for none), and what it has earned.
    struct Many {
        Venue[][] books;
        address[] bases;
        uint256[] nexts;
        uint256[] profits;
        uint256 venues;
        uint256 floor;
        uint256 failures;
        bool earned;
        bool capped;
        bool before;
        address payer;
        address resync;
    }

    IPoolManager public immutable poolManager;
    Liquidity public immutable liquidity;
    SzrCore public immutable core;
    address public immutable token;
    address public immutable backingAsset;

    /// @notice SZR's own market, the first one. Its profit token is always SZR, it alone
    /// has Core redemption as a venue, and it retires its profit instead of paying it out.
    uint256 public constant SZR_MARKET = SZR_MARKET_ID;
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
    /// @dev How many wrapped pools the market being searched has, set when a search asks them
    /// (`_fill`), and only meaningful while `asking` is not zero.
    uint256 internal transient pooled;
    /// @dev The number of the search whose answers the cache holds. Every search that asks
    /// raises it, so nothing has to be cleared, and an answer of an earlier search is never
    /// read. The search after a swap keeps its predecessor's number when it keeps its venues'
    /// prices (see `_open`).
    uint256 internal transient searching;
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

    /// @dev The searches a wrapped venue starts around its own swaps; see `venueSearch`.
    struct Trigger {
        uint32 market;
        uint32 gasCap;
        address base;
    }

    mapping(bytes32 poolId => Trigger[]) internal triggers;
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
    /// @dev The distinct wrapped pools each market tracks or uses as a connecting pool, and
    /// each one's place in that list from one. A search asks each of them once.
    mapping(uint256 market => bytes32[]) internal wrappedIn;
    mapping(uint256 market => mapping(bytes32 poolId => uint256)) internal wrappedAt;
    /// @notice The most `gasForSwap` a market may ask of a swap when it is switched on or
    /// changed. Declared last, so that no slot above it moves.
    uint256 public swapGasCeiling;

    error InvalidHookAddress();
    error NotManager();
    error NominationExpired();
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
    error Incomplete();
    error Unprofitable();
    error Starved();
    /// @dev What `askFrame` always reverts with when the pricer answered with five words.
    error Answer(uint256[5] answer);
    error InsufficientGas();
    error TooManyMarkets();
    error NotTrusted();
    error TooManyTriggers();

    event MarketOpened(uint256 indexed market, address indexed owner);
    event OwnerNominated(uint256 indexed market, address indexed nominee);
    event OwnerSet(uint256 indexed market, address indexed owner);
    event RecipientSet(uint256 indexed market, address recipient);
    event ProfitTokenSet(address indexed asset, address recipient);
    event TokensSet(uint256 indexed market, address[] assets);
    event SwapGasCeilingSet(uint256 ceiling);
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
    /// @notice A search found a cycle and had too little gas to start it. Seen often, it
    /// means the gas allowance is too small for the venues a search prices. A search that
    /// stops early to keep what it has already earned is usually not reported, since ranking
    /// again only to say so would cost gas in every profitable search. It can still be, when
    /// ranking itself used the last of the gas.
    event SearchCutShort(bytes32 indexed poolId);
    event VenueTriggerSet(
        uint256 indexed market, bytes32 indexed poolId, address token, uint32 gasCap, bool on
    );
    /// @notice A venue's trigger found too little gas for a search and stood aside.
    event VenueSearchSkipped(bytes32 indexed poolId, uint256 indexed market, bool before);
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
        liquidity = treasury;
        core = treasury.core();
        poolManager = treasury.poolManager();
        token = treasury.token();
        backingAsset = treasury.backingAsset();
    }

    /// @dev The one-time setup only the hook runs, from its constructor. The modules share
    /// this storage layout but have storage of their own, which none of this is for, and the
    /// test probe, which stands in for all of them, runs it too.
    function _initialise() internal {
        // Core pulls SZR for both `redeem` and `donateSzr`. The hook holds none in between.
        SafeTransferLib.safeApprove(token, address(core), type(uint256).max);
        // The profit default is roughly what a cycle's gas cost the swapper at launch
        // prices. The edge default is about 0.02% of price beyond fees; smaller gaps cost
        // more gas than they return.
        Settings storage own = markets[SZR_MARKET];
        own.gasLimit = 8_000_000;
        own.edge = uint56(1.0001e18 / EDGE_UNIT);
        minimumProfit[SZR_MARKET][token] = 10e18;
        // Sized for Robinhood Chain's 32M cap, with room for the router and for a swap that
        // costs more than `SWAP_GAS`.
        swapGasCeiling = 30_000_000;
        emit SwapGasCeilingSet(30_000_000);
        // WETH is the first token profit may be counted in. Core counts the protocol's
        // share of it as backing when anyone calls `absorbBacking`.
        shareRecipient[backingAsset] = address(core);
        emit ProfitTokenSet(backingAsset, address(core));
    }

    /// @dev Anything paid to the hook itself would be stuck in it.
    function _requireRecipient(address recipient) internal view {
        if (recipient == address(0)) revert InvalidPool();
        if (recipient == address(this)) revert InvalidPool();
        if (recipient == address(poolManager)) revert InvalidPool();
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

    /// @dev Notes that a market now uses a pool priced by a pricer, and lists it once for
    /// the market's searches to ask. Searches in it reserve more gas from here on, so its
    /// allowance is checked again.
    function _wrap(uint256 id, address wrapper, bytes32 poolId) internal {
        wrappers[poolId] = wrapper;
        if (wrappedAt[id][poolId] == 0) {
            wrappedIn[id].push(poolId);
            wrappedAt[id][poolId] = wrappedIn[id].length;
        }
        if (markets[id].ask == 0) markets[id].ask = ASK_DEFAULT;
        _requireWorkable(id, markets[id].gasLimit);
    }

    /// @dev Takes a pool off a market's list of wrapped pools once the market neither
    /// tracks it nor has it as the connecting pool of its pair. With the list empty the
    /// market is a plain one again and reserves nothing for asking.
    function _unlist(uint256 id, bytes32 poolId) internal {
        uint256 at = wrappedAt[id][poolId];
        if (at == 0) return;
        if (tracked[id][poolId]) return;
        PoolKey storage pool = keys[poolId];
        address lower = Currency.unwrap(pool.currency0);
        if (connector[id][lower][Currency.unwrap(pool.currency1)] == poolId) return;
        bytes32[] storage list = wrappedIn[id];
        bytes32 last = list[list.length - 1];
        list[at - 1] = last;
        wrappedAt[id][last] = at;
        list.pop();
        wrappedAt[id][poolId] = 0;
        if (list.length == 0) markets[id].ask = 0;
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

    /// @dev Whether a market may count profit in `base`.
    function _countable(uint256 id, address base) internal view returns (bool) {
        if (id == SZR_MARKET) return base == token;
        if (rankIn[id][base] == 0) return false;
        return shareRecipient[base] != address(0);
    }

    /// @dev An allowance too small for the venues a search prices would leave it idle, and a
    /// reserve no transaction can carry would fail every swap that meets a gap.
    function _requireWorkable(uint256 id, uint256 gas) internal view {
        if (gas == 0) return;
        if (gas < _minimumGasLimit(id)) revert InvalidLimit();
        if (_gasForSwap(id) > swapGasCeiling) revert InvalidLimit();
    }

    /// @dev A market that is on and counts in several tokens needs a minimum profit for each:
    /// with none, a cycle too small to matter in one token could release the required rule
    /// for a valuable gap in another. Checked after the change, so a revert undoes it.
    function _requireMinimums(uint256 id) internal view {
        if (markets[id].gasLimit == 0) return;
        address[] storage list = chosen[id];
        if (list.length < 2) return;
        for (uint256 index; index < list.length; index++) {
            if (minimumProfit[id][list[index]] == 0) revert InvalidLimit();
        }
    }

    /// @dev What `gasForSwap` reports; see there.
    function _gasForSwap(uint256 id) internal view returns (uint256) {
        // Outside markets also read where each chosen token's book is centred, before the
        // search and so outside its allowance.
        uint256 centres = id == SZR_MARKET ? 0 : CENTRE_BASE + CENTRE_GAS * chosen[id].length;
        return (_hopped(_minimumGasLimit(id)) + OVERHEAD_GAS + centres) * 64 / 63 * 64 / 63;
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

    function _requireSzrConnector(PoolKey calldata pool, bytes32 poolId) internal view {
        if (!liquidity.poolRegistered(poolId)) revert PoolNotRegistered();
        // Never another market's pool: trading it would skip that market's search.
        if (pools[poolId].origin > SZR_MARKET) revert InvalidPool();
        // A hook the manager has not paired with a pricer is never run in a cycle: the
        // market's guards while a hook's code runs depend on its pool being listed.
        _requireTrusted(pool);
    }

    function _requireLink(uint256 id, PoolKey calldata pool, bytes32 poolId) internal view {
        if (address(pool.hooks) == address(0)) return;
        // A hook with a pricer is one Liquidity's manager trusts to run in a cycle.
        if (pricers[address(pool.hooks)] != address(0)) return;
        if (address(pool.hooks) != address(this)) revert NotTrusted();
        if (pools[poolId].origin != id) revert InvalidPool();
    }

    /// @dev Refuses a pool on a hook other than this one that has no pricer.
    function _requireTrusted(PoolKey calldata pool) internal view {
        address hooked = address(pool.hooks);
        if (hooked == address(0)) return;
        if (hooked == address(this)) return;
        if (pricers[hooked] == address(0)) revert NotTrusted();
    }

    /// @dev The smallest gas allowance with which a search can always start its first
    /// cycle, for the groups and leaders set now. It does not depend on how many pools are
    /// tracked, only on how many venues one search can price.
    function _minimumGasLimit(uint256 id) internal view returns (uint256) {
        (uint256 venues, uint256 books) = _mostVenues(id);
        uint256 ask = markets[id].ask * ASK_UNIT;
        uint256 wrapped = _listed(id, ask);
        (uint256 book, uint256 scan, uint256 overhead) = _reserves(venues, ask, wrapped);
        // What the search before a swap needs to start, reading the prices and the first
        // ranking, and enough to get past the failed cycles it must be able to absorb.
        // Every book's profit is retired on its own, in both searches.
        return _floor(venues, true, ask, wrapped) + book + scan + FAILURES_COVERED
            * (_plan(ask) + overhead + scan) + 2 * RETIRE_GAS * (books - 1);
    }

    /// @dev How many wrapped pools a market has to ask about; nothing is read for a market
    /// that has none, which is the one whose `ask` is zero.
    function _listed(uint256 id, uint256 ask) internal view returns (uint256) {
        return ask == 0 ? 0 : wrappedIn[id].length;
    }

    /// @dev The gas held back for reading every venue's price, for ranking them, and for
    /// what a cycle costs beyond its own budget. `ask` is what a pricer gets for one
    /// answer, zero in a market that uses none, and `wrapped` how many pools it has that
    /// are priced by one; see `ASK_UNIT`. Reading the venues asks every wrapped pool once.
    /// Ranking only reads the answers. A cycle that succeeds asks again about the three
    /// wrapped pools it can have used, its venue and two links.
    function _reserves(uint256 venues, uint256 ask, uint256 wrapped)
        internal
        pure
        returns (uint256 book, uint256 scan, uint256 overhead)
    {
        if (ask == 0) {
            return (BOOK_GAS_PER_VENUE * venues, SCAN_GAS_PER_VENUE * venues, OVERHEAD_GAS);
        }
        uint256 each = ask + ASK_OVERHEAD;
        book = BOOK_GAS_PER_VENUE * venues + each * wrapped;
        scan = (SCAN_GAS_PER_VENUE + 5 * CACHE_READ_GAS) * venues;
        overhead = OVERHEAD_GAS + 3 * each;
    }

    /// @dev The gas all the tries at one cycle may use between them. A leg through a
    /// wrapped pool trades on another exchange and moves the tokens, which costs far more
    /// than a leg inside the pool manager, so a market that uses them is given twice.
    function _plan(uint256 ask) internal pure returns (uint256) {
        return ask == 0 ? PLAN_GAS : 2 * PLAN_GAS;
    }

    /// @dev The most venues one swap's search prices, and in how many books. A swap can
    /// open a book for every token its market counts profit in (see `_centres`), but for
    /// only one ether token, whose book also prices the other's pools.
    function _mostVenues(uint256 id) internal view returns (uint256 most, uint256 books) {
        if (id == SZR_MARKET) return (_venueCount(id, token), 1);
        address[] storage list = chosen[id];
        bool sawEther;
        for (uint256 index; index < list.length; index++) {
            address asset = list[index];
            if (_isEther(asset)) {
                if (sawEther) continue;
                sawEther = true;
            }
            most += _venueCount(id, asset);
            books++;
        }
        if (most < 2) most = 2;
        if (books == 0) books = 1;
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

    function _pair(uint256 id, address base, bytes32 poolId, bytes32 venue, bool buying)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(id, base, poolId, venue, buying));
    }

    /// @dev Like `arb`, it sets nothing aside. Each head gets a fresh start so that `strained`
    /// does not carry from one to the next.
    function _sweep() internal returns (uint256 profit) {
        address[] memory list = groups[active][home];
        // A search reads and ranks its venues before its first gas check, so a head is
        // only started with that much to spare. Otherwise running out between heads would
        // undo the earlier heads' profit.
        _begin(active);
        (uint256 book, uint256 scan,) =
            _reserves(_venueCount(active, home), asking, _listed(active, asking));
        _reuseAnswers(true);
        for (uint256 index; index < list.length; index++) {
            bytes32 head = heads[active][home][list[index]];
            if (gasleft() < book + scan) {
                emit SearchCutShort(head);
                break;
            }
            _begin(active);
            profit += _search(head, list[index], true, false, address(0));
        }
        _reuseAnswers(false);
    }

    /// @dev Starts or ends a run of heads that share the pricers' answers.
    function _reuseAnswers(bool on) internal {
        _keepInMind(ANSWERED_SLOT, 0);
        _keepInMind(REUSE_SLOT, on ? 1 : 0);
    }

    /// @dev One trigger: a search centred on each group's first leader, or, when the swapped
    /// wrapped pool holds the trigger's token, one search from that pool. All of a trigger's
    /// searches share one budget, the lowest of the market's gas allowance, the trigger's
    /// own cap, and what is available now less `VENUE_RESERVE`. So a market with many groups
    /// cannot cost a swap more than its allowance, and a search only starts when that much
    /// is left for the swap's later work. This is best effort: a route whose later work
    /// exceeds the reserve can still fail just above the threshold at which searches run.
    /// The prices a search before a swap leaves for the one after it belong to the hook's
    /// own pools, so none is left behind here.
    function _trigger(bytes32 poolId, Trigger memory entry, bool before, address sender)
        internal
    {
        if (markets[entry.market].gasLimit == 0) return;
        if (!tracked[entry.market][poolId]) return;
        if (!_countable(entry.market, entry.base)) return;
        uint256 cap = FixedPointMathLib.min(markets[entry.market].gasLimit, entry.gasCap);
        uint256 start = gasleft();
        uint256 needed = _needed(entry.market, entry.base, before);
        address[] memory list = groups[entry.market][entry.base];
        // A wrapped pool that holds the token is searched from itself, once; it is compared
        // with the plain pools of every group (`_bestFromWrapped`).
        address mine = _wrappedPartner(entry.market, poolId, entry.base);
        uint256 length = mine == address(0) ? list.length : 1;
        _reuseAnswers(true);
        for (uint256 index; index < length; index++) {
            uint256 left = _budgetLeft(cap, start, needed);
            if (left < needed) {
                emit VenueSearchSkipped(poolId, entry.market, before);
                break;
            }
            remembered = bytes32(0);
            _forgetCentres();
            if (mine == address(0)) {
                _attemptHead(
                    entry.market, entry.base, list[index], bytes32(0), before, sender, left
                );
            } else {
                _attemptHead(entry.market, entry.base, mine, poolId, before, sender, left);
            }
        }
        _reuseAnswers(false);
    }

    /// @dev The other token of a swapped wrapped pool of the market that holds `base`; zero
    /// when the pool is not one, or does not hold it (the twin of an ether token included).
    /// A pool of both ether tokens is never searched, so it is not one either.
    function _wrappedPartner(uint256 id, bytes32 poolId, address base)
        internal
        view
        returns (address)
    {
        if (wrappedAt[id][poolId] == 0) return address(0);
        PoolKey storage key = keys[poolId];
        address lower = Currency.unwrap(key.currency0);
        address higher = Currency.unwrap(key.currency1);
        if (_isEther(lower)) {
            if (_isEther(higher)) return address(0);
        }
        if (lower == base) return higher;
        if (higher == base) return lower;
        return address(0);
    }

    /// @dev What a trigger's next search may use: what is left of its cap, and no more than
    /// is available beyond the reserve. Zero when the search could not start.
    function _budgetLeft(uint256 cap, uint256 start, uint256 needed)
        internal
        view
        returns (uint256)
    {
        uint256 available = gasleft();
        if (available < needed + VENUE_RESERVE) return 0;
        uint256 used = start - available;
        if (used >= cap) return 0;
        return FixedPointMathLib.min(cap - used, available - VENUE_RESERVE);
    }

    /// @dev What a head's search needs to start: its floor, and reading the prices first.
    function _needed(uint256 id, address base, bool before) internal view returns (uint256) {
        uint256 ask = markets[id].ask * ASK_UNIT;
        uint256 venues = _venueCount(id, base);
        uint256 wrapped = _listed(id, ask);
        (uint256 book,,) = _reserves(venues, ask, wrapped);
        return _floor(venues, before, ask, wrapped) + book;
    }

    function _attemptHead(
        uint256 id,
        address base,
        address partner,
        bytes32 head,
        bool before,
        address sender,
        uint256 gas
    ) internal {
        // A zero head is the first leader of the partner's group.
        if (head == bytes32(0)) head = heads[id][base][partner];
        // Capped, so that running short of gas ends the search quietly: it must never revert
        // `Starved` inside a triggered search.
        try IArbitrageSelf(address(this)).search{ gas: _hopped(gas) }(
            head, id, base, partner, true, before, sender
        ) { }
        catch (bytes memory reason) {
            emit SearchUndone(head, bytes4(reason));
        }
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
        if (entry.market != SZR_MARKET) {
            return _runMarket(poolId, pool, entry.market, before, sender);
        }
        address partner = Currency.unwrap(pool.currency0) == entry.home
            ? Currency.unwrap(pool.currency1)
            : Currency.unwrap(pool.currency0);
        _guard(poolId, entry.market, entry.home, partner, before, sender);
    }

    /// @dev An outside market's swap searches in every token the market counts profit in
    /// that a cycle through the pool can end in. One book is a search exactly as before;
    /// several are searched together, under one allowance and one required rule.
    function _runMarket(
        bytes32 poolId,
        PoolKey calldata pool,
        uint256 id,
        bool before,
        address sender
    ) internal {
        // The search after the swap uses the books the one before it listed, unless the
        // pool's books changed in between, which nothing can do while a swap is running.
        Centres memory found;
        if (before) {
            found = _centres(id, poolId, pool);
        } else {
            found = _recallCentres(poolId);
            if (found.count == 0) found = _centres(id, poolId, pool);
        }
        if (before) _forgetCentres();
        if (found.count == 0) return;
        if (found.count == 1) {
            _guard(found.centres[0], id, found.bases[0], found.partners[0], before, sender);
        } else {
            _guardMany(poolId, id, found.centres, found.bases, found.partners, before, sender);
        }
        if (before) _keepCentres(poolId, found);
    }

    /// @dev Where a swap's books are kept in transient storage for the search after it: the
    /// pool they are for (zero when none), their number, and three words per book.
    /// Cleared wherever `remembered` is, by `_forgetCentres`.
    function _keepCentres(bytes32 poolId, Centres memory found) internal {
        uint256 slot = CENTRES_SLOT;
        _keepInMind(slot + 1, found.count);
        for (uint256 index; index < found.count; index++) {
            _keepInMind(slot + 2 + index * 3, uint256(found.centres[index]));
            _keepInMind(slot + 3 + index * 3, uint256(uint160(found.bases[index])));
            _keepInMind(slot + 4 + index * 3, uint256(uint160(found.partners[index])));
        }
        _keepInMind(slot, uint256(poolId));
    }

    function _forgetCentres() internal {
        _keepInMind(CENTRES_SLOT, 0);
    }

    /// @dev The books kept for `poolId`, taken out of storage so they are used once; empty
    /// (no centres array) when none are kept for it.
    function _recallCentres(bytes32 poolId) internal returns (Centres memory found) {
        uint256 slot = CENTRES_SLOT;
        if (_recall(slot) != uint256(poolId)) return found;
        _forgetCentres();
        uint256 count = _recall(slot + 1);
        found.centres = new bytes32[](count);
        found.bases = new address[](count);
        found.partners = new address[](count);
        found.count = count;
        for (uint256 index; index < count; index++) {
            found.centres[index] = bytes32(_recall(slot + 2 + index * 3));
            found.bases[index] = address(uint160(_recall(slot + 3 + index * 3)));
            found.partners[index] = address(uint160(_recall(slot + 4 + index * 3)));
        }
    }

    /// @dev Where each of a swap's books is centred. For a token the pool holds, on the pool
    /// itself. For one it does not, on that token's leader for one of the pool's tokens, but
    /// only while the pool is its market's connecting pool for its pair: otherwise no route
    /// passes through it, so its swap cannot have opened a gap that token's cycles close.
    /// Only one ether token is searched, since each one's book already prices the other's
    /// pools. A pool of ETH and WETH is never searched.
    /// @dev The pool's own tokens come first, so that where a cycle shows the same gap in
    /// two books, the pool's own token is the one it is counted in.
    function _centres(uint256 id, bytes32 poolId, PoolKey calldata pool)
        internal
        view
        returns (Centres memory found)
    {
        address[] storage list = chosen[id];
        uint256 length = list.length;
        found.centres = new bytes32[](length);
        found.bases = new address[](length);
        found.partners = new address[](length);
        // Each token's centre is read once, and both passes below sort the same answers.
        address[] memory tokens = new address[](length);
        bytes32[] memory spots = new bytes32[](length);
        address[] memory others = new address[](length);
        for (uint256 index; index < length; index++) {
            address base = list[index];
            tokens[index] = base;
            // A chosen token always has a rank, so only its approval needs reading.
            if (shareRecipient[base] == address(0)) continue;
            (spots[index], others[index]) = _centreFor(id, base, poolId, pool);
        }
        _addCentres(poolId, tokens, spots, others, true, found);
        _addCentres(poolId, tokens, spots, others, false, found);
        bytes32[] memory centres = found.centres;
        address[] memory bases = found.bases;
        address[] memory partners = found.partners;
        uint256 count = found.count;
        assembly ("memory-safe") {
            mstore(centres, count)
            mstore(bases, count)
            mstore(partners, count)
        }
    }

    /// @dev Adds the books centred on the pool itself (`own`) or on a leader, from the
    /// centres `_centres` read.
    function _addCentres(
        bytes32 poolId,
        address[] memory tokens,
        bytes32[] memory spots,
        address[] memory others,
        bool own,
        Centres memory found
    ) internal view {
        for (uint256 index; index < tokens.length; index++) {
            bytes32 centre = spots[index];
            if (centre == bytes32(0)) continue;
            address base = tokens[index];
            if (_isEther(base)) {
                if (found.sawEther) continue;
            }
            bool onPool = centre == poolId;
            if (onPool != own) continue;
            if (_isEther(base)) found.sawEther = true;
            uint256 count = found.count;
            found.centres[count] = centre;
            found.bases[count] = base;
            found.partners[count] = others[index];
            found.count = count + 1;
        }
    }

    /// @dev A leader that is a wrapped pool can be the centre, as it can in `sweep`. Its
    /// search compares it with plain pools only, each of which carries the price limit
    /// (`_bestFromWrapped`).
    function _centreFor(uint256 id, address base, bytes32 poolId, PoolKey calldata pool)
        internal
        view
        returns (bytes32 centre, address partner)
    {
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        if (_isEther(lower)) {
            if (_isEther(higher)) return (bytes32(0), address(0));
        }
        if (base == lower) return (poolId, higher);
        if (base == higher) return (poolId, lower);
        if (connector[id][lower][higher] != poolId) return (bytes32(0), address(0));
        // The pool holds this token's twin. If the market chose the twin, its book prices
        // this pool and this token adds nothing; if it did not, this token opens no book here.
        if (_isEther(base)) {
            if (_isEther(lower)) return (bytes32(0), address(0));
            if (_isEther(higher)) return (bytes32(0), address(0));
        }
        centre = heads[id][base][lower];
        if (centre != bytes32(0)) return (centre, lower);
        centre = heads[id][base][higher];
        return (centre, centre == bytes32(0) ? address(0) : higher);
    }

    /// @dev The cap to give a self-call so that the module it reaches by delegatecall gets
    /// `gas`: the hook's call to the module keeps back a 64th and costs `HOP_GAS` before it.
    function _hopped(uint256 gas) internal pure returns (uint256) {
        return gas * 64 / 63 + HOP_GAS;
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
        uint256 id,
        address base,
        address partner,
        bool before,
        address sender
    ) internal {
        // Whatever an earlier swap left remembered is out of date by now. Cleared here,
        // outside the search, so that it is cleared even if the search is undone.
        if (before) remembered = bytes32(0);
        uint256 stipend = markets[id].gasLimit;
        if (stipend == 0) return;
        // Whether the search is bounded by the hook's own allowance or by the swap's gas.
        uint256 available = gasleft();
        stipend = _hopped(stipend);
        bool capped = available - available / 64 >= stipend;
        try IArbitrageSelf(address(this)).search{ gas: stipend }(
            poolId, id, base, partner, capped, before, sender
        ) { }
        catch (bytes memory reason) {
            _judge(poolId, reason, capped, before);
        }
    }

    /// @dev `_guard` for a swap with several books, searched in one call.
    function _guardMany(
        bytes32 poolId,
        uint256 id,
        bytes32[] memory centres,
        address[] memory bases,
        address[] memory partners,
        bool before,
        address sender
    ) internal {
        // Several books are never remembered, so there is nothing to keep.
        if (before) remembered = bytes32(0);
        uint256 stipend = markets[id].gasLimit;
        if (stipend == 0) return;
        uint256 available = gasleft();
        stipend = _hopped(stipend);
        bool capped = available - available / 64 >= stipend;
        try IArbitrageSelf(address(this)).searchMany{ gas: stipend }(
            centres, id, bases, partners, capped, before, sender
        ) { }
        catch (bytes memory reason) {
            _judge(poolId, reason, capped, before);
        }
    }

    /// @dev What a search that was undone means for the swap.
    function _judge(bytes32 poolId, bytes memory reason, bool capped, bool before) internal {
        // Before a swap the swapper's own input is not yet owed, so a shortage is read
        // as a drain and fails the swap whether or not the search was capped. That
        // reading is wrong when something earlier in the same unlock is still unpaid,
        // or an earlier hop through a wrapped pool had its hook move that unpaid input
        // out of the pool manager: it can look short without a drain, and a search
        // with more gas can reach a further cycle that meets it, so more gas can fail
        // a swap that less gas passes. This is accepted; such a swap must pay first or
        // be split.
        // After a swap, the search is undone like any other and the next swap, `arb`
        // or `sweep` closes the gap.
        if (before) {
            if (bytes4(reason) == V4Read.Drained.selector) revert V4Read.Drained();
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

    /// @dev Sets what lasts for one search only.
    function _begin(uint256 id) internal {
        if (strained) strained = false;
        asking = markets[id].ask * ASK_UNIT;
    }

    function _cycleMany(Many memory run) internal {
        for (uint256 number; number < MAX_ROUNDS; number++) {
            // Once something is earned, stop while there is still gas to keep it, as in
            // `_search`: failing the swap instead while closing a gap is still required.
            if (run.earned) {
                if (_short(run.floor, run.failures, run.capped, run.before)) break;
            }
            if (number != 0) {
                uint256 rescan = _rescan(run.venues);
                if (_short(rescan, run.failures, run.capped, run.before)) break;
            }
            (uint256 pick, Plan memory plan) = _bestOf(run);
            if (plan.score == 0) {
                run.failures = FAILURES_COVERED + 1;
                if (!_followMany(run)) break;
                continue;
            }
            if (_short(run.floor, run.failures, run.capped, run.before)) {
                emit SearchCutShort(run.books[pick][0].id);
                break;
            }
            if (!_tryMany(run, pick, plan)) break;
        }
    }

    /// @dev The widest gap of any book, and which book it is in.
    function _bestOf(Many memory run) internal returns (uint256 pick, Plan memory best) {
        for (uint256 index; index < run.books.length; index++) {
            home = run.bases[index];
            Plan memory plan = _best(run.books[index]);
            if (plan.score == 0) continue;
            if (!_wider(best, plan)) continue;
            best = plan;
            pick = index;
        }
    }

    /// @dev Runs one book's cycle. False when the search should stop with what it has.
    function _tryMany(Many memory run, uint256 pick, Plan memory plan) internal returns (bool) {
        home = run.bases[pick];
        if (run.resync == UNRELEASED) run.resync = _release(run.payer);
        Venue[] memory book = run.books[pick];
        (uint256 gained, bool piece) = _attempt(_limitEnd(book, plan), plan);
        if (gained == 0) {
            run.failures++;
            _fail(book, plan, run.payer);
            return true;
        }
        run.profits[pick] += gained;
        run.earned = true;
        // One full cycle in any book ends the rule for all of them.
        run.failures = piece ? run.failures + 1 : FAILURES_COVERED + 1;
        // The profit stays a credit, which later cycles through this token must leave alone.
        _setCredited(run.bases[pick], run.profits[pick]);
        if (!_reprice(book, plan)) {
            _starve(run.failures, run.capped, run.before);
            return false;
        }
        _requoteOthers(run, pick, _limitEnd(book, plan), plan);
        // A venue on the twin is no longer a pool of this book's token.
        if (plan.venue != bytes32(0)) {
            if (!_onTwin(book, plan.index)) run.nexts[pick] = plan.index;
        }
        return true;
    }

    /// @dev The cycle moved its centre, its venue and both its connecting pools, and other
    /// books may price any of them as venues of their own, so each entry for one of them is
    /// priced again. Only the pools a cycle used move, so nothing else is read.
    function _requoteOthers(Many memory run, uint256 pick, bytes32 centre, Plan memory plan)
        internal
    {
        for (uint256 other; other < run.books.length; other++) {
            if (other == pick) continue;
            home = run.bases[other];
            Venue[] memory book = run.books[other];
            for (uint256 index; index < book.length; index++) {
                bytes32 id = book[index].id;
                if (id == bytes32(0)) continue;
                bool moved = id == centre;
                if (id == plan.venue) moved = true;
                if (id == plan.links[0]) moved = true;
                if (id == plan.links[1]) moved = true;
                if (moved) _requoteAt(book, index);
            }
        }
    }

    /// @dev As in `_search`: with nothing left in any book, look again from the venue a
    /// book last traded against, one book at a time.
    function _followMany(Many memory run) internal returns (bool) {
        for (uint256 index; index < run.books.length; index++) {
            Venue[] memory book = run.books[index];
            uint256 next = run.nexts[index];
            if (next == book.length) continue;
            home = run.bases[index];
            Venue[] memory fresh = _book(book[next].id, book[next].partner, false);
            run.books[index] = fresh;
            run.nexts[index] = fresh.length;
            run.venues = run.venues - book.length + fresh.length;
            // Never lowered, as in `_search`.
            uint256 again = _floorMany(run);
            if (again > run.floor) run.floor = again;
            return true;
        }
        return false;
    }

    /// @dev `_floorHere` over every book, with each token's profit retired on its own.
    function _floorMany(Many memory run) internal view returns (uint256) {
        uint256 extra = RETIRE_GAS * (run.books.length - 1);
        if (run.before) extra *= 2;
        return _floorHere(run.venues, run.before) + extra;
    }

    /// @dev Takes the most profitable cycle first. A cycle that fails is set aside for
    /// `BENCH_TIME`, so a broken venue costs one failure and cannot starve the others.
    /// Profit stays as a credit with the pool manager and is retired once.
    /// @dev `capped` means the search is bounded by the hook's own gas allowance, not by
    /// the swap's gas. Lacking the gas to start its first cycle then just ends the search;
    /// otherwise it reverts with `Starved`, which fails the swap.
    /// @dev `before` marks the search that runs ahead of a swap. Once it has earned
    /// something it only goes on while enough gas would be left for the swap and for the
    /// search after it, so that giving a swap more gas can never make it fail. That holds
    /// for one hooked swap, not for a transaction of several, and for ordinary pools. Until
    /// a cycle has worked in full, three have failed or worked in part, or a round has found
    /// nothing left, every stop for gas fails the swap instead (`_required`). The empty
    /// round ends that rule before the follow, whose read is not in the reserve.
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
        uint256 floor = _floorHere(book.length, before);
        uint256 failures;
        for (uint256 number; number < MAX_ROUNDS; number++) {
            // Once something is earned, stop while there is still gas to keep it.
            if (profit != 0) {
                if (_short(floor, failures, capped, before)) break;
            }
            // Pricing every venue again must not run out of gas. The first cycle is only
            // started with this much to spare, so it is always there after one failure.
            if (number != 0) {
                if (_short(_rescan(book.length), failures, capped, before)) break;
            }
            Plan memory plan = _best(book);
            if (plan.score == 0) {
                failures = FAILURES_COVERED + 1;
                // Nothing left here. The pool at `plan.index` (the venue, or the plain limit
                // end of an exchanged plan) has moved and may have opened a gap with the
                // pools it is compared with, so look from there next.
                if (next == book.length) break;
                book = _book(book[next].id, book[next].partner, false);
                next = book.length;
                // Never lowered: before a swap it also holds back gas for the search
                // after it, which prices the first pool's venues, not this one's.
                uint256 again = _floorHere(book.length, before);
                if (again > floor) floor = again;
                continue;
            }
            // A token taken off the list is no longer paid out, so nothing is tried, and
            // no swap is failed for bringing too little gas to try it.
            if (!_listedAtStart(number)) break;
            // A cycle is only started with its whole budget available, and enough beyond
            // it to look again if it fails and, before a swap, to finish the swap.
            if (_short(floor, failures, capped, before)) {
                emit SearchCutShort(book[0].id);
                break;
            }
            if (resync == UNRELEASED) resync = _release(payer);
            (uint256 gained, bool piece) = _attempt(_limitEnd(book, plan), plan);
            if (gained == 0) {
                failures++;
                _fail(book, plan, payer);
                continue;
            }
            profit += gained;
            failures = piece ? failures + 1 : FAILURES_COVERED + 1;
            // Short of gas to ask again about what the cycle moved: stop with the profit.
            if (!_reprice(book, plan)) {
                _starve(failures, capped, before);
                break;
            }
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
        IArbitrageSelf(address(this)).retire(profit);
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
        if (payer == address(0)) return _book(poolId, partner, true);
        if (remembered != poolId) return _book(poolId, partner, true);
        // Its predecessor's number, and so its answers, are kept with its prices.
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
            slot += 3;
            book[index].id = bytes32(_recall(slot));
            book[index].partner = address(uint160(_recall(slot + 1)));
            uint256 priced = _recall(slot + 2);
            book[index].rate = uint192(priced);
            book[index].keep = priced >> 192;
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
            slot += 3;
            _keepInMind(slot, uint256(book[index].id));
            _keepInMind(slot + 1, uint256(uint160(book[index].partner)));
            // A rate is at most `MAX_RATE` (2^152) and a keep at most `WAD` (under 2^60), so
            // both fit one word.
            _keepInMind(slot + 2, book[index].rate | book[index].keep << 192);
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
        (, uint256 scan,) = _reserves(venues, asking, 0);
        return RETIRE_GAS + scan;
    }

    /// @dev The gas a cycle needs before it may start: its own budget, retiring, and pricing
    /// the venues again if it fails. The search before a swap must also leave enough for
    /// the swap itself and for the search after it to read the prices, rank them and run
    /// its own first cycle.
    function _floor(uint256 venues, bool before, uint256 ask, uint256 wrapped)
        internal
        pure
        returns (uint256 floor)
    {
        (uint256 book, uint256 scan, uint256 overhead) = _reserves(venues, ask, wrapped);
        floor = RETIRE_GAS + _plan(ask) + overhead + scan;
        if (before) floor = floor * 2 + SWAP_GAS + scan + book;
    }

    /// @dev `_floor` for the market being searched, reading `asking` and `pooled` itself. A
    /// plain market never reads `pooled`, which `_floor` called with it would: that and the
    /// longer call cost a no-gap swap about 160 gas more (measured), and a search checks the
    /// floor at least once.
    function _floorHere(uint256 venues, bool before) internal view returns (uint256) {
        uint256 ask = asking;
        (uint256 book, uint256 scan, uint256 overhead) =
            _reserves(venues, ask, ask == 0 ? 0 : pooled);
        uint256 floor = RETIRE_GAS + _plan(ask) + overhead + scan;
        if (before) floor = floor * 2 + SWAP_GAS + scan + book;
        return floor;
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

    /// @dev The search before a swap must get past `FAILURES_COVERED` cycles that failed or
    /// closed only part of the gap, since the swapper would gain from it standing aside and
    /// chooses the gas. A cycle that worked in full, or a round with nothing left to try,
    /// ends it at once by setting `failures` to the bound. The search after a swap only has
    /// to make its first attempt, whatever it closes: gas for more is not reserved, and
    /// requiring it could make more gas fail where less succeeded.
    function _required(uint256 failures, bool before) internal pure returns (bool) {
        return failures < (before ? FAILURES_COVERED + 1 : 1);
    }

    /// @dev Reverts `Starved` if the search is stopping for want of gas while closing a gap
    /// is still required and the swap's own gas, not the hook's allowance, is the limit.
    /// Every stop for gas goes through here, so that a swap can never stop quietly just short
    /// of a check that, with a little more gas, would have failed it.
    function _starve(uint256 failures, bool capped, bool before) internal pure {
        if (capped) return;
        if (_required(failures, before)) revert Starved();
    }

    /// @dev Whether the search must stop for want of `reserve` gas, after failing the swap
    /// if closing a gap is still required (see `_starve`).
    function _short(uint256 reserve, uint256 failures, bool capped, bool before)
        internal
        view
        returns (bool)
    {
        if (gasleft() >= reserve) return false;
        _starve(failures, capped, before);
        return true;
    }

    /// @dev A swap's failed cycle is set aside. `arb` and `sweep` set nothing aside, so that
    /// calling them cannot switch a pair off for swappers; the pool at `plan.index` is passed
    /// over for the rest of that search instead. That is the venue in an ordinary plan and
    /// the plain limit end in an exchanged one, whose venue is the wrapped start pool. The
    /// pair is named limit end first either way, so both ends set it aside under one key.
    function _fail(Venue[] memory book, Plan memory plan, address payer) internal {
        _bench(_limitEnd(book, plan), plan, payer != address(0));
        if (payer == address(0)) book[plan.index].rate = 0;
    }

    function _bench(bytes32 poolId, Plan memory plan, bool aside) internal {
        emit CycleFailed(poolId, plan.venue);
        if (!aside) return;
        benched[_pair(active, home, poolId, plan.venue, plan.buying)] =
            Bench(uint64(block.timestamp + BENCH_TIME), plan.standin ? 0 : uint192(plan.gap));
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
            if (poolManager.settle() != amount) revert V4Read.InvalidDelta();
            return;
        }
        IWrapped(backingAsset).withdraw(amount);
        poolManager.sync(Currency.wrap(address(0)));
        if (poolManager.settle{ value: amount }() != amount) revert V4Read.InvalidDelta();
    }

    /// @dev The takes a cycle makes go through here, so that a pool manager short of the
    /// token is reported as `Drained` and not as a failed cycle. `_payOut` is the exception:
    /// it checks `_funded` once for the whole profit and then calls `poolManager.take`
    /// directly. Whether `Drained` fails the swap depends on when the search runs: before a
    /// swap it does, and after a swap it only undoes that search (see `_guard`). Only the
    /// controller of the current unlock can cause a shortage, by taking the balance out and
    /// repaying it at the end. Each take is of something the hook already holds a credit
    /// for, so an honest pool manager always has it. Only the profit token, SZR, ETH, WETH
    /// and the input token of a wrapped leg (see `_legLimit`) are ever asked about.
    function _take(Currency asset, address to, uint256 amount) internal {
        V4Read._funded(poolManager, asset, amount, false);
        poolManager.take(asset, to, amount);
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
        if (bytes4(word) == V4Read.Drained.selector) revert V4Read.Drained();
    }

    /// @dev The first try is sized by `size`, which walks the legs' ticks, when the cycle is
    /// one it can read and the search is not strained; otherwise it stops where the depths of
    /// the legs say their prices meet. That assumes the liquidity read at the current price
    /// is what the trade will meet, which is wrong when a leg crosses into a different range
    /// and can be made wrong on purpose. So the next try closes the whole gap, and each one
    /// after goes half as far. All the tries and the walk share `_plan(asking)`; when it runs out
    /// the cycle has failed.
    /// @dev `piece` says the size that worked was not the whole of what the cycle could
    /// close: the walk stopped short or failed and its size worked, or the size was a half or
    /// less of the gap. The whole-gap size and an unsized plan's estimate count as full. The
    /// search before a swap must not treat a partial cycle as closing the gap, or a gap
    /// shaped to make cycles small could be left for a swap that brings just enough gas.
    function _attempt(bytes32 poolId, Plan memory plan) internal returns (uint256, bool piece) {
        // The pool's price, read only if a third size is reached.
        uint160 current;
        uint256 whole = _plan(asking);
        uint256 budget = whole;
        // Once a try has run out of gas, here or earlier in this search, only the smallest
        // size is tried: an eighth of the whole gap, which crosses the fewest ticks of the
        // sizes that close a set share of it.
        bool smallest = strained;
        // Whether the first try's size is a walk's that stopped short or failed.
        bool short;
        if (!smallest) {
            if (_sizeable(plan)) {
                bool declined;
                (budget, declined, short) = _size(poolId, plan, budget);
                // The walk found the best size there is and it cannot earn enough: no
                // tries, and the cycle fails as one whose tries all failed.
                if (declined) return (0, false);
            }
        }
        for (uint256 number; number < TRIES; number++) {
            if (budget < ATTEMPT_GAS) break;
            if (number == 1) {
                if (_repeats(plan)) continue;
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
            try IArbitrageSelf(address(this)).execute{ gas: _hopped(stipend) }(
                poolId, plan
            ) returns (
                uint256 profit
            ) {
                // The first size is the walk's, the second the whole gap, the rest smaller.
                return (profit, number == 0 ? short : number > 1);
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
        return (0, false);
    }

    /// @dev A stand-in whose walk found no size already tries the whole gap at its first
    /// size, so the second size would repeat it.
    function _repeats(Plan memory plan) internal pure returns (bool) {
        if (!plan.standin) return false;
        if (plan.limit != plan.full) return false;
        return plan.spend == plan.fullSpend;
    }

    /// @dev The first try's size, from `size`. Its gas comes out of the budget, not out of
    /// the try's stipend, so the first try still gets a full share. If the walk fails or
    /// runs out of gas the first try keeps the estimate, and is a partial size.
    function _size(bytes32 poolId, Plan memory plan, uint256 budget)
        internal
        virtual
        returns (uint256, bool declined, bool short)
    {
        uint256 available = gasleft();
        try IArbitrageSelf(address(this)).size{ gas: _hopped(SIZING_GAS) }(
            poolId, plan
        ) returns (
            uint160 limit, uint256 spend, bool decline, bool stopped
        ) {
            plan.limit = limit;
            plan.spend = spend;
            declined = decline;
            short = stopped;
        } catch {
            short = true;
        }
        uint256 used = available - gasleft();
        return (used < budget ? budget - used : 0, declined, short);
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
        if (holding != held + int256(profit)) revert V4Read.Unsettled();
        if (held == 0) open++;
        if (poolManager.getNonzeroDeltaCount() > open) revert V4Read.Unsettled();
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
        (uint256 owed, uint256 bought) =
            V4Read._trade(poolManager, own, asset, -int256(plan.spend), plan.limit);
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
        (uint256 sold, uint256 held) =
            V4Read._trade(poolManager, own, base, -int256(plan.spend), plan.limit);
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
        if (poolManager.settle() != received) revert V4Read.InvalidDelta();
        excess = received - owed;
        if (wrapped) return (amount, excess);
        if (excess != 0) poolManager.clear(Currency.wrap(backingAsset), excess);
    }

    function _exactInput(PoolKey memory pool, address input, uint256 amount, uint256 gap)
        internal
        returns (uint256 received)
    {
        uint256 spent;
        (spent, received) = V4Read._trade(
            poolManager, pool, input, -int256(amount), _legLimit(pool, input, gap)
        );
        if (spent != amount) revert Incomplete();
    }

    function _exactOutput(PoolKey memory pool, address output, uint256 amount, uint256 gap)
        internal
        returns (uint256 spent)
    {
        uint256 received;
        address input = _other(pool, output);
        (spent, received) = V4Read._trade(
            poolManager, pool, input, int256(amount), _legLimit(pool, input, gap)
        );
        if (received != amount) revert Incomplete();
    }

    /// @dev The price limit for a venue or connecting leg that is a plain pool: its
    /// square-root price moved against the trade by `(1 + gap)²`, `gap` being the cycle's
    /// square-root gap. A leg that has moved that far has moved its price about twice the
    /// whole cycle's gap, so the optimum never reaches it. Without a limit a leg that cannot
    /// fill walks every empty bitmap word to the extreme price first, whatever the try's size.
    /// A wrapped pool ignores price limits, so it keeps none (zero). A wrapped pool is never
    /// the first leg of a cycle (`_bestFromWrapped`), only a later one paid from a credit.
    /// @dev A wrapped pool's own hook takes the leg's input from the pool manager, where a
    /// failure would reach `_raiseDrained` wrapped and look like a failed cycle, benching it.
    /// So before such a leg the hook checks what it is owed in the input token: a positive
    /// delta is a credit, which an honest pool manager always holds. `_consider` never plans
    /// a buy through a wrapped leg whose input is borrowed, where this would be unsound.
    /// @dev The limit that stays accepted is an unpaid debit: the router's unpaid input, or
    /// an earlier hop through a wrapped pool in the same unlock whose hook moved that input
    /// out of the pool manager. The pool manager can then hold less than it did before the
    /// transaction, and no check here can tell that from a drain.
    function _legLimit(PoolKey memory pool, address input, uint256 gap)
        internal
        view
        returns (uint160)
    {
        if (pricers[address(pool.hooks)] != address(0)) {
            Currency asset = Currency.wrap(input);
            int256 credit = poolManager.currencyDelta(address(this), asset);
            if (credit > 0) V4Read._funded(poolManager, asset, uint256(credit), false);
            return 0;
        }
        (uint160 price,,,) = poolManager.getSlot0(pool.toId());
        return V4Read._limitFrom(price, Currency.unwrap(pool.currency0) == input, gap);
    }

    /// @dev A cycle owes and is owed nothing in a token it passes through. In a search over
    /// several books an earlier book's profit is still a credit, in its own token, until the
    /// search ends, so that credit is what "nothing" means there. It is read only when the
    /// balance is not zero or no book has earned yet, so a search over one book pays one
    /// flag read per check. A zero balance is wrong too when another book holds a credit: the cycle
    /// would have spent it.
    function _requireSettled(address asset) internal view {
        int256 held = poolManager.currencyDelta(address(this), Currency.wrap(asset));
        if (held == 0) {
            if (!_anyCredit()) return;
        }
        if (held != int256(_credited(asset))) revert V4Read.Unsettled();
    }

    /// @dev What the books of this search have earned in `asset` and not yet had paid out.
    function _credited(address asset) internal view returns (uint256 amount) {
        uint256 slot = CREDIT_SLOT;
        assembly ("memory-safe") {
            mstore(0, slot)
            mstore(0x20, asset)
            amount := tload(keccak256(0, 0x40))
        }
    }

    /// @dev Whether any book of this search holds a credit. The flag sits at the slot the
    /// per-token credits are hashed from, which no credit key can equal.
    function _anyCredit() internal view returns (bool any) {
        uint256 slot = CREDIT_SLOT;
        assembly ("memory-safe") {
            any := tload(slot)
        }
    }

    function _clearCredit() internal {
        uint256 slot = CREDIT_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    function _setCredited(address asset, uint256 amount) internal {
        uint256 slot = CREDIT_SLOT;
        assembly ("memory-safe") {
            if amount { tstore(slot, 1) }
            mstore(0, slot)
            mstore(0x20, asset)
            tstore(keccak256(0, 0x40), amount)
        }
    }

    /// @dev The venues one search prices, read in one call to the pool manager: the pool
    /// itself first, then the other leaders of its group, then the first leader of every
    /// other group, and Core last. Connecting pools are read when used. When the search
    /// counts in an ether token, the same from the twin's lists follows the others.
    function _book(bytes32 poolId, address partner, bool fill)
        internal
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
        // The search's first book asks every wrapped pool; later ones read the answers.
        if (wraps) {
            if (fill) _fill();
        }
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
        if (!redeemable) return book;
        book[count].partner = backingAsset;
        _requote(book[count]);
    }

    /// @dev Which pools a search prices and the partner token of each: the pool itself,
    /// the other leaders of its group, and the first leader of every other group. The pool
    /// itself may be a wrapped pool; it is then the venue of every cycle and the other
    /// pools carry the price limit (`_bestFromWrapped`).
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

    /// @dev After a cycle: asks again about the wrapped pools it traded in, whose answers
    /// are now old, and prices the venue and the pool searched again. False when there is
    /// not the gas to ask, which is no reason to undo what the cycle earned.
    function _reprice(Venue[] memory book, Plan memory plan) internal returns (bool) {
        if (asking != 0) {
            if (!_refreshed(plan)) {
                // A pool this cycle traded is stale in the cache: no later head may use it.
                _keepInMind(ANSWERED_SLOT, 0);
                return false;
            }
        }
        _requote(book[0]);
        _requoteAt(book, plan.index);
        return true;
    }

    function _refreshed(Plan memory plan) internal returns (bool) {
        if (!_refresh(plan.venue)) return false;
        if (!_refresh(plan.links[0])) return false;
        return _refresh(plan.links[1]);
    }

    /// @dev A pool's price and fee in the form of the first storage word of a v4 pool. For
    /// a pool on a hook with a pricer these come from the pricer; for any other, from the
    /// pool manager.
    function _word(bytes32 poolId) internal view returns (bytes32 word) {
        word = poolManager.extsload(StateLibrary._getPoolStateSlot(PoolId.wrap(poolId)));
        if (asking != 0) return _wrapped(poolId, word);
    }

    /// @dev What `word` should be if the pool is on a hook with a pricer: the pricer's
    /// answer from this search's cache, or nothing at all when it has none to give. Any
    /// other pool keeps its own.
    function _wrapped(bytes32 poolId, bytes32 word) internal view returns (bytes32) {
        address wrapper = wrappers[poolId];
        if (wrapper == address(0)) return word;
        address pricer = pricers[wrapper];
        if (pricer == address(0)) return bytes32(0);
        uint256[5] memory answer = _ask(poolId);
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
        units = _ask(poolId)[2];
    }

    /// @dev Asks every wrapped pool of the market being searched once, under a new search
    /// number. Anything it cannot afford to ask fails the search `Starved`, so that a swap
    /// that brought too little gas fails as `InsufficientGas` and never reads "no price".
    function _fill() internal {
        // A later head of a sweep or a trigger uses the answers the first head's search
        // asked for: a cycle's own `_reprice` has refreshed what it traded, and a head that
        // failed took its writes with it, so `ANSWERED_SLOT` only names this market when
        // the answers under `searching` were asked in this run.
        // An answer can move without the hook trading the pool (two keys over one outside
        // pool, say), and a later head then keeps the stale one for the run, where before it
        // asked again. That costs a failed cycle or a missed gap at worst: `execute` checks
        // the profit.
        if (_recall(REUSE_SLOT) != 0) {
            if (_recall(ANSWERED_SLOT) == active) return;
        }
        searching++;
        bytes32[] storage list = wrappedIn[active];
        uint256 count = list.length;
        pooled = count;
        for (uint256 index; index < count; index++) {
            if (!_refresh(list[index])) revert Starved();
        }
        _keepInMind(ANSWERED_SLOT, active);
    }

    /// @dev Asks a pool's pricer again and replaces what the cache holds. Only the pools of
    /// the market's list are asked. False, with nothing changed, when the gas left does not
    /// cover the pricer's allowance and the frame around it, which has to be started with
    /// enough for the pricer to get all of `asking` through the holdbacks of a 64th. `askFrame`
    /// now runs on the hook itself, so only two calls hold back (the self-call and the call
    /// to the pricer); the check still allows for three, and is merely conservative.
    function _refresh(bytes32 poolId) internal returns (bool) {
        if (poolId == bytes32(0)) return true;
        if (poolId == WRAP) return true;
        if (wrappedAt[active][poolId] == 0) return true;
        if (gasleft() < asking * 64 / 63 * 64 / 63 * 64 / 63 + ASK_OVERHEAD) return false;
        address pricer = pricers[wrappers[poolId]];
        uint256[5] memory answer;
        if (pricer != address(0)) answer = _poll(pricer, poolId);
        uint256 slot = _answerSlot(poolId);
        for (uint256 word; word < 5; word++) {
            _keepInMind(slot + word, answer[word]);
        }
        return true;
    }

    function _answerSlot(bytes32 poolId) internal view returns (uint256) {
        return uint256(keccak256(abi.encode(ANSWER_SLOT, searching, poolId)));
    }

    /// @dev What this search's cache holds for a pool: the five words of an answer, or all
    /// zeros, which is no price, for a pool not asked.
    function _ask(bytes32 poolId) internal view returns (uint256[5] memory answer) {
        uint256 slot = _answerSlot(poolId);
        for (uint256 word; word < 5; word++) {
            answer[word] = _recall(slot + word);
        }
    }

    /// @dev One ask through `askFrame`. The answer is accepted only as exactly an `Answer`
    /// error of 4 + 160 bytes, of which exactly that much is copied. A failure, a different
    /// length or selector, or a value out of range all give zeros, which reads as no price.
    /// The book uses the first three words; the sizing walk also uses the range.
    function _poll(address pricer, bytes32 poolId) internal returns (uint256[5] memory answer) {
        bytes memory question =
            abi.encodeCall(IArbitrageSelf(address(this)).askFrame, (pricer, poolId));
        bytes4 expected = Answer.selector;
        bool heard;
        assembly ("memory-safe") {
            let failed :=
                iszero(call(gas(), address(), 0, add(question, 0x20), mload(question), 0, 0))
            if and(failed, eq(returndatasize(), 164)) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, 4)
                if eq(shr(224, mload(ptr)), shr(224, expected)) {
                    returndatacopy(answer, 4, 0xa0)
                    heard := 1
                }
            }
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
        (venue.rate, fee, levy) = V4Read._unpack(word, base < venue.partner);
        venue.keep = V4Read._keepFast(V4Read._swapFee(fee, levy));
    }

    /// @dev Prices every other venue against the focus pool and keeps the cycle expected
    /// to return the most. The profit check in `execute` decides.
    function _best(Venue[] memory book) internal view returns (Plan memory best) {
        // The pool searched is always the first entry.
        Venue memory own = book[0];
        if (own.rate == 0) return best;
        // Only a market with a pricer has wrapped pools, so a plain one skips the read.
        if (asking != 0) {
            if (wrappers[own.id] != address(0)) return _bestFromWrapped(book);
        }
        Focus memory focus = _focus(own, markets[active].edge * EDGE_UNIT, book.length);
        focus.start = true;
        for (uint256 other = 1; other < book.length; other++) {
            _consider(best, focus, book[other], other);
        }
    }

    /// @dev The pool a cycle is priced from, with room for `routes` routes to be kept.
    function _focus(Venue memory venue, uint256 edge, uint256 routes)
        internal
        pure
        returns (Focus memory focus)
    {
        focus.id = venue.id;
        focus.partner = venue.partner;
        focus.rate = venue.rate;
        focus.keep = venue.keep;
        focus.edge = edge;
        focus.seen = new address[](routes);
        focus.routes = new Route[](routes);
    }

    /// @dev A search that starts from a wrapped pool compares it with plain pools only, and
    /// in each cycle the plain pool carries the price limit: the first trade of a cycle is
    /// never in a wrapped pool, which ignores limits and whose input would be borrowed. So
    /// the ends are exchanged: each other entry is the focus and the start pool is the
    /// venue, with that entry's place as the plan's index. Passed over, never reverted on:
    /// a wrapped entry, Core, an entry on the twin, and one with no price (it divides).
    function _bestFromWrapped(Venue[] memory book) internal view returns (Plan memory best) {
        Venue memory wrapped = book[0];
        uint256 edge = markets[active].edge * EDGE_UNIT;
        for (uint256 other = 1; other < book.length; other++) {
            Venue memory end = book[other];
            if (end.rate == 0) continue;
            if (end.id == bytes32(0)) continue;
            if (_onTwin(book, other)) continue;
            if (wrappers[end.id] != address(0)) continue;
            // One venue is compared, so one route is ever kept.
            Focus memory focus = _focus(end, edge, 1);
            _consider(best, focus, wrapped, other);
        }
    }

    /// @dev The pool a plan's first trade is in, the one that carries the price limit. An
    /// ordinary plan's venue is never the start pool, so a plan whose venue is the start
    /// pool is an exchanged one (`_bestFromWrapped`) and its limit end is at `plan.index`.
    function _limitEnd(Venue[] memory book, Plan memory plan) internal pure returns (bytes32) {
        if (plan.venue == book[0].id) return book[plan.index].id;
        return book[0].id;
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
        uint256 keep;
        // Each keep is at most WAD, so the products here stay below 1e54, under 2^180. The
        // rates met below are bounded too: `rate` by `MAX_CYCLE_RATE` (2^180), `focus.rate`
        // by `MAX_RATE` (2^152), so no product through `fullMulDiv` is near 2^256.
        unchecked {
            keep = venue.keep * focus.keep / WAD * route.keep / WAD;
        }
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
        if (buying) {
            if (_borrowsWrapped(venue.id, route)) return;
        }
        // `edge` is a ratio above one, at least WAD, so the subtraction cannot underflow.
        Plan memory candidate;
        unchecked {
            candidate =
                Plan(edge - WAD, index, venue.id, route.links, 0, 0, 0, 0, buying, 0, false);
        }
        if (!_offer(best, focus, candidate, target, _cycleDepth(focus, venue, route), false)) {
            return;
        }
        _standIn(best, focus, venue, route, candidate, target);
    }

    /// @dev The estimate missed the gate. If the focus pool is thin, it may be hiding a gap
    /// (an empty pool past a range edge, dust, a pulled position): the rest of the cycle has
    /// depth, so a plan is made as if the focus had as much, and the sizing walk finds the
    /// real amount. Only for the pool a search started from; a venue or link with no depth
    /// is never planned against, because its price can be pushed anywhere for free.
    function _standIn(
        Plan memory best,
        Focus memory focus,
        Venue memory venue,
        Route memory route,
        Plan memory candidate,
        uint256 target
    ) internal view {
        if (!focus.start) return;
        // A failed stand-in benches stand-ins only (its bench has no gap, so it never blocks a
        // real plan), and none is made while any bench on the pair is active.
        bytes32 key = _pair(active, home, focus.id, candidate.venue, candidate.buying);
        if (block.timestamp < benched[key].until) return;
        uint256 others =
            venue.id == bytes32(0) ? MAX_DEPTH : _depth(venue.id, venue.rate, venue.rate);
        if (route.links[0] != bytes32(0)) others = V4Read._harmonic(others, route.depth);
        // Above a tenth of `others` the real estimate is at least an eleventh of the
        // stand-in's, so only a gap worth under about eleven times the gate can hide.
        if (focus.depth * STANDIN_RATIO >= others) return;
        _offer(best, focus, candidate, target, others, true);
    }

    /// @dev Whether a buy would run a wrapped leg whose input the hook does not yet hold: a
    /// connecting pool, or a venue paid in the twin of the ether token searched. That input
    /// is borrowed from the pool manager until a later leg supplies it, so a drain there
    /// cannot be told from an honest shortage and `_legLimit` cannot check it. Such a buy is
    /// never planned, so a drain cannot skip its gap.
    function _borrowsWrapped(bytes32 venue, Route memory route) internal view returns (bool) {
        for (uint256 hop; hop < 2; hop++) {
            bytes32 link = route.links[hop];
            if (link == bytes32(0)) continue;
            if (link == WRAP) continue;
            if (pricers[address(keys[link].hooks)] != address(0)) return true;
        }
        if (venue == bytes32(0)) return false;
        if (pricers[address(keys[venue].hooks)] == address(0)) return false;
        return _holdsTwin(venue, home);
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
        // A missing pool has no price, which leaves the route's rate at zero, and the other
        // pool need not be priced.
        _hop(route, 0, near, backingAsset < to);
        if (near == bytes32(0)) return route;
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
        // No pool is no price: the route has no rate, and nothing is read.
        if (poolId == bytes32(0)) {
            route.rate = 0;
            return;
        }
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
            depth = V4Read._harmonic(depth, _depth(venue.id, venue.rate, venue.rate));
        }
        if (route.links[0] == bytes32(0)) return depth;
        if (!route.sized) {
            route.depth = _routeDepth(focus.rate, route);
            route.sized = true;
        }
        depth = V4Read._harmonic(depth, route.depth);
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
        depth = V4Read._harmonic(depth, _linkDepth(route.links[1], route.rates[1], flow));
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
        uint256 depth,
        bool standin
    ) internal view returns (bool missed) {
        if (depth == 0) return true;
        uint256 gap = candidate.gap;
        uint256 score = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(gap, gap, WAD), depth, WAD
        );
        if (score == 0) return true;
        // The estimate has to clear the smallest profit with room to spare. A cycle
        // estimated just above it mostly returns just below, and fails at every size.
        if (score < uint256(minimumProfit[active][home]) * PLAN_MARGIN / 100) return true;
        if (!_outranks(best, standin, score)) return false;
        Bench memory bench =
            benched[_pair(active, home, focus.id, candidate.venue, candidate.buying)];
        if (block.timestamp < bench.until) {
            if (gap / BENCH_ESCAPE < bench.gap) return false;
        }
        // A stand-in takes the whole cycle's depth as the focus pool's own.
        uint256 own = standin ? depth : focus.depth;
        uint256 share = FixedPointMathLib.fullMulDiv(depth, WAD, own);
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
        best.fullSpend =
            _spend(focus, candidate.buying, FixedPointMathLib.fullMulDiv(gap, own, WAD));
        best.buying = candidate.buying;
        best.score = score;
        best.standin = standin;
        return false;
    }

    /// @dev Whether a plan from another book replaces the best so far: a real plan always
    /// does over a stand-in, and otherwise the wider gap does.
    function _wider(Plan memory best, Plan memory plan) internal pure returns (bool) {
        if (best.score == 0) return true;
        if (best.standin != plan.standin) return !plan.standin;
        return plan.gap > best.gap;
    }

    /// @dev Whether a candidate replaces the best plan so far. A real plan always outranks a
    /// stand-in, whatever their scores, so a search's required attempt is never spent on a
    /// stand-in while a real gap is skipped.
    function _outranks(Plan memory best, bool standin, uint256 score)
        internal
        pure
        returns (bool)
    {
        if (best.score == 0) return true;
        if (best.standin != standin) return !standin;
        return score > best.score;
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

    /// @dev Square-root price of the quote token per base token, and the square root of the
    /// share of a trade the pool's fees leave. Zero for a pool that does not exist.
    function _quote(bytes32 poolId, bool baseFirst)
        internal
        view
        returns (uint256 rate, uint256 keep)
    {
        uint24 fee;
        uint24 levy;
        (rate, fee, levy) = V4Read._unpack(_word(poolId), baseFirst);
        keep = V4Read._keepFast(V4Read._swapFee(fee, levy));
    }

    /// @dev Core pays exactly NAV in WETH per SZR and takes no fee.
    function _redeemQuote() internal view returns (uint256 rate, uint256 keep) {
        uint256 nav = core.NAV();
        // Beyond this the conversion below would overflow; no real NAV comes close.
        if (nav > type(uint64).max) return (0, 0);
        rate = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(nav, Q192, WAD));
        keep = WAD;
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

    /// @dev Whether the walk reads this pool from the search's answers instead of the pool
    /// manager. A market with no wrapped pool has `asking` zero, and nothing to look up.
    function _asked(bool asks, bytes32 poolId) internal view returns (bool) {
        if (!asks) return false;
        return wrappers[poolId] != address(0);
    }

    function _walk(bytes32 poolId, Plan calldata plan)
        internal
        view
        returns (uint160 limit, uint256 spend, uint256 steps, bool declined, bool short)
    {
        (SizingWalk.Leg[] memory legs, uint256 focus) = _legs(poolId, plan);
        _load(legs, plan.gap, plan.full, focus);
        SizingWalk.Walk memory walk;
        // Reaching a wrapped leg's range end is an under-trade, never a dead end: the venue
        // may hold deep liquidity past what its pricer reports, so the walk never declines.
        for (uint256 index; index < legs.length; index++) {
            if (legs[index].wrapped) walk.stopped = true;
        }
        for (uint256 round; round <= SIZING_STEPS; round++) {
            if (!SizingWalk._round(poolManager, legs, walk, focus, round)) break;
        }
        steps = walk.steps;
        short = walk.short;
        (limit, spend, steps, declined) = _answer(walk, plan, steps);
    }

    /// @dev What the walk answers. A walk that ran to its natural end, the optimum within
    /// range or the end of a leg, and found too little is final: profit is concave in size,
    /// so no size can earn what this one cannot. One that stopped short answers only if what
    /// it found is enough. Every size is held back by a millionth and a few wei, so that
    /// every leg still fills whatever rounding the crossings left.
    function _answer(SizingWalk.Walk memory walk, Plan calldata plan, uint256 steps)
        internal
        view
        returns (uint160, uint256, uint256, bool)
    {
        if (walk.total == 0) {
            // A stand-in whose walk ran to its end with nothing to trade met an empty pool.
            return (plan.limit, plan.spend, steps, plan.standin && !walk.stopped);
        }
        bool poor = walk.predicted < int256(uint256(minimumProfit[active][home]));
        if (poor) {
            return (plan.limit, plan.spend, steps, !walk.stopped);
        }
        uint256 spend = SizingWalk._shaved(plan.buying ? walk.focusIn : walk.total);
        uint256 most = uint256(uint128(type(int128).max));
        if (spend > most) spend = most;
        if (spend == 0) return (plan.limit, plan.spend, steps, false);
        return (plan.full, spend, steps, false);
    }

    /// @dev The legs of a cycle in the order value flows, and the focus pool's place in it.
    /// A selling cycle runs the focus pool first and the venue last; a buying cycle the
    /// other way round, so its legs are found in the order `_buyCycle` trades them and
    /// turned over.
    function _legs(bytes32 poolId, Plan calldata plan)
        internal
        view
        returns (SizingWalk.Leg[] memory legs, uint256 focus)
    {
        SizingWalk.Leg[] memory found = new SizingWalk.Leg[](4);
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
        legs = new SizingWalk.Leg[](count);
        for (uint256 index; index < count; index++) {
            legs[buying ? count - 1 - index : index] = found[index];
        }
        focus = buying ? count - 1 : 0;
    }

    function _coreRate() internal view returns (uint256 rate) {
        (rate,) = _redeemQuote();
        if (rate == 0) revert SizingWalk.Unsizable();
    }

    /// @dev A pool as a leg whose input is `input`.
    function _leg(bytes32 poolId, PoolKey memory key, address input)
        internal
        pure
        returns (SizingWalk.Leg memory leg)
    {
        leg.id = poolId;
        leg.zeroForOne = Currency.unwrap(key.currency0) == input;
        leg.spacing = key.tickSpacing;
    }

    /// @dev Reads every leg's price, fee and liquidity in one call to the pool manager, and
    /// finds each one's first boundary. A wrapped pool is read from the search's answers
    /// instead, and its boundary is the end of the range it reports. Whatever is out of
    /// bounds reverts.
    function _load(SizingWalk.Leg[] memory legs, uint256 gap, uint160 full, uint256 focus)
        internal
        view
    {
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
            SizingWalk.Leg memory leg = legs[index];
            if (leg.id == bytes32(0)) continue;
            if (_asked(asks, leg.id)) {
                _loadWrapped(leg, gap);
                continue;
            }
            // Read into locals: the order arguments are evaluated in is not specified.
            uint256 first = uint256(words[read++]);
            uint256 second = uint256(words[read++]);
            SizingWalk._read(leg, first, second, gap);
            if (index == focus) leg.limit = full;
            SizingWalk._bound(poolManager, leg);
            // Nothing is found yet, so a boundary that cannot be read is a guard.
            if (leg.broken) revert SizingWalk.Unsizable();
        }
    }

    /// @dev A wrapped pool as a leg: its pricer's price, fee and liquidity, as the book reads
    /// them. It has no ticks and ignores a price limit, so the end of the range the pricer
    /// reports, in the direction the leg trades, is where it ends. Without a price, or with
    /// no room before that end, the walk gives up and the estimate is used.
    function _loadWrapped(SizingWalk.Leg memory leg, uint256 gap) internal view {
        uint256[5] memory answer = _ask(leg.id);
        SizingWalk._read(leg, answer[0] | (answer[1] << 208), answer[2], gap);
        leg.target = uint160(leg.zeroForOne ? answer[3] : answer[4]);
        leg.edge = true;
        leg.wrapped = true;
        if (leg.target == leg.price) revert SizingWalk.Unsizable();
    }
}
