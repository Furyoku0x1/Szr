// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexToken, IndexWorld, MockIndexHook } from "./utils/IndexWorld.sol";

/// @dev Random swaps of both kinds (by holders, paying the fee, and by the hook, fee-free),
/// joins, exits with deferrals, claims, donations, protocol payouts, pauses and time jumps.
/// Each action checks what it must and records a break instead of reverting, so the
/// invariants report it. Calls the pool refuses are caught: refusing is always allowed.
contract IndexHandler is Test {
    using FixedPointMathLib for uint256;

    uint256 internal constant FAR = type(uint256).max;
    /// `lnWad` is off by at most 1.05 wei per term (`tools/index_vectors.py`); two
    /// evaluations of up to eight terms, each also truncated by the weighting, stay within
    /// this.
    int256 internal constant LN_TOLERANCE = 24;

    IndexPool internal pool;
    MockIndexHook internal hook;
    address[] internal list;
    address[] internal actors;
    uint256 internal count;

    bool public valueFell;
    bool public roundTripProfited;
    bool public perShareFell;
    bool public joinExitProfited;
    bool public donationSniped;
    bool public owedMovedWrongly;
    bool public balanceBelowMinimum;
    uint256 public swaps;
    uint256 public hookSwaps;
    uint256 public roundTrips;
    uint256 public joins;
    uint256 public exits;
    uint256 public deferrals;
    uint256 public claims;
    uint256 public donations;

    constructor(IndexPool pool_, MockIndexHook hook_, address[] memory actors_) {
        pool = pool_;
        hook = hook_;
        list = pool_.tokens();
        actors = actors_;
        count = list.length;
    }

    // ---------------------------------------------------------------- swaps

    function swap(uint256 seed, uint256 amount, bool exactIn, uint256 action) external {
        address actor = actors[seed % actors.length];
        (uint256 i, uint256 o) = _pair(seed >> 8);
        uint256 given = _given(i, o, amount, exactIn);
        _setHookAction(action);
        int256 before = _value();
        uint256[] memory owedBefore = _owed();
        vm.prank(actor);
        try pool.swap(list[i], list[o], given, exactIn, exactIn ? 0 : FAR, actor, FAR) returns (
            uint256 amountIn, uint256
        ) {
            swaps++;
            _afterSwap(before, i, o);
            _checkSwapOwed(owedBefore, i, amountIn);
        } catch { }
    }

    function hookSwap(uint256 seed, uint256 amount, bool exactIn) external {
        (uint256 i, uint256 o) = _pair(seed);
        uint256 given = _given(i, o, amount, exactIn);
        int256 before = _value();
        uint256[] memory owedBefore = _owed();
        try hook.swapAsHook(list[i], list[o], given, exactIn, exactIn ? 0 : FAR) {
            hookSwaps++;
            _afterSwap(before, i, o);
            _checkUnchanged(owedBefore, count);
        } catch { }
    }

    /// The hook's fee-free trades there and back, every combination of kinds. They are kept:
    /// a snapshot undone inside a handler call does not reliably keep what is written after.
    function hookRoundTrip(uint256 seed, uint256 amount, bool firstExactIn, bool backExactIn)
        external
    {
        (uint256 i, uint256 o) = _pair(seed);
        uint256 given = _given(i, o, amount, firstExactIn);
        uint256 a = _balanceOf(list[i], address(hook));
        uint256 b = _balanceOf(list[o], address(hook));
        try hook.swapAsHook(
            list[i], list[o], given, firstExactIn, firstExactIn ? 0 : FAR
        ) returns (
            uint256 paid, uint256 got
        ) {
            if (_back(i, o, paid, got, backExactIn, a, b)) roundTrips++;
        } catch { }
    }

    // ---------------------------------------------------------------- shares

    function join(uint256 seed, uint256 shares) external {
        address actor = actors[seed % actors.length];
        shares = bound(shares, 1, pool.totalSupply() / 5 + 1);
        (uint256[] memory before, uint256 supply) = _perShare();
        vm.prank(actor);
        try pool.join(shares, _maxes(), FAR) {
            joins++;
            _checkPerShare(before, supply);
        } catch { }
    }

    function exit(uint256 seed, uint256 shares, uint256 mask) external {
        address actor = actors[seed % actors.length];
        uint256 held = pool.balanceOf(actor);
        if (held == 0) return;
        shares = bound(shares, 1, held);
        address[] memory deferring = _deferring(mask);
        (uint256[] memory before, uint256 supply) = _perShare();
        vm.prank(actor);
        try pool.exit(shares, new uint256[](count), deferring, FAR) {
            exits++;
            if (deferring.length != 0) deferrals++;
            _checkPerShare(before, supply);
        } catch { }
    }

    function claim(uint256 seed, uint256 index) external {
        address actor = actors[seed % actors.length];
        address token = list[index % count];
        uint256 owed = pool.deferred(actor, token);
        uint256 had = _balanceOf(token, actor);
        vm.prank(actor);
        try pool.claim(token) returns (uint256 paid) {
            if (paid != 0) claims++;
            if (paid != owed) owedMovedWrongly = true;
            if (_balanceOf(token, actor) != had + paid) owedMovedWrongly = true;
        } catch { }
    }

    /// Invariant 5: joining and leaving with the same shares returns no more than was paid.
    function joinExit(uint256 seed, uint256 shares) external {
        address actor = actors[seed % actors.length];
        shares = bound(shares, 1, pool.totalSupply() * 3);
        uint256[] memory start = _holdings(actor);
        vm.startPrank(actor);
        try pool.join(shares, _maxes(), FAR) {
            try pool.exit(shares, new uint256[](count), new address[](0), FAR) {
                _checkNoGain(actor, start, false);
            } catch { }
        } catch { }
        vm.stopPrank();
    }

    /// Invariant 11: a large deposit, a donation and a withdrawal in one transaction return
    /// no more than was deposited.
    function joinDonateExit(uint256 seed, uint256 shares, uint256 index, uint256 amount)
        external
    {
        address actor = actors[seed % actors.length];
        address donor = actors[(seed % actors.length + 1) % actors.length];
        address token = list[index % count];
        shares = bound(shares, 1, pool.totalSupply() * 10);
        amount = bound(amount, 1, pool.balances()[index % count]);
        uint256[] memory start = _holdings(actor);
        vm.prank(actor);
        try pool.join(shares, _maxes(), FAR) { }
        catch {
            return;
        }
        vm.prank(donor);
        try pool.donate(token, amount) { } catch { }
        vm.prank(actor);
        try pool.exit(shares, new uint256[](count), new address[](0), FAR) {
            _checkNoGain(actor, start, true);
        } catch { }
    }

    // ---------------------------------------------------------------- donations and fees

    function donate(uint256 seed, uint256 index, uint256 amount) external {
        address actor = actors[seed % actors.length];
        index = index % count;
        amount = bound(amount, 1, pool.balances()[index] / 10 + 1);
        (uint256[] memory before, uint256 supply) = _perShare();
        uint256[] memory owedBefore = _owed();
        vm.prank(actor);
        try pool.donate(list[index], amount) {
            donations++;
            _checkPerShare(before, supply);
            if (pool.owed(list[index]) != owedBefore[index] + amount * 3000 / 10_000) {
                owedMovedWrongly = true;
            }
            owedBefore[index] = pool.owed(list[index]);
            _checkUnchanged(owedBefore, count);
        } catch { }
    }

    function payProtocol(uint256 index) external {
        address token = list[index % count];
        uint256 owed = pool.owed(token);
        address protocol = pool.protocol();
        uint256 had = _balanceOf(token, protocol);
        try pool.payProtocol(token) returns (uint256 paid) {
            if (paid != owed) owedMovedWrongly = true;
            if (pool.owed(token) != 0) owedMovedWrongly = true;
            if (_balanceOf(token, protocol) != had + paid) owedMovedWrongly = true;
        } catch { }
    }

    /// Pauses at most one token at a time, and lifts every pause seven times in eight, so
    /// the pool keeps trading while holders learn to leave around a stuck token.
    function pause(uint256 index) external {
        for (uint256 at; at < count; at++) {
            IndexToken(list[at]).setPaused(false);
        }
        if (index % 8 != 0) return;
        IndexToken(list[(index >> 8) % count]).setPaused(true);
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    // ---------------------------------------------------------------- checks

    function _afterSwap(int256 before, uint256 i, uint256 o) internal {
        if (_value() + LN_TOLERANCE < before) valueFell = true;
        uint256[] memory balances = pool.balances();
        if (balances[o] < _minimumRaw(o)) balanceBelowMinimum = true;
        if (balances[i] < _minimumRaw(i)) balanceBelowMinimum = true;
    }

    /// Invariant 7 for a holder's swap: only the token in's cut, at most 15% of the fee,
    /// plus whatever the honest hook donated meanwhile.
    function _checkSwapOwed(uint256[] memory before, uint256 i, uint256 amountIn) internal {
        for (uint256 index; index < count; index++) {
            uint256 owed = pool.owed(list[index]);
            if (owed < before[index]) owedMovedWrongly = true;
            uint256 allowed = _hookDonationCut(index);
            if (index == i) allowed += amountIn.mulWadUp(pool.swapFee()) * 15 / 100 + 2;
            if (owed > before[index] + allowed) owedMovedWrongly = true;
        }
    }

    function _checkUnchanged(uint256[] memory before, uint256 length) internal {
        for (uint256 index; index < length; index++) {
            if (pool.owed(list[index]) != before[index]) owedMovedWrongly = true;
        }
    }

    /// Invariant 4: `after / supplyAfter >= before / supplyBefore` for every token.
    function _checkPerShare(uint256[] memory before, uint256 supply) internal {
        uint256[] memory balances = pool.balances();
        uint256 supplyAfter = pool.totalSupply();
        for (uint256 index; index < count; index++) {
            if (balances[index] * supply < before[index] * supplyAfter) perShareFell = true;
        }
    }

    function _checkNoGain(address actor, uint256[] memory start, bool donation) internal {
        uint256[] memory end = _holdings(actor);
        for (uint256 index; index < count; index++) {
            if (end[index] <= start[index]) continue;
            if (donation) donationSniped = true;
            else joinExitProfited = true;
        }
    }

    function _back(
        uint256 i,
        uint256 o,
        uint256 paid,
        uint256 got,
        bool backExactIn,
        uint256 a,
        uint256 b
    ) internal returns (bool done) {
        if (backExactIn) {
            try hook.swapAsHook(list[o], list[i], got, true, 0) {
                if (_balanceOf(list[i], address(hook)) > a) roundTripProfited = true;
                done = true;
            } catch { }
            return done;
        }
        try hook.swapAsHook(list[o], list[i], paid, false, FAR) {
            if (_balanceOf(list[o], address(hook)) > b) roundTripProfited = true;
            done = true;
        } catch { }
    }

    // ---------------------------------------------------------------- helpers

    function _setHookAction(uint256 action) internal {
        if (hook.mode() != MockIndexHook.Mode.Honest) return;
        (uint256 i, uint256 o) = _pair(action);
        uint256 amount = pool.balances()[i] / (100 + (action >> 16) % 10_000);
        hook.setAction(list[i], list[o], amount);
        uint256 donated = pool.balances()[o] / (1000 + (action >> 32) % 100_000);
        hook.setDonation(list[o], donated);
    }

    function _hookDonationCut(uint256 index) internal view returns (uint256) {
        if (hook.mode() != MockIndexHook.Mode.Honest) return 0;
        if (hook.donateToken() != list[index]) return 0;
        return hook.donateAmount() * 3000 / 10_000;
    }

    function _pair(uint256 seed) internal view returns (uint256 i, uint256 o) {
        i = seed % count;
        o = (i + 1 + (seed >> 4) % (count - 1)) % count;
    }

    /// Mostly inside every limit, now and then far outside it.
    function _given(uint256 i, uint256 o, uint256 amount, bool exactIn)
        internal
        view
        returns (uint256)
    {
        uint256 balance = pool.balances()[exactIn ? i : o];
        if (amount % 8 == 0) return bound(amount, 0, balance);
        return bound(amount, 1, balance / 25 + 1);
    }

    function _deferring(uint256 mask) internal view returns (address[] memory deferring) {
        uint256 total;
        for (uint256 index; index < count; index++) {
            if (mask & (1 << index) != 0) total++;
        }
        deferring = new address[](total);
        uint256 at;
        for (uint256 index; index < count; index++) {
            if (mask & (1 << index) == 0) continue;
            deferring[at] = list[index];
            at++;
        }
    }

    function _perShare() internal view returns (uint256[] memory, uint256) {
        return (pool.balances(), pool.totalSupply());
    }

    function _owed() internal view returns (uint256[] memory owed) {
        owed = new uint256[](count);
        for (uint256 index; index < count; index++) {
            owed[index] = pool.owed(list[index]);
        }
    }

    /// What the holder has and is owed by deferral, per token.
    function _holdings(address actor) internal view returns (uint256[] memory held) {
        held = new uint256[](count);
        for (uint256 index; index < count; index++) {
            held[index] = _balanceOf(list[index], actor) + pool.deferred(actor, list[index]);
        }
    }

    function _maxes() internal view returns (uint256[] memory maxes) {
        maxes = new uint256[](count);
        for (uint256 index; index < count; index++) {
            maxes[index] = FAR;
        }
    }

    function _value() internal view returns (int256 total) {
        uint256[] memory balances = pool.balances();
        uint256[] memory weights = pool.weights();
        for (uint256 index; index < count; index++) {
            uint256 scale = 10 ** (18 - IndexToken(list[index]).decimals());
            int256 ln = FixedPointMathLib.lnWad(int256(balances[index] * scale));
            total += ln * int256(weights[index]) / 1e18;
        }
    }

    function _minimumRaw(uint256 index) internal view returns (uint256) {
        uint256 scale = 10 ** (18 - IndexToken(list[index]).decimals());
        if (scale >= 1e6) return 1;
        return 1e6 / scale;
    }

    function _balanceOf(address token, address who) internal view returns (uint256) {
        return ERC20(token).balanceOf(who);
    }
}

/// @dev One pool, its handler and the invariants checked after every call.
abstract contract IndexInvariantBase is IndexWorld {
    IndexPool internal pool;
    MockIndexHook internal hook;
    IndexHandler internal handler;
    address[] internal holders;

    function _deploy(uint8[] memory places, uint256[] memory weights, MockIndexHook.Mode mode)
        internal
    {
        hook = new MockIndexHook();
        pool = _create(_tokens(places), weights, FEE, address(hook), 2_000_000);
        uint256[] memory units = new uint256[](places.length);
        for (uint256 index; index < units.length; index++) {
            units[index] = 1e6 + index * 1013;
        }
        _start(pool, units, 1e24);
        _fundAll(address(hook), pool, 1e45);
        hook.setPool(pool);
        hook.setMode(mode);
        for (uint256 index; index < 3; index++) {
            address actor = address(uint160(0xA1 + index));
            holders.push(actor);
            _fundAll(actor, pool, 1e45);
            pool.transfer(actor, 2e23);
        }
        handler = new IndexHandler(pool, hook, holders);
        holders.push(address(this));
        holders.push(address(hook));
        holders.push(pool.DEAD());
        targetContract(address(handler));
    }

    /// Invariant 1, and every holder's possible withdrawal together with the cut, the
    /// deferred amounts and what is unreleased never exceed what the pool holds.
    function invariant_solvent() public view {
        address[] memory list = pool.tokens();
        uint256[] memory balances = pool.balances();
        uint256[] memory withdrawable = new uint256[](list.length);
        for (uint256 at; at < holders.length; at++) {
            uint256 shares = pool.balanceOf(holders[at]);
            if (shares == 0) continue;
            uint256[] memory out = pool.previewExit(shares);
            for (uint256 index; index < list.length; index++) {
                withdrawable[index] += out[index];
            }
        }
        for (uint256 index; index < list.length; index++) {
            address token = list[index];
            assertLe(withdrawable[index], balances[index], "withdrawals");
            uint256 recorded = balances[index] + pool.unreleased(token) + pool.owed(token);
            for (uint256 at; at < holders.length; at++) {
                recorded += pool.deferred(holders[at], token);
            }
            assertGe(ERC20(token).balanceOf(address(pool)), recorded, "solvent");
        }
    }

    /// Invariant 6: the locked first shares never go.
    function invariant_supply() public view {
        assertGe(pool.totalSupply(), pool.DEAD_SHARES());
        assertEq(pool.balanceOf(pool.DEAD()), pool.DEAD_SHARES());
    }

    function invariant_actions() public view {
        assertFalse(handler.valueFell(), "value function fell");
        assertFalse(handler.roundTripProfited(), "fee-free round trip profited");
        assertFalse(handler.perShareFell(), "balance per share fell");
        assertFalse(handler.joinExitProfited(), "join and exit profited");
        assertFalse(handler.donationSniped(), "donation taken in one transaction");
        assertFalse(handler.owedMovedWrongly(), "owed moved wrongly");
        assertFalse(handler.balanceBelowMinimum(), "swap left a balance below the minimum");
    }

    function afterInvariant() public view {
        console2.log(
            "swaps, hook swaps, joins", handler.swaps(), handler.hookSwaps(), handler.joins()
        );
        console2.log(
            "exits, deferrals, claims", handler.exits(), handler.deferrals(), handler.claims()
        );
        console2.log("donations, hook round trips", handler.donations(), handler.roundTrips());
    }
}

contract IndexPoolInvariantTwoTest is IndexInvariantBase {
    function setUp() public override {
        super.setUp();
        _deploy(_pair(6, 18), _weights(8e17, 2e17), MockIndexHook.Mode.Honest);
    }
}

contract IndexPoolInvariantFiveTest is IndexInvariantBase {
    function setUp() public override {
        super.setUp();
        uint8[] memory places = new uint8[](5);
        places[0] = 6;
        places[1] = 8;
        places[2] = 18;
        places[3] = 18;
        places[4] = 6;
        _deploy(places, _equal(5), MockIndexHook.Mode.Honest);
    }
}

contract IndexPoolInvariantEightTest is IndexInvariantBase {
    function setUp() public override {
        super.setUp();
        uint8[] memory places = new uint8[](8);
        uint256[] memory weights = new uint256[](8);
        for (uint256 index; index < 8; index++) {
            places[index] = [6, 18, 8, 18, 6, 12, 18, 2][index];
            weights[index] = index == 0 ? 3e17 : 1e17;
        }
        _deploy(places, weights, MockIndexHook.Mode.Idle);
    }
}
