// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Pools are grouped by partner token and each group has a few leaders. A search
/// prices the leaders of the searched pool's group and the first leader of every other
/// group, so its cost does not depend on how many pools are tracked.
contract ArbitrageGroupsTest is ArbitrageWorld {
    function _list(bytes32 first) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = first;
    }

    function _venuesTraded() internal returns (bytes32[] memory venues) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        venues = new bytes32[](logs.length);
        uint256 count;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.Arbitraged.selector) continue;
            venues[count++] = logs[index].topics[2];
        }
        assembly ("memory-safe") {
            mstore(venues, count)
        }
    }

    function _contains(bytes32[] memory list, bytes32 wanted) internal pure returns (bool) {
        for (uint256 index; index < list.length; index++) {
            if (list[index] == wanted) return true;
        }
        return false;
    }

    /// A pool that is not a leader is still searched when it trades, against its group's
    /// leaders and the other groups' first leaders.
    function testPoolThatIsNotALeaderIsSearchedWhenItTrades() public {
        _addHooked(address(usd), 500);
        _addHooked(address(usd), 100);
        // The group's three leader slots are taken, so this one only follows.
        PoolKey memory follower = _addHooked(address(usd), 10_000);
        assertEq(hook.leadersOf(1, address(szr), address(usd)).length, hook.MAX_LEADERS());
        uint256 inventory = core.unreleasedSupply();
        _trade(follower, address(szr), 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "gap closed against the leaders");
        assertEq(hook.arb(_id(follower)), 0, "nothing left");
        _assertHookEmpty();
    }

    /// Only a group's first leader is compared with other groups. A second leader of the
    /// WETH group, priced far from everything, is not what a USD pool trades against.
    function testOtherGroupsAreComparedThroughTheirFirstLeader() public {
        PoolKey memory second = _addHooked(address(backing), 500);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(second, address(szr), 150_000e18);
        hook.setLimits(1, address(szr), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        vm.recordLogs();
        _trade(usdPool, address(szr), 50_000e18);
        bytes32[] memory venues = _venuesTraded();
        assertTrue(_contains(venues, _id(mainPool)), "traded against the first leader");
        // The search then moves to the main pool, whose own group does include it.
        assertGt(venues.length, 1, "and followed on within the WETH group");
    }

    /// Swapping the order of a group's leaders changes which one other groups see.
    function testLeaderOrderDecidesWhatOtherGroupsSee() public {
        PoolKey memory second = _addHooked(address(backing), 500);
        bytes32[] memory order = new bytes32[](2);
        order[0] = _id(second);
        order[1] = _id(mainPool);
        _setLeaders(address(backing), order);
        vm.recordLogs();
        _trade(usdPool, address(szr), 50_000e18);
        bytes32[] memory venues = _venuesTraded();
        assertEq(venues[0], _id(second), "first cycle is against the new first leader");
    }

    function testLeaderRules() public {
        PoolKey memory second = _addHooked(address(usd), 500);
        PoolKey memory third = _addHooked(address(usd), 100);
        PoolKey memory fourth = _addHooked(address(usd), 10_000);
        bytes32[] memory list = new bytes32[](4);
        list[0] = _id(usdPool);
        list[1] = _id(second);
        list[2] = _id(third);
        list[3] = _id(fourth);
        vm.expectRevert(ArbitrageHook.TooManyLeaders.selector);
        hook.setLeaders(1, address(szr), address(usd), list);
        // A leader must be a tracked pool of that partner token, listed once.
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(szr), address(usd), _list(_id(mainPool)));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(szr), address(usd), _list(bytes32(uint256(1))));
        list = new bytes32[](2);
        list[0] = _id(second);
        list[1] = _id(second);
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(szr), address(usd), list);
        // A leader cannot be untracked until it is replaced.
        vm.expectRevert(ArbitrageHook.StillLeader.selector);
        hook.untrack(1, _id(usdPool));
        hook.setLeaders(1, address(szr), address(usd), _list(_id(second)));
        hook.untrack(1, _id(usdPool));
        assertEq(hook.partnerOf(_id(usdPool)), address(0));
        // An empty list removes the group.
        assertEq(hook.groupsOf(1, address(szr)).length, 2);
        hook.setLeaders(1, address(szr), address(usd), new bytes32[](0));
        assertEq(hook.groupsOf(1, address(szr)).length, 1);
        vm.prank(alice);
        vm.expectRevert(ArbitrageHook.NotManager.selector);
        hook.setLeaders(1, address(szr), address(usd), _list(_id(second)));
    }

    /// There is room for a fixed number of groups, and the gas allowance has to cover the
    /// venues a search prices once they are all in use.
    function testGroupLimitAndAllowance() public {
        poolUnits = 20_000e18;
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        for (uint256 index; index < 6; index++) {
            _addPartner(new TestAsset());
        }
        assertEq(hook.groupsOf(1, address(szr)).length, hook.MAX_GROUPS());
        // The ninth partner's pool can be tracked and searched, but cannot lead.
        TestAsset ninth = new TestAsset();
        PoolKey memory extra = _addPartner(ninth);
        assertEq(
            hook.leadersOf(1, address(szr), address(ninth)).length, 0, "helper found no room"
        );
        vm.expectRevert(ArbitrageHook.TooManyGroups.selector);
        hook.setLeaders(1, address(szr), address(ninth), _list(_id(extra)));
        // A second USD pool, tracked while the hook is off and kept out of the leaders.
        PoolKey memory second = _register(address(usd), 500, uint160(1 << 96));
        _setLeaders(address(usd), _list(_id(usdPool)));
        // Eight groups of one leader: the default allowance is no longer enough.
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        hook.setLimits(1, address(szr), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        // With the hook on, growing a group past what the allowance covers is refused.
        bytes32[] memory list = new bytes32[](2);
        list[0] = _id(usdPool);
        list[1] = _id(second);
        vm.expectRevert(ArbitrageHook.InvalidLimit.selector);
        hook.setLeaders(1, address(szr), address(usd), list);
    }

    /// Only a tracked pool of that very pair can lead a group, and SZR's market counts
    /// profit in SZR alone.
    function testOnlyATrackedPoolOfThePairCanLead() public {
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(szr), address(usd), _list(bytes32(uint256(1))));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(szr), address(backing), _list(_id(usdPool)));
        vm.expectRevert(ArbitrageHook.InvalidPool.selector);
        hook.setLeaders(1, address(usd), address(szr), _list(_id(usdPool)));
    }
}
