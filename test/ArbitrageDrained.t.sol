// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { BrokenWrapAsset } from "./utils/ArbitrageNative.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { DrainRouter } from "./utils/ArbitrageDrain.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";

/// @dev Whoever controls the current unlock can borrow the pool manager's whole balance of a
/// token with `take` and repay it at the end. A swap that needs the hook to take that token
/// while it is gone must fail, like a swap with too little gas, so a gap cannot be skipped.
/// Every test with a drain has a control that runs the same swap without one.
///
/// Every drain test here is BEFORE-SWAP: the gap is already open when the draining swap
/// starts (the test opened it), so the search before the swap meets the shortage and the
/// swap must fail with `Drained`. A failed swap leaves no state, so these tests check what
/// can be checked afterwards: the next plain swap closes the gap. The AFTER-SWAP case, where
/// the shortage only bites the search after the swap and the swap fills, is in
/// `ArbitrageDrainedAfterTest`.
contract ArbitrageDrainedTest is WrapWorld {
    uint256 internal constant NONE = type(uint256).max;

    DrainRouter internal drain;

    function setUp() public override {
        super.setUp();
        drain = new DrainRouter(manager);
        vm.deal(address(drain), 1_000e18);
        usd.approve(address(drain), type(uint256).max);
        szr.approve(address(drain), type(uint256).max);
        coin.approve(address(drain), type(uint256).max);
        backing.approve(address(drain), type(uint256).max);
    }

    // ----- helpers -----

    function _try(PoolKey memory pool, address input, address drained, uint256 leave)
        internal
        returns (bool ok, bytes memory data)
    {
        (ok, data) = address(drain)
            .call(abi.encodeCall(drain.trade, (pool, input, 1e18, drained, leave)));
    }

    /// The pool manager wraps a hook's error, so look for its selector inside the data.
    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
        return false;
    }

    function _assertDrained(bool ok, bytes memory data) internal pure {
        assertFalse(ok, "the swap fails");
        assertTrue(_has(data, V4Read.Drained.selector), "with Drained");
    }

    /// A sale into the SZR/USD pool with SZR's market switched off, so the gap stays open.
    function _openSzrGap() internal {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
    }

    /// Only Core's NAV differs from the pools: a donation lifts it above every price.
    function _openNavGap() internal returns (PoolKey memory pool) {
        pool = _addHooked(address(backing), 500);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
    }

    /// How many cycles redeemed at Core. Only the first can be the gap the test opened;
    /// the pools it moves may open others after it.
    function _coreCycles() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageLogic.Arbitraged.selector) continue;
            if (logs[index].topics[2] == bytes32(0)) count++;
        }
    }

    // ----- SZR's market -----

    /// Before-swap: the gap is open already.
    function testSzrDrainedWithAGapOpenFailsTheSwap() public {
        _openSzrGap();
        uint256 inventory = core.unreleasedSupply();
        (bool ok, bytes memory data) = _try(usdPool, address(usd), address(szr), 0);
        _assertDrained(ok, data);
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        _assertHookEmpty();
    }

    function testSzrControlRetiresTheGapWithoutTheDrain() public {
        _openSzrGap();
        uint256 inventory = core.unreleasedSupply();
        (bool ok,) = _try(usdPool, address(usd), address(szr), NONE);
        assertTrue(ok, "the swap fills");
        assertGt(core.unreleasedSupply(), inventory, "the gap is closed and retired");
        _assertHookEmpty();
    }

    /// Before-swap: Core's NAV gap is open already. The failed swap is undone whole, so the
    /// check that nothing was benched is that the next plain swap redeems at Core.
    function testSzrDrainedWithANavGapFailsTheSwap() public {
        PoolKey memory pool = _openNavGap();
        (bool ok, bytes memory data) = _try(pool, address(backing), address(szr), 0);
        _assertDrained(ok, data);
        vm.recordLogs();
        _trade(pool, address(backing), 1e18);
        assertGt(_coreCycles(), 0, "the next swap redeems at Core");
    }

    function testSzrControlRedeemsAtCoreWithoutTheDrain() public {
        PoolKey memory pool = _openNavGap();
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        (bool ok,) = _try(pool, address(backing), address(szr), NONE);
        assertTrue(ok, "the swap fills");
        assertGt(_coreCycles(), 0, "redeemed at Core");
        assertGt(core.unreleasedSupply(), inventory, "retired");
    }

    /// A router that borrows less than everything leaves the hook what it needs.
    function testBorrowingLessThanTheWholeBalanceIsUnaffected() public {
        _openSzrGap();
        uint256 inventory = core.unreleasedSupply();
        uint256 leave = szr.balanceOf(address(manager)) / 2;
        (bool ok,) = _try(usdPool, address(usd), address(szr), leave);
        assertTrue(ok, "the swap fills");
        assertGt(core.unreleasedSupply(), inventory, "the gap is closed and retired");
    }

    // ----- conversions -----

    /// Opens a gap the hook closes with a buy cycle (it unwraps WETH) or a sell cycle (it
    /// wraps ETH), then trades through the draining router.
    function _convertWith(bool buy, address drained, uint256 leave)
        internal
        returns (PoolKey memory hooked, PoolKey memory venue, bool ok, bytes memory data)
    {
        (hooked, venue) = _usdEtherAndWeth();
        _in(venue, buy ? address(backing) : address(usd), 50_000e18);
        vm.recordLogs();
        (ok, data) = _try(hooked, address(usd), drained, leave);
    }

    /// Before-swap: the venue was moved first, so the gap is open when the swap starts.
    function _assertConversionDrained(bool buy, address drained) internal {
        (PoolKey memory hooked,, bool ok, bytes memory data) = _convertWith(buy, drained, 0);
        _assertDrained(ok, data);
        // The failed swap changed nothing, so the next plain swap closes the gap.
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold,,) = _tally();
        assertGt(bought + sold, 0, "the next swap closes the gap");
        _assertClean();
    }

    function _assertConversionUnaffected(bool buy, address drained) internal {
        (,, bool ok,) = _convertWith(buy, drained, 0);
        assertTrue(ok, "a token the cycle does not take");
        (uint256 bought, uint256 sold,,) = _tally();
        assertGt(bought + sold, 0, "gap closed");
        _assertClean();
    }

    function testWethDrainedFailsABuyCycleThatUnwraps() public {
        _assertConversionDrained(true, address(backing));
    }

    function testEthDrainedFailsASellCycleThatWraps() public {
        _assertConversionDrained(false, address(0));
    }

    function testControlsOfTheConversionsCloseTheGap() public {
        (,, bool ok,) = _convertWith(true, address(backing), NONE);
        assertTrue(ok);
        (uint256 bought,,, uint256 unwraps) = _tally();
        assertGt(bought, 0, "bought");
        assertGt(unwraps, 0, "unwrapped");
        _assertClean();
    }

    function testSellControlWraps() public {
        (,, bool ok,) = _convertWith(false, address(backing), NONE);
        assertTrue(ok);
        (, uint256 sold, uint256 wraps,) = _tally();
        assertGt(sold, 0, "sold");
        assertGt(wraps, 0, "wrapped");
        _assertClean();
    }

    /// The token a cycle does not take can be drained without effect.
    function testEthDrainedDoesNotStopABuyCycleThatUnwraps() public {
        _assertConversionUnaffected(true, address(0));
    }

    function testWethDrainedDoesNotStopASellCycleThatWraps() public {
        _assertConversionUnaffected(false, address(backing));
    }

    // ----- payouts -----

    /// Before-swap: the gap is open already.
    function testProfitTokenDrainedAtPayoutFailsTheSwapAndMintsNoClaim() public {
        (,, bool ok, bytes memory data) = _convertWith(true, address(usd), 0);
        _assertDrained(ok, data);
        assertEq(manager.balanceOf(desk, uint256(uint160(address(usd)))), 0, "no claim");
        assertEq(usd.balanceOf(desk), 0, "nothing paid");
        assertEq(usd.balanceOf(treasury), 0, "nothing paid");
    }

    function testPayoutControlPaysTheSplit() public {
        (,, bool ok,) = _convertWith(true, address(usd), NONE);
        assertTrue(ok);
        assertGt(usd.balanceOf(desk), 0, "protocol paid");
        assertGt(usd.balanceOf(treasury), 0, "market paid");
        assertEq(manager.balanceOf(desk, uint256(uint160(address(usd)))), 0, "no claim");
    }

    /// An outside market that counts profit in native ETH, paid out as WETH.
    function _ethMarket() internal returns (PoolKey memory hooked) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(team);
        hook.setTokens(id, tokens);
        // The world's WETH/coin group would be read as venues on the twin, and a cycle
        // against them refills the pool manager's ETH, which is not what is tested here.
        _lead(address(backing), address(coin), new bytes32[](0));
        hooked = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory venue = _make(address(0), address(coin), 500, address(0));
        _venue(venue);
        _lead(address(0), address(coin), _list(_id(hooked), _id(venue)));
        _limits(address(0), 1e15);
        _in(venue, address(coin), 50_000e18);
    }

    /// Before-swap: the venue holds a gap already.
    function testEthDrainedAtPayoutFailsTheSwap() public {
        PoolKey memory hooked = _ethMarket();
        uint256 paid = backing.balanceOf(ethDesk);
        (bool ok, bytes memory data) = _try(hooked, address(coin), address(0), 0);
        _assertDrained(ok, data);
        assertEq(backing.balanceOf(ethDesk), paid, "nothing paid");
    }

    function testEthPayoutControl() public {
        PoolKey memory hooked = _ethMarket();
        (bool ok,) = _try(hooked, address(coin), address(0), NONE);
        assertTrue(ok, "the swap fills");
        assertGt(backing.balanceOf(ethDesk), 0, "protocol paid in WETH");
        assertGt(backing.balanceOf(treasury), 0, "market paid in WETH");
    }

    // ----- arb and sweep -----

    /// `arb` and `sweep` unlock the pool manager themselves, so inside a draining unlock
    /// they cannot run at all.
    function testArbAndSweepCannotRunInsideADrainingUnlock() public {
        _openSzrGap();
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        drain.callWhileDrained(
            address(szr), address(hook), abi.encodeCall(hook.arb, (_id(usdPool)))
        );
        vm.expectRevert(IPoolManager.AlreadyUnlocked.selector);
        drain.callWhileDrained(
            address(szr), address(hook), abi.encodeCall(hook.sweep, (1, address(szr)))
        );
    }

    /// A pool manager that really is short (here by moving the tokens out of it) fails them.
    function _empty(address asset) internal {
        uint256 held = TestAsset(asset).balanceOf(address(manager));
        vm.prank(address(manager));
        TestAsset(asset).transfer(address(0xDEAD), held);
    }

    function testArbFailsWhenTheProfitCannotBeRetired() public {
        _openSzrGap();
        uint256 snapshot = vm.snapshotState();
        assertGt(hook.arb(_id(usdPool)), 0, "control");
        vm.revertToState(snapshot);
        _empty(address(szr));
        vm.expectRevert(V4Read.Drained.selector);
        hook.arb(_id(usdPool));
    }

    function testArbAndSweepFailWhenCoreCannotBePaid() public {
        _untrack(usdPool);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        uint256 snapshot = vm.snapshotState();
        assertGt(hook.arb(_id(mainPool)), 0, "arb control");
        vm.revertToState(snapshot);
        assertGt(hook.sweep(1, address(szr)), 0, "sweep control");
        vm.revertToState(snapshot);
        _empty(address(szr));
        vm.expectRevert(V4Read.Drained.selector);
        hook.arb(_id(mainPool));
        vm.expectRevert(V4Read.Drained.selector);
        hook.sweep(1, address(szr));
    }

    // ----- the wrap link beside a wrapped pool -----

    WrappedPool internal wrapper;

    /// A market that uses a pool whose trades are filled elsewhere (`asking` is not zero),
    /// with a hooked USD pool on one ether token and the wrapped one on the other.
    function _wrappedMarket(address focusEther)
        internal
        returns (PoolKey memory hooked, PoolKey memory outside)
    {
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        hook.setPricer(address(wrapper), address(new WrappedPricer(wrapper)));
        address other = focusEther == address(0) ? address(backing) : address(0);
        hooked = _make(focusEther, address(usd), 3_000, address(hook));
        outside = _pair(other, address(usd), 3_000, address(wrapper));
        manager.initialize(outside, uint160(1 << 96));
        usd.mint(address(wrapper), 1_000_000e18);
        if (other == address(0)) {
            vm.deal(address(wrapper), 1_000_000e18);
        } else {
            backing.mint(address(wrapper), 1_000_000e18);
        }
        wrapper.seed(outside, 1_000_000e18, 1_000_000e18);
        vm.prank(team);
        hook.setLimits(id, address(usd), 0, 1e15, 1.0001e18);
        _venue(outside);
        _lead(address(usd), focusEther, _list(_id(hooked)));
        _lead(address(usd), other, _list(_id(outside)));
        _limits(address(usd), 1e15);
        assertGt(hook.market(id).pricerGas, 0, "the market uses a wrapped pool");
    }

    /// The hooked pool is on WETH and the wrapped one on ETH, which no pool of the pool
    /// manager's holds: the wrapped pool's exchange pays it in only when the cycle sells
    /// there. The buy cycle needs that ETH for its conversion, so it can only succeed if
    /// the conversion waits until the ETH is in. Without the wait the pool manager has none
    /// to give, with nothing drained.
    function testBuyCycleConvertsOnlyOnceTheOtherEtherTokenIsIn() public {
        (PoolKey memory hooked,) = _wrappedMarket(address(backing));
        assertEq(address(manager).balance, 0, "the pool manager holds no ETH");
        // The mode that pays ETH out of the wrapped pool with the right sync slot.
        wrapper.arm(7, hooked, address(hook), id);
        vm.recordLogs();
        _in(hooked, address(usd), 100_000e18);
        (uint256 bought,, uint256 wraps,) = _tally();
        assertGt(bought, 0, "bought in the hooked pool");
        assertGt(wraps, 0, "and wrapped what the wrapped pool paid in");
        assertEq(address(manager).balance, 0, "still none");
        _assertClean();
    }

    function testWrapLinkBesideAWrappedPoolInBothDirections() public {
        (PoolKey memory hooked,) = _wrappedMarket(address(0));
        vm.recordLogs();
        _in(hooked, address(usd), 100_000e18);
        (uint256 bought,, uint256 wraps, uint256 unwraps) = _tally();
        assertGt(bought, 0, "bought in the ETH pool");
        assertGt(unwraps, 0, "unwrapped what the wrapped pool paid in");
        assertEq(wraps, 0, "no wrap");
        vm.recordLogs();
        _in(hooked, address(0), 400_000e18);
        (, uint256 sold,,) = _tally();
        assertGt(sold, 0, "sold in the ETH pool");
        _assertClean();
    }

    // ----- a failing WETH -----

    /// A WETH whose `deposit` fails with no data, inside a real wrapping cycle: the cycle
    /// fails, the swap fills, and nothing is left owed or held.
    function testBrokenWrapFailsTheCycleNotTheSwap() public {
        (PoolKey memory hooked, PoolKey memory venue) = _usdEtherAndWeth();
        _in(venue, address(usd), 50_000e18);
        vm.etch(address(backing), address(new BrokenWrapAsset()).code);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        assertGt(_failures(), 0, "the cycle failed");
        assertGt(
            hook.benchedUntil(id, address(usd), _id(hooked), _id(venue), false),
            block.timestamp,
            "and is set aside"
        );
        assertEq(usd.balanceOf(treasury), 0, "nothing paid");
        _assertClean();
    }
}
