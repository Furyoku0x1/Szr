// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../../src/arbitrage/ArbitrageLogic.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev The hook with its scan exposed, so tests can measure what the gas constants assume.
/// It is one contract with every module's functions and no routing, the way the hook was
/// before it was split, so it can reach the internals. It runs the hook's setup itself and
/// skips the checks that only the hook has (its address, its modules).
contract ArbitrageProbe is ArbitrageApi {
    /// While set, no cycle is sized by the walk, so the first try uses the plan's estimate
    /// as it did before the walk existed. For tests of what the other sizes do.
    bool public declineSizing;

    constructor(Liquidity treasury) ArbitrageLogic(treasury) {
        _initialise();
    }

    function setDeclineSizing(bool decline) external {
        declineSizing = decline;
    }

    function _sizeable(Plan memory plan) internal view override returns (bool) {
        if (declineSizing) return false;
        return super._sizeable(plan);
    }

    /// Gas to read every pool's price, gas to rank every venue against one pool, the number
    /// of venues, and what the hook allows per venue for the ranking and for the reading.
    /// This is a search in SZR's market.
    function scanCost(bytes32 poolId)
        external
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        return _scanCost(SZR_MARKET, token, poolId);
    }

    /// Like `scanCost`, for a search in `market` that counts profit in `base`.
    function scanCostIn(uint256 market, address base, bytes32 poolId)
        external
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        return _scanCost(market, base, poolId);
    }

    /// The books a swap in `poolId` opens in `market`, and what listing them costs, cold.
    function centresOf(uint256 market, bytes32 poolId, PoolKey calldata pool)
        external
        view
        returns (uint256 used, address[] memory bases, bytes32[] memory centres)
    {
        used = gasleft();
        Centres memory found = _centres(market, poolId, pool);
        used -= gasleft();
        return (used, found.bases, found.centres);
    }

    /// The constants `gasForSwap` is built from.
    function swapGasConstants()
        external
        pure
        returns (uint256 hop, uint256 overhead, uint256 centre, uint256 base)
    {
        return (HOP_GAS, OVERHEAD_GAS, CENTRE_GAS, CENTRE_BASE);
    }

    /// The most venues the gas allowance of `market` is sized for.
    function mostVenues(uint256 market) external view returns (uint256 venues) {
        (venues,) = _mostVenues(market);
    }

    function _scanCost(uint256 market, address base, bytes32 poolId)
        internal
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        active = market;
        home = base;
        address partner = _other(keys[poolId], base);
        // A market with wrapped pools has its answers asked first, as a search does, so
        // that this is the cost of reading the book again from them.
        _begin(market);
        if (asking != 0) _fill();
        uint256 start = gasleft();
        Venue[] memory prices = _book(poolId, partner, false);
        book = start - gasleft();
        start = gasleft();
        _best(prices);
        best = start - gasleft();
        venues = prices.length;
        // Ranking in a market with wrapped pools also reads five answers per venue.
        allowance = SCAN_GAS_PER_VENUE + (asking == 0 ? 0 : 5 * CACHE_READ_GAS);
        bookAllowance = BOOK_GAS_PER_VENUE;
        asking = 0;
        active = 0;
    }

    /// The gas `_payOut` uses for native ETH profit in `market`, and the gas a search holds
    /// back for retiring. The pool manager must be unlocked and this hook must already be
    /// owed `profit` in ETH.
    function payoutCost(uint256 market, uint256 profit)
        external
        returns (uint256 used, uint256 reserved)
    {
        active = market;
        home = address(0);
        uint256 start = gasleft();
        _payOut(profit);
        used = start - gasleft();
        reserved = RETIRE_GAS;
        active = 0;
    }

    /// Like `payoutCost`, for profit counted in the token `asset`, which this hook must
    /// already be owed in the unlocked pool manager.
    function tokenPayoutCost(uint256 market, address asset, uint256 profit)
        external
        returns (uint256 used, uint256 reserved)
    {
        active = market;
        home = asset;
        uint256 start = gasleft();
        _payOut(profit);
        used = start - gasleft();
        reserved = RETIRE_GAS;
        active = 0;
    }

    /// The gas the wrap link uses to turn `amount` of ether token `from` into its twin, and
    /// then sends the twin to the caller. The pool manager must be unlocked and this hook
    /// must already be owed `amount` of `from`.
    function convertCost(address from, uint256 amount) external returns (uint256 used) {
        uint256 start = gasleft();
        _convert(from, amount);
        used = start - gasleft();
        poolManager.take(Currency.wrap(_twin(from)), msg.sender, amount);
    }

    /// Runs one try at a cycle the way a search does, with the stipend a try gets, and says
    /// how much gas it used and the error it failed with (zero if it succeeded). The pool
    /// manager must be unlocked. A try that earns has its profit retired afterwards.
    function tryCost(uint256 market, address base, bytes32 poolId, Plan calldata plan)
        external
        returns (uint256 used, bytes4 reason)
    {
        active = market;
        home = base;
        uint256 start = gasleft();
        uint256 won;
        try this.execute{ gas: PLAN_GAS / 2 }(poolId, plan) returns (uint256 profit) {
            won = profit;
        } catch (bytes memory data) {
            reason = bytes4(data);
        }
        used = start - gasleft();
        // A try that earned leaves a credit, which a search retires; do the same, so the
        // pool manager can be locked again.
        if (won != 0) _retire(won);
        active = 0;
    }

    /// The first sizing step a search runs, as `_attempt` runs it: how many it ran, the gas
    /// the walk's call took (the call, the encoding and a failure included), the boundaries
    /// the walk followed given the same gas, and whether the first try used the walk's size.
    /// Later ones are not recorded.
    uint256 public sizingCalls;
    uint256 public sizingGas;
    uint256 public sizingSteps;
    bool public sizingUsed;
    bool public sizingDeclined;
    bool public sizingCut;
    bool public sizingReverted;

    /// While set, `_size` is skipped and leaves nothing of the budget, so a failed cycle runs
    /// no try: what is left is what a failed cycle costs beyond its budget.
    bool public skipTries;

    function setSkipTries(bool skip) external {
        skipTries = skip;
    }

    /// The gas a failed cycle at a swap's search costs beyond the budget its tries share:
    /// dealing with the sync slot, reading the legs' hooks (`_sizeable`), and setting the pair
    /// aside. `skipTries` must be set so that no try runs. The pool manager must be unlocked.
    function failedCycleCost(
        uint256 market,
        address base,
        bytes32 poolId,
        Plan calldata plan,
        address payer
    ) external returns (uint256 used) {
        active = market;
        home = base;
        _begin(market);
        Venue[] memory book = new Venue[](plan.index + 1);
        book[0].id = poolId;
        uint256 start = gasleft();
        _release(payer);
        if (_attempt(poolId, plan) != 0) revert();
        _fail(book, plan, payer);
        used = start - gasleft();
        active = 0;
    }

    function _size(bytes32 poolId, Plan memory plan, uint256 budget)
        internal
        override
        returns (uint256 left, bool declined)
    {
        if (skipTries) return (0, false);
        Plan memory before = abi.decode(abi.encode(plan), (Plan));
        (left, declined) = super._size(poolId, plan, budget);
        if (sizingCalls++ != 0) return (left, declined);
        sizingGas = budget - left;
        walkInput = abi.encode(poolId, before);
        sizingDeclined = declined;
        sizingUsed = plan.limit != before.limit || plan.spend != before.spend;
        // The walk is run again to count its boundaries. It finds the storage warm and so can
        // afford more than the real one did; if its answer differs, the real walk was cut
        // short for gas, and the count is of the rerun.
        try this.walkSteps{ gas: SIZING_GAS }(poolId, before) returns (uint256 followed) {
            sizingSteps = followed;
        } catch { }
        try this.size{ gas: SIZING_GAS }(poolId, before) returns (
            uint160, uint256 again, bool
        ) {
            sizingCut = again != plan.spend;
        } catch (bytes memory reason) {
            // A walk that gives up with `Unsizable` reverted on purpose; any other failure
            // is the gas running out.
            if (bytes4(reason) == Unsizable.selector) sizingReverted = true;
            else sizingCut = true;
        }
    }

    /// One round of the walk on two legs of one real pool's tick grid set up by hand: a leg
    /// selling token0 at `priceA` and a leg selling token1 at `priceB`, both of `units`
    /// liquidity and a 0.05% fee, with limits far away. Says whether the walk goes on, what it
    /// moved, and how many boundaries it crossed.
    function thinRound(bytes32 poolId, uint160 priceA, uint160 priceB, uint128 units)
        external
        returns (bool more, uint256 total, uint256 steps)
    {
        Leg[] memory legs = new Leg[](2);
        bool[2] memory zero = [true, false];
        uint160[2] memory prices = [priceA, priceB];
        for (uint256 index; index < 2; index++) {
            Leg memory leg = legs[index];
            leg.id = poolId;
            leg.zeroForOne = zero[index];
            leg.spacing = 60;
            leg.price = prices[index];
            leg.tick = TickMath.getTickAtSqrtPrice(leg.price);
            leg.liquidity = units;
            leg.fee = 500;
            leg.keep = _keep(500);
            leg.depth = 1;
            leg.limit = _limitFrom(leg.price, leg.zeroForOne, 1e17);
            _bound(leg);
        }
        Walk memory walk;
        more = _round(legs, walk, 0, 0);
        return (more, walk.total, walk.steps);
    }

    /// What a pricer answers to one ask through `askFrame` given `gas`, as the hook reads
    /// it: five words, or all zeros for no price.
    function ask(address pricer, bytes32 poolId, uint256 gas)
        external
        returns (uint256[5] memory answer)
    {
        asking = gas;
        answer = _poll(pricer, poolId);
        asking = 0;
    }

    /// The gas one refresh of a wrapped pool in `market` costs, the frame and the cache
    /// writes included, and `ASK_OVERHEAD`, which is what the hook reserves beyond the
    /// pricer's own gas. Returns the gas of a second refresh too, which finds the pool's
    /// storage warm but the pricer's frame cold, as every ask is.
    function askCost(uint256 market, bytes32 poolId, uint256 gas)
        external
        returns (uint256 used, uint256 overhead)
    {
        active = market;
        asking = gas;
        searching++;
        uint256 start = gasleft();
        _refresh(poolId);
        used = start - gasleft();
        asking = 0;
        active = 0;
        overhead = ASK_OVERHEAD;
    }

    /// What reading one answer from the cache costs, after a fill of `market`.
    function cacheReadCost(uint256 market, bytes32 poolId) external returns (uint256 used) {
        active = market;
        _begin(market);
        _fill();
        uint256 start = gasleft();
        _ask(poolId);
        used = start - gasleft();
        asking = 0;
        active = 0;
    }

    /// What `askFrame` does in a test of how `_poll` reads it: 0 is the real frame. 1 reverts
    /// with an answer and one byte more, 2 with a selector that is not `Answer`'s, 3 with one
    /// byte too few, and 4 returns the right bytes instead of reverting.
    uint256 public frameMode;

    function setFrameMode(uint256 mode) external {
        frameMode = mode;
    }

    function askFrame(address pricer, bytes32 poolId) public override onlySelf {
        uint256 mode = frameMode;
        if (mode == 0) return super.askFrame(pricer, poolId);
        uint256[5] memory good = [uint256(1 << 96), 3_000, 1_000e18, 0, 0];
        good[3] = TickMath.MIN_SQRT_PRICE;
        good[4] = TickMath.MAX_SQRT_PRICE;
        bytes4 tag = mode == 2 ? bytes4(0xdeadbeef) : Answer.selector;
        bytes memory data = abi.encodePacked(tag, good);
        uint256 length = mode == 1 ? 165 : mode == 3 ? 163 : 164;
        if (mode == 4) {
            assembly ("memory-safe") {
                return(add(data, 0x20), 164)
            }
        }
        if (mode == 1) data = abi.encodePacked(data, uint8(1));
        assembly ("memory-safe") {
            revert(add(data, 0x20), length)
        }
    }

    /// Fills `market`'s answers as a search does, then prices again after a cycle through
    /// `poolId`, which is all that cycle used. Says whether the pool could be asked again.
    /// Called with limited gas, it is cut short at the ask and not before it.
    function repriceShort(uint256 market, address base, bytes32 poolId)
        external
        returns (bool done)
    {
        active = market;
        home = base;
        _begin(market);
        _fill();
        Venue[] memory book = new Venue[](1);
        book[0].id = poolId;
        book[0].partner = address(1);
        Plan memory plan;
        plan.venue = poolId;
        done = _reprice(book, plan);
        asking = 0;
        active = 0;
    }

    /// `_floorHere`, which a search uses, and `_floor`, which the allowance uses, for the
    /// same market once its answers are filled. They must agree.
    function floorsBoth(uint256 market, uint256 venues, bool before)
        external
        returns (uint256 here, uint256 plain)
    {
        active = market;
        _begin(market);
        _fill();
        uint256 ask = asking;
        here = _floorHere(venues, before);
        plain = _floor(venues, before, ask, _listed(market, ask));
        asking = 0;
        active = 0;
    }

    /// What the search before a swap holds back as its floor, for `venues` venues in
    /// `market`, once the market's answers are filled as a search fills them.
    function floorAfterFill(uint256 market, uint256 venues) external returns (uint256 floor) {
        active = market;
        _begin(market);
        _fill();
        floor = _floorHere(venues, true);
        asking = 0;
        active = 0;
    }

    /// Runs `_requireSettled` with another book's credit held in `asset`, in one call since
    /// the credit is transient.
    function settledWithCredit(address asset, uint256 credit) external {
        _setCredited(asset, credit);
        _requireSettled(asset);
        _clearCredit();
    }

    /// The pool whose venues the hook has left remembered for the search after a swap.
    function rememberedNow() external view returns (bytes32) {
        return remembered;
    }

    /// The hook's constants for what reading the cache costs, and for one ask.
    function cacheReadGas() external pure returns (uint256) {
        return CACHE_READ_GAS;
    }

    function askOverhead() external pure returns (uint256) {
        return ASK_OVERHEAD;
    }

    /// What `_size` charges beyond the gas the walk's call is given: encoding the call,
    /// making it, decoding the answer and working out the gas. Measured at about 5.4k warm,
    /// and rounded up for cold reads. The walk's gas, `SIZING_GAS`, is far below half a
    /// cycle's budget less this, so that even a walk that spends all it is given leaves the
    /// first try a full share.
    function sizingCallGas() external pure returns (uint256) {
        return 10_000;
    }

    /// The gas `_walk` itself uses for a plan.
    function walkGas(bytes32 poolId, Plan calldata plan)
        external
        view
        onlySelf
        returns (uint256 used)
    {
        uint256 start = gasleft();
        _walk(poolId, plan);
        used = start - gasleft();
    }

    /// What `_size` charges a cycle's budget for the walk on a `walkInput`, and what the walk
    /// itself used, both warm. The difference is the overhead of the call: encoding it, making
    /// it, decoding the answer, and working out the gas it gets. Market `market` is filled
    /// first, so that the walk reads answers.
    function callOverhead(bytes calldata input, uint256 market)
        external
        returns (uint256 charged, uint256 inner)
    {
        (bytes32 poolId, Plan memory plan) = abi.decode(input, (bytes32, Plan));
        active = market;
        _begin(market);
        _fill();
        this.walkGas(poolId, plan);
        (uint256 left,) = super._size(poolId, plan, type(uint128).max);
        charged = type(uint128).max - left;
        inner = this.walkGas(poolId, plan);
        asking = 0;
        active = 0;
    }

    /// Whether the walk could read every leg of `plan`.
    function sizeable(Plan memory plan) external view returns (bool) {
        return _sizeable(plan);
    }

    /// Whether the walk could read every leg of `plan` in a search whose market's pricers get
    /// `gas` each; `sizeable` is the search of a market that uses no pricer.
    function sizeableAsking(Plan memory plan, uint256 gas) external returns (bool readable) {
        asking = gas;
        readable = _sizeable(plan);
        asking = 0;
    }

    /// The first walk's input as `_size` saw it, for `coldSteps`.
    bytes public walkInput;

    /// The boundaries the walk follows for a `walkInput`, given only `SIZING_GAS`, with
    /// whatever warmth the caller has left. Zero if it ran out.
    function coldSteps(bytes calldata input) external returns (uint256 steps) {
        (bytes32 poolId, Plan memory plan) = abi.decode(input, (bytes32, Plan));
        try this.walkSteps{ gas: SIZING_GAS }(poolId, plan) returns (uint256 followed) {
            steps = followed;
        } catch { }
    }

    /// The boundaries the walk follows for `plan`, for the probe.
    function walkSteps(bytes32 poolId, Plan calldata plan)
        external
        view
        onlySelf
        returns (uint256 steps)
    {
        (,, steps,) = _walk(poolId, plan);
    }

    /// The gas the sizing walk is given, the most boundary events it follows, and the gas a
    /// cycle's tries share, which the walk's gas comes out of.
    function sizingLimits() external pure returns (uint256 gas, uint256 steps, uint256 plan) {
        return (SIZING_GAS, SIZING_STEPS, PLAN_GAS);
    }

    /// What the hook leaves for the user's own swap, and the most one try at a cycle may use.
    function gasAllowances() external pure returns (uint256 swap, uint256 attempt) {
        return (SWAP_GAS, PLAN_GAS / 2);
    }
}
