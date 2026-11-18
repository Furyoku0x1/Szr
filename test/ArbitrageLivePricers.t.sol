// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { MetricVenueSearchWorld } from "./MetricVenueSearch.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import {
    WrappedPool,
    WrappedPricer,
    CallOnlyPricer,
    HungryPricer,
    GatedPricer,
    MeddlingPricer,
    EchoRevertPricer
} from "./utils/WrappedPool.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { IVenuePricer } from "../src/interfaces/IVenuePricer.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract Pinger {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

contract AlwaysReverts {
    function run(Pinger pinger) external {
        pinger.ping();
        revert();
    }
}

/// @dev `docs/specs/hook-live-pricers.md`: every pricer is asked with a normal call inside
/// a frame that always reverts, once per wrapped pool per search, and the answers are kept
/// for the search to read.
contract ArbitrageLivePricersTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    WrappedPool internal wrapper;
    WrappedPricer internal mock;
    PoolKey internal outside;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        mock = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(mock));
        outside = _venue(3_000);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, outside);
        vm.stopPrank();
        _lead(address(backing), address(coin), _list(_id(first), _id(outside)));
        _limits(address(backing), 1e15);
    }

    /// A wrapped pool holding a million of each token somewhere else.
    function _venue(uint24 fee) internal returns (PoolKey memory pool) {
        pool = _pair(address(backing), address(coin), fee, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        TestAsset(address(backing)).mint(address(wrapper), 1_000_000e18);
        TestAsset(address(coin)).mint(address(wrapper), 1_000_000e18);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    function _question(PoolKey memory pool) internal pure returns (bytes memory) {
        return abi.encodeCall(IVenuePricer.price, (pool));
    }

    /// Pairs the wrapper with a pricer and gives pricers enough gas to write storage, which
    /// the default allowance does not cover.
    function _use(address pricer) internal {
        hook.setPricer(address(wrapper), pricer);
        _allow(200_000);
    }

    function _allow(uint32 gas) internal {
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.setPricerGas(id, gas);
        vm.stopPrank();
        _limits(address(backing), 1e15);
    }

    /// Sells coin into the market's own pool with the market switched off, so that a gap
    /// stays open between it and the wrapped pool.
    function _openGap() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
    }

    function _swapWithGas(uint256 amount, uint256 gas) internal returns (bool filled) {
        bool zeroForOne = Currency.unwrap(first.currency0) == address(coin);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(mock));
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (first, params, settings, ""))
        );
    }

    // ---------------------------------------------------------------------------------
    // the frame
    // ---------------------------------------------------------------------------------

    /// The cache tests count asks with `vm.expectCall`, which has to see the calls of a frame
    /// that reverts: the pricer's storage cannot count them.
    function testExpectCallCountsCallsInRevertedFrames() public {
        Pinger pinger = new Pinger();
        AlwaysReverts frame = new AlwaysReverts();
        vm.expectCall(address(pinger), abi.encodeCall(Pinger.ping, ()), 2);
        vm.expectRevert();
        frame.run(pinger);
        vm.expectRevert();
        frame.run(pinger);
        assertEq(pinger.pings(), 0, "the pings were undone");
    }

    /// A pricer that writes storage and opens a balance with the pool manager is answered,
    /// and then both are gone: the swap settles as if it had done neither.
    function testPricerThatWritesAndOpensABalanceIsUndone() public {
        MeddlingPricer meddler = new MeddlingPricer(manager, mock, address(backing));
        meddler.arm(1, second);
        _use(address(meddler));
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "its answer was used");
        assertEq(meddler.marker(), 0, "its write was undone");
        assertEq(manager.getNonzeroDeltaCount(), 0, "and its balance");
        assertGt(backing.balanceOf(treasury), 0, "the market was paid");
        _assertNothingHeld();
    }

    /// A pricer that reads its price with a normal call, as Metric's does, is priced.
    function testPricerThatNeedsACallIsPriced() public {
        CallOnlyPricer needy = new CallOnlyPricer(mock);
        (bool ok,) = address(needy).staticcall{ gas: 100_000 }(_question(outside));
        assertFalse(ok, "it refuses a static call");
        _use(address(needy));
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "its pool was traded");
        assertEq(needy.calls(), 0, "the frame undid its count");
    }

    /// Only exactly an `Answer` error of 4 + 160 bytes is an answer: one byte more or
    /// fewer, another selector, or a frame that returns instead of reverting is no price.
    function testWrongRevertDataIsNoPrice() public {
        ArbitrageProbe probe = _probeInHook();
        bytes32 poolId = _id(outside);
        uint256[5] memory good = probe.ask(address(mock), poolId, 20_000);
        assertEq(good[0], 1 << 96, "the real frame answers");
        for (uint256 mode = 1; mode <= 4; mode++) {
            probe.setFrameMode(mode);
            uint256[5] memory answer = probe.ask(address(mock), poolId, 20_000);
            for (uint256 word; word < 5; word++) {
                assertEq(answer[word], 0, "no price");
            }
        }
    }

    /// A pricer that itself reverts with an answer, whole or behind `Answer`'s selector, has
    /// failed: `askFrame` sees a failed call and reverts with nothing.
    function testPricerThatRevertsWithAnAnswerHasNoPrice() public {
        EchoRevertPricer echo = new EchoRevertPricer();
        _use(address(echo));
        for (uint256 mode = 1; mode <= 2; mode++) {
            uint256 snapshot = vm.snapshotState();
            echo.arm(mode);
            vm.recordLogs();
            _trade(first, address(coin), 50_000e18);
            assertEq(_cycles(), 0, "no cycle");
            vm.revertToState(snapshot);
        }
    }

    /// A pricer that tries to swap one of the hook's own pools in the middle of its ask is
    /// refused (a search is running), and what it tried is undone with the frame: the outer
    /// search goes on and ends as it does with an honest pricer.
    function testPricerCannotSwapTheHooksPoolsMidAsk() public {
        uint256 snapshot = vm.snapshotState();
        _trade(first, address(coin), 50_000e18);
        uint256 plain = backing.balanceOf(treasury);
        (uint160 price,,,) = manager.getSlot0(first.toId());
        vm.revertToState(snapshot);
        MeddlingPricer meddler = new MeddlingPricer(manager, mock, address(backing));
        meddler.arm(2, second);
        _use(address(meddler));
        // The fill and the ask after the cycle each try it once.
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams(true, -1e15, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectCall(
            address(manager), abi.encodeCall(IPoolManager.swap, (second, params, "")), 2
        );
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "the search went on");
        assertEq(backing.balanceOf(treasury), plain, "to the same profit");
        (uint160 later,,,) = manager.getSlot0(first.toId());
        assertEq(later, price, "and the same price");
        (uint160 untouched,,,) = manager.getSlot0(second.toId());
        assertEq(untouched, 1 << 96, "the pool it tried is where it was");
        _assertNothingHeld();
    }

    // ---------------------------------------------------------------------------------
    // the cache
    // ---------------------------------------------------------------------------------

    /// A swap with no gap asks each wrapped pool once, for the search before it: the search
    /// after keeps the answers, as it keeps the venues' prices.
    function testNoGapSwapAsksEachWrappedPoolOnce() public {
        PoolKey memory two = _venue(500);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.addVenue(id, two);
        vm.stopPrank();
        bytes32[] memory three = new bytes32[](3);
        three[0] = _id(first);
        three[1] = _id(outside);
        three[2] = _id(two);
        _lead(address(backing), address(coin), three);
        _limits(address(backing), 1e15);
        vm.expectCall(address(mock), _question(outside), 1);
        vm.expectCall(address(mock), _question(two), 1);
        vm.recordLogs();
        _trade(first, address(coin), 1e15);
        assertEq(_cycles(), 0, "nothing to close");
    }

    /// A swap whose after-search closes a gap asks once for the search before it and once
    /// more after the cycle, which moved the wrapped pool: the walk asked nothing.
    function testACycleThroughAWrappedPoolAsksItOnceMore() public {
        vm.expectCall(address(mock), _question(outside), 2);
        vm.recordLogs();
        _trade(first, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "closed after the swap");
    }

    /// When the search before a swap trades, the answers it kept are old: the search after
    /// asks again. The search before asked, and asked again after its cycle.
    function testSearchAfterATradeAsksAgain() public {
        _openGap();
        vm.expectCall(address(mock), _question(outside), 3);
        vm.recordLogs();
        _trade(first, address(coin), 1e15);
        assertGt(_cycles(), 0, "the search before closed the gap");
    }

    /// The sizing walk reads a wrapped leg from the cache: asked nothing, it still sizes the
    /// cycle from the pricer's price and range. A search that asked nothing would find no
    /// price, and neither trade nor size.
    function testWalkSizesAWrappedLegFromTheCache() public {
        _openGap();
        ArbitrageProbe probe = _probeInHook();
        vm.recordLogs();
        vm.expectCall(address(mock), _question(outside), 2);
        hook.sweep(id, address(backing));
        assertGt(_cycles(), 0, "the gap was closed");
        assertGt(probe.sizingCalls(), 0, "the cycle was sized");
        assertFalse(probe.sizingReverted(), "from what the cache held");
        assertTrue(probe.sizingUsed(), "and its size was used");
    }

    /// With gas just short of what an ask needs, a swap fails as `InsufficientGas`: it never
    /// fills with the gap still open because a pricer was given less than its allowance and
    /// so had no price. The pricer here needs nearly all of its allowance, and the gas is
    /// scanned finely across where the first ask can start.
    function testStarvedAskFailsTheSwapAndNeverFillsUnarbitraged() public {
        _scanStarved(address(new HungryPricer(mock, 1_000_000)), 1_020_000);
    }

    /// The same with a pricer that refuses cheaply when short, so the search around it can
    /// go on: only the hook's own gas check before an ask stands between a short swap and
    /// a fill that read "no price". The gate sits just under the allowance, which only an
    /// ask given the whole allowance clears. It fails if the check ignores the allowance.
    function testShortAskNeverReadsNoPriceWhenTheCheckIgnoresTheAllowance() public {
        _scanStarved(address(new GatedPricer(mock, 1_015_000)), 1_020_000);
    }

    /// And with the gate a few hundred gas under the allowance: an ask is only given all of
    /// its allowance when the check allows for the holdback of a 64th at both calls, the
    /// frame's and the pricer's. It fails if the check allows for one.
    function testShortAskNeverReadsNoPriceWhenTheCheckAllowsOneHoldback() public {
        _scanStarved(address(new GatedPricer(mock, 1_019_600)), 1_020_000);
    }

    /// Swaps with ever more gas, from far too little: a short one must fail, never fill
    /// with the gap open, and once one fills more gas must keep filling it.
    function _scanStarved(address pricer, uint32 allowance) internal {
        _use(pricer);
        _allow(allowance);
        _openGap();
        uint256 stated = hook.gasForSwap(id) + 300_000;
        bool settled;
        bool failedOnce;
        uint256 gas = 1_000_000;
        while (gas <= stated) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            bool ok = _swapWithGas(1e15, gas);
            uint256 cycles = _cycles();
            vm.revertToState(snapshot);
            if (ok) assertGt(cycles, 0, "filled with the gap open");
            if (settled) assertTrue(ok, "more gas failed");
            if (!ok) failedOnce = true;
            if (ok) settled = true;
            gas += gas < 1_600_000 ? 10_000 : 500_000;
        }
        assertTrue(failedOnce, "short gas fails the swap");
        assertTrue(settled, "and enough gas fills it");
    }
}

/// @dev A swap through a venue whose own hook starts the searches: the search after the fill
/// asks again, because the fill moved the wrapped pool itself. It never keeps what the
/// search before it left.
contract ArbitrageLiveTriggerTest is MetricVenueSearchWorld {
    function testTriggeredSearchesNeverKeepTheFill() public {
        address pricer = hook.pricers(address(venue));
        bytes memory question = abi.encodeCall(IVenuePricer.price, (metricKey));
        vm.expectCall(pricer, question, 2);
        _trade(metricKey, address(backing), 1e18);
    }
}
