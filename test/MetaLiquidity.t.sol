// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { MockHooks } from "v4-core/test/MockHooks.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract MetaLiquidityTest is SzrWorld {
    function _newPool(uint24 fee, IHooks hooks) internal returns (uint256 id) {
        Liquidity.PoolConfig memory config = _config();
        config.feePips = fee;
        config.hooks = hooks;
        FeeCollector.AssetConfig memory unused;
        return locker.addPool(config, unused);
    }

    function testMigrationPreservesFloorAndDoesNotIssueTokens() public {
        uint256 units = locker.liquidityHeld(0);
        uint256 id = _newPool(500, IHooks(address(0)));
        uint256 nav = core.NAV();
        uint256 inventory = core.publicInventory();
        uint256 credit = core.releaseCredit();
        uint256 released = core.totalReleased();
        uint256 managerTokens = core.token().balanceOf(address(this));
        uint256 managerWeth = backing.balanceOf(address(this));
        locker.moveLiquidity(
            Liquidity.Move(
                0,
                id,
                units,
                units / 2,
                1,
                1,
                Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
            )
        );
        assertEq(locker.liquidityHeld(0), 0);
        assertEq(locker.liquidityHeld(id), units / 2);
        assertEq(core.NAV(), nav);
        assertEq(core.publicInventory(), inventory);
        assertEq(core.releaseCredit(), credit);
        assertEq(core.totalReleased(), released);
        assertEq(core.token().balanceOf(address(this)), managerTokens);
        assertEq(backing.balanceOf(address(this)), managerWeth);
        _assertCash();
    }

    function testMigrationFailureRollsBackEverything() public {
        uint256 units = locker.liquidityHeld(0);
        uint256 id = _newPool(500, IHooks(address(0)));
        uint256 held = locker.heldPrincipal(address(backing));
        Liquidity.Move memory request = Liquidity.Move(
            0, id, units, units / 2, 1, 1, Liquidity.Bounds(0, 0, block.timestamp)
        );
        vm.expectRevert(Liquidity.AboveMaximum.selector);
        locker.moveLiquidity(request);
        assertEq(locker.liquidityHeld(0), units);
        assertEq(locker.liquidityHeld(id), 0);
        assertEq(locker.heldPrincipal(address(backing)), held);
        _assertCash();
    }

    function testOnlyManagerCanReallocate() public {
        uint256 units = locker.liquidityHeld(0);
        Liquidity.Bounds memory bounds = Liquidity.Bounds(1e18, 1e18, block.timestamp);
        PoolKey memory pool = locker.key(0);
        vm.startPrank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.withdrawPrincipal(0, units, 0, 0, block.timestamp);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.deployPrincipal(0, units, bounds);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.swapPrincipal(pool, true, 1, 0, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        vm.stopPrank();
    }

    function testSlippageDeadlineAndRepeatedRemovalAreRejected() public {
        uint256 units = locker.liquidityHeld(0);
        vm.expectRevert(Liquidity.BelowMinimum.selector);
        locker.withdrawPrincipal(0, units, type(uint256).max, 0, block.timestamp);
        vm.expectRevert(Liquidity.DeadlinePassed.selector);
        locker.withdrawPrincipal(0, units, 0, 0, block.timestamp - 1);
        locker.withdrawPrincipal(0, units, 0, 0, block.timestamp);
        vm.expectRevert(Liquidity.InvalidUnits.selector);
        locker.withdrawPrincipal(0, units, 0, 0, block.timestamp);
        _assertCash();
    }

    function testMovingLiquidityCannotActivateUnreleasedTokens() public {
        uint256 id = 0;
        uint256 before = locker.liquidityHeld(id);
        uint256 supply = core.activeSupply();
        uint256 inventory = core.unreleasedSupply();
        locker.withdrawPrincipal(id, before / 100, 0, 0, block.timestamp);
        assertEq(locker.liquidityHeld(id), before - before / 100);
        assertEq(core.activeSupply(), supply);
        assertEq(core.unreleasedSupply(), inventory);
        vm.prank(address(core));
        (bool success,) = address(locker)
            .call(
                abi.encodeWithSignature("seed(uint256,uint256)", uint256(1e18), block.timestamp)
            );
        assertFalse(success);
        _assertCash();
    }

    function testNativeHookPositionCanBeFundedAndUnwound() public {
        MockHooks implementation = new MockHooks();
        address hook = address(uint160(Hooks.BEFORE_INITIALIZE_FLAG));
        vm.etch(hook, address(implementation).code);
        uint256 id = _newPool(500, IHooks(hook));
        assertEq(MockHooks(hook).beforeInitializeData().length, 123);
        locker.deployPrincipal(
            id, 1e10, Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
        assertEq(address(locker.key(id).hooks), hook);
        locker.withdrawPrincipal(id, 1e10, 0, 0, block.timestamp);
        assertEq(locker.liquidityHeld(id), 0);
        _assertCash();
    }

    function testSwapSpendsOnlyTreasuryFundsAndHonorsSlippage() public {
        PoolKey memory pool = locker.key(0);
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(backing);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        uint256 input = locker.heldPrincipal(address(backing)) / 10;
        uint256 cash = core.reserveCash();
        uint256 inventory = core.unreleasedSupply();
        uint256 beforeTokens = locker.heldPrincipal(address(core.token()));
        vm.expectRevert(Liquidity.BelowMinimum.selector);
        locker.swapPrincipal(pool, zeroForOne, input, type(uint256).max, limit, block.timestamp);
        (uint256 spent, uint256 received) =
            locker.swapPrincipal(pool, zeroForOne, input, 1, limit, block.timestamp);
        assertEq(spent, input);
        assertGt(received, 0);
        assertEq(locker.heldPrincipal(address(core.token())), beforeTokens + received);
        assertEq(core.reserveCash(), cash);
        assertEq(core.unreleasedSupply(), inventory);
        _assertCash();
    }

    function testCallbackCannotBeForgedOrReplayed() public {
        vm.expectRevert(Liquidity.NotPoolManager.selector);
        locker.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(Liquidity.UnexpectedCallback.selector);
        locker.unlockCallback("");
    }

    function testFeesRecycleTokensAndSplitWethWithoutSpendingPrincipal() public {
        _swap(alice, address(core.token()), 100e18);
        _swap(alice, address(backing), 100e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 ownPrincipal = locker.heldPrincipal(address(core.token()));
        uint256 cashPrincipal = locker.heldPrincipal(address(backing));
        uint256 reserves = core.reserveCash();
        uint256 team = core.economics().claimableFees();
        locker.collect(0);
        uint256 teamGain = core.economics().claimableFees() - team;
        uint256 reservesGain = core.reserveCash() - reserves;
        assertGt(teamGain, 0);
        assertEq(teamGain, (teamGain + reservesGain) * 3_300 / 10_000);
        assertGt(core.unreleasedSupply(), inventory);
        assertEq(locker.heldPrincipal(address(core.token())), ownPrincipal);
        assertEq(locker.heldPrincipal(address(backing)), cashPrincipal);
        _assertCash();
    }

    function _externalRoute(TestAsset other) internal returns (PoolKey memory route) {
        bool first = address(backing) < address(other);
        route = PoolKey(
            Currency.wrap(first ? address(backing) : address(other)),
            Currency.wrap(first ? address(other) : address(backing)),
            500,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        other.mint(bob, 1e18);
        vm.startPrank(bob);
        other.approve(address(provider), type(uint256).max);
        backing.approve(address(provider), type(uint256).max);
        provider.modifyLiquidity(
            route,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e18), bytes32(0)
            ),
            ""
        );
        vm.stopPrank();
    }

    function testTreasuryCanAcquireANewPartnerThroughAnExternalV4Pool() public {
        TestAsset other = _registerFeeAsset();
        PoolKey memory route = _externalRoute(other);
        bool zeroForOne = Currency.unwrap(route.currency0) == address(backing);
        uint256 nav = core.NAV();
        uint256 issued = core.totalReleased();
        locker.swapPrincipal(
            route,
            zeroForOne,
            locker.heldPrincipal(address(backing)) / 4,
            1,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        locker.deployPrincipal(
            1, 1e10, Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
        assertEq(locker.liquidityHeld(1), 1e10);
        assertEq(core.NAV(), nav);
        assertEq(core.totalReleased(), issued);
        assertEq(other.balanceOf(address(locker)), locker.heldPrincipal(address(other)));
        _assertCash();
    }

    function testFuzzWithdrawRedeployConservesPrincipal(uint128 raw) public {
        uint256 units = locker.liquidityHeld(0);
        uint256 removed = bound(raw, 10_000, units);
        uint256 id = _newPool(500, IHooks(address(0)));
        uint256 nav = core.NAV();
        locker.withdrawPrincipal(0, removed, 0, 0, block.timestamp);
        locker.deployPrincipal(
            id,
            removed / 2,
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
        assertEq(locker.liquidityHeld(id), removed / 2);
        assertEq(core.NAV(), nav);
        _assertCash();
    }
}
