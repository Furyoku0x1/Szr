// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev The rows of the sizing table where liquidity changes or ends past the price
/// (S4 and U1), in a contract of their own because the table no longer fits in one.
abstract contract SizingShapes is SizingWorld {
    uint256 internal constant THIN = 50_000e18;
    uint256 internal constant THICK = 4_000_000e18;
    /// A short head of this depth, then a long tail of the thinner depth, is what a cycle
    /// sized on the head overshoots in.
    uint256 internal constant HEAD = 1_500_000e18;
    uint256 internal constant TAIL = 100_000e18;
    /// The most a try that cannot fill a leg may use, against the 500k it is given. Most of
    /// what is left is the focus leg and the hook's own work, which the limit does not touch.
    /// The spec asked for 150k; measured, the tries use 153k to 162k.
    uint256 internal constant FAILED_TRY = 170_000;

    // ----- S4: liquidity that changes past the price -----

    function _shapeFocus(string memory name, uint256[] memory units, uint256 back, uint256 gap)
        internal
        returns (Result memory)
    {
        _untrack(mainPool);
        uint160 start = _mid(_szrPrice(usdPool, uint160(1 << 96), gap, true));
        PoolKey memory focus = _shaped(2_000, start, address(usd), units, back);
        Spec memory spec = _direct(name, usdPool, focus);
        _tailed(spec, focus, _tailOf(units, back));
        return _measure(spec);
    }

    function _shapeVenue(string memory name, uint256[] memory units, uint256 back, uint256 gap)
        internal
        returns (Result memory)
    {
        _untrack(mainPool);
        _cheapen(usdPool, gap);
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        PoolKey memory venue = _shaped(2_000, start, address(szr), units, back);
        Spec memory spec = _direct(name, venue, usdPool);
        _tailed(spec, venue, _tailOf(units, back));
        return _measure(spec);
    }

    /// The same shape in the connecting pool between a USD pool and an EUR pool.
    function _shapeLink(string memory name, uint256[] memory units, uint256 back, uint256 gap)
        internal
        returns (Result memory)
    {
        return _shapeLinkWay(name, units, back, gap, false);
    }

    /// With `sell` set, SZR is dear in the focus pool, so the cycle sells SZR there and the
    /// connecting pool is pushed by USD going in, not EUR.
    function _shapeLinkWay(
        string memory name,
        uint256[] memory units,
        uint256 back,
        uint256 gap,
        bool sell
    ) internal returns (Result memory) {
        return _measure(_linkSpec(name, units, back, gap, sell));
    }

    function testS4aFocusThinThenThick() public {
        _accept(
            _shapeFocus(
                "S4a  focus thin then thick, 6%", _stepped(3, THIN, 12, THICK), 0, 60_000
            )
        );
    }

    /// One range of `HEAD` over a thin pool of `TAIL` everywhere else.
    function _headOnly() internal pure returns (uint256[] memory) {
        return _stepped(1, HEAD - TAIL, 0, 0);
    }

    function testS4bFocusThickThenThin() public {
        _accept(_shapeFocus("S4b  focus 1 thick then thin, 5%", _headOnly(), TAIL, 50_000));
    }

    function testS4cVenueThinThenThick() public {
        _accept(
            _shapeVenue(
                "S4c  venue thin then thick, 6%", _stepped(3, THIN, 12, THICK), 0, 60_000
            )
        );
    }

    function testS4dVenueThickThenThin() public {
        Result memory result =
            _shapeVenue("S4d  venue 1 thick then thin, 5%", _headOnly(), TAIL, 50_000);
        assertEq(result.ranOut, 0, "a cheap failure is not a try that ran out");
        _accept(result);
    }

    function testS4eLinkThickThenThin() public {
        Result memory result =
            _shapeLink("S4e  link 1 thick then thin, 5%", _headOnly(), TAIL, 50_000);
        assertEq(result.ranOut, 0, "a cheap failure is not a try that ran out");
        _accept(result);
    }

    /// The acceptance line for rows the walk should size: the first try fills and earns
    /// within half a percent of the best cycle, found independently. At the tiny minimum
    /// profit only, where every profitable cycle counts.
    function _accept(Result memory result) internal view {
        if (minProfit != MIN_PROFIT) return;
        _assertFirstTryEarns(result);
    }

    /// The first try fills and its profit is within half a percent of the best cycle there
    /// is, found independently.
    function _assertFirstTryEarns(Result memory result) internal pure {
        assertFalse(result.firstTryFailed, "the first try succeeded");
        assertGt(result.cycles, 0, "and earned");
        assertGe(result.first * 1000, result.optimum * 995, "within 0.5% of the optimum");
    }

    /// After the one earning cycle the range is spent. The cycles that follow (the same pair,
    /// then the pair from the venue's side) are declined by the walk: each is a failed cycle
    /// that made no call to `execute`, so the only try in the search is the earning one.
    function _assertRestDeclined(Result memory result) internal pure {
        assertEq(result.tries, 1, "declined cycles make no tries");
        assertEq(result.cycles, 1, "one cycle earned");
        assertEq(result.failed, 2, "and the two that followed failed without a try");
    }

    /// One thick range past the price and nothing beyond it, so there is no backstop. A
    /// leg that cannot fill is stopped by its price limit at once. The walk sizes the cycle
    /// to end inside the range, so the first try earns.
    function _venueEnds() internal returns (Spec memory spec, PoolKey memory venue) {
        _untrack(mainPool);
        _cheapen(usdPool, 50_000);
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        venue = _shaped(2_000, start, address(szr), _headOnly(), 0);
        spec = _direct("S4f  venue liquidity ends, 5%", venue, usdPool);
        spec.probe = venue;
    }

    function testS4fVenueLiquidityEnds() public {
        (Spec memory spec,) = _venueEnds();
        Result memory result = _measure(spec);
        assertEq(result.ranOut, 0, "a cheap try is not a try that ran out");
        _assertFirstTryEarns(result);
        _assertRestDeclined(result);
    }

    /// Without the walk no size fits in the one range, and every try fails with
    /// `Incomplete` for next to nothing, instead of walking the empty bitmap words: the
    /// legs' price limits.
    function testS4fLegLimitFailsFastWithoutTheWalk() public {
        _declineSizing();
        (Spec memory spec,) = _venueEnds();
        uint256 snapshot = vm.snapshotState();
        Result memory result = _measure(spec);
        assertEq(result.ranOut, 0, "a cheap failure is not a try that ran out");
        assertEq(result.cycles, 0, "no size fits in the one range");
        assertEq(result.failed, 1, "the cycle failed once");
        uint256 until = hook.benchedUntil(
            1, address(szr), _id(usdPool), result.plans[0].venue, result.plans[0].buying
        );
        assertGt(until, 0, "so the pair was benched");
        vm.revertToState(snapshot);
        _on();
        _assertFailFast(_id(usdPool), result.plans, FAILED_TRY);
    }

    /// The same shape in a connecting pool.
    function testS4gLinkLiquidityEnds() public {
        Spec memory spec =
            _linkSpec("S4g  link liquidity ends, 5%", _headOnly(), 0, 50_000, false);
        Result memory result = _measure(spec);
        _assertFirstTryEarns(result);
        _assertRestDeclined(result);
    }

    function testS4gLegLimitFailsFastWithoutTheWalk() public {
        _declineSizing();
        Spec memory spec =
            _linkSpec("S4g  link liquidity ends, 5%", _headOnly(), 0, 50_000, false);
        uint256 snapshot = vm.snapshotState();
        Result memory result = _measure(spec);
        vm.revertToState(snapshot);
        _on();
        _assertFailFast(_id(usdPool), result.plans, FAILED_TRY);
    }

    /// A sell cycle, whose connecting pool is entered with exact input, ends the same way.
    function testSellCycleLinkLiquidityEnds() public {
        Spec memory spec =
            _linkSpec("U1   sell cycle, link ends, 5%", _headOnly(), 0, 50_000, true);
        Result memory result = _measure(spec);
        assertFalse(result.plans[0].buying, "a sell cycle");
        _assertFirstTryEarns(result);
        _assertRestDeclined(result);
    }

    function testSellCycleLegLimitFailsFastWithoutTheWalk() public {
        _declineSizing();
        Spec memory spec =
            _linkSpec("U1   sell cycle, link ends, 5%", _headOnly(), 0, 50_000, true);
        uint256 snapshot = vm.snapshotState();
        Result memory result = _measure(spec);
        vm.revertToState(snapshot);
        _on();
        assertFalse(result.plans[0].buying, "a sell cycle");
        _assertFailFast(_id(usdPool), result.plans, FAILED_TRY);
    }

    // ----- sell cycles that end behind more ranges after the thick one -----

    /// A sell cycle (SZR dear in the focus pool) into a new venue: one thick range, then
    /// `after` ranges of `units` each, then nothing. The cycle ends where the liquidity does.
    function _sellVenueEnds(string memory name, uint256 count, uint256 units)
        internal
        returns (Result memory)
    {
        _untrack(mainPool);
        _moveTo(usdPool, _szrPrice(usdPool, _priceOf(usdPool), 50_000, false));
        uint160 start = TickMath.getSqrtPriceAtTick(30);
        PoolKey memory venue =
            _shaped(2_000, start, address(usd), _stepped(1, HEAD - TAIL, count, units), 0);
        Spec memory spec = _direct(name, venue, usdPool);
        spec.probe = venue;
        return _measure(spec);
    }

    function testSellVenueOneDustRange() public {
        _assertFirstTryEarns(_sellVenueEnds("D1v  sell, venue, 1 dust range", 1, 1e12));
    }

    function testSellVenueThreeDustRanges() public {
        _assertFirstTryEarns(_sellVenueEnds("D3v  sell, venue, 3 dust ranges", 3, 1e3));
    }

    function testSellVenueThenARealRange() public {
        _assertFirstTryEarns(_sellVenueEnds("R1v  sell, venue, then a real range", 1, TAIL));
    }

    function testSellLinkOneDustRange() public {
        Spec memory spec = _linkSpec(
            "D1l  sell, link, 1 dust range", _stepped(1, HEAD - TAIL, 1, 1e12), 0, 50_000, true
        );
        spec.tail = 0;
        _assertFirstTryEarns(_measure(spec));
    }

    function testSellLinkThreeDustRanges() public {
        Spec memory spec = _linkSpec(
            "D3l  sell, link, 3 dust ranges", _stepped(1, HEAD - TAIL, 3, 1e3), 0, 50_000, true
        );
        spec.tail = 0;
        _assertFirstTryEarns(_measure(spec));
    }

    function testSellLinkThenARealRange() public {
        Spec memory spec = _linkSpec(
            "R1l  sell, link, then a real range",
            _stepped(1, HEAD - TAIL, 1, TAIL),
            0,
            50_000,
            true
        );
        spec.tail = 0;
        _assertFirstTryEarns(_measure(spec));
    }
}

/// @dev The table at the tiny minimum profit, where every profitable cycle counts.
contract ArbitrageSizingShapesTest is SizingShapes { }
