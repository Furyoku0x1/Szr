// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Which cycles the sizing walk reads (`docs/specs/hook-exact-sizing.md`, part 1): it
/// must agree with the price limit on which legs are wrapped.
contract ArbitrageSizingEligibleTest is SizingWorld {
    /// The slot of `wrappers[poolId]`: a mapping at storage slot 6 of the hook.
    function _wrappersSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, uint256(6)));
    }

    /// A wrapped pool is walked: its pricer gives the range its answer holds over. But a pool
    /// added before its hook was given a pricer has no `wrappers` entry, while its hook has a
    /// pricer now and `_legLimit` already treats it as wrapped. The walk must not read it as a
    /// plain pool, and nor a wrapped one whose pricer has been taken away.
    function testPoolOnAPricedHookIsNeverWalkedAsPlain() public {
        PoolKey memory venue = _wrappedVenue(75_000);
        ArbitrageProbe probe = _probeInHook();
        ArbitrageHook.Plan memory plan;
        plan.venue = _id(venue);
        assertTrue(
            probe.sizeableAsking(plan, 20_000), "added as a wrapped pool, which gives a range"
        );
        hook.setPricer(wrapped, address(0));
        assertFalse(probe.sizeableAsking(plan, 20_000), "once its pricer is taken away");
        hook.setPricer(wrapped, wrappedPricer);
        vm.store(address(hook), _wrappersSlot(plan.venue), bytes32(0));
        assertFalse(probe.sizeableAsking(plan, 20_000), "added before its hook had a pricer");
        ArbitrageHook.Plan memory link;
        link.links[1] = plan.venue;
        assertFalse(probe.sizeableAsking(link, 20_000), "as a connecting pool too");
        plan.venue = _id(usdPool);
        assertTrue(probe.sizeableAsking(plan, 20_000), "a plain pool is walked");
        plan.venue = bytes32(0);
        assertTrue(probe.sizeableAsking(plan, 20_000), "and so is Core");
        // With the pricer taken away the pool is not wrapped by either test.
        hook.setPricer(wrapped, address(0));
        link.venue = bytes32(0);
        assertTrue(probe.sizeableAsking(link, 20_000), "once its hook has no pricer");
    }

    /// `wrappers` is global but `asking` is one market's. A search of a market that uses no
    /// pricer (SZR's, say, while another market added a pool its own hook has a pricer for)
    /// trades that pool as wrapped, with no price limit, and cannot ask its pricer: the walk
    /// must not read it as a plain pool.
    function testWrappedPoolIsNotWalkedWhereNoPricerIsAsked() public {
        PoolKey memory venue = _wrappedVenue(75_000);
        ArbitrageProbe probe = _probeInHook();
        ArbitrageHook.Plan memory plan;
        plan.venue = _id(venue);
        assertTrue(probe.sizeableAsking(plan, 20_000), "asked in its own market");
        assertFalse(probe.sizeable(plan), "not where no pricer is asked");
        ArbitrageHook.Plan memory link;
        link.links[0] = plan.venue;
        assertFalse(probe.sizeable(link), "as a connecting pool too");
    }
}
