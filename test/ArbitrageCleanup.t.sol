// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { EntryPart } from "../src/arbitrage/ArbitrageEntry.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";

/// @dev Marks a token as synced and pays it in inside one unlock, then has the probe run a
/// failed cycle with that payment waiting in the pool manager's sync slot.
contract SyncedPayer is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function run(
        ArbitrageProbe probe,
        TestAsset asset,
        uint256 amount,
        bytes32 poolId,
        ArbitrageLogic.Plan calldata plan
    ) external returns (uint256 used) {
        return abi.decode(
            manager.unlock(abi.encode(probe, asset, amount, poolId, abi.encode(plan))),
            (uint256)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            ArbitrageProbe probe,
            TestAsset asset,
            uint256 amount,
            bytes32 poolId,
            bytes memory raw
        ) = abi.decode(data, (ArbitrageProbe, TestAsset, uint256, bytes32, bytes));
        ArbitrageLogic.Plan memory plan = abi.decode(raw, (ArbitrageLogic.Plan));
        Currency currency = Currency.wrap(address(asset));
        manager.sync(currency);
        asset.transfer(address(manager), amount);
        uint256 used = probe.failedCycleCost(1, probe.token(), poolId, plan, address(this));
        // The probe's `_release` credited the payment to this contract. Take it back.
        manager.take(currency, address(this), amount);
        return abi.encode(used);
    }
}

