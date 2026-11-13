// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrCore } from "../src/SzrCore.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { SzrMigration } from "../src/SzrMigration.sol";
import { LaunchWorld } from "./utils/LaunchWorld.sol";

/// @notice Edge cases around the launch sequence that the lifecycle run does not reach.
contract LaunchEdgesTest is LaunchWorld {
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
}
