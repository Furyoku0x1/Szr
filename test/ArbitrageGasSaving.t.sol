// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { StartWorld } from "./ArbitrageWrappedStart.t.sol";
import { IVenuePricer } from "../src/interfaces/IVenuePricer.sol";
import { Vm } from "forge-std/Vm.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The gas savings of `docs/specs/hook-gas-2026-11-23.md` must change nothing but gas.
contract ArbitrageGasSavingWrappedTest is StartWorld {
    PoolKey internal daiPool;

    /// Two groups of the market, each with its own head, and a gap at each head, with the
    /// wrapped pool shared by both.
    function _twoHeads() internal {
        daiPool = _create(address(backing), address(dai), 3_000);
        _lead(address(backing), address(dai), _list(_id(daiPool)));
        _gap(address(coin), 50_000e18);
        _off();
        _trade(daiPool, address(dai), 50_000e18);
        _on();
    }

    /// How many times `pricer` was asked for a price, in calls that were undone too.
    function _asks(Vm.AccountAccess[] memory accesses) internal view returns (uint256 count) {
        for (uint256 index; index < accesses.length; index++) {
            if (accesses[index].account != address(pricer)) continue;
            if (accesses[index].data.length < 4) continue;
            if (bytes4(accesses[index].data) == IVenuePricer.price.selector) count++;
        }
    }

    /// A sweep over several heads asks each pricer once, not once per head. With no gap
    /// open no cycle runs, so nothing asks again after a cycle.
    function testASweepAsksEachPricerOnce() public {
        daiPool = _create(address(backing), address(dai), 3_000);
        _lead(address(backing), address(dai), _list(_id(daiPool)));
        _on();
        assertEq(hook.groupsOf(id, address(backing)).length, 2, "two heads");
        vm.startStateDiffRecording();
        hook.sweep(id, address(backing));
        assertEq(_asks(vm.stopAndReturnStateDiff()), 1, "asked once");
    }

    /// And it earns what it did when each head asked for itself.
    function testASweepEarnsWhatSeparateSearchesEarn() public {
        _twoHeads();
        uint256 swept = hook.sweep(id, address(backing));
        // What the sweep earned before its heads shared the answers, measured then.
        assertEq(swept, 1_177_005_403_106_953_687_759, "the same profit");
    }
}

