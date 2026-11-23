// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { FlatPricer } from "./utils/WrappedPool.sol";
import { PeekVenue } from "./utils/PeekVenue.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";

/// @dev What a venue's triggered searches leave remembered for the search after a swap. It
/// is only ever for the search that follows the same swap in the same market, so a trigger
/// must neither read what another's search left nor leave anything behind.
contract ArbitrageRememberedTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;

    uint32 internal constant CAP = 12_000_000;

    PeekVenue internal peek;
    PoolKey internal venue;
    PoolKey internal shared;
    ArbitrageProbe internal probe;

    function setUp() public override {
        super.setUp();
        address at = address(uint160(0xB0B0 << 24 | 1 << 7));
        deployCodeTo("PeekVenue.sol:PeekVenue", abi.encode(manager, hook), at);
        peek = PeekVenue(at);
        hook.setPricer(at, address(new FlatPricer()));
        // The venue holds USD, not WETH, which the trigger counts in. A wrapped pool that held
        // WETH would be searched once, from itself (`docs/specs/hook-wrapped-start.md`, part
        // B), and these tests are about the searches from each group's head.
        venue = _pair(address(usd), address(coin), 100, at);
        manager.initialize(venue, uint160(1 << 96));
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, venue);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first), _id(second)));
        _limits(address(backing), 1e15);
        peek.setTrigger(id, _id(venue), address(backing), CAP);
        probe = _probeInHook();
    }

    /// A trigger's search before a swap that trades nothing leaves its pool's venues
    /// remembered. `venueSearch` clears that as it returns: it is nobody else's to use.
    function testVenueSearchLeavesNothingRemembered() public {
        vm.expectCall(address(manager), abi.encodeWithSignature("extsload(bytes32[])"), 1);
        peek.run(_id(venue), true);
        assertEq(peek.seen(), bytes32(0), "nothing left behind");
    }

    /// Two triggers of different markets whose groups share a head pool, which is no pool of
    /// this hook: the second market's search must read its own venues, not what the first
    /// left remembered for the same pool, which are the first market's.
    function testTriggersOfDifferentMarketsDoNotShareARememberedHead() public {
        shared = _pair(address(backing), address(coin), 1_000, address(0));
        manager.initialize(shared, uint160(1 << 96));
        _provide(shared, 1_000_000e18);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, shared);
        vm.stopPrank();
        bytes32[] memory leaders = new bytes32[](3);
        leaders[0] = _id(shared);
        leaders[1] = _id(first);
        leaders[2] = _id(second);
        _lead(address(backing), address(coin), leaders);
        _limits(address(backing), 1e15);
        _openRival();
        vm.expectCall(address(manager), abi.encodeWithSignature("extsload(bytes32[])"), 2);
        peek.run(_id(venue), true);
    }

    /// A second market, owned by someone else, that tracks the shared pool and the venue.
    function _openRival() internal {
        address owner = address(0xB0B);
        vm.startPrank(owner);
        uint256 rival = hook.openMarket(owner);
        address[] memory chosen = new address[](1);
        chosen[0] = address(backing);
        hook.setTokens(rival, chosen);
        hook.addVenue(rival, shared);
        hook.addVenue(rival, venue);
        hook.setLeaders(rival, address(backing), address(coin), _list(_id(shared)));
        hook.setLimits(
            rival, address(backing), uint32(hook.minimumGasLimit(rival)), 1e15, 1.0001e18
        );
        vm.stopPrank();
        peek.setTrigger(rival, _id(venue), address(backing), CAP);
    }
}
