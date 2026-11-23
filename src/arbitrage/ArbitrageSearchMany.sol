// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `searchMany`, the search over several books. Apart from the other
/// searches only to keep each module under 24,576 bytes.
abstract contract SearchManyPart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @dev One search over several books, each counting profit in its own token. Every
    /// rule of `_search` holds across them as one: one allowance, one floor, and closing a
    /// gap is required until a cycle in any token has worked in full, or the cycles that
    /// failed plus those that closed only part of a gap, across all books, number more than
    /// `FAILURES_COVERED`, or a round finds nothing left. Today a second gap in the same
    /// token is not required once a cycle has worked either, so sending less gas skips
    /// nothing more than it did. Each round takes the widest gap of any book: gaps are
    /// shares, so they compare across tokens, while profits would need a price between
    /// them.
    function searchMany(
        bytes32[] calldata centres,
        uint256 id,
        address[] calldata bases,
        address[] calldata partners,
        bool capped,
        bool before,
        address payer
    ) external onlySelf {
        active = id;
        _begin(id);
        Many memory run;
        run.bases = bases;
        run.capped = capped;
        run.before = before;
        run.payer = payer;
        run.resync = UNRELEASED;
        uint256 count = centres.length;
        run.books = new Venue[][](count);
        run.nexts = new uint256[](count);
        run.profits = new uint256[](count);
        for (uint256 index; index < count; index++) {
            home = bases[index];
            // The first book asks every wrapped pool; the others read its answers.
            Venue[] memory book = _book(centres[index], partners[index], index == 0);
            run.books[index] = book;
            run.nexts[index] = book.length;
            run.venues += book.length;
        }
        run.floor = _floorMany(run);
        _cycleMany(run);
        for (uint256 index; index < count; index++) {
            if (run.profits[index] == 0) continue;
            home = bases[index];
            // Cleared first: paying the profit out leaves its token owed nothing.
            _setCredited(bases[index], 0);
            _retire(run.profits[index]);
        }
        _clearCredit();
        _resync(run.resync);
        active = 0;
    }
}

/// @notice The deployed `searchMany` module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageSearchMany is SearchManyPart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