/// @dev G-1, G-2 and G-3, which must change nothing but gas.
contract ArbitrageGasSavingTest is MultiWorld {
    uint256 internal constant WAD = 1e18;

    /// The fee table is the square root it stands for, at each tier and at any fee.
    function testKeepTableMatchesTheSquareRoot() public {
        ArbitrageProbe probe = _probeInHook();
        uint24[4] memory tiers = [uint24(100), 500, 3_000, 10_000];
        for (uint256 index; index < 4; index++) {
            uint256 fee = tiers[index];
            assertEq(probe.keepOf(tiers[index]), FixedPointMathLib.sqrt((1e6 - fee) * 1e30));
        }
    }

    function testFuzzKeepMatchesTheSquareRoot(uint24 fee) public {
        ArbitrageProbe probe = _probeInHook();
        uint256 expected = fee >= 1e6 ? 0 : FixedPointMathLib.sqrt((1e6 - uint256(fee)) * 1e30);
        assertEq(probe.keepOf(fee), expected);
    }

    /// `_consider`, with its unchecked arithmetic, against the same steps checked, over the
    /// rates and keeps its checks allow: the same gap and direction whenever it plans.
    function testFuzzConsiderMatchesACheckedReference(
        uint256 focusRate,
        uint256 venueRate,
        uint256 focusKeep,
        uint256 venueKeep
    ) public {
        ArbitrageProbe probe = _probeInHook();
        focusRate = bound(focusRate, 1 << 40, 1 << 152);
        // Within a factor of a few of the focus rate, where plans are made.
        venueRate =
            FixedPointMathLib.fullMulDiv(focusRate, bound(venueRate, WAD / 2, 3 * WAD), WAD);
        venueRate = bound(venueRate, 1 << 40, 1 << 152);
        focusKeep = bound(focusKeep, 9e17, WAD);
        venueKeep = bound(venueKeep, 9e17, WAD);
        (uint256 gap, bool buying, uint256 score) =
            probe.considered(_id(mainPool), focusRate, venueRate, focusKeep, venueKeep);
        uint256 keep = venueKeep * focusKeep / WAD * WAD / WAD;
        if (keep < 1e12) {
            assertEq(score, 0);
            return;
        }
        uint256 target = FixedPointMathLib.fullMulDiv(venueRate, keep, WAD);
        bool wantBuy = target > focusRate;
        if (!wantBuy) {
            target = FixedPointMathLib.fullMulDiv(venueRate, WAD, keep);
            if (target >= focusRate) {
                assertEq(score, 0, "no gap, no plan");
                return;
            }
        }
        uint256 edge = wantBuy
            ? FixedPointMathLib.fullMulDiv(target, WAD, focusRate)
            : FixedPointMathLib.fullMulDiv(focusRate, WAD, target);
        if (edge > 4e18) {
            assertEq(score, 0, "too wide");
            return;
        }
        if (score == 0) return;
        assertEq(gap, edge - WAD, "the same gap");
        assertEq(buying, wantBuy, "the same direction");
    }

    /// G-2: the one-pass listing gives each pool of the world the books it gave before.
    function testEveryPoolOfTheWorldListsTheSameBooks() public {
        ArbitrageProbe probe = _probeInHook();
        PoolKey[7] memory pools = [first, second, stable, wethDai, usdCoin, usdDai, usdPool];
        for (uint256 index; index < pools.length; index++) {
            assertTrue(
                probe.centresAgree(id, _id(pools[index]), pools[index]), "the same books"
            );
        }
    }

    /// G-2: kept books come back as they were, once, only for their pool, and are cleared
    /// when the hook forgets them.
    function testKeptBooksComeBackOnceForTheirPool() public {
        ArbitrageProbe probe = _probeInHook();
        (bool same, bool once, bool forgotten, bool keyed) =
            probe.centresRoundTrip(id, _id(stable), stable);
        assertTrue(same, "the same books");
        assertTrue(once, "given once");
        assertTrue(forgotten, "cleared by forgetting");
        assertTrue(keyed, "not given for another pool");
    }

    /// G-2: a change to the market's tokens in the same transaction is seen by the next swap
    /// in the pool: the books kept for the swap before it were used and cleared.
    function testAChangeOfTokensIsSeenByTheNextSwap() public {
        _trade(stable, address(coin), 50_000e18);
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        uint256 paid = usd.balanceOf(treasury);
        address[] memory only = new address[](1);
        only[0] = address(backing);
        vm.prank(team);
        hook.setTokens(id, only);
        _trade(stable, address(coin), 50_000e18);
        assertEq(usd.balanceOf(treasury), paid, "no book in USD any more");
        // And a leader change: a token whose leaders are gone opens no book either.
        address[] memory both = new address[](2);
        both[0] = address(backing);
        both[1] = address(usd);
        vm.prank(team);
        hook.setTokens(id, both);
        bytes32[] memory none = new bytes32[](0);
        _lead(address(usd), address(coin), none);
        _lead(address(usd), address(dai), none);
        _trade(stable, address(coin), 50_000e18);
        assertEq(usd.balanceOf(treasury), paid, "no leader, no book");
    }

    /// G-3: a venue is remembered in three words and comes back whole.
    function testRememberedVenuesComeBackWhole() public {
        ArbitrageProbe probe = _probeInHook();
        (bool same, uint256 venues) =
            probe.rememberRoundTrip(id, address(backing), _id(first), address(coin));
        assertTrue(same, "the same venues");
        assertGt(venues, 1, "with venues to remember");
        (same, venues) = probe.rememberRoundTrip(id, address(usd), _id(usdCoin), address(coin));
        assertTrue(same, "and in another book");
    }
}
