// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VaultWorld } from "./utils/VaultWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { IHookVault } from "../src/interfaces/IHookVault.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev The curator's moves on the v4 vault: positions, rebalances and idle swaps, and the
/// guards on each.
contract HookVaultCuratorTest is VaultWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAX = type(uint256).max;
    uint160 internal constant ONE = uint160(1 << 96);

    function setUp() public override {
        super.setUp();
        _seed(3);
        // Idle principal for the swaps.
        vm.prank(alice);
        vault.addIdle(200_000e18, 200_000e18);
    }

    function _changes(uint256 index, int128 delta)
        internal
        pure
        returns (ArbitrageVault.Change[] memory list, uint160[] memory prices)
    {
        list = new ArbitrageVault.Change[](1);
        list[0] = ArbitrageVault.Change(index, delta);
        prices = new uint160[](1);
        prices[0] = ONE;
    }

    function _two(uint256 from, uint256 to, int128 amount)
        internal
        pure
        returns (ArbitrageVault.Change[] memory list, uint160[] memory prices)
    {
        list = new ArbitrageVault.Change[](2);
        list[0] = ArbitrageVault.Change(to, amount);
        list[1] = ArbitrageVault.Change(from, -amount);
        prices = new uint160[](2);
        prices[0] = ONE;
        prices[1] = ONE;
    }

    function _rebalance(ArbitrageVault.Change[] memory list, uint160[] memory prices) internal {
        vm.prank(curator);
        vault.rebalance(list, prices, block.timestamp);
    }

    function _swap(bool zeroForOne, uint128 amount, uint160 price) internal {
        vm.prank(curator);
        vault.swapIdle(zeroForOne, amount, 0, price, block.timestamp);
    }

    /// The pool manager's liquidity under a salt, for a position still at its first index.
    function _heldAt(uint256 index, uint256 salt) internal view returns (uint128 liquidity) {
        ArbitrageVault.Range memory range = _ranges(index + 1)[index];
        (liquidity,,) = manager.getPositionInfo(
            first.toId(), address(vault), range.tickLower, range.tickUpper, bytes32(salt)
        );
    }

    // Rebalancing.

    function testRebalanceMovesLiquidityBetweenPositions() public {
        uint256 before0 = vault.unitsOf(0);
        uint256 before2 = vault.unitsOf(2);
        (uint256 idle0, uint256 idle1) = vault.principal();
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 100_000e18);
        _rebalance(list, prices);
        assertEq(vault.unitsOf(0), before0 - 100_000e18);
        assertEq(vault.unitsOf(2), before2 + 100_000e18);
        assertEq(_held(0), vault.unitsOf(0), "the pool agrees");
        assertEq(_held(2), vault.unitsOf(2), "and agrees");
        (uint256 now0, uint256 now1) = vault.principal();
        // The wide range gives up more than the narrow one takes, so idle grew.
        assertGt(now0 + now1, idle0 + idle1, "the difference is idle principal");
        assertEq(_surplus(token0), 0, "no principal strayed into rewards");
        assertEq(_surplus(token1), 0);
    }

    /// Principal is whatever the pool's own deltas say, and it all stays in the vault.
    function testNoPathSendsPrincipalOut() public {
        uint256 held0 = TestAsset(token0).balanceOf(address(vault));
        uint256 held1 = TestAsset(token1).balanceOf(address(vault));
        (uint256 idle0, uint256 idle1) = vault.principal();
        uint256 cur0 = TestAsset(token0).balanceOf(curator);
        uint256 cur1 = TestAsset(token1).balanceOf(curator);
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 100_000e18);
        _rebalance(list, prices);
        vm.roll(block.number + 1);
        _swap(true, 1_000e18, ONE);
        vm.roll(block.number + 1);
        vm.prank(curator);
        vault.addPosition(-120, 120);
        // The vault's balances moved only by what the pools paid in and out, and every
        // change is in idle principal; the curator got nothing.
        (uint256 now0, uint256 now1) = vault.principal();
        assertEq(
            TestAsset(token0).balanceOf(address(vault)) - held0 + idle0, now0, "token0 idle"
        );
        assertEq(
            TestAsset(token1).balanceOf(address(vault)) - held1 + idle1, now1, "token1 idle"
        );
        assertEq(TestAsset(token0).balanceOf(curator), cur0, "curator token0");
        assertEq(TestAsset(token1).balanceOf(curator), cur1, "curator token1");
    }

    /// An addition may use only idle principal, never what the vault holds for rewards.
    function testAnAdditionCannotSpendRewards() public {
        TestAsset(token0).mint(address(vault), 1_000_000e18);
        TestAsset(token1).mint(address(vault), 1_000_000e18);
        // Idle is 200,000 of each, and one position's removal returns far less than this.
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) =
            _changes(0, int128(int256(900_000e18)));
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.InsufficientIdle.selector);
        vault.rebalance(list, prices, block.timestamp);
    }

    /// With no idle token0 left, an addition that needs token0 can only be paid from what
    /// the same rebalance removes, whatever order the changes are listed in.
    function testRemovalsRunBeforeAdditions() public {
        (uint256 idle0,) = vault.principal();
        _swap(true, uint128(idle0), ONE);
        (idle0,) = vault.principal();
        assertEq(idle0, 0, "no token0 left idle");
        vm.roll(block.number + 1);
        (uint160 price,,,) = manager.getSlot0(first.toId());
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 100_000e18);
        prices[0] = price;
        prices[1] = price;
        _rebalance(list, prices);
        assertEq(_held(2), vault.unitsOf(2));
    }

    // The price guard.

    function _passes(uint160 expectedPrice) internal view returns (bool) {
        try vault.checkPrice(expectedPrice) {
            return true;
        } catch {
            return false;
        }
    }

    /// The tolerance is 1% of price exactly: the first passing value on each side is found
    /// and checked with plain arithmetic against `10000 * price <= 10100 * expected`.
    function testTheToleranceIsExactlyOnePercentOfPrice() public {
        uint256 price2 = uint256(ONE) * ONE;
        uint160 low = uint160(uint256(ONE) * 99 / 100);
        uint160 high = uint160(uint256(ONE) * 101 / 100);
        // The smallest expected value that passes.
        (uint160 a, uint160 b) = (low, ONE);
        while (b - a > 1) {
            uint160 mid = a + (b - a) / 2;
            if (_passes(mid)) b = mid;
            else a = mid;
        }
        assertGe(uint256(b) * b * 10_100, price2 * 10_000, "smallest passing value");
        assertLt(uint256(a) * a * 10_100, price2 * 10_000, "and the one below it fails");
        // The largest.
        (a, b) = (ONE, high);
        while (b - a > 1) {
            uint160 mid = a + (b - a) / 2;
            if (_passes(mid)) a = mid;
            else b = mid;
        }
        assertLe(uint256(a) * a * 9_900, price2 * 10_000, "largest passing value");
        assertGt(uint256(b) * b * 9_900, price2 * 10_000, "and the one above it fails");
        // A square-root tolerance of 1% would be far wider than this.
        assertFalse(_passes(uint160(uint256(ONE) * 1_006 / 1_000)));
        assertFalse(_passes(uint160(uint256(ONE) * 994 / 1_000)));
        assertTrue(_passes(uint160(uint256(ONE) * 1_004 / 1_000)));
        assertTrue(_passes(uint160(uint256(ONE) * 996 / 1_000)));
        assertFalse(_passes(0));
    }

    function testARebalanceOutsideTheToleranceReverts() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 1e18);
        prices[1] = uint160(uint256(ONE) * 1_006 / 1_000);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.PriceOutOfRange.selector);
        vault.rebalance(list, prices, block.timestamp);
        prices[1] = uint160(uint256(ONE) * 1_004 / 1_000);
        _rebalance(list, prices);
    }

    function testASwapOutsideTheToleranceReverts() public {
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.PriceOutOfRange.selector);
        vault.swapIdle(true, 1e18, 0, ONE * 102 / 100, block.timestamp);
    }

    // One move per block.

    function testOneMovePerBlock() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 1e18);
        _rebalance(list, prices);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.MovedThisBlock.selector);
        vault.rebalance(list, prices, block.timestamp);
        // A swap through the same pool is a move too.
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.MovedThisBlock.selector);
        vault.swapIdle(true, 1e18, 0, ONE, block.timestamp);
        // The next block is free.
        vm.roll(block.number + 1);
        _rebalance(list, prices);
    }

    /// Two changes in one pool are one move.
    function testTwoChangesInOnePoolShareARebalance() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 1e18);
        assertEq(address(vault.hook()), address(hook));
        _rebalance(list, prices);
        assertEq(_held(2), vault.unitsOf(2));
    }

    // The home pool.

    /// The review's attack: a new pool of the pair with a 99.99% fee, then a swap of idle
    /// principal through it. A swap goes only through the home pool, so the pool the market
    /// adds later is never touched, and the swap pays the home pool's fee.
    function testANewHugeFeePoolIsNeverUsed() public {
        PoolKey memory trap = _create(address(backing), address(coin), 999_900);
        (uint160 trapPrice,,,) = manager.getSlot0(trap.toId());
        uint128 trapLiquidity = manager.getLiquidity(trap.toId());
        (uint160 homePrice,,,) = manager.getSlot0(first.toId());
        (uint256 idle0, uint256 idle1) = vault.principal();
        _swap(true, 1_000e18, ONE);
        (uint160 trapAfter,,,) = manager.getSlot0(trap.toId());
        (uint160 homeAfter,,,) = manager.getSlot0(first.toId());
        assertEq(trapAfter, trapPrice, "the new pool is untouched");
        assertEq(manager.getLiquidity(trap.toId()), trapLiquidity);
        assertLt(homeAfter, homePrice, "the swap moved the home pool");
        (uint256 now0, uint256 now1) = vault.principal();
        assertEq(now0, idle0 - 1_000e18);
        assertGt(now1 - idle1, 990e18, "at the home pool's fee, not 99.99%");
    }

    /// Every position is in the home pool: the pool manager holds nothing for the vault in
    /// the market's other pool, however the curator re-ranges.
    function testPositionsStayInTheHomePool() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 100_000e18);
        _rebalance(list, prices);
        uint128 otherLiquidity = manager.getLiquidity(second.toId());
        vm.prank(curator);
        vault.addPosition(-120, 120);
        for (uint256 index; index < vault.positionCount(); index++) {
            for (uint256 salt = 1; salt < 6; salt++) {
                for (int24 reach = 60; reach <= 180; reach += 60) {
                    (uint128 held,,) = manager.getPositionInfo(
                        second.toId(), address(vault), -reach, reach, bytes32(salt)
                    );
                    assertEq(held, 0, "nothing in the other pool");
                }
            }
        }
        assertEq(manager.getLiquidity(second.toId()), otherLiquidity);
    }

    // Swapping idle principal.

    function testSwapIdleBooksOnlyThePoolsDelta() public {
        (uint256 idle0, uint256 idle1) = vault.principal();
        bool zeroForOne = true;
        _swap(zeroForOne, 1_000e18, ONE);
        (uint256 now0, uint256 now1) = vault.principal();
        assertEq(now0, idle0 - 1_000e18, "what was spent");
        assertGt(now1, idle1, "and what came back");
        assertEq(_surplus(token0), 0);
        assertEq(_surplus(token1), 0);
    }

    function testSwapIdleChecksItsLimits() public {
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.ZeroAmount.selector);
        vault.swapIdle(true, 0, 0, ONE, block.timestamp);
        vm.prank(curator);
        vm.expectRevert(IHookVault.BelowMinimum.selector);
        vault.swapIdle(true, 1e18, 2e18, ONE, block.timestamp);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.InsufficientIdle.selector);
        vault.swapIdle(true, 300_000e18, 0, ONE, block.timestamp);
        vm.prank(curator);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.swapIdle(true, 1e18, 0, ONE, block.timestamp - 1);
    }

    /// Rewards sitting in the vault are not idle principal, and a swap cannot spend them.
    function testSwapIdleCannotSpendRewards() public {
        TestAsset(token0).mint(address(vault), 1_000_000e18);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.InsufficientIdle.selector);
        vault.swapIdle(true, 300_000e18, 0, ONE, block.timestamp);
    }

    function testSwapIdleNeedsTheGasASearchNeeds() public {
        uint256 need = hook.gasForSwap(id);
        emit log_named_uint("gas the hook needs for a swap", need);
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.InsufficientGas.selector);
        vault.swapIdle{ gas: need }(true, 1e18, 0, ONE, block.timestamp);
        vm.prank(curator);
        vault.swapIdle{ gas: need + 3_000_000 }(true, 1e18, 0, ONE, block.timestamp);
    }

    /// The hook pays its profit to the vault when the vault is the recipient, and that is
    /// a reward: it never joins idle principal.
    function testProfitPaidDuringASwapIsRewardNotPrincipal() public {
        vm.prank(team);
        hook.setRecipient(id, address(vault));
        (uint256 idle0, uint256 idle1) = vault.principal();
        address backingToken = address(backing);
        bool backingIsZero = backingToken == token0;
        uint256 coinBefore = backingIsZero ? idle1 : idle0;
        _swap(!backingIsZero, 50_000e18, ONE);
        (uint256 now0, uint256 now1) = vault.principal();
        assertEq(backingIsZero ? now1 : now0, coinBefore - 50_000e18, "the coin spent");
        uint256 profit = vault.unbooked(backingToken);
        assertGt(profit, 0, "the hook paid the vault");
        assertEq(_surplus(backingToken), profit, "apart from principal");
        // It books as a reward, and a holder earns it.
        vault.harvest();
        // The swap's own LP fees book with it.
        assertGe(vault.owed(backingToken), profit, "booked as reward");
        assertEq(vault.owed(backingToken), _surplus(backingToken), "all of it, and only it");
        (uint256 after0, uint256 after1) = vault.principal();
        assertEq(after0, now0, "principal untouched by booking");
        assertEq(after1, now1);
        skip(3 days);
        assertGt(vault.earned(curator, backingToken), 0);
        assertGt(idle0 + idle1, 0);
    }

    // Positions.

    function testAnEmptyPositionNeverBlocksTheVault() public {
        vm.prank(curator);
        vault.addPosition(-60, 60);
        assertEq(vault.positionCount(), 4);
        assertEq(vault.unitsOf(3), 0);
        vm.prank(bob);
        vault.deposit(1e24, MAX, MAX, block.timestamp);
        vault.harvest();
        vm.prank(bob);
        vault.withdraw(1e24, 0, 0, block.timestamp);
        // And it can be funded.
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _changes(3, 1e18);
        _rebalance(list, prices);
        assertEq(vault.unitsOf(3), 1e18);
    }

    function testAddPositionRules() public {
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.addPosition(-60, 60);
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.addPosition(60, 60);
        // Ticks must be inside the pool manager's range and on the pool's spacing.
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.addPosition(TickMath.MIN_TICK - 60, 60);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.addPosition(-60, TickMath.MAX_TICK + 60);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.addPosition(-61, 60);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.addPosition(-60, 61);
        for (uint256 index = 3; index < 8; index++) {
            vault.addPosition(-60, 60);
        }
        vm.expectRevert(IHookVault.TooManyPositions.selector);
        vault.addPosition(-60, 60);
        vm.stopPrank();
    }

    function testDropPositionRefusesOneWithLiquidity() public {
        vm.prank(curator);
        vm.expectRevert(ArbitrageVault.PositionNotEmpty.selector);
        vault.dropPosition(0);
        vm.prank(curator);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.dropPosition(3);
    }

    /// Dropping an emptied position moves the last one into its place. It keeps its own
    /// pool-manager salt, so the vault can still reach its liquidity.
    function testDroppingAPositionKeepsTheOthersReachable() public {
        uint256 last = vault.unitsOf(2);
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) =
            _changes(0, -int128(int256(vault.unitsOf(0))));
        _rebalance(list, prices);
        assertEq(vault.unitsOf(0), 0);
        vm.prank(curator);
        vault.dropPosition(0);
        assertEq(vault.positionCount(), 2);
        assertEq(vault.unitsOf(0), last, "the last took its place");
        assertEq(_heldAt(2, 3), uint128(last), "still under its own salt");
        // Everything still works, and a holder gets the position's liquidity back.
        vm.prank(bob);
        vault.deposit(1e24, MAX, MAX, block.timestamp);
        vault.harvest();
        uint256 half = vault.balanceOf(curator) / 2;
        vm.prank(curator);
        vault.withdraw(half, 0, 0, block.timestamp);
        vm.prank(bob);
        vault.withdraw(1e24, 0, 0, block.timestamp);
        assertEq(_heldAt(2, 3), uint128(vault.unitsOf(0)));
    }

    // Access and deadlines.

    function testCuratorPowersAreRefusedToOthers() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 1e18);
        vm.startPrank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.rebalance(list, prices, block.timestamp);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.swapIdle(true, 1e18, 0, ONE, block.timestamp);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.dropPosition(0);
        vm.stopPrank();
    }

    function testRebalanceRefusesBadInput() public {
        (ArbitrageVault.Change[] memory list, uint160[] memory prices) = _two(0, 2, 1e18);
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.rebalance(list, prices, block.timestamp - 1);
        uint160[] memory one = new uint160[](1);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(list, one, block.timestamp);
        list[0].index = 9;
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(list, prices, block.timestamp);
        list[0].index = 2;
        list[1].liquidityDelta = -int128(int256(vault.unitsOf(0) + 1));
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(list, prices, block.timestamp);
        list[1].liquidityDelta = 0;
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(list, prices, block.timestamp);
        vm.stopPrank();
    }
}
