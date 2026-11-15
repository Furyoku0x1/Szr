// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The hook with its scan exposed, so tests can measure what the gas constants assume.
contract ArbitrageProbe is ArbitrageHook {
    constructor(Liquidity treasury) ArbitrageHook(treasury) { }

    /// Gas to read every pool's price, gas to rank every venue against one pool, the number
    /// of venues, and what the hook allows per venue for the ranking and for the reading.
    /// This is a search in SZR's market.
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
        return _scanCost(SZR_MARKET, token, poolId);
    }

    /// Like `scanCost`, for a search in `market` that counts profit in `base`.
    function scanCostIn(uint256 market, address base, bytes32 poolId)
        external
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        return _scanCost(market, base, poolId);
    }

    /// The most venues the gas allowance of `market` is sized for.
    function mostVenues(uint256 market) external view returns (uint256) {
        return _mostVenues(market);
    }

    function _scanCost(uint256 market, address base, bytes32 poolId)
        internal
        returns (
            uint256 book,
            uint256 best,
            uint256 venues,
            uint256 allowance,
            uint256 bookAllowance
        )
    {
        active = market;
        home = base;
        address partner = _other(keys[poolId], base);
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

    /// The gas `_payOut` uses for native ETH profit in `market`, and the gas a search holds
    /// back for retiring. The pool manager must be unlocked and this hook must already be
    /// owed `profit` in ETH.
    function payoutCost(uint256 market, uint256 profit)
        external
        returns (uint256 used, uint256 reserved)
    {
        active = market;
        home = address(0);
        uint256 start = gasleft();
        _payOut(profit);
        used = start - gasleft();
        reserved = RETIRE_GAS;
        active = 0;
    }

    /// Like `payoutCost`, for profit counted in the token `asset`, which this hook must
    /// already be owed in the unlocked pool manager.
    function tokenPayoutCost(uint256 market, address asset, uint256 profit)
        external
        returns (uint256 used, uint256 reserved)
    {
        active = market;
        home = asset;
        uint256 start = gasleft();
        _payOut(profit);
        used = start - gasleft();
        reserved = RETIRE_GAS;
        active = 0;
    }

    /// The gas the wrap link uses to turn `amount` of ether token `from` into its twin, and
    /// then sends the twin to the caller. The pool manager must be unlocked and this hook
    /// must already be owed `amount` of `from`.
    function convertCost(address from, uint256 amount) external returns (uint256 used) {
        uint256 start = gasleft();
        _convert(from, amount);
        used = start - gasleft();
        poolManager.take(Currency.wrap(_twin(from)), msg.sender, amount);
    }

    /// What the hook leaves for the user's own swap, and the most one try at a cycle may use.
    function gasAllowances() external pure returns (uint256 swap, uint256 attempt) {
        return (SWAP_GAS, PLAN_GAS / 2);
    }
}
