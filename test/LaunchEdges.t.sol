// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrCore } from "../src/SzrCore.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { SzrMigration } from "../src/SzrMigration.sol";
import { LaunchWorld } from "./utils/LaunchWorld.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @notice Edge cases around the launch sequence that the lifecycle run does not reach.
contract LaunchEdgesTest is LaunchWorld {
    using StateLibrary for IPoolManager;

    /// Migration closed before anyone migrated: 25M live tokens, no reserves at all.
    function testSaleAndLoansWorkFromZeroBacking() public {
        _world(address(0x1000));
        vm.prank(team);
        core.closeMigration();
        assertEq(core.NAV(), 0);
        vm.warp(block.timestamp + 1 days);
        emit log_named_decimal_uint("price with zero backing", core.price(), 18);
        (uint256 payment, uint256 reserves, uint256 funding) = core.quote(100_000e18);
        assertGt(payment, 0);
        assertEq(reserves + funding, payment);
        vm.startPrank(alice);
        core.buy(100_000e18, payment, block.timestamp);
        assertGt(core.NAV(), 0);
        // A loan against tokens that now have backing, then a full exit.
        uint256 capacity = core.backingRequired(50_000e18) - 1;
        core.borrow(50_000e18, capacity);
        core.repayAndReclaim(capacity);
        uint256 paid = core.redeem(100_000e18, 0);
        vm.stopPrank();
        assertGt(paid, 0);
        _books();
    }

    /// With zero backing a loan has no capacity, and a 1-wei buy still works.
    function testZeroBackingHasNoLoanCapacityAndTinyBuysWork() public {
        _world(address(0x1000));
        vm.prank(team);
        core.closeMigration();
        vm.warp(block.timestamp + 30 days);
        (uint256 payment,,) = core.quote(1);
        vm.startPrank(alice);
        core.buy(1, payment, block.timestamp);
        vm.stopPrank();
        _poolSwap(bob, true, 1e18); // bob gets SZR from the pool; reserves are still ~nothing
        uint256 held = szr.balanceOf(bob);
        vm.startPrank(bob);
        vm.expectRevert(SzrCore.AboveNAV.selector);
        core.borrow(held, 1e15);
        vm.stopPrank();
        _books();
    }

    /// Funding left for later: migrators who are in when it lands are diluted at that
    /// moment, anyone can trigger it, and nothing reverts or is taken from the caller.
    function testLateGenesisFundingDilutesWhoeverIsInAtThatMoment() public {
        _world(address(0x1000), false);
        assertFalse(locker.initialLiquidityFunded());
        vm.prank(alice);
        uint256 recovered = migrator.migrate(100_000_000e18, 0, block.timestamp);
        uint256 navBefore = core.NAV();
        assertEq(navBefore, recovered * 1e18 / 100_000_000e18);
        vm.prank(bob); // bob holds no SZR and pays nothing
        uint256 spent = locker.fundInitialLiquidity(1, block.timestamp);
        assertEq(szr.balanceOf(bob), 0);
        assertEq(core.NAV(), recovered * 1e18 / (100_000_000e18 + spent));
        assertLt(core.NAV(), navBefore);
        vm.prank(alice);
        core.redeem(100_000_000e18, 0);
        _books();
    }

    /// Everyone leaves before genesis is funded, so supply returns to zero; funding and
    /// migration must still work afterwards.
    function testSupplyReturnsToZeroBeforeGenesisAndRecovers() public {
        _world(address(0x1000), false);
        vm.startPrank(alice);
        migrator.migrate(1_000_000e18, 0, block.timestamp);
        core.redeem(1_000_000e18, 0);
        vm.stopPrank();
        assertEq(core.activeSupply(), 0);
        assertEq(core.reserveCash(), 0);
        uint256 emptyNav = core.NAV(); // remembered from the last holder
        assertGt(emptyNav, 0);
        locker.fundInitialLiquidity(1, block.timestamp);
        assertEq(core.NAV(), 0);
        vm.prank(bob);
        uint256 recovered = migrator.migrate(2_000_000e18, 0, block.timestamp);
        assertEq(core.NAV(), recovered * 1e18 / core.activeSupply());
        vm.prank(team);
        core.closeMigration();
        vm.warp(block.timestamp + 2 days);
        (uint256 payment,,) = core.quote(1_000e18);
        vm.prank(carol);
        core.buy(1_000e18, payment, block.timestamp);
        _books();
    }

    /// Found by independent review: one actor migrating, redeeming and re-buying old SZR in
    /// a loop used to use up the whole allowance, closing migration for everyone and opening
    /// the sale without the team. A redeemed token now frees its slot.
    function testCyclingMigrateAndRedeemCannotUseUpTheAllowance() public {
        _world(address(0x1000));
        vm.prank(alice);
        migrator.migrate(100_000_000e18, 0, block.timestamp);
        address attacker = address(0xBAD);
        vm.startPrank(attacker);
        oldToken.approve(address(migrator), type(uint256).max);
        szr.approve(address(core), type(uint256).max);
        vm.stopPrank();
        uint256 inventory = core.publicInventory();
        for (uint256 cycle; cycle < 12; cycle++) {
            oldToken.mint(attacker, 50_000_000e18); // stands for re-buying old SZR
            vm.startPrank(attacker);
            uint256 brought = migrator.migrate(50_000_000e18, 0, block.timestamp);
            assertLt(core.redeem(50_000_000e18, 0), brought); // and every cycle loses money
            vm.stopPrank();
        }
        assertEq(core.migrationRemaining(), 250_000_000e18);
        assertEq(core.publicInventory(), inventory);
        assertEq(core.auctionsOpenAt(), 0);
        vm.prank(bob);
        migrator.migrate(50_000_000e18, 0, block.timestamp); // others can still migrate
        _books();
    }

    /// A freed slot never takes the reservation above the allowance: genesis tokens bought
    /// from the pool and donated while nobody has migrated go to the public sale.
    function testFreedSlotsNeverExceedTheAllowance() public {
        _world(address(0x1000));
        uint256 inventory = core.publicInventory();
        _poolSwap(carol, true, 1e18);
        uint256 bought = szr.balanceOf(carol);
        vm.prank(carol);
        core.donateSzr(bought);
        assertEq(core.migrationRemaining(), 350_000_000e18);
        assertEq(core.publicInventory(), inventory + bought);
        _books();
    }

    /// Found by independent review: someone holding enough migrated tokens could fill the
    /// allowance, which used to close migration for good and open the sale without the team.
    /// Filling it now ends nothing, and the manager can reserve more room.
    function testFillingTheAllowanceEndsNothingAndTheManagerCanExtendIt() public {
        _world(address(0x1000));
        oldToken.mint(alice, 230_000_000e18);
        vm.prank(alice);
        migrator.migrate(350_000_000e18 - 1, 0, block.timestamp);
        assertEq(core.migrationRemaining(), 1);
        assertEq(core.auctionsOpenAt(), 0);
        vm.prank(bob);
        vm.expectRevert(SzrMigration.InsufficientAllocation.selector);
        migrator.migrate(1e18, 0, block.timestamp);
        vm.prank(team);
        core.extendMigration(50_000_000e18);
        vm.prank(bob);
        migrator.migrate(40_000_000e18, 0, block.timestamp);
        vm.prank(team);
        core.closeMigration();
        assertEq(core.auctionsOpenAt(), block.timestamp);
        vm.warp(block.timestamp + 1 days);
        assertApproxEqRel(core.releaseCredit(), 1_000_000e18, 1e16);
        (uint256 payment,,) = core.quote(10_000e18);
        vm.prank(bob);
        core.buy(10_000e18, payment, block.timestamp);
        _books();
    }

    /// Buying everything on offer in one go, then again after a long idle period.
    function testBuyingAllAvailableAndAfterLongIdle() public {
        _world(address(0x1000));
        vm.prank(alice);
        migrator.migrate(100_000_000e18, 0, block.timestamp);
        vm.prank(team);
        core.closeMigration();
        vm.warp(block.timestamp + 12 hours);
        uint256 all = core.availableRelease();
        (uint256 payment,,) = core.quote(all);
        backing.mint(carol, payment);
        vm.prank(carol);
        core.buy(all, payment, block.timestamp);
        assertEq(core.availableRelease(), 0);
        vm.expectRevert(SzrCore.ReleaseLimit.selector);
        core.quote(1);
        vm.warp(block.timestamp + 20 * 365 days);
        all = core.availableRelease();
        assertEq(all, core.publicInventory()); // the schedule has outrun the inventory
        (payment,,) = core.quote(1_000_000e18);
        vm.prank(carol);
        core.buy(1_000_000e18, payment, block.timestamp);
        _books();
    }

    /// v4 caps the liquidity that may reference one tick, and whoever fills that cap locks
    /// everyone else out of ranges ending there. At the extreme usable ticks that costs dust.
    /// The script's range ends sit where it costs more SZR than exists or over a million
    /// WETH, for the genesis position and the wide position, whichever way the tokens sort.
    function testFix_ScriptRangeEndsCannotBeFilledToTheTickCap() public {
        _capCosts(address(0x1000));
    }

    function testFix_ScriptRangeEndsCannotBeFilledToTheTickCapOtherOrdering() public {
        _capCosts(address(uint160(type(uint160).max - 4096)));
    }

    function _capCosts(address asset) internal {
        _world(asset, false);
        Liquidity.Position memory genesis = locker.position(locker.INITIAL_POSITION());
        Liquidity.Position memory wide = locker.position(0);
        int24[4] memory ends =
            [genesis.tickLower, genesis.tickUpper, wide.tickLower, wide.tickUpper];
        // Checked at the pool's own spacing and at 60, the narrowest the script accepts.
        for (uint256 index; index < 4; index++) {
            _assertCostly(genesis.key, ends[index], genesis.key.tickSpacing);
            _assertCostly(genesis.key, ends[index], 60);
        }
        // Someone holding 100M SZR puts nearly all of it at the genesis range's far end, and
        // funding still goes through.
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        bool szrFirst = Currency.unwrap(genesis.key.currency0) == address(szr);
        int24 far = szrFirst ? genesis.tickUpper : genesis.tickLower;
        int24 lower = szrFirst ? far : far - genesis.key.tickSpacing;
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(lower + genesis.key.tickSpacing);
        uint256 perUnit = szrFirst
            ? SqrtPriceMath.getAmount0Delta(a, b, 1e18, true)
            : SqrtPriceMath.getAmount1Delta(a, b, 1e18, true);
        vm.startPrank(alice);
        migrator.migrate(100_000_000e18, 0, block.timestamp);
        szr.approve(address(provider), type(uint256).max);
        provider.modifyLiquidity(
            genesis.key,
            IPoolManager.ModifyLiquidityParams(
                lower,
                lower + genesis.key.tickSpacing,
                int256(99_000_000e18 * 1e18 / perUnit),
                0
            ),
            ""
        );
        vm.stopPrank();
        assertLt(szr.balanceOf(alice), 2_000_000e18);
        locker.fundInitialLiquidity(0, block.timestamp);
        assertTrue(core.initialLiquidityReleased());
        _books();
    }

    /// Filling the cap at `tick` means holding a one-spacing position on either side of it.
    /// Wherever the price sits, that takes one token, the other, or a mix; so both pure costs
    /// must be out of reach: more than ten times all SZR, and more than a million WETH.
    function _assertCostly(PoolKey memory pool, int24 tick, int24 spacing) internal view {
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(spacing);
        bool szrFirst = Currency.unwrap(pool.currency0) == address(szr);
        for (int24 lower = tick - spacing; lower <= tick; lower += spacing) {
            uint160 a = TickMath.getSqrtPriceAtTick(lower);
            uint160 b = TickMath.getSqrtPriceAtTick(lower + spacing);
            uint256 amount0 = SqrtPriceMath.getAmount0Delta(a, b, cap, true);
            uint256 amount1 = SqrtPriceMath.getAmount1Delta(a, b, cap, true);
            assertGt(szrFirst ? amount0 : amount1, 10 * szr.totalSupply());
            assertGt(szrFirst ? amount1 : amount0, 1_000_000e18);
        }
    }

    /// The genesis range cannot be registered a second time as an ordinary position, so no
    /// manager-controlled id can ever point at the permanent genesis liquidity.
    function testGenesisRangeCannotBeRegisteredAsAnOrdinaryPosition() public {
        _duplicate(address(0x1000));
    }

    function testGenesisRangeCannotBeRegisteredAsAnOrdinaryPositionOtherOrdering() public {
        _duplicate(address(uint160(type(uint160).max - 4096)));
    }

    function _duplicate(address asset) internal {
        _world(asset);
        Liquidity.Position memory genesis = locker.position(locker.INITIAL_POSITION());
        (uint160 current,,,) = manager.getSlot0(PoolIdLibrary.toId(genesis.key));
        Liquidity.PoolConfig memory config = Liquidity.PoolConfig(
            address(backing),
            genesis.key.fee,
            genesis.key.tickSpacing,
            genesis.tickLower,
            genesis.tickUpper,
            current,
            genesis.key.hooks
        );
        FeeCollector.AssetConfig memory unused;
        vm.prank(team);
        vm.expectRevert(Liquidity.DuplicatePosition.selector);
        locker.addPool(config, unused);
        // A different range in the same pool is its own position and holds nothing.
        config.tickLower -= genesis.key.tickSpacing;
        config.tickUpper += genesis.key.tickSpacing;
        vm.prank(team);
        uint256 id = locker.addPool(config, unused);
        assertEq(locker.liquidityHeld(id), 0);
        vm.prank(team);
        vm.expectRevert();
        locker.withdrawPrincipal(id, 1, 0, 0, block.timestamp);
        assertGt(locker.liquidityHeld(locker.INITIAL_POSITION()), 0);
    }
}
