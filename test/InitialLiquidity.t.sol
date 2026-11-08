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
    uint256 internal constant INITIAL = 100_000_000e18;
    uint256 internal constant HOLDERS = TOTAL - INITIAL;

    function setUp() public {
        backing = new TestAsset();
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        _legacy();
        DeploySzr.Config memory config;
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
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (core,, locker) = deployment.run(config);
        migrator = SzrMigration(core.migration());
        oldToken.mint(alice, HOLDERS + 1e18);
        oldToken.mint(contributor, INITIAL);
        vm.prank(alice);
        oldToken.approve(address(migrator), type(uint256).max);
        vm.prank(contributor);
        oldToken.approve(address(migrator), type(uint256).max);
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

    function _migrateContributor() internal {
        vm.startPrank(contributor);
        migrator.migrate(INITIAL, 0, block.timestamp);
        assertEq(core.token().balanceOf(contributor), INITIAL);
        core.token().approve(address(locker), INITIAL);
        vm.stopPrank();
    }

    function _fundInitial() internal returns (uint256 spent) {
        _migrateContributor();
        vm.prank(contributor);
        return locker.fundInitialLiquidity(1, block.timestamp);
    }

    function testExistingHolderExplicitlyFundsLiquidityWithoutNewIssuance() public {
        _migrateContributor();
        uint256 supply = core.activeSupply();
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        uint256 inventory = core.publicInventory();
        uint256 credit = core.releaseCredit();
        vm.prank(contributor);
        uint256 spent = locker.fundInitialLiquidity(1, block.timestamp);
        assertGt(spent, INITIAL - 1e18);
        assertLe(spent, INITIAL);
        assertEq(core.token().balanceOf(contributor), INITIAL - spent);
        assertEq(core.activeSupply(), supply);
        assertEq(core.activeSupply(), INITIAL);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
        assertEq(core.publicInventory(), inventory);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.migrationRemaining(), HOLDERS);
        assertEq(core.token().totalSupply(), 1_000_000_000e18);
        assertTrue(locker.initialLiquidityFunded());
        assertGt(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }

    function testFullMigrationCountsLiquidityContributorsTokensOnlyOnce() public {
        _fundInitial();
        vm.prank(alice);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(HOLDERS + 1, 0, block.timestamp);
        vm.prank(alice);
        migrator.migrate(HOLDERS, 0, block.timestamp);
        assertEq(core.token().balanceOf(alice), HOLDERS);
        assertEq(migrator.totalMigrated(), TOTAL);
        assertEq(core.activeSupply(), TOTAL);
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.publicInventory(), 650_000_000e18);
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

    function testFundingFromAlreadyActiveTokensDoesNotDiluteAnOpenLoan() public {
        _migrateContributor();
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        vm.prank(core.initializer());
        core.closeMigration();
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        core.borrow(500e18, core.backingRequired(500e18) / 2);
        vm.stopPrank();
        uint256 supply = core.activeSupply();
        uint256 nav = core.NAV();
        uint256 debt = core.loanPrincipal();
        vm.prank(contributor);
        locker.fundInitialLiquidity(1, block.timestamp);
        assertEq(core.activeSupply(), supply);
        assertEq(core.NAV(), nav);
        assertEq(core.loanPrincipal(), debt);
        vm.prank(contributor);
        vm.expectRevert(Liquidity.InitialLiquidityExists.selector);
        locker.fundInitialLiquidity(1, block.timestamp);
    }

    function testAnotherCallerCannotSpendTheContributorsTokensOrCoreInventory() public {
        _migrateContributor();
        uint256 inventory = core.unreleasedSupply();
        vm.prank(alice);
        vm.expectRevert();
        locker.fundInitialLiquidity(1, block.timestamp);
        assertEq(core.token().balanceOf(contributor), INITIAL);
        assertEq(core.unreleasedSupply(), inventory);
        assertFalse(locker.initialLiquidityFunded());
    }

    function testHolderFundedInitialPoolTradesAndRoutesOnlyFees() public {
        _fundInitial();
        uint256 supply = core.activeSupply();
        uint256 inventory = core.publicInventory();
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        uint256 initialUnits = locker.liquidityHeld(locker.INITIAL_POSITION());
        assertEq(supply, INITIAL);
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

        // A normal exact-input sell can trade through the same one-sided position without touching Core backing.
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
        int24 externalTickLower = TickMath.minUsableTick(60);
        int24 externalTickUpper = TickMath.maxUsableTick(60);
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

        _sellBelowNavWithoutChangingAccounting(key, nav, supply, reserves, genesisUnits);
    }

    function _sellBelowNavWithoutChangingAccounting(
        PoolKey memory key,
        uint256 nav,
        uint256 supply,
        uint256 reserves,
        uint256 genesisUnits
    ) internal {
        // A holder may sell below NAV; the pool executes at market price and Core accounting is unchanged.
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
        assertLt(wethReceived, sellAmount * nav / 1e18);
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), genesisUnits);
        assertEq(core.activeSupply(), supply);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
    }

    function testFundingDeadlineAndMinimumUnitsRollBackWithoutTakingTokens() public {
        _migrateContributor();
        vm.startPrank(contributor);
        vm.expectRevert(Liquidity.DeadlinePassed.selector);
        locker.fundInitialLiquidity(1, block.timestamp - 1);
        vm.expectRevert(Liquidity.BelowMinimum.selector);
        locker.fundInitialLiquidity(type(uint256).max, block.timestamp);
        vm.stopPrank();
        assertEq(core.token().balanceOf(contributor), INITIAL);
        assertFalse(locker.initialLiquidityFunded());
        assertEq(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }
}
