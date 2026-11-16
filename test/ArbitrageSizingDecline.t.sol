// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A walk that stopped short (at its cap or for gas) never declines a cycle: it only
/// knows what it found so far, so if that is too little the first try uses the estimate.
contract ArbitrageSizingDeclineTest is SizingWorld {
    /// Dust at every tick, so the walk stops at its cap of eight boundaries having found
    /// about 3,319 SZR of the 4,183 there is. With the smallest profit above the first and
    /// below the estimate's score, its answer is too poor to use and the cycle is not declined.
    function testWalkStoppedAtItsCapNeverDeclines() public {
        minProfit = 3330e18;
        PoolKey memory venue = _addHooked(address(usd), 500);
        _untrack(mainPool);
        _cheapen(usdPool, 200_000);
        _dust(usdPool, 60);
        Spec memory spec = _direct("C1   capped walk, poor profit", venue, usdPool);
        _on();
        uint256 open = vm.snapshotState();
        Result memory result = _measure(spec);
        (uint256 limit,,) = _probeInHook().sizingLimits();
        assertEq(result.walkSteps, 8, "the walk stopped at its cap");
        assertLt(result.walkGas, limit, "inside the gas it is given");
        assertGt(result.tries, 0, "and the estimate was tried");
        // The count above is of a warm rerun. Take the first walk's input from a real search,
        // then run it fully cold with only the gas it is given: a pessimistic bound.
        vm.revertToState(open);
        ArbitrageProbe probe = _probeInHook();
        _cool();
        _start(spec);
        bytes memory input = probe.walkInput();
        vm.revertToState(open);
        probe = _probeInHook();
        _cool();
        assertEq(probe.coldSteps(input), 8, "a cold walk stops at its cap too");
    }

    /// Reaching the end of a wrapped leg's range is an under-trade, not the end of liquidity:
    /// the venue may hold more past what its pricer reports. With the floor above what the
    /// short range earns, the cycle is still tried and the ladder earns what it can.
    function testWrappedRangeEndNeverDeclines() public {
        minProfit = 300e18;
        PoolKey memory venue = _wrappedVenue(75_000);
        _untrack(mainPool);
        int24 dir = _push(usdPool, address(usd));
        _bands(usdPool, dir, _alternating(3, poolUnits, poolUnits * 2));
        WrappedPricer pricer = WrappedPricer(wrappedPricer);
        pricer.arm(10);
        pricer.setReach(3_000);
        Result memory result =
            _measure(_direct("C2   wrapped short range, high floor", venue, usdPool));
        assertGt(result.tries, 0, "the cycle was tried");
        assertGt(result.total, 0, "and earned");
    }

    /// The walk's gas is capped at half the cycle's budget, however much a market lets its
    /// pricers use, so the first try keeps a full share.
    function testWalkGasIsCappedAtHalfTheBudget() public {
        PoolKey memory venue = _wrappedVenue(75_000);
        hook.setPricerGas(1, 1_020_000);
        ArbitrageProbe probe = _probeInHook();
        (uint256 gas,, uint256 plan) = probe.sizingLimits();
        ArbitrageHook.Plan memory cycle;
        cycle.venue = _id(venue);
        uint256 asking = hook.market(1).pricerGas;
        uint256 most = plan - probe.sizingCallGas();
        assertEq(probe.sizingGasWith(asking, cycle), most, "capped below half of the budget");
        cycle.links[0] = _id(venue);
        cycle.links[1] = _id(venue);
        assertEq(probe.sizingGasWith(asking, cycle), most, "and with three wrapped legs");
        assertEq(probe.sizingGasWith(0, cycle), gas, "a market with no pricers gets its own");
        // A real search in such a market, with a pricer that burns what it is given inside
        // the walk: the walk's whole charge leaves the first try a full share, and a swap
        // given what `gasForSwap` states fills.
        WrappedPricer(wrappedPricer).arm(16);
        _on();
        uint256 stated = hook.gasForSwap(1);
        _cheapen(usdPool, 100_000);
        _cool();
        probe = _probeInHook();
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(szr);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -1e15,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        PoolSwapTest.TestSettings memory settings;
        (bool filled,) = address(swapper).call{ gas: stated + 300_000 }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
        assertTrue(filled, "the swap fills on the stated gas");
        assertGt(probe.sizingCalls(), 0, "a cycle was sized");
        emit log_named_uint("walk charge", probe.sizingGas());
        // `_attempt` gives the first try the lesser of what is left and half the budget.
        uint256 whole = 2 * plan;
        assertGe(whole - probe.sizingGas(), whole / 2, "the first try keeps a full share");
    }

    /// What `_size` charges beyond the gas it hands the walk fits the margin held back from
    /// the cap, so a walk that spends everything it is given still leaves a full share.
    function testSizingCallOverheadFitsItsMargin() public {
        PoolKey memory venue = _wrappedVenue(75_000);
        _untrack(mainPool);
        int24 dir = _push(usdPool, address(usd));
        _bands(usdPool, dir, _alternating(3, poolUnits, poolUnits * 2));
        Spec memory spec = _direct("O", venue, usdPool);
        _on();
        uint256 open = vm.snapshotState();
        ArbitrageProbe probe = _probeInHook();
        _start(spec);
        bytes memory input = probe.walkInput();
        vm.revertToState(open);
        probe = _probeInHook();
        (uint256 charged, uint256 inner) = probe.callOverhead(input, 20_000);
        assertLe(charged - inner, probe.sizingCallGas(), "the call's overhead fits its margin");
    }
}
