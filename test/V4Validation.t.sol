// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

contract V4ValidationTest is SzrWorld {
    function testDuplicatePoolsCannotCreateSecondPositions() public {
        Liquidity.PoolConfig memory config = _config();
        FeeCollector.AssetConfig memory unused;
        vm.expectRevert(Liquidity.DuplicatePosition.selector);
        locker.addPool(config, unused);
        assertEq(locker.poolCount(), 1);
        _assertCash();
    }

    function testPoolRegistrationIsManagerOnly() public {
        Liquidity.PoolConfig memory config = _config();
        FeeCollector.AssetConfig memory unused;
        vm.prank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.addPool(config, unused);
    }

    function testInvalidAssetsAndHooksAreRejected() public {
        Liquidity.PoolConfig memory config = _config();
        FeeCollector.AssetConfig memory unused;
        config.partner = address(core.token());
        vm.expectRevert(Liquidity.InvalidAsset.selector);
        locker.addPool(config, unused);
        config.partner = alice;
        vm.expectRevert(Liquidity.InvalidAsset.selector);
        locker.addPool(config, unused);
        config.partner = address(backing);
        config.hooks = IHooks(alice);
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.addPool(config, unused);
    }

    function testFullRangeSpacingAndFeeBoundsAreEnforced() public {
        Liquidity.PoolConfig memory config = _config();
        FeeCollector.AssetConfig memory unused;
        config.tickSpacing = 0;
        vm.expectRevert(Liquidity.InvalidRange.selector);
        locker.addPool(config, unused);
        config = _config();
        config.tickLower++;
        vm.expectRevert(Liquidity.InvalidRange.selector);
        locker.addPool(config, unused);
        config = _config();
        config.tickLower += config.tickSpacing;
        vm.expectRevert(Liquidity.InvalidRange.selector);
        locker.addPool(config, unused);
        config = _config();
        config.feePips = 100_001;
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.addPool(config, unused);
        config.feePips = 0;
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.addPool(config, unused);
    }

    function testExistingPoolPriceMustMatchRegistrationInput() public {
        PoolKey memory pool = locker.key(0);
        pool.fee = 500;
        manager.initialize(pool, uint160((1 << 96) + 1));
        Liquidity.PoolConfig memory config = _config();
        config.feePips = 500;
        FeeCollector.AssetConfig memory unused;
        vm.expectRevert(Liquidity.InvalidPrice.selector);
        locker.addPool(config, unused);
        assertEq(locker.poolCount(), 1);
    }

    function testOnlyActualCoreFundingCanEnterTreasuryLedger() public {
        vm.expectRevert(Liquidity.NotCore.selector);
        locker.recordFunding(1);
        uint256 before = locker.heldPrincipal(address(backing));
        vm.prank(address(core));
        vm.expectRevert(Liquidity.AccountingMismatch.selector);
        locker.recordFunding(1);
        assertEq(locker.heldPrincipal(address(backing)), before);
        _assertCash();
    }

    function testHeldWethLeavesOnlyToADestinationAnnouncedSevenDaysAhead() public {
        address staking = address(0x57A);
        _acquire(alice);
        uint256 held = locker.heldPrincipal(address(backing));
        assertGt(held, 0);
        vm.startPrank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.announceDestination(staking);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.revokeDestination(staking);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.sendFunding(staking, 1);
        vm.stopPrank();
        vm.expectRevert(Liquidity.InvalidModule.selector);
        locker.announceDestination(address(locker));
        vm.expectRevert(Liquidity.InvalidModule.selector);
        locker.announceDestination(address(core));

        vm.expectRevert(Liquidity.DestinationNotReady.selector);
        locker.sendFunding(staking, 1); // never announced
        locker.announceDestination(staking);
        assertEq(locker.destinationReadyAt(staking), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(Liquidity.DestinationNotReady.selector);
        locker.sendFunding(staking, 1); // one second early
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Liquidity.MissingContribution.selector);
        locker.sendFunding(staking, held + 1);

        uint256 nav = core.NAV();
        uint256 reserves = core.reserveCash();
        uint256 szrHeld = locker.heldPrincipal(address(core.token()));
        locker.sendFunding(staking, held);
        assertEq(backing.balanceOf(staking), held);
        assertEq(locker.heldPrincipal(address(backing)), 0);
        assertEq(locker.heldPrincipal(address(core.token())), szrHeld);
        assertEq(core.NAV(), nav);
        assertEq(core.reserveCash(), reserves);
        _assertCash();

        locker.revokeDestination(staking);
        _acquire(alice);
        vm.expectRevert(Liquidity.DestinationNotReady.selector);
        locker.sendFunding(staking, 1); // revoked
        _assertCash();
    }

    function testUnknownPoolsAndZeroUnitsCannotConsumePrincipal() public {
        vm.expectRevert(Liquidity.UnknownPool.selector);
        locker.position(999);
        vm.expectRevert(Liquidity.InvalidUnits.selector);
        locker.quotePosition(0, 0);
        vm.expectRevert(Liquidity.InvalidUnits.selector);
        locker.withdrawPrincipal(0, 0, 0, 0, block.timestamp);
        _assertCash();
    }

    function testManagerNominationRequiresAcceptance() public {
        locker.nominateManager(alice);
        Liquidity.PoolConfig memory config = _config();
        FeeCollector.AssetConfig memory unused;
        vm.prank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.addPool(config, unused);
        vm.prank(bob);
        vm.expectRevert(Liquidity.NotNominee.selector);
        locker.acceptManager();
        vm.prank(alice);
        locker.acceptManager();
        assertEq(locker.manager(), alice);
        assertEq(locker.pendingManager(), address(0));
    }
}
