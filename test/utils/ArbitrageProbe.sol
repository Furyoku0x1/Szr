// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { Liquidity } from "../../src/Liquidity.sol";

/// @dev The hook with its scan exposed, so tests can measure what the gas constants assume.
contract ArbitrageProbe is ArbitrageHook {
    constructor(Liquidity treasury) ArbitrageHook(treasury) { }

    /// Gas to read every pool's price, gas to rank every venue against one pool, the number
    /// of venues, and what the hook allows per venue for the ranking and for the reading.
    function scanCost(bytes32 poolId)
        external
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        active = SZR_MARKET;
        home = token;
        address partner = _other(keys[poolId], token);
        uint256 start = gasleft();
        Venue[] memory prices = _book(poolId, partner);
        book = start - gasleft();
        start = gasleft();
        _best(prices, 0);
        best = start - gasleft();
        venues = prices.length;
        allowance = SCAN_GAS_PER_VENUE;
        bookAllowance = BOOK_GAS_PER_VENUE;
        active = 0;
    }

    /// What the hook leaves for the user's own swap, and the most one try at a cycle may use.
    function gasAllowances() external pure returns (uint256 swap, uint256 attempt) {
        return (SWAP_GAS, PLAN_GAS / 2);
    }
}
