// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../script/DeploySzr.s.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { SzrMigration, ILegacySzrHook } from "../src/SzrMigration.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { LegacyMigrationHook, LegacyMigrationToken } from "./utils/LegacyMigrationHook.sol";

contract InitialLiquidityTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    TestAsset internal backing;
    SzrCore internal core;
    Liquidity internal locker;
    SzrMigration internal migrator;
    IPoolManager internal manager;
    LegacyMigrationHook internal oldHook;
    LegacyMigrationToken internal oldToken;
    address internal alice = address(0xA11CE);
    address internal contributor = address(0xF00D);
    uint256 internal constant TOTAL = 350_000_000e18;
    uint256 internal constant INITIAL = 25_000_000e18;
    uint256 internal constant HOLDERS = TOTAL - INITIAL;

    function setUp() public {
        backing = new TestAsset();
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        _legacy();
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (core,, locker) = deployment.run(_deployConfig());
        migrator = SzrMigration(core.migration());
        oldToken.mint(alice, HOLDERS + 1e18);
        oldToken.mint(contributor, INITIAL);
        vm.prank(alice);
        oldToken.approve(address(migrator), type(uint256).max);
        vm.prank(contributor);
        oldToken.approve(address(migrator), type(uint256).max);
    }

    function _deployConfig() internal view returns (DeploySzr.Config memory config) {
        config.chainId = block.chainid;
        config.asset = address(backing);
        config.poolManager = address(manager);
        config.teamBeneficiary = address(this);
        config.legacyToken = address(oldToken);
        config.marketPrice = 4e12;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = TOTAL;
        config.initialLiquidityTokens = INITIAL;
        config.auction = SzrCore.AuctionConfig(8e12, 1, 20_000e18);
    }

    /// The pool is buy-only until someone has bought, because genesis starts as SZR only.
    function _tradeBothWays(SzrCore next, Liquidity nextLocker) internal {
        address szr = address(next.token());
        PoolKey memory pool = nextLocker.key(nextLocker.INITIAL_POSITION());
        bool first = Currency.unwrap(pool.currency0) == address(backing);
        PoolSwapTest router = new PoolSwapTest(manager);
        PoolSwapTest.TestSettings memory settings;
        backing.mint(alice, 1e18);
        vm.startPrank(alice);
        backing.approve(address(router), 1e18);
        router.swap(
            pool,
            IPoolManager.SwapParams(
                first,
                -int256(1e18),
                first ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        uint256 bought = TestAsset(szr).balanceOf(alice);
        assertGt(bought, 0);
        TestAsset(szr).approve(address(router), bought / 2);
        router.swap(
            pool,
            IPoolManager.SwapParams(
                !first,
                -int256(bought / 2),
                first ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
        assertGt(backing.balanceOf(alice), 0);
        assertEq(next.reserveCash(), 0); // pool trades never touch reserves
    }

    function testDeployScriptRejectsGenesisPricedBelowTheHighestPossibleNav() public {
        DeploySzr.Config memory config = _deployConfig();
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        // One old SZR recovers 297e10 from the mock hook. With all 350M migrated and the 25M
        // genesis tokens sharing the reserves, NAV tops out at 297e10 * 350 / 375.
        config.marketPrice = 2_772e9;
        deployment.run(config);
        config.marketPrice = 2_772e9 - 1;
        vm.expectRevert(DeploySzr.InitialPriceBelowNav.selector);
        deployment.run(config);
    }

    /// The pool's fee and tick spacing are script inputs, so a deployment can move to a
    /// different pool if someone creates the default one first at another price.
    function testDeployScriptCanUseAnotherFeeTier() public {
        DeploySzr.Config memory config = _deployConfig();
        config.poolFee = 3_000;
        config.tickSpacing = 60;
        config.fundInitialLiquidity = true;
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (SzrCore next,, Liquidity nextLocker) = deployment.run(config);
        assertEq(nextLocker.key(0).fee, 3_000);
        assertEq(nextLocker.key(0).tickSpacing, 60);
        assertEq(nextLocker.key(nextLocker.INITIAL_POSITION()).fee, 3_000);
        assertTrue(nextLocker.initialLiquidityFunded());
        assertEq(locker.key(0).fee, 10_000); // the fixture used the defaults
        assertEq(next.auctionsOpenAt(), 0);
    }

    function testDeployScriptRejectsTheDeployerAsManager() public {
        DeploySzr.Config memory config = _deployConfig();
        config.manager = core.initializer();
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        vm.expectRevert(DeploySzr.ManagerIsDeployer.selector);
        deployment.run(config);
    }

    function testDeployScriptFundsGenesisFromCoreInventory() public {
        address deployer = core.initializer(); // the fixture's run used the same broadcaster
        DeploySzr.Config memory config = _deployConfig();
        config.fundInitialLiquidity = true;
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (SzrCore next,, Liquidity nextLocker) = deployment.run(config);
        assertEq(next.initializer(), deployer);
        assertTrue(nextLocker.initialLiquidityFunded());
        // The genesis tokens are the only live supply, came from inventory and have no backing.
        assertGt(next.activeSupply(), INITIAL - 1e18);
        assertLe(next.activeSupply(), INITIAL);
        assertEq(next.publicInventory(), 650_000_000e18 - next.activeSupply());
        assertEq(next.reserveCash(), 0);
        assertEq(next.NAV(), 0);
        assertEq(next.migrationRemaining(), TOTAL); // the migration reservation is untouched
        assertEq(next.auctionsOpenAt(), 0);
        assertEq(next.token().balanceOf(deployer), 0); // the deployer supplied and kept nothing
        assertEq(oldToken.balanceOf(deployer), 0);
        assertEq(next.token().balanceOf(address(nextLocker)), 0);
        assertGt(next.token().balanceOf(address(manager)), INITIAL - 1e18);
        _tradeBothWays(next, nextLocker);
        assertEq(next.auctionsOpenAt(), 0); // traded while migration is open and the sale closed
    }

    function _legacy() internal {
        LegacyMigrationHook implementation = new LegacyMigrationHook();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        oldHook = LegacyMigrationHook(address(flags));
        vm.etch(address(oldHook), address(implementation).code);
        oldHook.initialize(manager, address(backing));
        oldToken = oldHook.token();
        bool first = address(oldToken) < address(backing);
        manager.initialize(
            PoolKey(
                Currency.wrap(first ? address(oldToken) : address(backing)),
                Currency.wrap(first ? address(backing) : address(oldToken)),
                0,
                60,
                IHooks(address(oldHook))
            ),
            uint160(1 << 96)
        );
        backing.mint(address(oldHook), 10_000e18);
    }

    function testFundingTargetDoesNotAddOrSubtractFromMigrationInventory() public view {
        assertEq(core.initialLiquidityTarget(), INITIAL);
        assertEq(core.migrationAllocation(), TOTAL);
        assertEq(core.migrationRemaining(), TOTAL);
        assertEq(core.publicInventory(), 650_000_000e18);
        assertEq(core.activeSupply(), 0);
        assertEq(core.unreleasedSupply(), 1_000_000_000e18);
        assertEq(core.token().balanceOf(address(core)), 1_000_000_000e18);
        assertEq(core.token().balanceOf(address(locker)), 0);
        assertEq(core.reserveCash(), 0);
        assertFalse(locker.initialLiquidityFunded());
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }

    function testHolderGetsFullOneForOneWithNoAutomaticLiquidityDeduction() public {
        uint256 amount = 1_000e18;
        (uint256 recovered,,) = migrator.quote(amount);
        vm.prank(alice);
        migrator.migrate(amount, recovered, block.timestamp);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(core.migrationRemaining(), TOTAL - amount);
        assertEq(core.reserveCash(), recovered);
        assertEq(backing.balanceOf(address(core)), recovered);
        assertEq(backing.balanceOf(address(locker)), 0);
        assertEq(core.activeSupply(), amount);
        assertEq(core.economics().claimableFees(), 0);
        assertFalse(locker.initialLiquidityFunded());
    }

    /// An ordinary holder migrating; nothing about them is special any more.
    function _migrateContributor() internal {
        vm.startPrank(contributor);
        migrator.migrate(INITIAL, 0, block.timestamp);
        assertEq(core.token().balanceOf(contributor), INITIAL);
        core.token().approve(address(locker), INITIAL);
        vm.stopPrank();
    }

    function _fundInitial() internal returns (uint256 spent) {
        return locker.fundInitialLiquidity(1, block.timestamp);
    }

    function testGenesisLiquidityComesFromCorePublicInventory() public {
        vm.prank(alice);
        uint256 spent = locker.fundInitialLiquidity(1, block.timestamp);
        assertGt(spent, INITIAL - 1e18);
        assertLe(spent, INITIAL);
        // Exactly what went into the pool left inventory; the rounding remainder went back.
        assertEq(core.activeSupply(), spent);
        assertEq(core.publicInventory(), 650_000_000e18 - spent);
        assertEq(core.unreleasedSupply(), 1_000_000_000e18 - spent);
        assertEq(core.token().balanceOf(address(core)), core.unreleasedSupply());
        assertEq(core.migrationRemaining(), TOTAL);
        // Not a scheduled release, not backed, and nothing is left with the caller or held.
        assertEq(core.totalReleased(), 0);
        assertEq(core.releaseCredit(), 0);
        assertEq(core.reserveCash(), 0);
        assertEq(core.NAV(), 0);
        assertEq(core.token().balanceOf(alice), 0);
        assertEq(core.token().balanceOf(address(locker)), 0);
        assertEq(locker.heldPrincipal(address(core.token())), 0);
        assertEq(core.token().totalSupply(), 1_000_000_000e18);
        assertTrue(core.initialLiquidityReleased());
        assertTrue(locker.initialLiquidityFunded());
        assertGt(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }

    /// Supply starts at 25M with no reserves. Everything must work from there, and the
    /// unbacked genesis tokens dilute what each migrator brings in.
    function testZeroBackingStartAndMigratorDilution() public {
        uint256 spent = _fundInitial();
        assertEq(core.price(), 8e12); // the sale has not opened, so no decay yet
        assertEq(core.backingRequired(1e18), 0);
        (uint256 recovered,,) = migrator.quote(100_000_000e18);
        vm.prank(alice);
        migrator.migrate(100_000_000e18, recovered, block.timestamp);
        assertEq(core.reserveCash(), recovered);
        assertEq(core.NAV(), recovered * 1e18 / (spent + 100_000_000e18));
        assertLt(core.NAV(), recovered * 1e18 / 100_000_000e18); // below what alice brought in
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        uint256 paid = core.redeem(1_000_000e18, 0);
        vm.stopPrank();
        assertApproxEqAbs(paid, 1_000_000e18 * recovered / (spent + 100_000_000e18), 1);
        vm.prank(core.initializer());
        core.closeMigration();
        assertEq(core.auctionsOpenAt(), block.timestamp);
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
    }

    function testFullMigrationFitsAlongsideGenesisLiquidity() public {
        uint256 spent = _fundInitial();
        _migrateContributor();
        vm.prank(alice);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(HOLDERS, 0, block.timestamp);
        vm.prank(alice);
        migrator.migrate(HOLDERS - 1, 0, block.timestamp);
        assertEq(core.token().balanceOf(alice), HOLDERS - 1);
        assertEq(migrator.totalMigrated(), TOTAL - 1);
        assertEq(core.activeSupply(), TOTAL - 1 + spent);
        assertEq(core.migrationRemaining(), 1); // the last unit never leaves
        assertEq(core.auctionsOpenAt(), 0); // and filling up does not open the sale
        assertEq(core.publicInventory(), 650_000_000e18 - spent);
    }

    function testClosingMigrationReturnsAllUnusedTokensWithoutCountingLiquidityAgain() public {
        _fundInitial();
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        uint256 publicBefore = core.publicInventory();
        uint256 unused = core.migrationRemaining();
        uint256 units = locker.liquidityHeld(locker.INITIAL_POSITION());
        uint256 supply = core.activeSupply();
        uint256 credit = core.releaseCredit();
        vm.prank(core.initializer());
        core.closeMigration();
        assertEq(core.publicInventory(), publicBefore + unused);
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.activeSupply(), supply);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), units);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.publicInventory(), core.unreleasedSupply());
    }

    /// Migration cannot end while the genesis allocation is still in Core's inventory. It
    /// could never be released afterwards (the release lowers NAV, which must not happen once
    /// loans and sales exist), and its pool tokens are what keep active supply from shrinking
    /// to dust.
    function testMigrationCannotCloseBeforeGenesisIsFunded() public {
        _migrateContributor();
        vm.prank(core.initializer());
        vm.expectRevert(SzrCore.InitialLiquidityNotReleased.selector);
        core.closeMigration();
        assertEq(core.auctionsOpenAt(), 0);
        // Filling the allowance cannot end migration either; only the manager's call can.
        vm.prank(alice);
        migrator.migrate(HOLDERS - 1, 0, block.timestamp);
        assertEq(core.auctionsOpenAt(), 0);

        _fundInitial();
        vm.prank(core.initializer());
        core.closeMigration();
        assertEq(core.auctionsOpenAt(), block.timestamp);
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        core.borrow(500e18, core.backingRequired(500e18) - 1);
        vm.stopPrank();
    }

    /// Extending the allowance takes public inventory, which still holds the genesis
    /// allocation until it is funded. Reserving that would leave the release with nothing to
    /// draw on and break every later inventory calculation.
    function testAllowanceCannotBeExtendedIntoTheGenesisAllocation() public {
        address team = core.initializer(); // manager in this fixture
        vm.prank(team);
        vm.expectRevert(SzrCore.InitialLiquidityNotReleased.selector);
        core.extendMigration(1e18);
        uint256 spent = _fundInitial();
        uint256 inventory = core.publicInventory();
        assertEq(inventory, 650_000_000e18 - spent);
        vm.prank(team);
        vm.expectRevert(SzrCore.InsufficientInventory.selector);
        core.extendMigration(inventory + 1);
        vm.prank(team);
        core.extendMigration(inventory); // every remaining public token, and no more
        assertEq(core.publicInventory(), 0);
        assertEq(core.migrationRemaining(), TOTAL + inventory);
        // Everything still works with public inventory at zero.
        _migrateContributor();
        vm.startPrank(contributor);
        core.token().approve(address(core), type(uint256).max);
        core.redeem(1_000e18, 0);
        vm.stopPrank();
        assertEq(core.publicInventory() + core.migrationRemaining(), core.unreleasedSupply());
        vm.prank(team);
        core.closeMigration();
        assertEq(core.publicInventory(), core.unreleasedSupply());
    }

    function testGenesisReleaseIsOnceOnlyAndOnlyThroughLiquidity() public {
        _migrateContributor(); // holds 25M and has approved Liquidity; none of it may be taken
        vm.prank(contributor);
        vm.expectRevert(SzrCore.NotLiquidity.selector);
        core.releaseInitialLiquidity();
        vm.prank(contributor);
        locker.fundInitialLiquidity(1, block.timestamp);
        assertEq(core.token().balanceOf(contributor), INITIAL);
        vm.expectRevert(Liquidity.InitialLiquidityExists.selector);
        locker.fundInitialLiquidity(1, block.timestamp);
        vm.prank(address(locker));
        vm.expectRevert(SzrCore.InitialLiquidityAlreadyReleased.selector);
        core.releaseInitialLiquidity();
    }

    function testGenesisPoolTradesAndRoutesOnlyFees() public {
        uint256 spent = _fundInitial();
        uint256 supply = core.activeSupply();
        uint256 inventory = core.publicInventory();
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        uint256 initialUnits = locker.liquidityHeld(locker.INITIAL_POSITION());
        assertEq(supply, spent);
        (, uint256 initialPartnerAmount) =
            locker.quotePosition(locker.INITIAL_POSITION(), initialUnits);
        assertEq(initialPartnerAmount, 0);
        PoolSwapTest router = new PoolSwapTest(manager);
        PoolKey memory key = locker.key(locker.INITIAL_POSITION());
        bool first = Currency.unwrap(key.currency0) == address(backing);
        backing.mint(alice, 1e18);
        vm.startPrank(alice);
        backing.approve(address(router), 1e18);
        PoolSwapTest.TestSettings memory settings;
        router.swap(
            key,
            IPoolManager.SwapParams(
                first,
                -int256(1e18),
                first ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
        uint256 boughtTokens = core.token().balanceOf(alice);
        assertEq(backing.balanceOf(alice), 0);
        assertGt(boughtTokens, 0);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
        assertEq(core.activeSupply(), supply);
        assertEq(core.publicInventory(), inventory);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), initialUnits);

        // A normal exact-input sell can trade through the same one-sided position without
        // touching Core backing.
        vm.startPrank(alice);
        core.token().approve(address(router), boughtTokens / 2);
        router.swap(
            key,
            IPoolManager.SwapParams(
                !first,
                -int256(boughtTokens / 2),
                first ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
        assertGt(backing.balanceOf(alice), 0);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
        assertEq(core.activeSupply(), supply);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), initialUnits);

        locker.collect(locker.INITIAL_POSITION());
        uint256 team = core.economics().claimableFees();
        uint256 reserveFees = core.reserveCash() - reserves;
        assertGt(team, 0);
        assertGt(reserveFees, 0);
        assertEq(team, (team + reserveFees) * 3_300 / 10_000);
        assertLt(core.activeSupply(), supply);
        assertGe(core.NAV(), nav);
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
    }

    function testExternalPoolLiquidityDoesNotChangeGenesisAccounting() public {
        _fundInitial();
        Liquidity.Position memory genesis = locker.position(locker.INITIAL_POSITION());
        PoolKey memory key = genesis.key;

        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        uint256 supply = core.activeSupply();
        uint256 nav = core.NAV();
        uint256 reserves = core.reserveCash();
        uint256 genesisUnits = locker.liquidityHeld(locker.INITIAL_POSITION());
        uint256 poolLiquidityBefore = manager.getLiquidity(key.toId());

        PoolModifyLiquidityTest externalLp = new PoolModifyLiquidityTest(manager);
        int24 externalTickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 externalTickUpper = TickMath.maxUsableTick(key.tickSpacing);
        backing.mint(alice, 1e18);
        vm.startPrank(alice);
        core.token().approve(address(externalLp), type(uint256).max);
        backing.approve(address(externalLp), type(uint256).max);
        externalLp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                externalTickLower, externalTickUpper, int256(1e18), bytes32(0)
            ),
            ""
        );
        vm.stopPrank();

        bytes32 externalPositionKey = Position.calculatePositionKey(
            address(externalLp), externalTickLower, externalTickUpper, bytes32(0)
        );
        assertGt(manager.getPositionLiquidity(key.toId(), externalPositionKey), 0);
        assertGt(manager.getLiquidity(key.toId()), poolLiquidityBefore);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), genesisUnits);

        _sellInPoolWithoutChangingAccounting(key, nav, supply, reserves, genesisUnits);
    }

    function _sellInPoolWithoutChangingAccounting(
        PoolKey memory key,
        uint256 nav,
        uint256 supply,
        uint256 reserves,
        uint256 genesisUnits
    ) internal {
        // A holder's pool sale executes at the pool's own price, whatever NAV is, and Core
        // accounting is unchanged.
        PoolSwapTest router = new PoolSwapTest(manager);
        uint256 sellAmount = 500e18;
        uint256 tokenBalanceBefore = core.token().balanceOf(alice);
        uint256 backingBalanceBefore = backing.balanceOf(alice);
        vm.startPrank(alice);
        core.token().approve(address(router), sellAmount);
        PoolSwapTest.TestSettings memory settings;
        router.swap(
            key,
            IPoolManager.SwapParams(
                address(core.token()) < address(backing),
                -int256(sellAmount),
                address(core.token()) < address(backing)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        vm.stopPrank();

        uint256 tokensSold = tokenBalanceBefore - core.token().balanceOf(alice);
        uint256 wethReceived = backing.balanceOf(alice) - backingBalanceBefore;
        assertEq(tokensSold, sellAmount);
        assertGt(wethReceived, 0);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), genesisUnits);
        assertEq(core.activeSupply(), supply);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
    }

    function testFundingDeadlineAndMinimumUnitsRollBackWithoutReleasingTokens() public {
        vm.expectRevert(Liquidity.DeadlinePassed.selector);
        locker.fundInitialLiquidity(1, block.timestamp - 1);
        vm.expectRevert(Liquidity.BelowMinimum.selector);
        locker.fundInitialLiquidity(type(uint256).max, block.timestamp);
        assertEq(core.unreleasedSupply(), 1_000_000_000e18);
        assertFalse(core.initialLiquidityReleased());
        assertFalse(locker.initialLiquidityFunded());
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }
}
