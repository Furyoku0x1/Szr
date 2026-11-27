// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { PositionsWorld } from "./IndexPositions.t.sol";

/// @dev Who may call what, the growth baselines, and which pools `open` takes.
contract IndexPositionsAccessTest is PositionsWorld {
    IndexPool internal share;
    PoolKey internal key;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        share = _share();
        key = _venue(address(share), _plain(), address(0));
        _fund(alice, key);
        _fund(bob, key);
        (int24 lower, int24 upper) = _full();
        id = _open(alice, key, lower, upper, UNITS);
    }

    // ---------------------------------------------------------------- ownership

    function testOwnerCallsRefuseEveryoneElse() public {
        _assertRefused(bob);
        _assertRefused(address(this));
    }

    function testUnknownPositionHasNoOwner() public {
        vm.prank(alice);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.harvest(id + 1, 0, 0, FAR);
    }

    function testTransferMovesEveryRight() public {
        vm.prank(alice);
        positions.transferOwner(id, bob);
        (address owner,,,,,,) = positions.position(id);
        assertEq(owner, bob);
        _assertRefused(alice);
        _grow(share, 10);
        uint256 before = _balanceOf(address(share), bob);
        uint256 aliceBefore = _balanceOf(address(share), alice);
        vm.startPrank(bob);
        assertGt(positions.harvest(id, 0, 0, FAR), 0);
        positions.collect(id);
        positions.increase(id, 1e18, FAR, FAR, FAR);
        positions.decrease(id, 1e18, 0, 0, FAR);
        positions.transferOwner(id, alice);
        vm.stopPrank();
        // Everything went to the owner at the time, none to the old one.
        assertGt(_balanceOf(address(share), bob), before);
        assertEq(_balanceOf(address(share), alice), aliceBefore);
        _assertEmpty(key);
    }

    function testTransferToZeroRefused() public {
        vm.prank(alice);
        vm.expectRevert(IndexPositions.ZeroAddress.selector);
        positions.transferOwner(id, address(0));
    }

    function _assertRefused(address who) internal {
        vm.startPrank(who);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.increase(id, 1e18, FAR, FAR, FAR);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.decrease(id, 1e18, 0, 0, FAR);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.collect(id);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.harvest(id, 0, 0, FAR);
        vm.expectRevert(IndexPositions.NotOwner.selector);
        positions.transferOwner(id, who);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- baseline

    function testIncreaseResetsTheBaseline() public {
        _grow(share, 10);
        assertGt(positions.harvestable(id), 0);
        vm.prank(alice);
        positions.increase(id, 1e18, FAR, FAR, FAR);
        _assertBaselineNow();
    }

    function testDecreaseResetsTheBaseline() public {
        _grow(share, 10);
        assertGt(positions.harvestable(id), 0);
        vm.prank(alice);
        positions.decrease(id, 1e18, 0, 0, FAR);
        _assertBaselineNow();
    }

    function testCollectKeepsTheBaseline() public {
        _grow(share, 10);
        uint128 before = positions.harvestable(id);
        vm.prank(alice);
        positions.collect(id);
        assertEq(positions.harvestable(id), before);
    }

    function testZeroHarvestStillMovesTheBaseline() public {
        // Growth too small to round to any liquidity at one unit of it.
        (int24 lower, int24 upper) = _full();
        uint256 tiny = _open(alice, key, lower, upper, 1000);
        _grow(share, 1);
        (uint256 last0, uint256 last1) = _lasts(tiny);
        assertEq(positions.harvestable(tiny), 0);
        vm.prank(alice);
        vm.expectRevert(IndexPositions.BelowMinimum.selector);
        positions.harvest(tiny, 1, 0, FAR);
        vm.prank(alice);
        assertEq(positions.harvest(tiny, 0, 0, FAR), 0);
        (uint256 now0, uint256 now1) = _lasts(tiny);
        assertGt(now0 + now1, last0 + last1);
    }

    /// The minimums bound the principal a harvest removes, as in a decrease.
    function testHarvestMinimumsBoundTheRemoval() public {
        _grow(share, 10);
        uint128 removed = positions.harvestable(id);
        assertGt(removed, 1e15);
        vm.startPrank(alice);
        vm.expectRevert(IndexPositions.BelowMinimum.selector);
        positions.harvest(id, removed, 0, FAR);
        vm.expectRevert(IndexPositions.BelowMinimum.selector);
        positions.harvest(id, 0, removed, FAR);
        // At a price of one a full range holds the same of each, about the liquidity.
        assertEq(positions.harvest(id, removed / 2, removed / 2, FAR), removed);
        vm.stopPrank();
    }

    /// The growth before the change is never harvested: the baseline is the index now.
    function _assertBaselineNow() internal {
        (uint256 last0, uint256 last1) = _lasts(id);
        assertEq(last0 + last1, share.growthIndex());
        assertEq(positions.harvestable(id), 0);
        vm.prank(alice);
        assertEq(positions.harvest(id, 0, 0, FAR), 0);
    }

    // ---------------------------------------------------------------- pools

    function testRefusesAPoolWithoutAnIndexShare() public {
        _assertRefusedPool(_key(_plain(), _plain(), address(0)));
    }

    function testRefusesAShareFromAnotherFactory() public {
        IndexPoolFactory elsewhere =
            new IndexPoolFactory(ISzrLiquidity(address(liquidity)), protocol);
        address[] memory list = _tokens(_pair(18, 18));
        IndexPool stranger =
            IndexPool(elsewhere.create("Index", "IDX", list, _equal(2), FEE, address(0), 0));
        // A real, started index pool, so only the factory tells it apart.
        _start(stranger, _weights(1000, 1000), 1e24);
        assertGt(stranger.growthIndex(), 0);
        _assertRefusedPool(_key(address(stranger), _plain(), address(0)));
    }

    function testRefusesHooksThatReturnLiquidityDeltas() public {
        address adding = address(
            uint160(0xB0 << 152 | Hooks.AFTER_ADD_LIQUIDITY_FLAG)
                | uint160(Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG)
        );
        address removing = address(
            uint160(0xB1 << 152 | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG)
                | uint160(Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        );
        _assertRefusedPool(_key(address(share), _plain(), adding));
        _assertRefusedPool(_key(address(share), _plain(), removing));
    }

    function testAcceptsAHooklessPoolAndRecordsIt() public view {
        (
            address owner,
            PoolKey memory stored,
            int24 lower,
            int24 upper,
            uint128 liquidity,
            uint256 last0,
            uint256 last1
        ) = positions.position(id);
        (int24 low, int24 high) = _full();
        assertEq(owner, alice);
        assertEq(address(stored.hooks), address(0));
        assertEq(lower, low);
        assertEq(upper, high);
        assertEq(liquidity, UNITS);
        assertEq(last0 + last1, share.growthIndex());
        assertEq(positions.positionCount(), id);
    }

    function _assertRefusedPool(PoolKey memory pool) internal {
        (int24 lower, int24 upper) = _full();
        vm.expectRevert(IndexPositions.InvalidPool.selector);
        positions.open(pool, lower, upper, UNITS, FAR, FAR, FAR);
    }

    // ---------------------------------------------------------------- other checks

    function testDeadlinesAndZeroLiquidity() public {
        (int24 lower, int24 upper) = _full();
        vm.startPrank(alice);
        vm.expectRevert(IndexPositions.DeadlinePassed.selector);
        positions.open(key, lower, upper, UNITS, FAR, FAR, block.timestamp - 1);
        vm.expectRevert(IndexPositions.ZeroLiquidity.selector);
        positions.open(key, lower, upper, 0, FAR, FAR, FAR);
        vm.expectRevert(IndexPositions.ZeroLiquidity.selector);
        positions.increase(id, 0, FAR, FAR, FAR);
        vm.expectRevert(IndexPositions.ZeroLiquidity.selector);
        positions.decrease(id, 0, 0, 0, FAR);
        vm.expectRevert(IndexPositions.DeadlinePassed.selector);
        positions.harvest(id, 0, 0, block.timestamp - 1);
        vm.expectRevert(IndexPositions.AboveMaximum.selector);
        positions.increase(id, UNITS, 1, FAR, FAR);
        vm.expectRevert(IndexPositions.BelowMinimum.selector);
        positions.decrease(id, 1e18, FAR, 0, FAR);
        vm.stopPrank();
    }

    function testUnlockCallbackOnlyFromItsOwnUnlock() public {
        vm.expectRevert(IndexPositions.NotPoolManager.selector);
        positions.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(IndexPositions.UnexpectedCallback.selector);
        positions.unlockCallback(abi.encode(id, int256(-1), 0, 0, 0));
    }

    function testRefusesEtherFromAnyoneButThePoolManager() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(positions).call{ value: 1 ether }("");
        assertFalse(ok);
        assertEq(IndexToken(address(share)).balanceOf(address(positions)), 0);
    }
}
