// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import {
    TwoHopRouter,
    PayFirstRouter,
    TopUpRouter,
    PresyncRouter,
    SyncEarlyRouter,
    SplitPayer,
    HostileSyncRouter
} from "./utils/Routers.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev How the hook behaves with routers that settle in unusual orders, and with the pool
/// manager's sync slot, which anyone can set.
contract ArbitrageRoutersTest is ArbitrageWorld {
    /// One transaction that swaps through two hooked pools in a single unlock: USD to SZR
    /// in one, SZR to WETH in the other. All four searches run inside the router's unlock,
    /// and the router's own settlement must still balance.
    function testTwoHookedSwapsInOneUnlock() public {
        PoolKey memory wethPool = _addHooked(address(backing), 500);
        TwoHopRouter router = new TwoHopRouter(manager);
        usd.approve(address(router), type(uint256).max);
        uint256 inventory = core.unreleasedSupply();
        uint256 held = backing.balanceOf(address(this));
        uint256 received = router.trade(usdPool, wethPool, address(usd), 50_000e18);
        assertGt(received, 0, "router filled");
        assertEq(backing.balanceOf(address(this)), held + received, "router paid out");
        assertGt(core.unreleasedSupply(), inventory, "gaps retired");
        _assertHookEmpty();
    }

    /// The pool manager has one slot recording a token marked as synced ahead of payment.
    /// A router that pays SZR in before it swaps uses it. The hook credits that payment to
    /// the router, as the router's own settlement would have, and then runs as usual: the
    /// swap fills, the router gets what it is owed, and the gap is closed and retired.
    function testRouterThatPaysFirstIsCreditedAndTheGapStillCloses() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        PayFirstRouter router = new PayFirstRouter(manager);
        szr.approve(address(router), type(uint256).max);
        uint256 inventory = core.unreleasedSupply();
        uint256 paid = szr.balanceOf(address(this));
        uint256 received = router.trade(usdPool, address(szr), 1_000e18);
        assertGt(received, 0, "pay-first swap filled");
        assertEq(paid - szr.balanceOf(address(this)), 1_000e18, "router paid exactly once");
        assertGt(core.unreleasedSupply(), inventory, "gap closed and retired in the same swap");
        _assertHookEmpty();
    }

    /// A router may pay part of its input before the swap and the rest after it. The hook
    /// credits the first part, then marks the token again so the rest is counted too.
    function testRouterThatPaysInTwoPartsStillSettles() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        TopUpRouter router = new TopUpRouter(manager);
        szr.approve(address(router), type(uint256).max);
        uint256 inventory = core.unreleasedSupply();
        uint256 paid = szr.balanceOf(address(this));
        assertGt(router.trade(usdPool, address(szr), 1_000e18), 0, "swap filled");
        assertEq(paid - szr.balanceOf(address(this)), 1_000e18, "router paid exactly once");
        assertGt(core.unreleasedSupply(), inventory, "gap closed and retired");
        _assertHookEmpty();
    }

    /// A router may mark its token as synced before the swap and pay only afterwards. The
    /// hook takes SZR out in between, so it marks the token again when it is done; without
    /// that the router's payment would be counted short by exactly the hook's profit.
    function testRouterThatSyncsEarlyAndPaysLateStillSettles() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        SyncEarlyRouter router = new SyncEarlyRouter(manager);
        szr.approve(address(router), type(uint256).max);
        uint256 inventory = core.unreleasedSupply();
        assertGt(router.trade(usdPool, address(szr), 1_000e18), 0, "swap filled");
        assertGt(core.unreleasedSupply(), inventory, "gap closed and retired");
        _assertHookEmpty();
    }

    /// Marking a token as synced costs nothing and anyone can do it. It must not make the
    /// hook stand aside: with SZR marked, a gap already open is still closed before the
    /// swap trades, so the swap cannot collect it.
    function testMarkingSzrAsSyncedDoesNotSkipTheHook() public {
        _trade(mainPool, address(backing), 600_000e18);
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        uint256 without = _buySzr();
        vm.revertToState(snapshot);
        PresyncRouter router = new PresyncRouter(manager);
        usd.approve(address(router), type(uint256).max);
        uint256 inventory = core.unreleasedSupply();
        uint256 aligned = router.trade(usdPool, address(usd), 1_000e18, address(szr));
        assertLt(aligned, without * 97 / 100, "still paid the aligned price");
        assertGt(core.unreleasedSupply(), inventory, "gap retired");
        _assertHookEmpty();
    }

    /// The token marked need not be a real one. A token written to misreport its balance,
    /// to revert, or to burn gas when asked must not undo the search either: the hook never
    /// calls a token it does not trade. In each case the gap is still closed before the
    /// swap, which pays the aligned price.
    function testMarkingAHostileTokenDoesNotSkipTheHook() public {
        _trade(mainPool, address(backing), 600_000e18);
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        uint256 without = _buySzr();
        vm.revertToState(snapshot);
        HostileSyncRouter router = new HostileSyncRouter(manager);
        usd.approve(address(router), type(uint256).max);
        for (uint256 mode = 1; mode <= 3; mode++) {
            snapshot = vm.snapshotState();
            uint256 inventory = core.unreleasedSupply();
            uint256 aligned = router.trade(usdPool, address(usd), 1_000e18, mode);
            assertLt(aligned, without * 97 / 100, "still paid the aligned price");
            assertGt(core.unreleasedSupply(), inventory, "gap retired");
            _assertHookEmpty();
            vm.revertToState(snapshot);
        }
    }

    /// Nor does marking some other token switch off redemption at Core. With a pool below
    /// NAV and WETH marked, the hook still buys in the pool and redeems.
    function testMarkingATokenDoesNotSwitchOffCoreRedemption() public {
        PoolKey memory pool = _addHooked(address(backing), 500);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        assertGt(core.NAV(), _price(pool), "pool below NAV");
        PresyncRouter router = new PresyncRouter(manager);
        szr.approve(address(router), type(uint256).max);
        vm.recordLogs();
        assertGt(router.trade(pool, address(szr), 1_000e18, address(backing)), 0, "filled");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 redemptions;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageLogic.Arbitraged.selector) continue;
            if (logs[index].topics[2] == bytes32(0)) redemptions++;
        }
        assertGt(redemptions, 0, "redeemed at Core in the same swap");
        _assertHookEmpty();
    }

    /// If one contract pays a token in and a different one then swaps, the hook credits the
    /// payment to the swapper. The payer's own settlement finds nothing, so that transaction
    /// fails as a whole and nothing is lost.
    function testPaymentFromSomeoneOtherThanTheSwapperRevertsCleanly() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        SplitPayer payer = new SplitPayer(manager, swapper);
        szr.transfer(address(payer), 2_000e18);
        uint256 inventory = core.unreleasedSupply();
        // The reason is the test router's own check that it was debited what it expected,
        // worded by which side of the pool it paid, so only the fact of reverting is pinned.
        vm.expectRevert();
        payer.payThenSwapThroughRouter(usdPool, address(szr), 1_000e18);
        assertEq(core.unreleasedSupply(), inventory, "nothing happened");
        assertEq(szr.balanceOf(address(payer)), 2_000e18, "payer kept its tokens");
        _assertHookEmpty();
    }

    /// `arb` has no swapper to credit a waiting payment to, so a caller who pays a token
    /// in and then calls it is refused.
    function testArbRefusesACallerWithAPaymentWaiting() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        SplitPayer payer = new SplitPayer(manager, swapper);
        szr.transfer(address(payer), 2_000e18);
        vm.expectRevert(ArbitrageLogic.Busy.selector);
        payer.payThenCall(
            address(szr), 1_000e18, address(hook), abi.encodeCall(hook.arb, (_id(usdPool)))
        );
    }
}
