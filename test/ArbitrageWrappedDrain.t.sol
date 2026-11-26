// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { DrainRouter } from "./utils/ArbitrageDrain.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";

/// @dev The drain guard on wrapped pools (`docs/specs/hook-wrapped-drain.md`). A wrapped
/// pool's own hook takes the leg's input from the pool manager, so a router that borrows
/// that token must fail the swap, not bench the cycle. The hook checks what it is owed in
/// the leg's input before such a leg, and never plans a buy through a wrapped leg whose
/// input is borrowed. The market counts in WETH; `first` is its hooked WETH/coin pool.
/// Selling coin into `first` leaves coin cheap there (the cycle that closes it is a sell
/// cycle); selling WETH into it leaves coin dear (a buy cycle).
contract ArbitrageWrappedDrainTest is WrapWorld {
    uint256 internal constant NONE = type(uint256).max;

    DrainRouter internal drain;
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    PoolKey internal outside;
    PoolKey internal bridge;

    function setUp() public override {
        super.setUp();
        drain = new DrainRouter(manager);
        vm.deal(address(drain), 1_000e18);
        usd.approve(address(drain), type(uint256).max);
        coin.approve(address(drain), type(uint256).max);
        backing.approve(address(drain), type(uint256).max);
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        address[] memory tokens = new address[](3);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        tokens[2] = address(0);
        vm.prank(team);
        hook.setTokens(id, tokens);
    }

    // ----- worlds -----

    function _wrap(address one, address other) internal returns (PoolKey memory pool) {
        pool = _pair(one, other, 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        _fillWrapper(one);
        _fillWrapper(other);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    function _fillWrapper(address asset) internal {
        if (asset == address(0)) vm.deal(address(wrapper), 1_000_000e18);
        else TestAsset(asset).mint(address(wrapper), 1_000_000e18);
    }

    /// The market's search is switched off while the test opens a gap, and on again after.
    function _off() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
    }

    function _on() internal {
        _limits(address(backing), 1e15);
    }

    /// A wrapped WETH/coin pool leads beside `first`: the venue of a sell cycle, and of a buy
    /// cycle paid in WETH.
    function _venueWorld() internal {
        _off();
        outside = _wrap(address(backing), address(coin));
        vm.prank(team);
        hook.addVenue(id, outside);
        _lead(address(backing), address(coin), _list(_id(first), _id(outside)));
        _on();
    }

    /// `first` against the public WETH/USD pool, across a wrapped coin/USD connecting pool.
    function _linkWorld() internal {
        _off();
        bridge = _wrap(address(coin), address(usd));
        vm.startPrank(team);
        hook.setConnector(id, bridge, true);
        hook.addVenue(id, publicPool);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first)));
        _lead(address(backing), address(usd), _list(_id(publicPool)));
        _on();
    }

    /// `first` against a wrapped WETH/USD venue, across a plain coin/USD connecting pool.
    function _plainLinkWorld() internal returns (PoolKey memory venue) {
        _off();
        PoolKey memory plain = _make(address(coin), address(usd), 500, address(0));
        venue = _wrap(address(backing), address(usd));
        vm.startPrank(team);
        hook.setConnector(id, plain, true);
        hook.addVenue(id, venue);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first)));
        _lead(address(backing), address(usd), _list(_id(venue)));
        _on();
    }

    /// A wrapped ETH/coin pool in the group of the twin: the venue is paid ETH, and the hook
    /// holds WETH.
    function _twinWorld() internal {
        _off();
        outside = _wrap(address(0), address(coin));
        vm.prank(team);
        hook.addVenue(id, outside);
        _lead(address(backing), address(coin), _list(_id(first)));
        _lead(address(0), address(coin), _list(_id(outside)));
        // The mode that pays an output of ETH with the right sync.
        wrapper.arm(7, first, address(hook), id);
        _on();
    }

    function _openSellGap() internal {
        _off();
        _trade(first, address(coin), 50_000e18);
        _on();
    }

    function _openBuyGap() internal {
        _off();
        _trade(first, address(backing), 120_000e18);
        _on();
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

    /// Cycles that bought and sold, cycles that failed, and searches undone by `Drained`.
    function _scan()
        internal
        returns (uint256 bought, uint256 sold, uint256 failed, uint256 undone)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bought, sold,,) = _tallyOf(logs);
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.CycleFailed.selector) failed++;
            if (topic != ArbitrageLogic.SearchUndone.selector) continue;
            if (abi.decode(logs[index].data, (bytes4)) == V4Read.Drained.selector) {
                undone++;
            }
        }
    }

    /// Moves the pool manager's whole balance of a token away, as a real shortage.
    function _empty(address asset) internal {
        uint256 held = TestAsset(asset).balanceOf(address(manager));
        vm.prank(address(manager));
        TestAsset(asset).transfer(address(0xDEAD), held);
    }

    function _assertNoBench() internal view {
        bytes32 own = _id(first);
        bytes32 other = _id(outside);
        assertEq(hook.benchedUntil(id, address(backing), own, other, true), 0, "bench buy");
        assertEq(hook.benchedUntil(id, address(backing), own, other, false), 0, "bench sell");
    }

    // ----- a sell cycle: every wrapped leg is an exact input of what was just paid -----

    /// The wrapped venue takes the coin that the pool searched just paid.
    function testDrainOfASellCycleVenueInputFailsTheSwap() public {
        _venueWorld();
        _openSellGap();
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = _try(first, address(backing), address(coin), 0);
        _assertDrained(ok, data);
        vm.revertToState(snapshot);
        // The same swap with nothing drained closes the gap.
        vm.recordLogs();
        (ok,) = _try(first, address(backing), address(coin), NONE);
        assertTrue(ok, "the swap fills");
        (, uint256 sold, uint256 failed,) = _scan();
        assertGt(sold, 0, "the gap is closed");
        assertEq(failed, 0, "no cycle failed");
    }

    /// The wrapped connecting pool takes the coin the pool searched paid, and the plain venue
    /// the USD it paid.
    function testDrainOfASellCycleLinkInputFailsTheSwap() public {
        _linkWorld();
        _openSellGap();
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = _try(first, address(backing), address(coin), 0);
        _assertDrained(ok, data);
        vm.revertToState(snapshot);
        vm.recordLogs();
        (ok,) = _try(first, address(backing), address(coin), NONE);
        assertTrue(ok, "the swap fills");
        (, uint256 sold, uint256 failed,) = _scan();
        assertGt(sold, 0, "the gap is closed through the wrapped link");
        assertEq(failed, 0, "no cycle failed");
    }

    // ----- a buy cycle: the wrapped venue is paid in the profit token -----

    function testDrainOfABuyCycleVenueInputFailsTheSwap() public {
        _venueWorld();
        _openBuyGap();
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = _try(first, address(coin), address(backing), 0);
        _assertDrained(ok, data);
        vm.revertToState(snapshot);
        vm.recordLogs();
        (ok,) = _try(first, address(coin), address(backing), NONE);
        assertTrue(ok, "the swap fills");
        (uint256 bought,, uint256 failed,) = _scan();
        assertGt(bought, 0, "the gap is closed");
        assertEq(failed, 0, "no cycle failed");
    }

    // ----- after the swap -----

    /// The swap itself opens the gap, so the search before it finds none. The router has
    /// borrowed all the coin, so the wrapped venue's input is short in the search after the
    /// swap: it is undone, nothing is benched, and the swap fills.
    function testDrainAfterTheSwapUndoesTheSearchAndBenchesNothing() public {
        _venueWorld();
        vm.recordLogs();
        drain.trade(first, address(coin), 50_000e18, address(coin), 0);
        (uint256 bought, uint256 sold, uint256 failed, uint256 undone) = _scan();
        assertEq(undone, 1, "the search after the swap is undone");
        assertEq(bought + sold, 0, "no cycle ran");
        assertEq(failed, 0, "no cycle counted as failed");
        _assertNoBench();
        _assertClean();
        // The gap waits for the next swap, which closes it.
        vm.recordLogs();
        _trade(first, address(backing), 1e15);
        (, sold,,) = _scan();
        assertGt(sold, 0, "the next swap closes the gap");
    }

    // ----- arb and sweep -----

    /// A pool manager that really is short fails `arb` and `sweep` when the cycle has a
    /// wrapped leg, with the same error as a hook's own take.
    function testArbAndSweepFailWhenAWrappedLegsInputIsShort() public {
        _venueWorld();
        _openSellGap();
        uint256 snapshot = vm.snapshotState();
        assertGt(hook.arb(_id(first)), 0, "arb control");
        vm.revertToState(snapshot);
        assertGt(hook.sweep(id, address(backing)), 0, "sweep control");
        vm.revertToState(snapshot);
        _empty(address(coin));
        vm.expectRevert(V4Read.Drained.selector);
        hook.arb(_id(first));
        vm.expectRevert(V4Read.Drained.selector);
        hook.sweep(id, address(backing));
    }

    // ----- gas -----

    /// Logs what a swap that closes a gap against a wrapped venue costs, to compare with the
    /// same run with the check removed: the difference is the cost of one wrapped leg's check.
    function testGapClosingSwapGasWithAWrappedLeg() public {
        _venueWorld();
        _openSellGap();
        uint256 spent = gasleft();
        _trade(first, address(backing), 1e15);
        spent -= gasleft();
        emit log_named_uint("gap-closing swap gas, one wrapped leg", spent);
    }

    // ----- what is left alone -----

    /// A router that borrows less than everything leaves the hook what it is owed.
    function testBorrowingLessThanTheWholeBalanceIsUnaffected() public {
        _venueWorld();
        _openSellGap();
        uint256 leave = coin.balanceOf(address(manager)) / 2;
        vm.recordLogs();
        (bool ok,) = _try(first, address(backing), address(coin), leave);
        assertTrue(ok, "the swap fills");
        (, uint256 sold, uint256 failed,) = _scan();
        assertGt(sold, 0, "the gap is closed");
        assertEq(failed, 0, "no cycle failed");
    }

    /// A buy through a wrapped connecting pool supplied by a wrapped venue borrows USD from
    /// the pool manager, which here honestly holds none. Such a buy is never planned, so the
    /// shortage is never read as a drain and nothing is tried.
    function testHonestShortageOfABorrowedInputIsNeverDrained() public {
        _off();
        bridge = _wrap(address(coin), address(usd));
        PoolKey memory venue = _wrap(address(backing), address(usd));
        vm.startPrank(team);
        hook.setConnector(id, bridge, true);
        hook.addVenue(id, venue);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first)));
        _lead(address(backing), address(usd), _list(_id(venue)));
        _on();
        _openBuyGap();
        _empty(address(usd));
        vm.recordLogs();
        _trade(first, address(backing), 1e15);
        (uint256 bought, uint256 sold, uint256 failed, uint256 undone) = _scan();
        assertEq(undone, 0, "never Drained");
        assertEq(failed, 0, "nothing tried");
        assertEq(bought + sold, 0, "no cycle");
    }

    // ----- buys that borrow a wrapped leg's input are never planned -----

    function testBuyThroughAWrappedConnectingPoolIsNeverPlanned() public {
        _linkWorld();
        _openBuyGap();
        vm.recordLogs();
        _trade(first, address(backing), 1e15);
        (uint256 bought, uint256 sold, uint256 failed,) = _scan();
        assertEq(bought + sold, 0, "no cycle");
        assertEq(failed, 0, "nothing tried");
        assertEq(hook.arb(_id(first)), 0, "the gap is left open");
    }

    function testSellThroughAWrappedConnectingPoolStillCloses() public {
        _linkWorld();
        _openSellGap();
        vm.recordLogs();
        _trade(first, address(coin), 1e15);
        (uint256 bought, uint256 sold,,) = _scan();
        assertEq(bought, 0, "no buy");
        assertGt(sold, 0, "the gap is closed");
    }

    /// The pool searched is USD/ETH and the venue USD/coin. The route from coin to ETH is the
    /// wrap link, then a wrapped coin/WETH pool in its second slot.
    function _secondLinkWorld() internal {
        _off();
        PoolKey memory ethPool = _make(address(usd), address(0), 3_000, address(hook));
        bridge = _wrap(address(coin), address(backing));
        PoolKey memory venue = _make(address(usd), address(coin), 500, address(0));
        vm.startPrank(team);
        hook.setLimits(id, address(usd), 0, 1e15, 1.0001e18);
        hook.setConnector(id, bridge, true);
        hook.addVenue(id, venue);
        vm.stopPrank();
        _lead(address(usd), address(0), _list(_id(ethPool)));
        _lead(address(usd), address(coin), _list(_id(venue)));
        outside = ethPool;
        _limits(address(usd), 1e15);
    }

    function _ethGap(address input, uint256 amount) internal {
        vm.prank(team);
        hook.setLimits(id, address(usd), 0, 1e15, 1.0001e18);
        _in(outside, input, amount);
        _limits(address(usd), 1e15);
    }

    /// A buy whose wrapped connecting pool sits in the route's second slot is never planned.
    function testBuyThroughASecondSlotWrappedLinkIsNeverPlanned() public {
        _secondLinkWorld();
        _ethGap(address(usd), 120_000e18);
        vm.recordLogs();
        _in(outside, address(usd), 1e15);
        (uint256 bought, uint256 sold, uint256 failed,) = _scan();
        assertEq(bought + sold, 0, "no cycle");
        assertEq(failed, 0, "nothing tried");
        assertEq(hook.arb(_id(outside)), 0, "the gap is left open");
    }

    function testSellThroughASecondSlotWrappedLinkStillCloses() public {
        _secondLinkWorld();
        _ethGap(address(0), 50_000e18);
        vm.recordLogs();
        _in(outside, address(0), 1e15);
        (uint256 bought, uint256 sold,,) = _scan();
        assertEq(bought, 0, "no buy");
        assertGt(sold, 0, "the gap is closed");
    }

    /// The venue is on ETH and the hook counts in WETH: paying it takes ETH that only the
    /// conversion after the venue supplies.
    function testBuyThroughAWrappedVenueHoldingTheTwinIsNeverPlanned() public {
        _twinWorld();
        _openBuyGap();
        vm.recordLogs();
        _trade(first, address(backing), 1e15);
        (uint256 bought, uint256 sold, uint256 failed,) = _scan();
        assertEq(bought + sold, 0, "no cycle");
        assertEq(failed, 0, "nothing tried");
        assertEq(hook.arb(_id(first)), 0, "the gap is left open");
    }

    function testSellThroughAWrappedVenueHoldingTheTwinStillCloses() public {
        _twinWorld();
        _openSellGap();
        vm.recordLogs();
        _trade(first, address(coin), 1e15);
        (uint256 bought, uint256 sold,,) = _scan();
        assertEq(bought, 0, "no buy");
        assertGt(sold, 0, "the gap is closed");
    }

    /// The connecting pool is plain, so its borrowed input is covered by the pool searched
    /// being the only thing that can fail: the wrapped venue is paid in WETH, which the hook
    /// holds. This buy is planned.
    function testBuyThroughAPlainConnectingPoolToAWrappedVenueIsStillPlanned() public {
        _plainLinkWorld();
        _openBuyGap();
        vm.recordLogs();
        _trade(first, address(backing), 1e15);
        (uint256 bought,, uint256 failed,) = _scan();
        assertGt(bought, 0, "the gap is closed");
        assertEq(failed, 0, "no cycle failed");
    }

    /// A drain of a leg of that buy is caught too: the venue is paid in WETH.
    function testDrainOfAPlainLinkBuyThroughAWrappedVenueFailsTheSwap() public {
        PoolKey memory venue = _plainLinkWorld();
        assertTrue(hook.tracked(id, _id(venue)));
        _openBuyGap();
        (bool ok, bytes memory data) = _try(first, address(coin), address(backing), 0);
        _assertDrained(ok, data);
    }
}

/// @dev A market with no pricer is as it was: the allowance and the gas of a swap that finds
/// no gap do not change.
contract ArbitrageWrappedDrainGasTest is WrapWorld {
    function testPlainMarketGasIsUnchanged() public {
        assertEq(hook.minimumGasLimit(1), 6_660_000, "minimum allowance");
        PoolKey memory hooked = _make(address(usd), address(coin), 3_000, address(hook));
        PoolKey memory venue = _make(address(usd), address(coin), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(coin), _list(_id(hooked), _id(venue)));
        _limits(address(usd), 1e15);
        assertEq(hook.minimumGasLimit(id), 6_660_000, "allowance");
        assertEq(
            hook.gasForSwap(id),
            7_080_242,
            "gas for a swap, with the base and the one centre it lists"
        );
        _in(hooked, address(usd), 1e18);
        _in(hooked, address(usd), 1e15);
        uint256 spent = gasleft();
        _in(hooked, address(usd), 1e15);
        spent -= gasleft();
        emit log_named_uint("no-gap swap gas, plain market", spent);
    }
}
