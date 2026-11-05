// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { DeploySzr } from "../script/DeploySzr.s.sol";
import { Test } from "forge-std/Test.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { SzrMigration, ILegacySzrHook } from "../src/SzrMigration.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { LegacyMigrationHook, LegacyMigrationToken } from "./utils/LegacyMigrationHook.sol";

contract SzrMigrationTest is Test {
    TestAsset internal backing;
    SzrCore internal core;
    Liquidity internal locker;
    IPoolManager internal manager;
    LegacyMigrationHook internal oldHook;
    LegacyMigrationToken internal oldToken;
    SzrMigration internal migrator;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    uint256 internal constant ALLOCATION = 350_000_000e18;

    function setUp() public {
        backing = new TestAsset();
        core = SzrCore(
            deployCode(
                "SzrCore.sol:SzrCore",
                abi.encode(
                    address(backing),
                    uint256(1e12),
                    address(this),
                    SzrCore.AuctionConfig(4e12, 1, 20_000e18)
                )
            )
        );
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        FeeCollector jar = new FeeCollector(core);
        locker = new Liquidity(core, jar, manager, address(this));
        core.initialize(address(locker), address(jar));
        _legacy();
        migrator = new SzrMigration(core, address(oldToken), ILegacySzrHook(address(oldHook)));
        core.configureMigration(address(migrator), ALLOCATION, 0);
        core.launch();
        backing.approve(address(core), type(uint256).max);
        oldToken.mint(alice, 400_000_000e18);
        oldToken.mint(bob, 400_000_000e18);
        vm.prank(alice);
        oldToken.approve(address(migrator), type(uint256).max);
        vm.prank(bob);
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
        PoolKey memory key = PoolKey(
            Currency.wrap(first ? address(oldToken) : address(backing)),
            Currency.wrap(first ? address(backing) : address(oldToken)),
            0,
            60,
            IHooks(address(oldHook))
        );
        manager.initialize(key, uint160(1 << 96));
        backing.mint(address(oldHook), 10_000e18);
    }

    function testAtomicOneForOneUsesRecoveredWethAndPreservesFloor() public {
        uint256 amount = 10_000e18;
        uint256 nav = core.NAV();
        uint256 reserves = core.reserveCash();
        uint256 oldSupply = oldToken.totalSupply();
        (uint256 recovered, uint256 required, bool covered) = migrator.quote(amount);
        assertTrue(covered);
        assertGe(recovered, required);
        vm.prank(alice);
        assertEq(migrator.migrate(amount, recovered, block.timestamp), recovered);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(oldToken.balanceOf(alice), 400_000_000e18 - amount);
        assertEq(oldToken.totalSupply(), oldSupply - amount);
        assertEq(core.reserveCash(), reserves + recovered);
        assertEq(backing.balanceOf(alice), 0);
        assertEq(backing.balanceOf(address(migrator)), 0);
        assertEq(oldToken.balanceOf(address(migrator)), 0);
        assertEq(backing.allowance(address(migrator), address(core)), 0);
        assertEq(core.economics().claimableFees(), 0);
        assertEq(locker.heldPrincipal(address(backing)), 0);
        assertGe(core.NAV(), nav);
        _accounting(amount);
    }

    function testMigrationIsReservedAndDoesNotConsumeOrCreateSaleAllowance() public {
        vm.warp(core.auctionsOpenAt() + 3 days);
        uint256 available = core.availableRelease();
        uint256 credit = core.releaseCredit();
        uint256 publicInventory = core.publicInventory();
        uint256 price = core.price();
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        assertEq(core.publicInventory(), publicInventory);
        assertEq(core.availableRelease(), available);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.totalReleased(), 0);
        assertGe(core.price(), price);
        _accounting(1_000e18);
    }

    function testRepeatedPartialMigrationsPayOnlyTheirOwners() public {
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        vm.prank(bob);
        migrator.migrate(2_000e18, 0, block.timestamp);
        vm.prank(alice);
        migrator.migrate(3_000e18, 0, block.timestamp);
        assertEq(core.token().balanceOf(alice), 4_000e18);
        assertEq(core.token().balanceOf(bob), 2_000e18);
        assertEq(core.token().balanceOf(address(this)), 0);
        _accounting(6_000e18);
    }

    function testBelowNavMigrationAcceptsActualHookProceeds() public {
        oldHook.setPrice(1e10);
        uint256 amount = 1_000e18;
        uint256 oldBalance = oldToken.balanceOf(alice);
        uint256 oldReserves = backing.balanceOf(address(oldHook));
        uint256 newReserves = core.reserveCash();
        uint256 supply = core.activeSupply();
        uint256 nav = core.NAV();
        (uint256 recovered, uint256 required, bool covered) = migrator.quote(amount);
        assertFalse(covered);
        assertLt(recovered, required);
        vm.prank(alice);
        assertEq(migrator.migrate(amount, 0, block.timestamp), recovered);
        assertEq(oldToken.balanceOf(alice), oldBalance - amount);
        assertEq(backing.balanceOf(address(oldHook)), oldReserves - recovered);
        assertEq(core.reserveCash(), newReserves + recovered);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(core.NAV(), (newReserves + recovered) * 1e18 / (supply + amount));
        assertLt(core.NAV(), nav);
        _accounting(amount);
    }

    function testDeadlineSlippageAndZeroAmountAreAtomic() public {
        vm.startPrank(alice);
        vm.expectRevert(SzrMigration.InvalidAmount.selector);
        migrator.migrate(0, 0, block.timestamp);
        vm.expectRevert(SzrMigration.DeadlinePassed.selector);
        migrator.migrate(1e18, 0, block.timestamp - 1);
        vm.expectRevert(SzrMigration.BelowMinimum.selector);
        migrator.migrate(1_000e18, type(uint256).max, block.timestamp);
        vm.stopPrank();
        assertEq(oldHook.sold(), 0);
        _accounting(0);
    }

    function testAllocationCannotBeOverdrawnOrSoldTwice() public {
        vm.prank(alice);
        migrator.migrate(ALLOCATION, 0, block.timestamp);
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.publicInventory(), core.unreleasedSupply());
        vm.prank(bob);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(1e18, 0, block.timestamp);
        assertEq(oldToken.balanceOf(bob), 400_000_000e18);
        _accounting(ALLOCATION);
    }

    function testOnlyBoundMigratorCanReleaseReservedInventory() public {
        vm.prank(alice);
        vm.expectRevert(SzrCore.NotMigration.selector);
        core.releaseMigration(alice, 1e18, 1e18);
        vm.expectRevert(SzrCore.AlreadyLaunched.selector);
        core.configureMigration(address(migrator), 1e18, 0);
        vm.prank(address(migrator));
        vm.expectRevert(SzrCore.InsufficientInventory.selector);
        core.releaseMigration(alice, ALLOCATION + 1, 0);
        _accounting(0);
    }

    function testUnauthenticatedAndReplayedCallbacksCannotSellTokens() public {
        vm.expectRevert(SzrMigration.InvalidCallback.selector);
        migrator.unlockCallback(abi.encode(1e18));
        vm.prank(address(manager));
        vm.expectRevert(SzrMigration.InvalidCallback.selector);
        migrator.unlockCallback(abi.encode(1e18));
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        vm.prank(address(manager));
        vm.expectRevert(SzrMigration.InvalidCallback.selector);
        migrator.unlockCallback(abi.encode(1_000e18));
        _accounting(1_000e18);
    }

    function testLegacyHookCannotReenterMigration() public {
        oldHook.setReentry(address(migrator));
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        assertFalse(oldHook.reentrySucceeded());
        _accounting(1_000e18);
    }

    function testTaxedLegacyTransfersCannotReceiveFullNewTokens() public {
        oldToken.setTaxed(true);
        vm.prank(alice);
        vm.expectRevert(SzrMigration.TransferAmountMismatch.selector);
        migrator.migrate(1_000e18, 0, block.timestamp);
        assertEq(oldToken.balanceOf(alice), 400_000_000e18);
        _accounting(0);
    }

    function testDonatedDustIsExcludedFromMigrationProceeds() public {
        backing.mint(address(migrator), 1_000e18);
        oldToken.mint(address(migrator), 1_000e18);
        oldHook.setPrice(1e10);
        uint256 reserves = core.reserveCash();
        (uint256 recovered,,) = migrator.quote(1_000e18);
        vm.prank(alice);
        vm.expectRevert(SzrMigration.BelowMinimum.selector);
        migrator.migrate(1_000e18, recovered + 1, block.timestamp);
        vm.prank(alice);
        migrator.migrate(1_000e18, recovered, block.timestamp);
        assertEq(core.reserveCash(), reserves + recovered);
        assertEq(backing.balanceOf(address(migrator)), 1_000e18);
        assertEq(oldToken.balanceOf(address(migrator)), 1_000e18);
        _accounting(1_000e18);
    }

    function testCoreIndependentlyVerifiesReceivedBacking() public {
        vm.prank(address(migrator));
        vm.expectRevert();
        core.releaseMigration(alice, 1_000e18, 1e18);
        _accounting(0);
    }

    function testLegacyAndManagerCodeArePinned() public {
        bytes memory originalCode = address(oldHook).code;
        vm.etch(address(oldHook), hex"00");
        vm.prank(alice);
        vm.expectRevert(SzrMigration.CodeChanged.selector);
        migrator.migrate(1_000e18, 0, block.timestamp);
        vm.etch(address(oldHook), originalCode);
        originalCode = address(manager).code;
        vm.etch(address(manager), hex"00");
        vm.prank(alice);
        vm.expectRevert(SzrMigration.CodeChanged.selector);
        migrator.migrate(1_000e18, 0, block.timestamp);
        vm.etch(address(manager), originalCode);
        _accounting(0);
    }

    function testRedeemingMigratedTokensRecyclesThemIntoPublicInventory() public {
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        uint256 inventory = core.publicInventory();
        uint256 remaining = core.migrationRemaining();
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        core.redeem(1_000e18, 0);
        vm.stopPrank();
        assertEq(core.publicInventory(), inventory + 1_000e18);
        assertEq(core.migrationRemaining(), remaining);
        assertEq(core.totalReleased(), 0);
        _accounting(1_000e18);
    }

    function testFuzzSplitMigrationsConserveSupplyAndActualBacking(uint96 raw, uint64 rawPrice)
        public
    {
        uint256 amount = bound(uint256(raw), 1e18, 1_000_000e18);
        uint256 price = bound(uint256(rawPrice), 1e6, 1e15);
        oldHook.setPrice(price);
        uint256 oldSupply = oldToken.totalSupply();
        uint256 reserves = core.reserveCash();
        uint256 supply = core.activeSupply();
        uint256 first = amount / 3;
        uint256 grossFirst = first * price / 1e18;
        uint256 grossSecond = (amount - first) * price / 1e18;
        uint256 expected = grossFirst - (grossFirst + 99) / 100;
        expected += grossSecond - (grossSecond + 99) / 100;
        vm.startPrank(alice);
        uint256 recovered = migrator.migrate(first, 0, block.timestamp);
        recovered += migrator.migrate(amount - first, 0, block.timestamp);
        vm.stopPrank();
        assertEq(recovered, expected);
        assertEq(oldToken.totalSupply(), oldSupply - amount);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(core.reserveCash(), reserves + expected);
        assertEq(core.NAV(), (reserves + expected) * 1e18 / (supply + amount));
        _accounting(amount);
    }

    function testDeploymentHasNoGenesisAllocationAndMigrationEstablishesBacking() public {
        DeploySzr.Config memory config;
        config.chainId = block.chainid;
        config.asset = address(backing);
        config.poolManager = address(manager);
        config.teamBeneficiary = address(this);
        config.legacyToken = address(oldToken);
        config.marketPrice = 4e12;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = ALLOCATION;
        config.initialLiquidityTokens = 0;
        config.auction = SzrCore.AuctionConfig(8e12, 1, 20_000e18);
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (SzrCore deployed,,) = deployment.run(config);
        SzrMigration migration = SzrMigration(deployed.migration());
        assertEq(address(migration.core()), address(deployed));
        assertEq(migration.legacyToken(), address(oldToken));
        assertEq(address(migration.legacyHook()), address(oldHook));
        assertEq(deployed.migrationRemaining(), ALLOCATION);
        assertEq(deployed.publicInventory(), deployed.unreleasedSupply() - ALLOCATION);
        assertEq(deployed.publicInventory(), 650_000_000e18);
        assertEq(deployed.activeSupply(), 0);
        assertEq(deployed.token().balanceOf(address(deployed)), 1_000_000_000e18);
        assertEq(deployed.reserveCash(), 0);
        vm.startPrank(alice);
        oldToken.approve(address(migration), 1_000e18);
        migration.migrate(1_000e18, 0, block.timestamp);
        vm.stopPrank();
        assertEq(deployed.token().balanceOf(alice), 1_000e18);
        assertGt(deployed.reserveCash(), 0);
        assertEq(deployed.activeSupply(), 1_000e18);
        assertEq(deployed.NAV(), deployed.reserveCash() * 1e18 / 1_000e18);
        assertEq(deployed.totalReleased(), 0);
        assertEq(deployed.releaseCredit(), 0);
    }

    function testPublicAuctionCannotConsumeReservedMigrationTokens() public {
        vm.warp(core.auctionsOpenAt() + 20 * 365 days);
        uint256 inventory = core.publicInventory();
        assertEq(core.availableRelease(), inventory);
        vm.expectRevert(SzrCore.ReleaseLimit.selector);
        core.quote(inventory + 1);
        // Drain through bounded fills and normal decay, preserving the curve's numeric guard.
        while (core.publicInventory() != 0) {
            uint256 amount = core.publicInventory();
            if (amount > 1_000_000e18) amount /= 2;
            (uint256 payment,,) = core.quote(amount);
            backing.mint(address(this), payment);
            core.buy(amount, payment, block.timestamp);
            vm.warp(block.timestamp + 2 days);
        }
        assertEq(core.publicInventory(), 0);
        assertEq(core.unreleasedSupply(), ALLOCATION);
        assertEq(core.migrationRemaining(), ALLOCATION);
        uint256 credit = core.releaseCredit();
        vm.prank(alice);
        migrator.migrate(1_000e18, 0, block.timestamp);
        assertEq(core.publicInventory(), 0);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.migrationRemaining(), ALLOCATION - 1_000e18);
        assertEq(core.token().balanceOf(alice), 1_000e18);
    }

    function testConfigCannotBeReplacedOrReserveMoreThanSupply() public {
        SzrCore fresh = SzrCore(
            deployCode(
                "SzrCore.sol:SzrCore",
                abi.encode(
                    address(backing),
                    uint256(1e12),
                    address(this),
                    SzrCore.AuctionConfig(4e12, 1, 20_000e18)
                )
            )
        );
        SzrMigration migration =
            new SzrMigration(fresh, address(oldToken), ILegacySzrHook(address(oldHook)));
        vm.prank(alice);
        vm.expectRevert(SzrCore.NotInitializer.selector);
        fresh.configureMigration(address(migration), ALLOCATION, 0);
        vm.expectRevert(SzrCore.InvalidModule.selector);
        fresh.configureMigration(address(migrator), ALLOCATION, 0);
        vm.expectRevert(SzrCore.ZeroAmount.selector);
        fresh.configureMigration(address(migration), 0, 0);
        vm.expectRevert(SzrCore.InsufficientInventory.selector);
        fresh.configureMigration(address(migration), 1_000_000_000e18 + 1, 0);
        fresh.configureMigration(address(migration), ALLOCATION, 0);
        vm.expectRevert(SzrCore.MigrationAlreadyConfigured.selector);
        fresh.configureMigration(address(migration), ALLOCATION, 0);
        vm.prank(alice);
        vm.expectRevert(SzrMigration.NotLaunched.selector);
        migration.migrate(1e18, 0, block.timestamp);
    }

    function testCoreAcceptsActualProceedsOneWeiBelowNav() public {
        uint256 amount = 1e18;
        uint256 recovered = core.backingRequired(amount) - 1;
        uint256 reserves = core.reserveCash();
        uint256 inventory = core.publicInventory();
        backing.mint(address(migrator), recovered);
        vm.prank(address(migrator));
        backing.approve(address(core), recovered);
        vm.prank(address(migrator));
        core.releaseMigration(alice, amount, recovered);
        assertEq(core.reserveCash(), reserves + recovered);
        assertEq(backing.balanceOf(address(core)), reserves + recovered);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(core.migrationRemaining(), ALLOCATION - amount);
        assertEq(core.publicInventory(), inventory);
    }

    function testMismatchedLegacyHookOrBackingAssetCannotBeBound() public {
        address newToken = address(core.token());
        vm.expectRevert(SzrMigration.InvalidLegacy.selector);
        new SzrMigration(core, newToken, ILegacySzrHook(address(oldHook)));
        vm.mockCall(
            address(oldHook), abi.encodeCall(ILegacySzrHook.weth, ()), abi.encode(alice)
        );
        vm.expectRevert(SzrMigration.InvalidLegacy.selector);
        new SzrMigration(core, address(oldToken), ILegacySzrHook(address(oldHook)));
    }

    function testFuzzMigrationThenBorrowAndSalePreservesCashAccounting(uint96 raw) public {
        vm.prank(bob);
        migrator.migrate(10_000e18, 0, block.timestamp);
        oldHook.setPrice(1e10);
        uint256 amount = bound(uint256(raw), 1e18, 1_000_000e18);
        vm.prank(alice);
        migrator.migrate(amount, 0, block.timestamp);
        core.closeMigration();
        uint256 nav = core.NAV();
        uint256 debt = core.backingRequired(5_000e18) / 2;
        vm.startPrank(bob);
        core.token().approve(address(core), type(uint256).max);
        core.borrow(5_000e18, debt);
        vm.stopPrank();
        vm.warp(core.auctionsOpenAt() + 2 days);
        (uint256 payment,,) = core.quote(1_000e18);
        backing.mint(address(this), payment);
        core.buy(1_000e18, payment, block.timestamp);
        assertEq(core.loanPrincipal(), debt);
        assertGe(core.NAV(), nav);
        assertEq(core.token().balanceOf(alice), amount);
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.publicInventory(), core.unreleasedSupply());
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
        assertEq(
            core.token().balanceOf(address(core)),
            core.unreleasedSupply() + core.pledgedSupply()
        );
    }

    function testBorrowingCannotOpenDuringMigration() public {
        vm.prank(alice);
        migrator.migrate(10_000e18, 0, block.timestamp);
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        vm.expectRevert(SzrCore.MigrationOpen.selector);
        core.borrow(5_000e18, 1e12);
        vm.stopPrank();
        assertEq(core.loanPrincipal(), 0);
        assertEq(core.pledgedSupply(), 0);
        _accounting(10_000e18);
    }

    function testClosingMigrationUnreservesInventoryWithoutCreatingCreditOrChangingNav()
        public
    {
        vm.prank(alice);
        migrator.migrate(10_000e18, 0, block.timestamp);
        vm.warp(core.auctionsOpenAt() + 3 days);
        uint256 inventory = core.publicInventory();
        uint256 unused = core.migrationRemaining();
        uint256 credit = core.releaseCredit();
        uint256 nav = core.NAV();
        uint256 supply = core.activeSupply();
        uint256 initializerTokens = core.token().balanceOf(address(this));
        core.closeMigration();
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.publicInventory(), inventory + unused);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.NAV(), nav);
        assertEq(core.activeSupply(), supply);
        assertEq(core.totalReleased(), 0);
        assertEq(core.token().balanceOf(address(this)), initializerTokens);
        assertEq(core.token().balanceOf(address(core)), core.unreleasedSupply());
        vm.prank(alice);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(1e18, 0, block.timestamp);
    }

    function testOnlyInitializerCanCloseMigrationAndItCannotReopen() public {
        vm.prank(alice);
        vm.expectRevert(SzrCore.NotInitializer.selector);
        core.closeMigration();
        assertEq(core.migrationRemaining(), ALLOCATION);
        core.closeMigration();
        vm.expectRevert(SzrCore.MigrationNotOpen.selector);
        core.closeMigration();
        vm.expectRevert(SzrCore.AlreadyLaunched.selector);
        core.configureMigration(address(migrator), ALLOCATION, 0);
        assertEq(core.migrationRemaining(), 0);
    }

    function testExhaustingAllocationAutomaticallyEnablesBorrowing() public {
        vm.prank(alice);
        migrator.migrate(ALLOCATION, 0, block.timestamp);
        uint256 debt = core.backingRequired(10_000e18) / 2;
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        core.borrow(10_000e18, debt);
        vm.stopPrank();
        assertEq(core.migrationRemaining(), 0);
        assertEq(core.loanPrincipal(), debt);
        assertEq(core.pledgedSupply(), 10_000e18);
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
    }

    function testBelowNavMigrationFinishesBeforeLoanSettlementBecomesPossible() public {
        vm.prank(bob);
        migrator.migrate(10_000e18, 0, block.timestamp);
        oldHook.setPrice(1e10);
        vm.prank(alice);
        migrator.migrate(100_000_000e18, 0, block.timestamp);
        core.closeMigration();
        uint256 debt = 10_000e18 * core.backingAmount() / core.activeSupply();
        vm.startPrank(bob);
        core.token().approve(address(core), type(uint256).max);
        core.borrow(10_000e18, debt);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(1_000e18, 0, block.timestamp);
        (,, uint256 expiresAt) = core.loans(bob);
        vm.warp(expiresAt);
        core.settleExpired(bob);
        (uint256 collateral, uint256 principal,) = core.loans(bob);
        assertEq(collateral, 0);
        assertEq(principal, 0);
        assertEq(core.loanPrincipal(), 0);
        assertEq(core.pledgedSupply(), 0);
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
    }

    function _accounting(uint256 migrated) internal view {
        assertEq(migrator.totalMigrated(), migrated);
        assertEq(core.migrationAllocation(), ALLOCATION);
        assertEq(core.migrationRemaining(), ALLOCATION - migrated);
        assertEq(core.publicInventory() + core.migrationRemaining(), core.unreleasedSupply());
        assertEq(core.token().totalSupply(), 1_000_000_000e18);
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
        assertEq(core.token().balanceOf(address(core)), core.unreleasedSupply());
        assertEq(oldHook.sold(), migrated);
    }
}
