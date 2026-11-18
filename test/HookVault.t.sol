// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VaultWorld, VaultHarness } from "./utils/VaultWorld.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { IHookVault } from "../src/interfaces/IHookVault.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The vault core and its v4 kind, over the arbitrage hook's outside market: the pair
/// is WETH and the market's own coin, in two pools on the hook.
contract HookVaultTest is VaultWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant MAX = type(uint256).max;

    function _deposit(address who, uint256 shares) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.deposit(shares, MAX, MAX, block.timestamp);
    }

    function _withdraw(address who, uint256 shares) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _units(uint256 count) internal view returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = vault.unitsOf(index);
        }
    }

    function _balance(address asset, address who) internal view returns (uint256) {
        return asset == address(backing) ? backing.balanceOf(who) : coin.balanceOf(who);
    }

    // Seed.

    function testSeedOpensPositionsAndLocksMinimumShares() public {
        uint256 before0 = _balance(token0, curator);
        uint256 before1 = _balance(token1, curator);
        _seed(3);
        uint256 total = 3 * SEED_UNITS + 3e18;
        assertEq(vault.totalSupply(), total, "supply is the liquidity seeded");
        assertEq(vault.balanceOf(vault.DEAD()), vault.MINIMUM_SHARES(), "minimum locked");
        assertEq(vault.balanceOf(curator), total - vault.MINIMUM_SHARES(), "curator shares");
        assertEq(vault.positionCount(), 3);
        for (uint256 index; index < 3; index++) {
            assertEq(vault.unitsOf(index), SEED_UNITS + index * 1e18, "units");
            assertEq(_held(index), vault.unitsOf(index), "the pool manager holds it");
        }
        assertGt(before0 - _balance(token0, curator), 0, "curator paid token0");
        assertGt(before1 - _balance(token1, curator), 0, "curator paid token1");
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0 + idle1, 0, "no idle principal");
        assertEq(_surplus(token0) + _surplus(token1), 0, "nothing left over");
    }

    function testOnlyTheCuratorSeedsAndOnlyOnce() public {
        ArbitrageVault.Range[] memory ranges = _ranges(1);
        uint256[] memory units = _units(1, SEED_UNITS);
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.seed(ranges, units, MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.NotSeeded.selector);
        vault.quoteDeposit(1);
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotSeeded.selector);
        vault.deposit(1e18, MAX, MAX, block.timestamp);
        _seed(1);
        vm.prank(curator);
        vm.expectRevert(IHookVault.AlreadySeeded.selector);
        vault.seed(ranges, units, MAX, MAX, block.timestamp);
    }

    function testSeedBounds() public {
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(_ranges(0), _units(0, 1), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.TooManyPositions.selector);
        vault.seed(_ranges(9), _units(9, SEED_UNITS), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(_ranges(2), _units(1, SEED_UNITS), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(_ranges(1), _units(1, 0), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        vault.seed(_ranges(1), _units(1, 1e6), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.seed(_ranges(1), _units(1, SEED_UNITS), 1, MAX, block.timestamp);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.seed(_ranges(1), _units(1, SEED_UNITS), MAX, 1, block.timestamp);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.seed(_ranges(1), _units(1, SEED_UNITS), MAX, MAX, block.timestamp - 1);
        vm.stopPrank();
        assertEq(vault.positionCount(), 0, "nothing stuck from the failed tries");
    }

    // Deposits and withdrawals.

    function _proRata(uint256 count) internal {
        _seed(count);
        uint256 supply = vault.totalSupply();
        uint256[] memory units = _units(count);
        uint256 shares = supply / 10;
        (uint256 need0, uint256 need1) = vault.quoteDeposit(shares);
        uint256 held0 = _balance(token0, bob);
        uint256 held1 = _balance(token1, bob);
        (uint256 paid0, uint256 paid1) = _deposit(bob, shares);
        assertEq(paid0, need0, "quote matches token0");
        assertEq(paid1, need1, "quote matches token1");
        assertEq(held0 - _balance(token0, bob), paid0, "bob paid token0");
        assertEq(held1 - _balance(token1, bob), paid1, "bob paid token1");
        assertEq(vault.balanceOf(bob), shares);
        for (uint256 index; index < count; index++) {
            uint256 added = FixedPointMathLib.fullMulDivUp(units[index], shares, supply);
            assertEq(vault.unitsOf(index), units[index] + added, "rounded up");
            assertEq(_held(index), vault.unitsOf(index), "pool agrees");
        }
        assertEq(_surplus(token0) + _surplus(token1), 0, "no dust kept");
        (uint256 out0, uint256 out1) = _withdraw(bob, shares);
        assertLe(out0, paid0, "no more token0 back");
        assertLe(out1, paid1, "no more token1 back");
        for (uint256 index; index < count; index++) {
            assertGe(vault.unitsOf(index), units[index], "holders lose nothing");
            assertEq(_held(index), vault.unitsOf(index), "pool agrees after");
        }
        assertEq(vault.balanceOf(bob), 0);
    }

    function testDepositAndWithdrawProRataOnePosition() public {
        _proRata(1);
    }

    function testDepositAndWithdrawProRataThreePositions() public {
        _proRata(3);
    }

    function testDepositAndWithdrawProRataEightPositions() public {
        _proRata(8);
    }

    function testSeedersWithdrawalLeavesTheLockedMinimum() public {
        _seed(3);
        uint256 all = vault.balanceOf(curator);
        _withdraw(curator, all);
        assertEq(vault.totalSupply(), vault.MINIMUM_SHARES());
        for (uint256 index; index < 3; index++) {
            assertGt(vault.unitsOf(index), 0, "a position is never emptied");
            assertEq(_held(index), vault.unitsOf(index));
        }
    }

    /// Idle principal follows the same rule: a depositor pays it rounded up and a holder is
    /// paid it rounded down, so one share in and out leaves a unit behind.
    function testIdlePrincipalRoundsAgainstTheUser() public {
        _seed(2);
        vm.prank(alice);
        vault.addIdle(10, 7);
        uint256 supply = vault.totalSupply();
        assertEq(_surplus(token0), 0, "idle is not unbooked");
        (uint256 paid0, uint256 paid1) = _deposit(bob, 1);
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0, 11, "paid one unit up for a fraction");
        assertEq(idle1, 8);
        assertGe(paid0, 1);
        assertGe(paid1, 1);
        (uint256 out0, uint256 out1) = _withdraw(bob, 1);
        (idle0, idle1) = vault.principal();
        assertEq(idle0, 11, "and was paid none for the same fraction");
        assertEq(idle1, 8);
        assertLe(out0, paid0);
        assertLe(out1, paid1);
        assertEq(vault.totalSupply(), supply);
    }

    function testFuzzRoundTripNeverProfits(uint256 shares, uint256 idle0, uint256 idle1)
        public
    {
        _seed(3);
        idle0 = bound(idle0, 0, 1e26);
        idle1 = bound(idle1, 0, 1e26);
        vm.prank(alice);
        vault.addIdle(idle0, idle1);
        uint256 supply = vault.totalSupply();
        shares = bound(shares, 1, supply * 2);
        (uint256 paid0, uint256 paid1) = _deposit(bob, shares);
        (uint256 out0, uint256 out1) = _withdraw(bob, shares);
        assertLe(out0, paid0, "token0");
        assertLe(out1, paid1, "token1");
        assertEq(vault.totalSupply(), supply);
    }

    function testDepositAndWithdrawLimits() public {
        _seed(2);
        (uint256 need0, uint256 need1) = vault.quoteDeposit(1e24);
        vm.startPrank(bob);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.deposit(1e24, need0 - 1, need1, block.timestamp);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.deposit(1e24, need0, need1 - 1, block.timestamp);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.deposit(1e24, need0, need1, block.timestamp - 1);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        vault.deposit(0, need0, need1, block.timestamp);
        (uint256 paid0, uint256 paid1) = vault.deposit(1e24, need0, need1, block.timestamp);
        vm.expectRevert(IHookVault.BelowMinimum.selector);
        vault.withdraw(1e24, paid0, paid1, block.timestamp);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.withdraw(1e24, 0, 0, block.timestamp - 1);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        vault.withdraw(0, 0, 0, block.timestamp);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1, 0, 0, block.timestamp);
    }

    function testDepositsCanBePausedAndWithdrawalsNeverCan() public {
        _seed(2);
        _deposit(bob, 1e24);
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.setDepositsPaused(true);
        vm.prank(curator);
        vault.setDepositsPaused(true);
        vm.prank(bob);
        vm.expectRevert(IHookVault.DepositsPaused.selector);
        vault.deposit(1e24, MAX, MAX, block.timestamp);
        _withdraw(bob, 1e24);
        _withdraw(curator, vault.balanceOf(curator));
        assertEq(vault.totalSupply(), vault.MINIMUM_SHARES(), "everyone left while paused");
        vm.prank(curator);
        vault.setDepositsPaused(false);
        _deposit(bob, 1e6);
    }

    function testCuratorChangesHandsInTwoSteps() public {
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.nominateCurator(alice);
        vm.prank(curator);
        vault.nominateCurator(alice);
        vm.prank(bob);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.acceptCurator();
        vm.prank(alice);
        vault.acceptCurator();
        assertEq(vault.curator(), alice);
        vm.prank(curator);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.setDepositsPaused(true);
    }

    // The first depositor.

    /// A donation sits outside principal, so it cannot change what a share costs: the
    /// attack that inflates the price of a share to round a victim down has nothing to use.
    function testFirstDepositorCannotInflateTheShare() public {
        _seed(2);
        _withdraw(curator, vault.balanceOf(curator));
        uint256 supply = vault.totalSupply();
        (uint256 need0, uint256 need1) = vault.quoteDeposit(supply);
        vm.startPrank(curator);
        backing.transfer(address(vault), 1e24);
        coin.transfer(address(vault), 1e24);
        vm.stopPrank();
        (uint256 after0, uint256 after1) = vault.quoteDeposit(supply);
        assertEq(after0, need0, "a donation does not move the price of a share");
        assertEq(after1, need1);
        (uint256 paid0, uint256 paid1) = _deposit(bob, supply);
        assertEq(paid0, need0);
        assertEq(paid1, need1);
        (uint256 out0, uint256 out1) = _withdraw(bob, supply);
        assertLe(out0, paid0, "no gain from the donation");
        assertLe(out1, paid1);
        assertEq(_surplus(address(backing)), 1e24, "the donation is left unbooked");
        assertEq(_surplus(address(coin)), 1e24);
    }

    // A price that is moved around a deposit.

    function _swapTo(bool zeroForOne, uint256 amount, uint160 limit) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            first, IPoolManager.SwapParams(zeroForOne, -int256(amount), limit), settings, ""
        );
    }

    /// The market is switched off so the hook does not move the pool after the trades,
    /// then one actor moves the price, deposits, moves it back to exactly where it was and
    /// withdraws. The actor ends with less than it began with, and a bystander's holding is
    /// worth the same at the restored price, so nobody lost to the sandwich.
    function testSandwichCostsTheActorAndNobodyElse() public {
        uint128 profit = hook.minimumProfit(id, address(backing));
        uint64 edge = hook.market(id).minimumEdge;
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, profit, edge);
        _seed(1);
        backing.approve(address(vault), MAX);
        coin.approve(address(vault), MAX);
        uint256 holding = vault.balanceOf(curator);
        (uint256 before0, uint256 before1) = vault.quoteDeposit(holding);
        uint256 wealth = backing.balanceOf(address(this)) + coin.balanceOf(address(this));
        uint256 shares = vault.totalSupply() / 2;
        _swapTo(true, 300_000e18, TickMath.MIN_SQRT_PRICE + 1);
        _deposit(address(this), shares);
        _swapTo(false, 1e25, uint160(1 << 96));
        (uint160 price,,,) = manager.getSlot0(first.toId());
        assertEq(price, 1 << 96, "the price is restored exactly");
        _withdraw(address(this), shares);
        uint256 after_ = backing.balanceOf(address(this)) + coin.balanceOf(address(this));
        assertLt(after_, wealth, "the actor paid fees and made nothing");
        (uint256 after0, uint256 after1) = vault.quoteDeposit(holding);
        assertGe(after0, before0, "the bystander's token0");
        assertGe(after1, before1, "the bystander's token1");
    }

    /// A round trip that does not divide: the supply is not a multiple of anything the
    /// positions' units are, so every deposit rounds up and every withdrawal rounds down,
    /// and the units a share stands for rise, never fall.
    function testRoundingDirectionWhenTheSupplyDoesNotDivide() public {
        _seed(3);
        uint256 supply = vault.totalSupply();
        uint256 shares = 7e17 + 3;
        (uint256 need0, uint256 need1) = vault.quoteDeposit(shares);
        uint256[] memory units = _units(3);
        (uint256 paid0, uint256 paid1) = _deposit(bob, shares);
        assertEq(need0, paid0, "the quote rounds up like the pool");
        assertEq(need1, paid1);
        for (uint256 index; index < 3; index++) {
            assertGt(mulmod(units[index], shares, supply), 0, "does not divide");
            uint256 floored = units[index] * shares / supply;
            assertEq(vault.unitsOf(index), units[index] + floored + 1, "added rounds up");
        }
        uint256[] memory held = _units(3);
        uint256 total = supply + shares;
        uint256 leaving = 5e17 + 1;
        _withdraw(bob, leaving);
        for (uint256 index; index < 3; index++) {
            assertGt(mulmod(held[index], leaving, total), 0, "does not divide");
            assertEq(vault.unitsOf(index), held[index] - held[index] * leaving / total, "down");
        }
    }

    // What counts as principal.

    function testFeesAreCollectedAsUnbookedNeverPrincipal() public {
        _seed(2);
        uint256[] memory units = _units(2);
        _trade(first, address(coin), 50_000e18);
        assertEq(_surplus(address(coin)), 0, "fees stay in the pool until collected");
        vault.harvest();
        assertGt(_surplus(address(coin)), 0, "harvest collects the fees");
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0 + idle1, 0, "and they are not principal");
        assertEq(_units(2)[0], units[0]);
        assertEq(_units(2)[1], units[1]);
        // A deposit and a withdrawal also collect fees, and never move them back into
        // principal or pay them out.
        uint256 kept = _surplus(address(coin));
        _trade(second, address(coin), 50_000e18);
        _deposit(bob, 1e24);
        uint256 afterDeposit = _surplus(address(coin));
        assertGt(afterDeposit, kept, "a deposit collected the new fees");
        _withdraw(bob, 1e24);
        assertGe(_surplus(address(coin)), afterDeposit, "a withdrawal paid none out");
        (idle0, idle1) = vault.principal();
        assertEq(idle0 + idle1, 0);
    }

    /// With the vault as the market's recipient, the hook pays it profit in WETH, which is
    /// also a pair token. It is told apart from principal because principal is booked from
    /// the calls' deltas, so it is unbooked and no deposit or withdrawal can move it.
    function testProfitPaidToTheVaultIsUnbooked() public {
        _seed(2);
        vm.prank(alice);
        vault.addIdle(1e18, 1e18);
        vm.prank(team);
        hook.setRecipient(id, address(vault));
        uint256 treasured = backing.balanceOf(treasury);
        _trade(first, address(coin), 50_000e18);
        uint256 profit = _surplus(address(backing));
        assertGt(profit, 0, "the hook paid the vault");
        assertEq(backing.balanceOf(treasury), treasured, "and not the old recipient");
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0, 1e18, "idle principal is untouched by profit");
        assertEq(idle1, 1e18);
        uint256 supply = vault.totalSupply();
        uint256 shares = supply / 3;
        _deposit(bob, shares);
        (idle0, idle1) = vault.principal();
        assertEq(idle0, 1e18 + FixedPointMathLib.fullMulDivUp(1e18, shares, supply));
        assertGe(_surplus(address(backing)), profit, "profit is not principal");
        _withdraw(bob, shares);
        assertGe(_surplus(address(backing)), profit, "and is not paid to a holder");
        assertGe(backing.balanceOf(address(vault)), profit + 1e18, "it stays in the vault");
    }

    /// A withdrawal collects a position's fees in full, but they are the vault's: they land
    /// as unbooked, by exactly what a harvest would have collected, and the withdrawer is
    /// paid principal only.
    function testWithdrawalLeavesFeesInTheVault() public {
        _seed(2);
        _deposit(bob, 1e24);
        _trade(first, address(coin), 50_000e18);
        _trade(second, address(backing), 50_000e18);
        uint256 saved = vm.snapshotState();
        vault.harvest();
        uint256 fees0 = _surplus(token0);
        uint256 fees1 = _surplus(token1);
        vm.revertToStateAndDelete(saved);
        assertGt(fees0, 0, "fees accrued in token0");
        assertGt(fees1, 0, "fees accrued in token1");
        uint256 held0 = _balance(token0, bob);
        uint256 held1 = _balance(token1, bob);
        (uint256 out0, uint256 out1) = _withdraw(bob, 1e24);
        assertEq(_surplus(token0), fees0, "the vault kept every fee in token0");
        assertEq(_surplus(token1), fees1, "and in token1");
        assertEq(_balance(token0, bob) - held0, out0, "bob got what was reported");
        assertEq(_balance(token1, bob) - held1, out1);
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0 + idle1, 0);
    }

    // The home pool.

    function _tryHome(PoolKey memory home, bytes4 reason) internal {
        if (reason != bytes4(0)) vm.expectRevert(reason);
        deployCode(
            "VaultWorld.sol:VaultHarness",
            abi.encode(hook, id, home, curator, address(0), uint16(0))
        );
    }

    function testTheHomePoolMustBeTrackedInTheMarket() public {
        // Not created or added anywhere.
        _tryHome(
            _pair(address(backing), address(coin), 10_000, address(hook)),
            IHookVault.InvalidPool.selector
        );
        // Created in another market.
        address stranger = address(0x5712);
        vm.startPrank(stranger);
        uint256 other = hook.openMarket(stranger);
        PoolKey memory foreign = _pair(address(backing), address(coin), 100, address(hook));
        hook.createPool(other, foreign, uint160(1 << 96));
        vm.stopPrank();
        _tryHome(foreign, IHookVault.InvalidPool.selector);
        // A hookless pool of the pair that the market has not added, and one on a hook of
        // someone else's.
        PoolKey memory bare = _pair(address(backing), address(coin), 3_000, address(0));
        manager.initialize(bare, uint160(1 << 96));
        _tryHome(bare, IHookVault.InvalidPool.selector);
        _tryHome(
            _pair(address(backing), address(coin), 3_000, address(0xBEEF)),
            IHookVault.InvalidPool.selector
        );
        // Once the market adds the hookless venue, it can be a home.
        vm.prank(team);
        hook.addVenue(id, bare);
        _tryHome(bare, bytes4(0));
    }

    /// The pair is the home pool's currencies, whatever other pools the market has.
    function testThePairIsTheHomePoolsCurrencies() public {
        PoolKey memory other = _pair(address(backing), address(usd), 500, address(hook));
        vm.prank(team);
        hook.createPool(id, other, uint160(1 << 96));
        VaultHarness made = _makeVault(other);
        assertEq(made.token0(), Currency.unwrap(other.currency0));
        assertEq(made.token1(), Currency.unwrap(other.currency1));
        assertEq(made.homeId(), PoolId.unwrap(other.toId()));
    }

    function testAPositionSurvivesItsPoolBeingUntracked() public {
        PoolKey memory third = _create(address(backing), address(coin), 10_000);
        vault = _makeVault(third);
        _fundVault(curator);
        _fundVault(bob);
        _seed(1);
        vm.prank(team);
        hook.untrack(id, _id(third));
        _deposit(bob, 1e24);
        _withdraw(bob, 1e24);
        _withdraw(curator, vault.balanceOf(curator));
        assertEq(vault.totalSupply(), vault.MINIMUM_SHARES());
    }

    // The pair.

    function _build(
        ArbitrageApi arbitrageHook,
        uint256 marketId,
        address who,
        address a,
        address b
    ) internal {
        PoolKey memory home = PoolKey(
            Currency.wrap(a), Currency.wrap(b), 3_000, 60, IHooks(address(hook))
        );
        deployCode(
            "ArbitrageVault.sol:ArbitrageVault",
            abi.encode(arbitrageHook, marketId, home, who, address(0), uint16(0))
        );
    }

    function testThePairIsChecked() public {
        (address low, address high) = address(backing) < address(szr)
            ? (address(backing), address(szr))
            : (address(szr), address(backing));
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, id, curator, address(0), address(coin));
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, id, curator, low, high);
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, id, curator, token1, token0);
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, id, curator, token0, token0);
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, 1, curator, token0, token1);
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _build(hook, 999, curator, token0, token1);
        vm.expectRevert(IHookVault.InvalidCurator.selector);
        _build(hook, id, address(0), token0, token1);
        assertEq(vault.primaryHook(), address(hook));
        assertEq(vault.token0(), token0);
        assertEq(vault.token1(), token1);
    }

    function testOnlyThePoolManagerCanCallBack() public {
        vm.expectRevert(IHookVault.NotPoolManager.selector);
        vault.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(IHookVault.UnexpectedCallback.selector);
        vault.unlockCallback("");
    }
}
