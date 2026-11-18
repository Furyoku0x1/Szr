// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { MockLiquidityPool, Donor } from "./utils/metric/MockLiquidityPool.sol";
import { MetricVault } from "../src/vaults/MetricVault.sol";
import { IHookVault, IMarketController } from "../src/interfaces/IHookVault.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IMetricLiquidityPool } from "../src/interfaces/metric/IMetricPool.sol";

/// @dev The Metric vault against a mock Metric pool that keeps Metric's liquidity rules and
/// storage layout. The pair's raw token1 is a thousandth of its scaled amount, so the
/// pool's rounding shows. The pool's smallest change is 1e9 bin shares.
contract MetricVaultTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant MIN = 1e9;

    TestAsset internal t0;
    TestAsset internal t1;
    MockMetricFactory internal factory;
    MockLiquidityPool internal pool;
    MetricVault internal vault;
    address internal curator = address(0xC0);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stranger = address(0x57A9);
    uint256[4] internal none;

    function setUp() public {
        TestAsset a = new TestAsset();
        TestAsset b = new TestAsset();
        (t0, t1) = address(a) < address(b) ? (a, b) : (b, a);
        factory = new MockMetricFactory();
        pool = _pool(MIN, none);
        vault = _vaultOf(pool);
        address[4] memory users = [curator, alice, bob, address(this)];
        for (uint256 i; i < users.length; i++) {
            t0.mint(users[i], 1_000e18);
            t1.mint(users[i], 1_000e18);
            vm.startPrank(users[i]);
            t0.approve(address(vault), MAX);
            t1.approve(address(vault), MAX);
            vm.stopPrank();
        }
    }

    function _vaultOf(MockLiquidityPool home) internal returns (MetricVault made) {
        made = new MetricVault(
            IMetricFactory(address(factory)),
            address(home),
            IMarketController(address(0)),
            1000,
            curator
        );
    }

    function _pool(uint256 minimum, uint256[4] memory orders)
        internal
        returns (MockLiquidityPool made)
    {
        made = new MockLiquidityPool(address(t0), address(t1), 1, 1000, minimum, orders);
        factory.register(address(made));
    }

    function _bins(int16 a) internal pure returns (int16[] memory list) {
        list = new int16[](1);
        list[0] = a;
    }

    function _bins(int16 a, int16 b) internal pure returns (int16[] memory list) {
        list = new int16[](2);
        list[0] = a;
        list[1] = b;
    }

    function _list(uint256 a) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = a;
    }

    function _list(uint256 a, uint256 b) internal pure returns (uint256[] memory list) {
        list = new uint256[](2);
        list[0] = a;
        list[1] = b;
    }

    function _ranges() internal pure returns (int16[][] memory ranges) {
        ranges = new int16[][](2);
        ranges[0] = _bins(0, 1);
        ranges[1] = _bins(-1);
    }

    /// Two positions: bins 0 and 1 (1e18 and 2e18 shares) and bin -1 (1e18). The supply is
    /// 4e18 shares.
    function _seed() internal {
        uint256[][] memory shares = new uint256[][](2);
        shares[0] = _list(1e18, 2e18);
        shares[1] = _list(1e18);
        vm.prank(curator);
        vault.seed(_ranges(), shares, MAX, MAX, block.timestamp);
    }

    function _deposit(address who, uint256 shares) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.deposit(shares, MAX, MAX, block.timestamp);
    }

    function _withdraw(address who, uint256 shares) internal returns (uint256, uint256) {
        vm.prank(who);
        return vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _held(uint80 salt, int16 bin) internal view returns (uint256) {
        return pool.sharesOf(address(vault), salt, bin);
    }

    function _changes(uint256 position, uint256 slot, int256 shares)
        internal
        pure
        returns (MetricVault.Change[] memory list)
    {
        list = new MetricVault.Change[](1);
        list[0] = MetricVault.Change(position, slot, shares);
    }

    function _rebalance(MetricVault.Change[] memory list) internal {
        vm.prank(curator);
        vault.rebalance(list, 0, 0, block.timestamp);
    }

    // Seed.

    function testSeedOpensPositionsAndLocksMinimumShares() public {
        uint256 before0 = t0.balanceOf(curator);
        uint256 before1 = t1.balanceOf(curator);
        _seed();
        assertEq(vault.totalSupply(), 4e18, "supply is the bin shares seeded");
        assertEq(vault.balanceOf(vault.DEAD()), vault.MINIMUM_SHARES(), "minimum locked");
        assertEq(vault.balanceOf(curator), 4e18 - vault.MINIMUM_SHARES());
        assertEq(vault.positionCount(), 2);
        assertEq(vault.binCount(), 3);
        assertEq(vault.unitsOf(0), 3e18, "units are the bin shares held");
        assertEq(vault.unitsOf(1), 1e18);
        assertEq(_held(1, 0), 1e18);
        assertEq(_held(1, 1), 2e18);
        assertEq(_held(2, -1), 1e18);
        // Bin 0 takes half of each, bin 1 token0 only, bin -1 token1 only (scaled).
        assertEq(before0 - t0.balanceOf(curator), 2.5e18, "token0 paid");
        assertEq(before1 - t1.balanceOf(curator), 1.5e15, "token1 paid, scaled down");
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0 + idle1, 0, "no idle principal");
        assertEq(vault.primaryHook(), address(factory));
    }

    function testSeedGuards() public {
        uint256[][] memory shares = new uint256[][](2);
        shares[0] = _list(1e18, 2e18);
        shares[1] = _list(1e18);
        int16[][] memory ranges = _ranges();
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp);
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp - 1);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(new int16[][](0), new uint256[][](0), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(ranges, new uint256[][](1), MAX, MAX, block.timestamp);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.seed(ranges, shares, 2.5e18 - 1, MAX, block.timestamp);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.seed(ranges, shares, MAX, 1.5e15 - 1, block.timestamp);
        shares[1] = _list(0);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp);
        shares[1] = new uint256[](2);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp);
        vm.stopPrank();
        _seed();
        shares[1] = _list(1e18);
        vm.prank(curator);
        vm.expectRevert(IHookVault.AlreadySeeded.selector);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp);
    }

    function testSeedTotalMustExceedTheMinimumShares() public {
        uint256[][] memory shares = new uint256[][](1);
        shares[0] = _list(vault.MINIMUM_SHARES());
        int16[][] memory one = new int16[][](1);
        one[0] = _bins(1);
        // A pool with a one-share minimum, so the pool itself accepts the small change.
        MetricVault small = _vaultOf(_pool(1, none));
        vm.startPrank(curator);
        t0.approve(address(small), MAX);
        t1.approve(address(small), MAX);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        small.seed(one, shares, MAX, MAX, block.timestamp);
        vm.stopPrank();
    }

    // Deposits and withdrawals.

    function testDepositAddsAFractionOfEveryBinAndMatchesTheQuote() public {
        _seed();
        (uint256 need0, uint256 need1) = vault.quoteDeposit(1e18);
        uint256 before0 = t0.balanceOf(alice);
        uint256 before1 = t1.balanceOf(alice);
        (uint256 paid0, uint256 paid1) = _deposit(alice, 1e18);
        assertEq(paid0, need0, "quote is the payment, token0");
        assertEq(paid1, need1, "quote is the payment, token1");
        assertEq(before0 - t0.balanceOf(alice), paid0);
        assertEq(before1 - t1.balanceOf(alice), paid1);
        assertEq(vault.balanceOf(alice), 1e18);
        // A quarter more of each bin.
        assertEq(_held(1, 0), 1.25e18);
        assertEq(_held(1, 1), 2.5e18);
        assertEq(_held(2, -1), 1.25e18);
        assertEq(paid0, 0.625e18, "a quarter of bin 0 (half) and of bin 1 (all)");
    }

    function testWithdrawReturnsTheFractionRoundedDown() public {
        _seed();
        _deposit(alice, 1e18);
        uint256 before0 = t0.balanceOf(alice);
        uint256 before1 = t1.balanceOf(alice);
        (uint256 out0, uint256 out1) = _withdraw(alice, 1e18);
        assertEq(t0.balanceOf(alice) - before0, out0);
        assertEq(t1.balanceOf(alice) - before1, out1);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(_held(1, 0), 1e18, "positions are back");
        assertEq(_held(1, 1), 2e18);
        assertEq(_held(2, -1), 1e18);
        assertEq(pool.sharesOf(address(vault), 1, 1), vault.unitsOf(0) - 1e18);
    }

    function testRoundTripNeverPaysMore(uint256 shares) public {
        _seed();
        shares = bound(shares, 1, 8e18);
        (uint256 paid0, uint256 paid1) = _deposit(alice, shares);
        (uint256 out0, uint256 out1) = _withdraw(alice, shares);
        assertLe(out0, paid0, "token0 rounds against the user");
        assertLe(out1, paid1, "token1 rounds against the user");
        assertEq(t0.balanceOf(address(vault)), 0, "nothing is left behind");
    }

    function testDepositGuards() public {
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotSeeded.selector);
        vault.deposit(1e18, MAX, MAX, block.timestamp);
        _seed();
        (uint256 need0,) = vault.quoteDeposit(1e18);
        vm.startPrank(alice);
        vm.expectRevert(IHookVault.AboveMaximum.selector);
        vault.deposit(1e18, need0 - 1, MAX, block.timestamp);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.deposit(1e18, MAX, MAX, block.timestamp - 1);
        vm.expectRevert(IHookVault.ZeroShares.selector);
        vault.deposit(0, MAX, MAX, block.timestamp);
        vm.stopPrank();
    }

    function testEarningsRaiseWhatAShareIsWorth() public {
        _seed();
        _deposit(alice, 1e18);
        (uint256 before0,) = vault.quoteDeposit(1e18);
        // A swap's fees land in bin 1 as token0.
        t0.mint(address(pool), 1e18);
        pool.earn(1, 1e18, 0);
        (uint256 after0,) = vault.quoteDeposit(1e18);
        assertGt(after0, before0, "a share costs more");
        (uint256 out0,) = _withdraw(alice, 1e18);
        assertGt(out0, before0, "and pays more");
        assertEq(vault.earned(alice, address(t0)), 0, "earnings are not rewards");
    }

    // Inflation: shares added for the vault by someone else.

    function testADonationBelongsToTheHoldersAndNeverHurtsThem() public {
        _seed();
        Donor donor = new Donor();
        t0.mint(address(donor), 1_000e18);
        t1.mint(address(donor), 1_000e18);
        uint256 supply = vault.totalSupply();
        uint256 unitsBefore = vault.unitsOf(0);
        donor.donate(pool, address(vault), 1, 1, 100e18);
        assertEq(vault.unitsOf(0), unitsBefore + 100e18, "units read what the pool holds");
        assertEq(vault.totalSupply(), supply, "no vault shares are minted");
        uint256 units = vault.unitsOf(0);
        (uint256 paid0, uint256 paid1) = _deposit(bob, 1e18);
        (uint256 out0, uint256 out1) = _withdraw(bob, 1e18);
        assertLe(out0, paid0, "no gain on the way out");
        assertLe(out1, paid1);
        assertGe(vault.unitsOf(0), units, "holders lose nothing");
        // A donation to a bin the position does not hold is simply gone from view.
        uint256 after_ = vault.unitsOf(0);
        donor.donate(pool, address(vault), 1, 5, 1e18);
        assertEq(vault.unitsOf(0), after_);
    }

    // Dust: Metric's minimum change and minimum leftover.

    function testATinyDepositIsLiftedToTheMinimum() public {
        _seed();
        (uint256 paid0,) = _deposit(alice, 1);
        assertEq(_held(1, 0), 1e18 + MIN, "bin 0 rose by the pool's minimum");
        assertEq(_held(1, 1), 2e18 + MIN);
        assertEq(_held(2, -1), 1e18 + MIN);
        assertGt(paid0, 0);
        (uint256 need0, uint256 need1) = vault.quoteDeposit(1);
        (uint256 paid0b, uint256 paid1b) = _deposit(alice, 1);
        assertEq(paid0b, need0, "quote holds for dust");
        assertEq(paid1b, need1);
    }

    function testATinyWithdrawalSkipsBinsBelowTheMinimum() public {
        _seed();
        vm.prank(curator);
        vault.transfer(alice, 1000);
        (uint256 out0, uint256 out1) = _withdraw(alice, 1000);
        assertEq(out0 + out1, 0, "nothing was worth removing");
        assertEq(_held(1, 0), 1e18, "the bins are untouched");
        assertEq(vault.balanceOf(alice), 0, "the shares are burned");
    }

    function testEmptyingAllButTheLockedSharesLeavesTheMinimum() public {
        _seed();
        uint256 all = vault.balanceOf(curator);
        _withdraw(curator, all);
        // The locked shares own about 2.5e5 of each bin, below the pool's minimum, so the
        // vault keeps the minimum instead of being refused.
        assertEq(_held(1, 0), MIN);
        assertEq(_held(1, 1), MIN);
        assertEq(_held(2, -1), MIN);
    }

    // Pool rules.

    function testRefusesAPoolMetricDidNotMake() public {
        MockLiquidityPool stray =
            new MockLiquidityPool(address(t0), address(t1), 1, 1000, MIN, none);
        vm.expectRevert(IHookVault.InvalidPool.selector);
        _vaultOf(stray);
    }

    /// The pair is the pool's own tokens, and they must be in order.
    function testRefusesAPoolWhoseTokensAreOutOfOrder() public {
        MockLiquidityPool swapped =
            new MockLiquidityPool(address(t1), address(t0), 1, 1, MIN, none);
        factory.register(address(swapped));
        vm.expectRevert(IHookVault.InvalidPair.selector);
        _vaultOf(swapped);
    }

    function testRefusesAPoolWhoseExtensionsRunAroundRemoval() public {
        uint256[4] memory before = [uint256(0), 0, 1, 0];
        uint256[4] memory later = [uint256(0), 0, 0, 0x11];
        MockLiquidityPool first = _pool(MIN, before);
        MockLiquidityPool second = _pool(MIN, later);
        vm.expectRevert(MetricVault.BlockingExtension.selector);
        _vaultOf(first);
        vm.expectRevert(MetricVault.BlockingExtension.selector);
        _vaultOf(second);
    }

    /// Extensions around adding cannot hold a withdrawal back, so the pool is allowed.
    function testAcceptsAPoolWhoseExtensionsRunOnlyAroundAdding() public {
        uint256[4] memory orders = [uint256(1), 0x21, 0, 0];
        MockLiquidityPool home = _pool(MIN, orders);
        assertEq(address(_vaultOf(home).pool()), address(home));
    }

    /// There is no way to name another pool: every position, and every share the vault
    /// holds, is in the home pool, even when Metric has made a second pool of the pair.
    function testLiquidityNeverLeavesTheHomePool() public {
        MockLiquidityPool other = _pool(MIN, none);
        t0.mint(address(other), 1e18);
        _seed();
        _deposit(alice, 1e18);
        _rebalance(_shiftIntoBinTwo());
        for (uint256 i; i < vault.positionCount(); i++) {
            (address where,,) = vault.positionInfo(i);
            assertEq(where, address(pool), "positions are in the home pool");
        }
        assertEq(address(vault.pool()), address(pool));
        assertEq(t0.balanceOf(address(other)), 1e18, "the other pool is untouched");
        assertEq(t1.balanceOf(address(other)), 0);
        for (int16 bin = -2; bin < 4; bin++) {
            for (uint80 salt = 1; salt < 5; salt++) {
                assertEq(other.sharesOf(address(vault), salt, bin), 0, "no shares elsewhere");
            }
        }
    }

    function testBinRules() public {
        vm.startPrank(curator);
        uint256[][] memory shares = new uint256[][](1);
        shares[0] = _list(1e18, 1e18);
        int16[][] memory one = new int16[][](1);
        one[0] = _bins(1, 1);
        vm.expectRevert(MetricVault.InvalidBins.selector);
        vault.seed(one, shares, MAX, MAX, block.timestamp);
        one[0] = _bins(2, 1);
        vm.expectRevert(MetricVault.InvalidBins.selector);
        vault.seed(one, shares, MAX, MAX, block.timestamp);
        one[0] = _bins(0, 11);
        vm.expectRevert(MetricVault.InvalidBins.selector);
        vault.seed(one, shares, MAX, MAX, block.timestamp);
        one[0] = _bins(-11, 0);
        vm.expectRevert(MetricVault.InvalidBins.selector);
        vault.seed(one, shares, MAX, MAX, block.timestamp);
        one[0] = new int16[](0);
        shares[0] = new uint256[](0);
        vm.expectRevert(MetricVault.InvalidBins.selector);
        vault.seed(one, shares, MAX, MAX, block.timestamp);
        vm.stopPrank();
    }

    function testTheBinAndPositionLimits() public {
        _seed();
        int16[] memory wide = new int16[](14);
        for (uint256 i; i < 14; i++) {
            wide[i] = int16(int256(i)) - 7;
        }
        vm.startPrank(curator);
        // Three bins are held, so 13 more is the most.
        vm.expectRevert(MetricVault.TooManyBins.selector);
        vault.addPosition(wide);
        int16[] memory thirteen = new int16[](13);
        for (uint256 i; i < 13; i++) {
            thirteen[i] = int16(int256(i)) - 6;
        }
        vault.addPosition(thirteen);
        assertEq(vault.binCount(), 16);
        vm.expectRevert(MetricVault.TooManyBins.selector);
        vault.addPosition(_bins(9));
        vault.dropPosition(2);
        vault.addPosition(_bins(9));
        vault.addPosition(_bins(10));
        vm.expectRevert(IHookVault.TooManyPositions.selector);
        vault.addPosition(_bins(8));
        vm.stopPrank();
    }

    function testSeedRefusesMoreThanFourPositions() public {
        int16[][] memory five = new int16[][](5);
        uint256[][] memory shares = new uint256[][](5);
        for (uint256 i; i < 5; i++) {
            five[i] = _bins(int16(int256(i)));
            shares[i] = _list(1e18);
        }
        vm.prank(curator);
        vm.expectRevert(IHookVault.TooManyPositions.selector);
        vault.seed(five, shares, MAX, MAX, block.timestamp);
    }

    // Curator moves.

    function testOnlyTheCuratorMovesPositions() public {
        _seed();
        vm.startPrank(stranger);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.addPosition(_bins(3));
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.dropPosition(0);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.rebalance(_changes(0, 1, -1e9), 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function testAddAndDropAnEmptyPosition() public {
        _seed();
        vm.startPrank(curator);
        vault.addPosition(_bins(2, 3));
        vault.addPosition(_bins(4));
        assertEq(vault.positionCount(), 4);
        assertEq(vault.binCount(), 6);
        assertEq(vault.unitsOf(2), 0);
        vault.dropPosition(2);
        assertEq(vault.positionCount(), 3);
        assertEq(vault.binCount(), 4, "the last position took the index");
        (, uint80 salt, int16[] memory bins) = vault.positionInfo(2);
        assertEq(salt, 4);
        assertEq(bins.length, 1);
        assertEq(bins[0], 4);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.dropPosition(3);
        vm.stopPrank();
    }

    /// A funded position is not refused: its shares go to idle principal, which still
    /// belongs to the holders, so a drop can never take value out of the vault.
    function testDroppingAFundedPositionMovesItToIdle() public {
        _seed();
        vm.prank(curator);
        vault.dropPosition(1);
        assertEq(_held(2, -1), 0, "the shares are out of the pool");
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0, 0);
        assertEq(idle1, 1e15, "and are idle token1");
        assertEq(vault.positionCount(), 1);
        assertEq(vault.binCount(), 2);
        assertEq(t1.balanceOf(address(vault)), idle1);
    }

    /// Anyone can add shares to a bin for the vault, so a donation to an empty position
    /// must not keep the curator from dropping it.
    function testADonationCannotBlockDroppingAPosition() public {
        _seed();
        vm.prank(curator);
        vault.addPosition(_bins(2));
        Donor donor = new Donor();
        t0.mint(address(donor), 1_000e18);
        t1.mint(address(donor), 1_000e18);
        donor.donate(pool, address(vault), 3, 2, 5e18);
        assertEq(vault.unitsOf(2), 5e18, "the donation is the position's");
        vm.prank(curator);
        vault.dropPosition(2);
        assertEq(vault.positionCount(), 2);
        assertEq(_held(3, 2), 0);
        (uint256 idle0,) = vault.principal();
        assertGt(idle0, 0, "the donation went to idle principal");
        assertEq(t0.balanceOf(address(vault)), idle0, "booked from what arrived");
    }

    function testAddPositionNeedsASeededVault() public {
        vm.prank(curator);
        vm.expectRevert(IHookVault.NotSeeded.selector);
        vault.addPosition(_bins(3));
    }

    /// Bin 1 holds only token0, so half its shares move into the empty bin 2 and the rest
    /// stays idle principal.
    function _shiftIntoBinTwo() internal returns (MetricVault.Change[] memory list) {
        vm.prank(curator);
        vault.addPosition(_bins(2));
        list = new MetricVault.Change[](2);
        list[0] = MetricVault.Change(0, 1, -1e18);
        list[1] = MetricVault.Change(2, 0, 0.6e18);
    }

    function testRebalanceMovesSharesBetweenBinsAndKeepsTheRestIdle() public {
        _seed();
        MetricVault.Change[] memory list = _shiftIntoBinTwo();
        uint256 curator0 = t0.balanceOf(curator);
        uint256 total0 = t0.balanceOf(address(vault)) + t0.balanceOf(address(pool));
        _rebalance(list);
        assertEq(_held(1, 1), 1e18);
        assertEq(_held(3, 2), 0.6e18);
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0, 0.4e18, "the 1e18 removed, 0.6e18 added");
        assertEq(idle1, 0);
        assertEq(t0.balanceOf(address(vault)), 0.4e18, "idle principal is held");
        assertEq(t0.balanceOf(curator), curator0, "nothing goes to the curator");
        assertEq(
            t0.balanceOf(address(vault)) + t0.balanceOf(address(pool)),
            total0,
            "tokens only moved between the pool and the vault"
        );
        // A later deposit brings its share of the idle principal too.
        uint256 before0 = t0.balanceOf(alice);
        (uint256 paid0,) = _deposit(alice, 1e18);
        assertEq(before0 - t0.balanceOf(alice), paid0);
        (idle0,) = vault.principal();
        assertEq(idle0, 0.4e18 + 0.1e18, "a quarter of the idle token0 came with it");
        _withdraw(alice, 1e18);
        (idle0,) = vault.principal();
        assertEq(idle0, 0.4e18);
    }

    function testRebalanceCannotSpendMoreThanItRemoved() public {
        _seed();
        MetricVault.Change[] memory list = _shiftIntoBinTwo();
        list[1].shares = 1.1e18;
        // The vault holds only what it removed, so the pool's callback cannot be paid.
        vm.prank(curator);
        vm.expectRevert();
        vault.rebalance(list, 0, 0, block.timestamp);
    }

    function testRebalanceCannotUseProfitAsPrincipal() public {
        _seed();
        MetricVault.Change[] memory list = _shiftIntoBinTwo();
        list[1].shares = 1.1e18;
        // A profit payment sits in the vault, unbooked. It is not there to spend.
        t0.mint(address(vault), 5e18);
        vm.prank(curator);
        vm.expectRevert(MetricVault.InsufficientIdle.selector);
        vault.rebalance(list, 0, 0, block.timestamp);
    }

    function testRebalanceMinimumOutputsAndDeadline() public {
        _seed();
        MetricVault.Change[] memory list = _shiftIntoBinTwo();
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.BelowMinimum.selector);
        vault.rebalance(list, 1e18 + 1, 0, block.timestamp);
        vm.expectRevert(IHookVault.BelowMinimum.selector);
        vault.rebalance(list, 0, 1, block.timestamp);
        vm.expectRevert(IHookVault.DeadlinePassed.selector);
        vault.rebalance(list, 0, 0, block.timestamp - 1);
        vault.rebalance(list, 1e18, 0, block.timestamp);
        vm.stopPrank();
    }

    function testRebalanceNamesRealBins() public {
        _seed();
        vm.startPrank(curator);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(_changes(2, 0, -1e9), 0, 0, block.timestamp);
        vm.expectRevert(IHookVault.InvalidPosition.selector);
        vault.rebalance(_changes(0, 2, -1e9), 0, 0, block.timestamp);
        vm.stopPrank();
    }

    function testOneRebalancePerPoolPerBlock() public {
        _seed();
        MetricVault.Change[] memory list = _shiftIntoBinTwo();
        _rebalance(list);
        MetricVault.Change[] memory back = _changes(2, 0, -0.1e18);
        vm.prank(curator);
        vm.expectRevert(MetricVault.RebalanceTooSoon.selector);
        vault.rebalance(back, 0, 0, block.timestamp);
        vm.roll(block.number + 1);
        _rebalance(back);
        assertEq(_held(3, 2), 0.5e18);
    }

    function testAnEmptyVaultCannotRebalance() public {
        vm.prank(curator);
        vm.expectRevert(IHookVault.NotSeeded.selector);
        vault.rebalance(_changes(0, 0, -1), 0, 0, block.timestamp);
    }

    // Rewards and the pool's honesty.

    function testProfitPaidToTheVaultIsAReward() public {
        _seed();
        _deposit(alice, 1e18);
        t0.mint(address(vault), 10e18);
        (uint256 idle0,) = vault.principal();
        vault.harvest();
        assertEq(vault.owed(address(t0)), 10e18, "reserved for rewards");
        assertEq(vault.feeOwed(address(t0)), 1e18, "the curator's fee");
        (uint256 idleAfter,) = vault.principal();
        assertEq(idleAfter, idle0, "principal is untouched");
        skip(3 days);
        assertApproxEqAbs(vault.earned(alice, address(t0)), 1.8e18, 2);
        uint256 before0 = t0.balanceOf(alice);
        (uint256 out0,) = _withdraw(alice, 1e18);
        assertApproxEqAbs(t0.balanceOf(alice) - before0, out0 + 1.8e18, 2, "paid with it");
    }

    function testRemovalThePoolReportsFalselyIsRefused() public {
        _seed();
        pool.setMode(1);
        vm.prank(curator);
        vm.expectRevert(IHookVault.TransferAmountMismatch.selector);
        vault.rebalance(_changes(0, 1, -1e18), 0, 0, block.timestamp);
        _deposit(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(IHookVault.TransferAmountMismatch.selector);
        vault.withdraw(1e18, 0, 0, block.timestamp);
    }

    function testOnlyThePoolBeingCalledMayAskForTokens() public {
        _seed();
        vm.expectRevert(MetricVault.NotPool.selector);
        vault.metricOmmModifyLiquidityCallback(1, 1, abi.encode(address(this)));
        vm.prank(address(pool));
        vm.expectRevert(MetricVault.NotPool.selector);
        vault.metricOmmModifyLiquidityCallback(1, 1, abi.encode(alice));
    }

    function testConstructorRefusesNoFactory() public {
        vm.expectRevert(IHookVault.InvalidPair.selector);
        new MetricVault(
            IMetricFactory(address(0)), address(pool), IMarketController(address(0)), 0, curator
        );
    }

    function testWithoutAControllerThereIsNoMarket() public view {
        assertEq(vault.market(), 0);
    }
}
