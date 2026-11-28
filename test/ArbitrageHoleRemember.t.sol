// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageHoleAheadBase } from "./ArbitrageHoleAhead.t.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev A stand-in that fails must not blind the search after the swap: the search before a
/// swap is remembered for the one after, so a venue passed over (its rate zeroed) in the
/// first would stay passed over in the second (27-M-6).
contract ArbitrageHoleRememberTest is ArbitrageHoleAheadBase {
    function testAFailedStandInDoesNotBlindTheSearchAfterTheSwap() public {
        _build(0);
        _untrack(usdPool);
        _unposition(centre - WIDTH, centre + WIDTH, BIG);
        _position(centre + 60, centre + 1_260, BIG);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            mainPool,
            IPoolManager.SwapParams(true, -1e30, TickMath.getSqrtPriceAtTick(centre - 300)),
            settings,
            ""
        );
        uint256 inventory = core.unreleasedSupply();
        _swapTo(false, -1e30, TickMath.getSqrtPriceAtTick(centre + 600));
        assertGe(core.unreleasedSupply() - inventory, 1_500e18, "the swap's searches retire it");
        assertLt(hook.arb(_id(focus)), 1e18, "nothing is left for arb");
    }
}
