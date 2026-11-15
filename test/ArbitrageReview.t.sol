// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Swaps one pool, then another, then the first again, all in one call.
contract SwapBatch {
    PoolSwapTest internal immutable swapper;

    constructor(PoolSwapTest swaps) {
        swapper = swaps;
    }

    function run(
        PoolKey calldata first,
        address firstInput,
        uint256 firstAmount,
        PoolKey calldata second,
        address secondInput,
        uint256 secondAmount
    ) external {
        TestAsset(firstInput).approve(address(swapper), type(uint256).max);
        TestAsset(secondInput).approve(address(swapper), type(uint256).max);
        _swap(first, firstInput, firstAmount);
        _swap(second, secondInput, secondAmount);
        _swap(first, firstInput, firstAmount);
    }

    function _swap(PoolKey calldata pool, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
    }
}

/// @dev Rules that an independent review found no test would notice the loss of.
contract ArbitrageReviewTest is ArbitrageWorld {
    /// A purchase in the USD pool sent with a set amount of gas, from untouched storage.
    function _buyWithGas(uint256 gas, uint256 amount) internal returns (bool filled) {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(usd);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (filled,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (usdPool, params, settings, ""))
        );
    }

    function _arbitraged() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.Arbitraged.selector) count++;
        }
    }

    /// Two venues that cannot be traded outrank a real gap, and the swap is a purchase that
    /// would collect that gap if the hook stood aside. The search before the swap has to
    /// get past both failures: at every gas limit, the swap either fails or goes through
    /// after the hook has closed the gap. It never goes through with the gap left to it.
    function testNoGasLimitLetsASwapCollectAGapBehindTwoFailures() public {
        _fakeVenueWithFee(21_960, 1e22, 100);
        _fakeVenueWithFee(21_960, 1e22, 200);
        _trade(mainPool, address(backing), 600_000e18);
        // What the purchase would get if the hook stood aside and left it the gap.
        uint256 snapshot = vm.snapshotState();
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        uint256 without = _buySzr();
        vm.revertToState(snapshot);
        bool filled;
        for (uint256 gas = 400_000; gas <= 9_000_000; gas += 25_000) {
            snapshot = vm.snapshotState();
            uint256 held = szr.balanceOf(address(this));
            bool ok = _buyWithGas(gas, 1_000e18);
            uint256 received = szr.balanceOf(address(this)) - held;
            vm.revertToState(snapshot);
            if (!ok) continue;
            filled = true;
            assertLt(received, without * 97 / 100, "the swap went through at the gap's price");
        }
        assertTrue(filled, "never filled");
    }

    /// The search after a swap reuses the prices read by the search before it. That is
    /// only right within one swap. A later swap in the same transaction, after another
    /// pool has moved, must price everything afresh: it closes the new gap and tries
    /// nothing that fails. The swaps are made in one call, as transient storage only lasts
    /// that long.
    function testLaterSwapInTheSameTransactionPricesAfresh() public {
        // Settles whatever gap the setup left, so the swaps below start with none.
        _trade(usdPool, address(szr), 1e15);
        SwapBatch batch = new SwapBatch(swapper);
        szr.transfer(address(batch), 1e18);
        backing.transfer(address(batch), 200_000e18);
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        batch.run(usdPool, address(szr), 1e15, mainPool, address(backing), 200_000e18);
        assertEq(_failures(), 0, "nothing tried on out-of-date prices");
        assertGt(core.unreleasedSupply(), inventory, "the new gap was closed");
    }

    /// `arb` passes over a venue whose cycle failed for the rest of that call, so the
    /// failure is reported once and the real gap behind it is still closed.
    function testArbPassesOverAFailedVenueAndClosesTheRealGap() public {
        PoolKey memory fake = _fakeVenue(21_960, 1e22);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(mainPool, address(backing), 600_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        hook.arb(_id(usdPool));
        assertEq(_failures(), 1, "the failed venue was tried once");
        assertGt(core.unreleasedSupply(), inventory, "the real gap was closed");
        assertEq(
            hook.benchedUntil(1, address(szr), _id(usdPool), _id(fake), false),
            0,
            "not set aside"
        );
    }
}
