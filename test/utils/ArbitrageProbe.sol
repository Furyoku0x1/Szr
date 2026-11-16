// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev The hook with its scan exposed, so tests can measure what the gas constants assume.
contract ArbitrageProbe is ArbitrageHook {
    /// While set, no cycle is sized by the walk, so the first try uses the plan's estimate
    /// as it did before the walk existed. For tests of what the other sizes do.
    bool public declineSizing;

    constructor(Liquidity treasury) ArbitrageHook(treasury) { }

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

    /// The most venues the gas allowance of `market` is sized for.
    function mostVenues(uint256 market) external view returns (uint256) {
        return _mostVenues(market);
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
        uint256 start = gasleft();
        Venue[] memory prices = _book(poolId, partner);
        book = start - gasleft();
        start = gasleft();
        _best(prices, 0);
        best = start - gasleft();
        venues = prices.length;
        allowance = SCAN_GAS_PER_VENUE;
        bookAllowance = BOOK_GAS_PER_VENUE;
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

    function _size(bytes32 poolId, Plan memory plan, uint256 budget)
        internal
        override
        returns (uint256 left, bool declined)
    {
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
        try this.walkSteps{ gas: _sizingGas(before) }(poolId, before) returns (
            uint256 followed
        ) {
            sizingSteps = followed;
        } catch { }
        try this.size{ gas: _sizingGas(before) }(poolId, before) returns (
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

    /// What a pricer answers to `_ask` given `gas`, as the hook reads it: five words, or all
    /// zeros for no price.
    function ask(address pricer, bytes32 poolId, uint256 gas)
        external
        returns (uint256[5] memory answer)
    {
        asking = gas;
        answer = _ask(pricer, poolId);
        asking = 0;
    }

    /// The gas one ask of a pool's pricer costs, the lookups around the call included, and
    /// `ASK_OVERHEAD`, which is what the hook reserves beyond the pricer's own gas.
    function askCost(bytes32 poolId, uint256 gas)
        external
        returns (uint256 used, uint256 overhead)
    {
        asking = gas;
        uint256 start = gasleft();
        _wrapped(poolId, bytes32(0));
        used = start - gasleft();
        asking = 0;
        overhead = ASK_OVERHEAD;
    }

    /// What the hook holds back from the walk's gas cap for the call's own overhead.
    function sizingCallGas() external pure returns (uint256) {
        return SIZING_CALL_GAS;
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
    /// it, decoding the answer, and working out the gas it gets.
    function callOverhead(bytes calldata input, uint256 gas)
        external
        returns (uint256 charged, uint256 inner)
    {
        (bytes32 poolId, Plan memory plan) = abi.decode(input, (bytes32, Plan));
        asking = gas;
        this.walkGas(poolId, plan);
        (uint256 left,) = super._size(poolId, plan, type(uint128).max);
        charged = type(uint128).max - left;
        inner = this.walkGas(poolId, plan);
        asking = 0;
    }

    /// The gas the walk is given for `plan` when the market's pricers get `gas` each.
    function sizingGasWith(uint256 gas, Plan memory plan) external returns (uint256 given) {
        asking = gas;
        given = _sizingGas(plan);
        asking = 0;
    }

    /// Whether the walk could read every leg of `plan`.
    function sizeable(Plan memory plan) external view returns (bool) {
        return _sizeable(plan);
    }

    /// The first walk's input as `_size` saw it, for `coldSteps`.
    bytes public walkInput;

    /// The boundaries the walk follows for a `walkInput`, given only `SIZING_GAS`, with
    /// whatever warmth the caller has left. Zero if it ran out.
    function coldSteps(bytes calldata input) external returns (uint256 steps) {
        (bytes32 poolId, Plan memory plan) = abi.decode(input, (bytes32, Plan));
        try this.walkSteps{ gas: _sizingGas(plan) }(poolId, plan) returns (uint256 followed) {
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