/// @dev Fixes from the whole-hook review (`docs/specs/hook-review-cleanup.md`, part A).
contract ArbitrageCleanupTest is WrapWorld {
    // ----- A2: `track` follows the pricer trust rule -----

    /// A Liquidity position on a hook that has no pricer is never priced: another hook could
    /// do anything in the middle of a cycle. Once Liquidity's manager gives that hook a
    /// pricer it can be tracked.
    function testTrackRefusesAPoolOnAHookWithoutAPricer() public {
        WrappedPool foreign =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(foreign));
        TestAsset other = new TestAsset();
        _approve(other);
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(other);
        config.hooks = IHooks(address(foreign));
        uint256 position =
            locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.track(position);
        hook.setPricer(address(foreign), address(new WrappedPricer(foreign)));
        // A wrapped pool raises what the market must reserve, so the allowance goes first.
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        hook.track(position);
        assertTrue(hook.tracked(1, _id(locker.key(position))), "tracked with a pricer");
    }

    /// Listing a wrapped pool through `track` grows what a swap must bring, so it is refused
    /// once SZR's market, which is on, would pass the ceiling (`_wrap` checks it).
    function testTrackRefusesAWrappedPoolPastTheSwapCeiling() public {
        WrappedPool foreign =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(foreign));
        TestAsset other = new TestAsset();
        _approve(other);
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(other);
        config.hooks = IHooks(address(foreign));
        uint256 position =
            locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
        hook.setPricer(address(foreign), address(new WrappedPricer(foreign)));
        hook.setLimits(1, address(szr), 100_000_000, 10e18, 1.0001e18);
        hook.setSwapGasCeiling(hook.gasForSwap(1));
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.track(position);
        hook.setSwapGasCeiling(type(uint256).max);
        hook.track(position);
        assertTrue(hook.tracked(1, _id(locker.key(position))), "tracked under the ceiling");
    }

    // ----- A3: who may receive a profit token's share -----

    /// Core can only count WETH, so any other token sent to it would be locked. ETH is paid
    /// as WETH and is fine. A zero recipient still takes a token off the list.
    function testCoreReceivesOnlyEtherAndWeth() public {
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(usd), address(core));
        hook.setProfitToken(address(0), address(core));
        hook.setProfitToken(address(backing), address(core));
        hook.setProfitToken(address(usd), address(0));
        assertEq(hook.shareRecipient(address(usd)), address(0), "taken off");
        assertEq(hook.shareRecipient(address(0)), address(core), "ETH to Core");
    }

    /// Anything credited to the pool manager itself would be surplus nobody can claim.
    function testPoolManagerReceivesNothing() public {
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(usd), address(manager));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.openMarket(address(manager));
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setRecipient(id, address(manager));
    }

    // ----- A4: a pool is never both a connector and the venue of one route -----

    /// Home is ETH and the market also chooses WETH. A hookless WETH/Y pool leads Y under
    /// WETH and is also the pool that connects Y to WETH. With a WETH/X connector the way from
    /// that venue to the focus ETH/X pool runs through the venue itself. The cycle would trade
    /// it twice while the walk counts two independent legs, so there is no such route.
    function testAVenueIsNeverItsOwnRoute() public {
        TestAsset partnerX = new TestAsset();
        _approve(partnerX);
        TestAsset partnerY = new TestAsset();
        _approve(partnerY);
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(backing);
        vm.prank(team);
        hook.setTokens(id, tokens);
        _lead(address(backing), address(coin), new bytes32[](0));
        PoolKey memory focus = _make(address(0), address(partnerX), 3_000, address(hook));
        PoolKey memory toX = _make(address(backing), address(partnerX), 500, address(0));
        PoolKey memory both = _make(address(backing), address(partnerY), 500, address(0));
        vm.startPrank(team);
        hook.addVenue(id, both);
        hook.setConnector(id, toX, true);
        hook.setConnector(id, both, true);
        vm.stopPrank();
        _lead(address(0), address(partnerX), _list(_id(focus)));
        _lead(address(backing), address(partnerY), _list(_id(both)));
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
        _in(toX, address(partnerX), 100_000e18);
        vm.recordLogs();
        _in(focus, address(0), 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 tried;
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic != ArbitrageLogic.CycleFailed.selector) {
                if (topic != ArbitrageLogic.Arbitraged.selector) continue;
            }
            if (logs[index].topics[2] == _id(both)) tried++;
        }
        assertEq(tried, 0, "the venue was tried through itself");
    }

    // ----- B: the swap callbacks keep what the pool manager decodes -----

    /// The hook no longer inherits `IHooks`, so the compiler no longer checks its two swap
    /// callbacks against it. Their selectors, and what they return for a swap that is left
    /// alone (Liquidity's own), are pinned here.
    function testSwapCallbacksMatchIHooks() public {
        assertEq(EntryPart.beforeSwap.selector, IHooks.beforeSwap.selector, "before");
        assertEq(EntryPart.afterSwap.selector, IHooks.afterSwap.selector, "after");
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(true, -1, 1);
        vm.startPrank(address(manager));
        (bytes4 beforeSelector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(locker), usdPool, params, "");
        assertEq(beforeSelector, IHooks.beforeSwap.selector, "before returns its selector");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "and no delta");
        assertEq(fee, 0, "and no fee");
        (bytes4 afterSelector, int128 owed) =
            hook.afterSwap(address(locker), usdPool, params, BalanceDelta.wrap(0), "");
        vm.stopPrank();
        assertEq(afterSelector, IHooks.afterSwap.selector, "after returns its selector");
        assertEq(owed, 0, "and takes nothing");
    }

    // ----- A7: what a failed cycle costs beyond its budget, against `OVERHEAD_GAS` -----

    /// The worst case together, in a market that uses no pricer: the reads of three pool legs'
    /// hooks all cold, a payment waiting in the sync slot to be credited, and a fresh bench
    /// slot written. Measured from just before `_release` to just after `_fail`, with no try
    /// run. The tries' own bookkeeping (five loops and a third-size price read) cannot be
    /// measured cleanly from here; the reviewer measured the full worst case, all five tries
    /// running, at about 64.6k (67,895 with instrumentation, less about 1.3k for it and about
    /// 2.1k for a cold read a real search has warm). `OVERHEAD_GAS` is 70,000.
    function testACycleThatFailsFitsTheReserveBeforeItsTries() public {
        ArbitrageProbe probe = _probeInHook();
        probe.setSkipTries(true);
        SyncedPayer payer = new SyncedPayer(manager);
        usd.mint(address(payer), 1e18);
        ArbitrageLogic.Plan memory plan;
        plan.index = 1;
        plan.venue = bytes32(uint256(0xA1));
        plan.links[0] = bytes32(uint256(0xA2));
        plan.links[1] = bytes32(uint256(0xA3));
        plan.gap = 1e16;
        vm.cool(address(probe));
        vm.cool(address(manager));
        vm.cool(address(usd));
        uint256 used = payer.run(probe, usd, 1e18, _id(mainPool), plan);
        emit log_named_uint("failed cycle beyond its budget, no tries", used);
        assertLe(used, 70_000, "more than OVERHEAD_GAS");
    }

    // ----- C: a zero balance is not settled while another book holds a credit -----

    /// A cycle that nets to nothing in a token in which an earlier book of the same search
    /// holds a credit has spent that credit. With no credit, nothing owed is settled.
    function testZeroBalanceWithCreditIsUnsettled() public {
        ArbitrageProbe probe = _probeInHook();
        probe.settledWithCredit(address(usd), 0);
        vm.expectRevert(ArbitrageLogic.Unsettled.selector);
        probe.settledWithCredit(address(usd), 1e18);
    }
}
