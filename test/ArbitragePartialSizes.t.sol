// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

contract ArbitragePartialSizesTest is SizingWorld {
    function _overshoot(uint256 gap) internal returns (Spec memory spec) {
        _declineSizing();
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        PoolKey memory venue = _register(address(usd), 2_000, start);
        uint256[] memory units = _stepped(1, 1_500_000e18, 4, 1e12);
        _bands(venue, _push(venue, address(szr)), units);
        spec = _direct("overshoot", venue, usdPool);
        spec.probe = venue;
    }

    /// One small sale of SZR into `pool` with `gas`, as one external call. The state is put
    /// back afterwards.
    function _swapWith(PoolKey memory pool, uint256 gas)
        internal
        returns (bool ok, bytes memory reason)
    {
        uint256 snapshot = vm.snapshotState();
        _cool();
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(szr);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -1e15,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok, reason) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (pool, params, settings, ""))
        );
        vm.revertToState(snapshot);
    }

    /// The router wraps the hook's revert, so look for its selector inside the data.
    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 i; i + 4 <= data.length; i++) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 0x20), i))
            }
            if (bytes4(word) == wanted) return true;
        }
        return false;
    }

    /// A first cycle whose size was a half of the gap (the walk is off and the estimate and
    /// the whole gap overshoot) closes only part of it. A swap that brings gas for that one
    /// cycle and no more used to settle with the rest of the gap open; it now reverts
    /// `InsufficientGas`, and one with gas for three such cycles settles.
    function testPartialFallbackCycleDoesNotReleaseTheRule() public {
        _overshoot(16_000);
        _on();
        uint256[3] memory short = [uint256(4_500_000), 4_750_000, 5_000_000];
        for (uint256 i; i < short.length; i++) {
            (bool ok, bytes memory reason) = _swapWith(usdPool, short[i]);
            assertFalse(ok, "a swap short of gas for the next cycle fails");
            assertTrue(_has(reason, ArbitrageLogic.InsufficientGas.selector), "for gas");
        }
        (bool settled,) = _swapWith(usdPool, 6_000_000);
        assertTrue(settled, "with gas for three cycles it settles");
        (settled,) = _swapWith(usdPool, hook.gasForSwap(1));
        assertTrue(settled, "and so does one that brings gasForSwap");
    }
}
