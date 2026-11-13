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
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract MetaLiquidityTest is SzrWorld {
    using PoolIdLibrary for PoolKey;

    function _newPool(uint24 fee, IHooks hooks) internal returns (uint256 id) {
        Liquidity.PoolConfig memory config = _config();
        config.feePips = fee;
        config.hooks = hooks;
        FeeCollector.AssetConfig memory unused;
        id = locker.addPool(config, unused);
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

    /// A third token paired with SZR, plus an outside WETH/USD pool to convert through.
    function _usdPools() internal returns (TestAsset usd, uint256 id, PoolKey memory route) {
        usd = new TestAsset();
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(usd);
        id = locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
        bool wethFirst = address(backing) < address(usd);
        route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(usd)),
            Currency.wrap(wethFirst ? address(usd) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        backing.mint(address(this), 1_000_000e18);
        usd.mint(address(this), 1_000_000e18);
        backing.approve(address(provider), type(uint256).max);
        usd.approve(address(provider), type(uint256).max);
        provider.modifyLiquidity(
            route,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1_000_000e18), 0
            ),
            ""
        );
        locker.registerRoute(route);
    }

    function _usdMove(uint256 id, uint256 units)
        internal
        view
        returns (Liquidity.Move memory move)
    {
        move = Liquidity.Move(
            0,
            id,
            units,
            units / 2,
            1,
            1,
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
    }

    function _wethToUsd(PoolKey memory route, uint256 amount, uint256 minimumOut)
        internal
        view
        returns (Liquidity.SwapRequest memory)
    {
        bool zeroForOne = Currency.unwrap(route.currency0) == address(backing);
        return Liquidity.SwapRequest(
            route,
            zeroForOne,
            amount,
            minimumOut,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// SZR/WETH to SZR/USD in one transaction: withdraw, convert the WETH, deploy.
    function testMoveBetweenDifferentPartnersWithOneAtomicSwap() public {
        (TestAsset usd, uint256 id, PoolKey memory route) = _usdPools();
        uint256 units = locker.liquidityHeld(0);
        uint256 nav = core.NAV();
        uint256 heldWeth = locker.heldPrincipal(address(backing));
        uint256 funding = locker.unallocatedFunding();
        assertGt(heldWeth, 0);
        // Asking to swap "everything" converts only the WETH this move withdrew.
        locker.moveLiquidityWithSwap(
            _usdMove(id, units), _wethToUsd(route, type(uint256).max, 1)
        );
        assertEq(locker.liquidityHeld(0), 0);
        assertEq(locker.liquidityHeld(id), units / 2);
        assertEq(locker.heldPrincipal(address(backing)), heldWeth); // earlier WETH untouched
        assertEq(locker.unallocatedFunding(), funding);
        assertEq(usd.balanceOf(address(locker)), locker.heldPrincipal(address(usd)));
        assertEq(core.NAV(), nav);
        _assertCash();
    }

    function testMoveWithSwapRollsBackAndIsRestricted() public {
        (TestAsset usd, uint256 id, PoolKey memory route) = _usdPools();
        uint256 units = locker.liquidityHeld(0);
        Liquidity.Move memory move = _usdMove(id, units);
        // A missed minimum on the swap undoes the withdrawal too.
        vm.expectRevert(Liquidity.BelowMinimum.selector);
        locker.moveLiquidityWithSwap(
            move, _wethToUsd(route, type(uint256).max, type(uint256).max)
        );
        assertEq(locker.liquidityHeld(0), units);
        assertEq(locker.liquidityHeld(id), 0);
        assertEq(locker.heldPrincipal(address(usd)), 0);
        // The swap input must be something this move withdrew.
        Liquidity.SwapRequest memory wrong = _wethToUsd(route, 1e18, 1);
        wrong.zeroForOne = !wrong.zeroForOne; // would sell USD, which the source never returned
        vm.expectRevert(Liquidity.InvalidUnits.selector);
        locker.moveLiquidityWithSwap(move, wrong);
        vm.prank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.moveLiquidityWithSwap(move, _wethToUsd(route, 1e18, 1));
        assertEq(locker.liquidityHeld(0), units);
        _assertCash();
    }

    /// Idle WETH becomes SZR/USD liquidity in one transaction: two swaps, then the deployment.
    function testManagerBatchesTwoSwapsAndADeploymentInOneCall() public {
        (TestAsset usd, uint256 id, PoolKey memory route) = _usdPools();
        _acquire(alice);
        uint256 idle = locker.heldPrincipal(address(backing));
        assertGt(idle, 0);
        PoolKey memory main = locker.key(0);
        bool wethFirst = Currency.unwrap(main.currency0) == address(backing);
        Liquidity.SwapRequest memory toUsd = _wethToUsd(route, idle / 4, 1);
        Liquidity.Bounds memory open =
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(
            locker.swapPrincipal,
            (route, toUsd.zeroForOne, idle / 4, 1, toUsd.sqrtPriceLimitX96, block.timestamp)
        );
        calls[1] = abi.encodeCall(
            locker.swapPrincipal,
            (
                main,
                wethFirst,
                idle / 4,
                1,
                wethFirst ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                block.timestamp
            )
        );
        calls[2] = abi.encodeCall(locker.deployPrincipal, (id, 1e12, open));

        // Only the manager's batch goes through; each inner call checks the caller itself.
        vm.prank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.multicall(calls);

        // If the last step fails, the swaps before it are undone as well.
        bytes[] memory failing = new bytes[](3);
        failing[0] = calls[0];
        failing[1] = calls[1];
        failing[2] = abi.encodeCall(locker.deployPrincipal, (id, type(uint128).max, open));
        vm.expectRevert(Liquidity.MissingContribution.selector);
        locker.multicall(failing);
        assertEq(locker.heldPrincipal(address(backing)), idle);
        assertEq(locker.heldPrincipal(address(usd)), 0);

        uint256 nav = core.NAV();
        locker.multicall(calls);
        assertEq(locker.liquidityHeld(id), 1e12);
        assertEq(locker.heldPrincipal(address(backing)), idle - idle / 4 - idle / 4);
        assertGt(locker.heldPrincipal(address(usd)), 0);
        assertEq(usd.balanceOf(address(locker)), locker.heldPrincipal(address(usd)));
        assertEq(core.NAV(), nav);
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
        locker.registerRoute(route);
    }

    /// An empty pool's price can be moved by anyone for free. The manager can now move it back
    /// and make the first deposit in one batch; a swap that spends nothing used to revert.
    function testManagerRestoresAnEmptyPoolsPriceAndDepositsInOneBatch() public {
        uint256 id = _newPool(500, IHooks(address(0)));
        PoolKey memory pool = locker.key(id);
        uint256 units = locker.liquidityHeld(0);
        locker.withdrawPrincipal(0, units / 2, 0, 0, block.timestamp);
        // A griefer with no tokens moves the empty pool far from its 1:1 price.
        PoolSwapTest.TestSettings memory settings;
        vm.prank(address(0x6121));
        swapper.swap(
            pool,
            IPoolManager.SwapParams(true, -1e18, TickMath.getSqrtPriceAtTick(-6_000)),
            settings,
            ""
        );
        Liquidity.Bounds memory tight = Liquidity.Bounds(
            locker.heldPrincipal(address(core.token())),
            locker.heldPrincipal(address(backing)),
            block.timestamp
        );
        uint256 deposit = units / 8;
        // At the moved price the same deposit would go in badly lopsided.
        (uint256 szrNeeded, uint256 wethNeeded) = locker.quotePosition(id, deposit);
        uint256 gap = szrNeeded > wethNeeded ? szrNeeded - wethNeeded : wethNeeded - szrNeeded;
        assertGt(gap, deposit / 4);
        // A swap that spent nothing used to revert, so the price could not be restored.

        uint256 heldWeth = locker.heldPrincipal(address(backing));
        uint256 heldSzr = locker.heldPrincipal(address(core.token()));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            locker.swapPrincipal, (pool, false, 1, 0, uint160(1 << 96), block.timestamp)
        );
        calls[1] = abi.encodeCall(locker.deployPrincipal, (id, deposit, tight));
        locker.multicall(calls);
        assertEq(locker.liquidityHeld(id), deposit);
        // The restoring swap spent nothing: both sides went into the position 1:1.
        assertApproxEqAbs(heldWeth - locker.heldPrincipal(address(backing)), deposit, 2);
        assertApproxEqAbs(heldSzr - locker.heldPrincipal(address(core.token())), deposit, 2);
        _assertCash();
    }

    /// Principal may only trade through a pool on the contract's list, and a pool the manager
    /// adds can take principal straight away.
    function testSwapsNeedARegisteredPoolAndNewPoolsAreUsableAtOnce() public {
        Liquidity.Bounds memory open =
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp);
        uint256 units = locker.liquidityHeld(0);
        locker.withdrawPrincipal(0, units / 2, 0, 0, block.timestamp);

        // A pool added now is on the list and takes principal in the same block.
        Liquidity.PoolConfig memory config = _config();
        config.feePips = 500;
        FeeCollector.AssetConfig memory unused;
        uint256 id = locker.addPool(config, unused);
        assertTrue(locker.poolRegistered(PoolId.unwrap(locker.key(id).toId())));
        locker.deployPrincipal(id, units / 8, open);
        assertEq(locker.liquidityHeld(id), units / 8);

        // A pool that is not on the list cannot be traded through, however it was created.
        TestAsset other = new TestAsset();
        bool first = address(backing) < address(other);
        PoolKey memory route = PoolKey(
            Currency.wrap(first ? address(backing) : address(other)),
            Currency.wrap(first ? address(other) : address(backing)),
            500,
            60,
            IHooks(address(0))
        );
        uint160 limit = first ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.registerRoute(route); // not even initialised
        manager.initialize(route, uint160(1 << 96));
        assertFalse(locker.poolRegistered(PoolId.unwrap(route.toId())));
        vm.expectRevert(Liquidity.PoolNotRegistered.selector);
        locker.swapPrincipal(route, first, 1e12, 0, limit, block.timestamp);
        vm.expectRevert(Liquidity.PoolNotRegistered.selector);
        locker.moveLiquidityWithSwap(
            Liquidity.Move(0, id, units / 8, units / 16, 1, 1, open),
            Liquidity.SwapRequest(route, first, 1e12, 0, limit)
        );
        // Only the manager can put a route on the list.
        vm.prank(alice);
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.registerRoute(route);
        locker.registerRoute(route);
        assertTrue(locker.poolRegistered(PoolId.unwrap(route.toId())));
        _assertCash();
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

    /// Real pool fees, not simulated receipts: after the manager updates a partner token's
    /// fee auction, collecting and withdrawing still record fees and the stock still sells.
    function testUpdatingAFeeAuctionLeavesCollectionWithdrawalAndSalesWorking() public {
        (TestAsset usd, uint256 id, PoolKey memory route) = _usdPools();
        locker.moveLiquidityWithSwap(
            _usdMove(id, locker.liquidityHeld(0)), _wethToUsd(route, type(uint256).max, 1)
        );
        _usdTrade(usd, id);
        locker.collect(id);
        uint256 stock = jar.auction(address(usd)).inventory;
        assertGt(stock, 0);

        jar.updateAsset(address(usd), FeeCollector.AssetConfig(1e18, stock * 2, 9e17));
        assertEq(jar.auction(address(usd)).inventory, stock);
        _usdTrade(usd, id);
        locker.withdrawPrincipal(id, locker.liquidityHeld(id) / 2, 0, 0, block.timestamp);
        uint256 grown = jar.auction(address(usd)).inventory;
        assertGt(grown, stock);
        _usdTrade(usd, id);
        locker.collect(id);
        grown = jar.auction(address(usd)).inventory;

        uint256 cost = jar.quote(address(usd), grown);
        assertGe(cost, grown * 9 / 10); // never below the floor of 0.9 WETH per token
        uint256 reserves = core.reserveCash();
        vm.prank(alice);
        jar.take(address(usd), grown, cost, block.timestamp);
        assertEq(usd.balanceOf(alice), grown);
        assertGt(core.reserveCash(), reserves);
        _assertCash();
    }

    function _usdTrade(TestAsset usd, uint256 id) internal {
        PoolKey memory pool = locker.key(id);
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(usd);
        address trader = address(0x7AD3);
        usd.mint(trader, 1e15);
        PoolSwapTest.TestSettings memory settings;
        vm.startPrank(trader);
        usd.approve(address(swapper), type(uint256).max);
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -1e15,
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
    }

    /// Why ranges should not end on the extreme usable ticks: v4 caps the liquidity that may
    /// reference one tick, and there the whole cap costs a stranger about 0.00002 WETH. This
    /// fixture's position ends on those ticks, and afterwards it can take no more liquidity.
    function testPoC_ExtremeTickRangesCanBeLockedOutForDust() public {
        PoolKey memory pool = locker.key(0);
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        address stranger = address(0x57A6);
        backing.mint(stranger, 1e18);
        uint256 units = locker.liquidityHeld(0);
        locker.withdrawPrincipal(0, units / 2, 0, 0, block.timestamp);

        bool wethFirst = Currency.unwrap(pool.currency0) == address(backing);
        int24 lower = wethFirst
            ? TickMath.maxUsableTick(pool.tickSpacing) - pool.tickSpacing
            : TickMath.minUsableTick(pool.tickSpacing);
        int24 end = wethFirst ? lower + pool.tickSpacing : lower;
        (uint128 used,) = StateLibrary.getTickLiquidity(manager, pool.toId(), end);
        uint128 room = Pool.tickSpacingToMaxLiquidityPerTick(pool.tickSpacing) - used;
        vm.startPrank(stranger);
        backing.approve(address(provider), type(uint256).max);
        provider.modifyLiquidity(
            pool,
            IPoolManager.ModifyLiquidityParams(
                lower, lower + pool.tickSpacing, int256(uint256(room)), 0
            ),
            ""
        );
        vm.stopPrank();
        assertLt(1e18 - backing.balanceOf(stranger), 1e15); // the lock cost under 0.001 WETH

        Liquidity.Bounds memory open =
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Pool.TickLiquidityOverflow.selector, end));
        locker.deployPrincipal(0, 1, open); // nothing can go back in
        locker.withdrawPrincipal(0, units / 4, 0, 0, block.timestamp); // getting out still works
        locker.collect(0);
        _assertCash();
    }
}
