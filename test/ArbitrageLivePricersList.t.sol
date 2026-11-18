// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev `docs/specs/hook-live-pricers.md`: the list of a market's wrapped pools, what is
/// reserved for asking them, and the ask after a cycle.
contract ArbitrageLivePricersListTest is MarketsWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal mock;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        mock = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(mock));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
    }

    function _venue(address partner, uint24 fee) internal returns (PoolKey memory pool) {
        pool = _pair(address(backing), partner, fee, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        TestAsset(address(backing)).mint(address(wrapper), 1_000_000e18);
        TestAsset(partner).mint(address(wrapper), 1_000_000e18);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    // ---------------------------------------------------------------------------------
    // the list
    // ---------------------------------------------------------------------------------

    /// The list grows with each wrapped pool a market tracks or connects with, once each,
    /// and shrinks as it lets one go. A pool that is both tracked and a connecting pool
    /// stays until it is neither, a connecting pool that another replaces is let go, and
    /// with the list empty the market reserves nothing for asking again.
    function testTheListFollowsTheMarket() public {
        uint256 plain = hook.minimumGasLimit(id);
        assertEq(hook.wrappedPools(id).length, 0, "none yet");
        assertEq(hook.market(id).pricerGas, 0, "and no pricer gas");
        PoolKey memory one = _venue(address(coin), 3_000);
        PoolKey memory two = _venue(address(coin), 500);
        PoolKey memory three = _venue(address(coin), 100);
        vm.startPrank(team);
        hook.addVenue(id, one);
        assertEq(hook.wrappedPools(id).length, 1, "a tracked pool");
        hook.addVenue(id, two);
        assertEq(hook.wrappedPools(id).length, 2, "and another");
        assertGt(hook.market(id).pricerGas, 0, "the market asks pricers now");
        // Tracked and connecting: one entry, and it stays while either holds.
        hook.setConnector(id, one, true);
        assertEq(hook.wrappedPools(id).length, 2, "no entry twice");
        hook.setConnector(id, one, false);
        assertEq(hook.wrappedPools(id).length, 2, "still tracked");
        hook.setConnector(id, one, true);
        hook.untrack(id, _id(one));
        assertEq(hook.wrappedPools(id).length, 2, "still a connecting pool");
        hook.setConnector(id, one, false);
        assertEq(hook.wrappedPools(id).length, 1, "neither now");
        assertEq(hook.wrappedPools(id)[0], _id(two), "the one left");
        // A connecting pool replaced by another goes when nothing else keeps it.
        hook.setConnector(id, three, true);
        assertEq(hook.wrappedPools(id).length, 2, "a connecting pool");
        hook.setConnector(id, two, true);
        assertEq(hook.wrappedPools(id).length, 1, "the replaced one went");
        assertEq(hook.wrappedPools(id)[0], _id(two), "and the tracked one stayed");
        hook.untrack(id, _id(two));
        assertEq(hook.wrappedPools(id).length, 1, "kept as the connecting pool");
        hook.setConnector(id, two, false);
        vm.stopPrank();
        assertEq(hook.wrappedPools(id).length, 0, "empty");
        assertEq(hook.market(id).pricerGas, 0, "a plain market again");
        assertEq(hook.minimumGasLimit(id), plain, "reserving what it did before");
    }

    /// SZR's market lists a wrapped pool it adds and lets it go when it stops tracking it.
    function testSzrMarketsListFollowsItsPools() public {
        PoolKey memory away = _pair(address(szr), address(backing), 3_000, address(wrapper));
        manager.initialize(away, uint160(1 << 96));
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        hook.addVenue(1, away);
        assertEq(hook.wrappedPools(1).length, 1);
        hook.untrack(1, _id(away));
        assertEq(hook.wrappedPools(1).length, 0);
        assertEq(hook.market(1).pricerGas, 0, "plain again");
    }

    // ---------------------------------------------------------------------------------
    // reserves
    // ---------------------------------------------------------------------------------

    /// Each wrapped pool adds one ask to what a market reserves, counted twice because the
    /// search before a swap reserves reading the venues for itself and for the search after,
    /// and nothing more: not five asks a venue, which is what the first design charged.
    function testReservesCountEachWrappedPoolOnce() public {
        ArbitrageProbe probe = _probeInHook();
        uint256 each = hook.market(id).pricerGas;
        vm.startPrank(team);
        hook.addVenue(id, _venue(address(coin), 3_000));
        each = hook.market(id).pricerGas + probe.askOverhead();
        uint256 one = hook.minimumGasLimit(id);
        hook.addVenue(id, _venue(address(coin), 500));
        uint256 two = hook.minimumGasLimit(id);
        hook.addVenue(id, _venue(address(coin), 100));
        uint256 three = hook.minimumGasLimit(id);
        vm.stopPrank();
        assertEq(two - one, 2 * each, "a second wrapped pool");
        assertEq(three - two, 2 * each, "a third");
    }

    /// A search holds back the same: its floor, which it checks before each cycle, counts each
    /// wrapped pool the market has to ask, as the allowance does.
    function testFloorsCountEachWrappedPoolOnce() public {
        vm.startPrank(team);
        hook.addVenue(id, _venue(address(coin), 3_000));
        vm.stopPrank();
        ArbitrageProbe probe = _probeInHook();
        uint256 each = hook.market(id).pricerGas + probe.askOverhead();
        uint256 one = probe.floorAfterFill(id, 4);
        PoolKey memory two = _venue(address(coin), 500);
        vm.prank(team);
        hook.addVenue(id, two);
        assertEq(probe.floorAfterFill(id, 4) - one, each, "a second wrapped pool");
    }

    /// After a cycle succeeds a search asks again about the venue and the two links it can
    /// have used, so what it holds back for that is three asks, whatever else the floor
    /// counts. Raising the pricer's allowance raises the floor of a search after a swap by
    /// three times as much, and the allowance for it by what the floors of both searches
    /// and the failed cycles it must absorb add up to.
    function testOverheadCountsThreeAsksAfterACycle() public {
        PoolKey memory one = _venue(address(coin), 3_000);
        vm.prank(team);
        hook.addVenue(id, one);
        ArbitrageProbe probe = _probeInHook();
        uint256 step = 8_000;
        (, uint256 low) = probe.floorsBoth(id, 4, false);
        uint256 limit = hook.minimumGasLimit(id);
        uint32 raised = uint32(hook.market(id).pricerGas + step);
        vm.prank(team);
        hook.setPricerGas(id, raised);
        (, uint256 high) = probe.floorsBoth(id, 4, false);
        assertEq(high - low, 3 * step, "three asks after a cycle");
        // The floor of the search before a swap holds two of those, and the allowance holds
        // the failed cycles it must absorb on top of that, with the one wrapped pool asked
        // while reading the venues each time.
        assertEq(
            hook.minimumGasLimit(id) - limit, (2 * 3 + 1 + 1 + 2 * 3) * step, "the allowance"
        );
    }

    /// The floor a search checks and the one the allowance is sized from are the same number,
    /// in a plain market and in one with wrapped pools, before a swap and after it.
    function testSearchAndAllowanceFloorsAgree() public {
        ArbitrageProbe probe = _probeInHook();
        for (uint256 round; round < 2; round++) {
            for (uint256 venues = 2; venues <= 10; venues += 4) {
                (uint256 here, uint256 plain) = probe.floorsBoth(id, venues, true);
                assertEq(here, plain, "before a swap");
                (here, plain) = probe.floorsBoth(id, venues, false);
                assertEq(here, plain, "after one");
            }
            PoolKey memory pool = _venue(address(coin), uint24(3_000 + round));
            vm.prank(team);
            hook.addVenue(id, pool);
        }
    }

    // ---------------------------------------------------------------------------------
    // the ask after a cycle
    // ---------------------------------------------------------------------------------

    /// Short of gas to ask again after a cycle, a search stops with its profit: it is not
    /// failed `Starved`. With the gas, the pool is asked again.
    function testRepriceShortOfGasStopsQuietly() public {
        PoolKey memory one = _venue(address(coin), 3_000);
        vm.prank(team);
        hook.addVenue(id, one);
        ArbitrageProbe probe = _probeInHook();
        bool short;
        bool done;
        for (uint256 gas = 60_000; gas <= 300_000; gas += 3_000) {
            try probe.repriceShort{ gas: gas }(id, address(backing), _id(one)) returns (
                bool asked
            ) {
                if (asked) done = true;
                else short = true;
            } catch { }
        }
        assertTrue(short, "cut short at the ask, without a revert");
        assertTrue(done, "and asked when there was gas");
    }

    // ---------------------------------------------------------------------------------
    // A1: the book read again after a success
    // ---------------------------------------------------------------------------------

    /// The most venues a search prices: a group of three leaders and seven other groups (ten,
    /// which `_venueCount` rounds up to twelve),
    /// every other group led by a wrapped pool, and the three leaders' pool wrapped too.
    /// A success makes a search read the venues again, from what the cache holds: it asks
    /// nothing and costs about what reading a plain book costs. It runs only with a floor's
    /// gas left, which holds a whole plan (two million) beyond the ranking before it.
    function testTheBookReadAgainFitsItsSlackAtTheMostVenues() public {
        PoolKey memory head = _venue(address(coin), 3_000);
        vm.startPrank(team);
        hook.addVenue(id, head);
        vm.stopPrank();
        bytes32[] memory leaders = new bytes32[](3);
        leaders[0] = _id(first);
        leaders[1] = _id(second);
        leaders[2] = _id(head);
        _lead(address(backing), address(coin), leaders);
        for (uint256 index; index < 7; index++) {
            TestAsset partner = new TestAsset();
            PoolKey memory pool = _venue(address(partner), 3_000);
            vm.prank(team);
            hook.addVenue(id, pool);
            _lead(address(backing), address(partner), _list(_id(pool)));
        }
        ArbitrageProbe probe = _probeInHook();
        (uint256 book, uint256 best, uint256 venues, uint256 allowance, uint256 bookAllowance) =
            probe.scanCostIn(id, address(backing), _id(first));
        (,, uint256 plan) = probe.sizingLimits();
        console.log("A1 venues", venues, "wrapped pools", hook.wrappedPools(id).length);
        console.log("A1 book read again", book, "allowance", venues * bookAllowance);
        console.log("A1 ranking", best, "allowance", venues * allowance);
        console.log("A1 the plan held beyond it", 2 * plan);
        assertEq(venues, 10, "the most venues the book holds");
        assertLe(book, venues * bookAllowance, "the read fits its allowance");
        assertLe(best, venues * allowance, "and so does the ranking");
        assertLt(book + best, 2 * plan, "both fit the plan held beyond them");
    }
}
