// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev A try on the budget the earlier tries left over is not a try that ran out of its
/// share (`docs/specs/hook-try-ran-out.md`, amended 2026-11-15).
contract ArbitrageLeftoverTest is SizingWorld {
    uint256 internal constant HEAD = 1_500_000e18;
    uint256 internal constant TAIL = 100_000e18;
    uint256 internal constant DUST_RANGES = 4;

    /// A venue with a few dust ranges after one thick range: each try crosses them and
    /// still cannot fill. Three tries of about 270k leave the fourth what is left of the
    /// budget, and it uses almost all of that.
    function testLeftoverStipendIsNotFlaggedAsRanOut() public {
        // Without the walk, whose size would let the first try fill the one thick range.
        _declineSizing();
        _untrack(mainPool);
        _cheapen(usdPool, 50_000);
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        PoolKey memory venue = _register(address(usd), 2_000, start);
        _bands(venue, _push(venue, address(szr)), _stepped(1, HEAD - TAIL, DUST_RANGES, 1e12));
        Spec memory spec = _direct("L1   venue dust ranges, 5%", venue, usdPool);
        spec.probe = venue;
        Result memory result = _measure(spec);
        assertGe(result.tries, 4, "the last try ran on what the others left");
        assertEq(result.cycles, 0, "and none fits");
        assertEq(result.ranOut, 0, "a leftover try is not a try that ran out");
    }
}
