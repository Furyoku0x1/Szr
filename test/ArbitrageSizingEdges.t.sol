// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingWorld } from "./utils/ArbitrageSizing.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { Vm } from "forge-std/Vm.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @dev Edges of the sizing walk (`docs/specs/hook-exact-sizing.md`): empty ranges that are
/// holes and not ends, a last range too small to leave room for rounding, and pairs whose
/// raw price makes dust too thin to shape. Each row asserts the first try fills and that
/// the search takes at least 99.5% of the best cycle there is.
abstract contract SizingEdges is SizingWorld {
    uint256 internal constant HEAD = 1_500_000e18;
    uint256 internal constant TAIL = 100_000e18;

    /// The first try fills, and the whole search earns within half a percent of the best.
    function _assertWhole(Result memory result) internal pure {
        assertFalse(result.firstTryFailed, "the first try succeeded");
        assertGt(result.cycles, 0, "and earned");
        assertGe(result.total * 1000, result.optimum * 995, "the search took 99.5% or more");
    }

    function _edgeShaped(address pushed, uint256[] memory units)
        internal
        returns (PoolKey memory pool)
    {
        pool = _register(address(usd), 2_000, TickMath.getSqrtPriceAtTick(30));
        _bands(pool, _push(pool, pushed), units);
    }

    /// A thick range, an empty one, then deep liquidity again.
    function _holey() internal pure returns (uint256[] memory units) {
        units = new uint256[](12);
        for (uint256 index; index < 12; index++) {
            units[index] = index == 1 ? 0 : HEAD - TAIL;
        }
    }

    // ----- holes -----

    /// A buy cycle (SZR cheap in the focus pool) into a venue with a hole in its path.
    function testHoleInAVenueOnABuyCycle() public {
        _untrack(mainPool);
        _cheapen(usdPool, 50_000);
        PoolKey memory venue = _edgeShaped(address(szr), _holey());
        Spec memory spec = _direct("H1v  hole in a venue, buy, 5%", venue, usdPool);
        spec.probe = venue;
        _assertWhole(_measure(spec));
    }

    /// A sell cycle through a connecting pool with a hole in its path.
    function testHoleInAConnectingPoolOnASellCycle() public {
        Spec memory spec = _linkSpec("H1l  hole in a link, sell, 5%", _holey(), 0, 50_000, true);
        spec.tail = 0;
        _assertWhole(_measure(spec));
    }

    // ----- a near-empty range between deep ones -----

    /// A thick range, a range of `middle` units, then deep liquidity again.
    function _thinMiddle(uint256 middle) internal pure returns (uint256[] memory units) {
        units = new uint256[](12);
        for (uint256 index; index < 12; index++) {
            units[index] = index == 1 ? middle : HEAD - TAIL;
        }
    }

    function _middleVenue(string memory name, uint256 middle, bool sell)
        internal
        returns (Result memory)
    {
        _untrack(mainPool);
        if (sell) _moveTo(usdPool, _szrPrice(usdPool, _priceOf(usdPool), 50_000, false));
        else _cheapen(usdPool, 50_000);
        PoolKey memory venue =
            _edgeShaped(sell ? address(usd) : address(szr), _thinMiddle(middle));
        Spec memory spec = _direct(name, venue, usdPool);
        spec.probe = venue;
        return _measure(spec);
    }

    function _middleLink(string memory name, uint256 middle, bool sell)
        internal
        returns (Result memory)
    {
        Spec memory spec = _linkSpec(name, _thinMiddle(middle), 0, 50_000, sell);
        spec.tail = 0;
        return _measure(spec);
    }

    function testMiddleTenVenueBuy() public {
        _assertWhole(_middleVenue("M10vb  10 units between deep, venue, buy", 10, false));
    }

    function testMiddleHundredVenueBuy() public {
        _assertWhole(_middleVenue("M100vb 100 units between deep, venue, buy", 100, false));
    }

    function testMiddleTenVenueSell() public {
        _assertWhole(_middleVenue("M10vs  10 units between deep, venue, sell", 10, true));
    }

    function testMiddleHundredVenueSell() public {
        _assertWhole(_middleVenue("M100vs 100 units between deep, venue, sell", 100, true));
    }

    function testMiddleTenLinkBuy() public {
        _assertWhole(_middleLink("M10lb  10 units between deep, link, buy", 10, false));
    }

    function testMiddleHundredLinkBuy() public {
        _assertWhole(_middleLink("M100lb 100 units between deep, link, buy", 100, false));
    }

    function testMiddleTenLinkSell() public {
        _assertWhole(_middleLink("M10ls  10 units between deep, link, sell", 10, true));
    }

    function testMiddleHundredLinkSell() public {
        _assertWhole(_middleLink("M100ls 100 units between deep, link, sell", 100, true));
    }

    /// The sweep: the middle range across four sizes, one direction.
    function testMiddleThreeHundredVenueBuy() public {
        _assertWhole(_middleVenue("M300vb 300 units between deep, venue, buy", 300, false));
    }

    function testMiddleThousandVenueBuy() public {
        _assertWhole(_middleVenue("M1000vb 1000 units between deep, venue, buy", 1000, false));
    }

    // ----- a best size of a few wei with the next boundary far away -----

    /// Two legs of a shallow pool, set up by hand so that the best size is about 12 wei with
    /// the rate above break-even, and the nearest boundary about 30 wei away. The best size
    /// is the optimum: the walk must stop there. Skipping to the boundary, as a best size of
    /// "no more than a few wei" first did, runs the legs a whole range past it (a venue
    /// ended at tick 90 instead of 59 and earned two thirds of the best).
    function testThinBestSizeWithAFarBoundaryIsTheOptimum() public {
        ArbitrageProbe probe = _probeInHook();
        uint160 high = uint160(Q96 * 1003 / 1000);
        (bool more, uint256 total, uint256 steps) =
            probe.thinRound(_id(usdPool), high, uint160(Q96), 10_000);
        assertFalse(more, "the walk is over");
        assertEq(steps, 0, "no boundary was crossed");
        assertEq(total, 0, "and it moved nothing: a dozen wei is not worth a range");
    }

    // ----- a tiny last range -----

    function _tinyVenue(string memory name, uint256 units, bool sell)
        internal
        returns (Result memory)
    {
        _untrack(mainPool);
        if (sell) _moveTo(usdPool, _szrPrice(usdPool, _priceOf(usdPool), 50_000, false));
        else _cheapen(usdPool, 50_000);
        PoolKey memory venue =
            _edgeShaped(sell ? address(usd) : address(szr), _stepped(1, HEAD - TAIL, 1, units));
        Spec memory spec = _direct(name, venue, usdPool);
        spec.probe = venue;
        return _measure(spec);
    }

    function testTinyLastRangeOneUnitSell() public {
        _assertWhole(_tinyVenue("T1s  sell, last range of 1 unit", 1, true));
    }

    function testTinyLastRangeTenUnitsSell() public {
        _assertWhole(_tinyVenue("T10s sell, last range of 10 units", 10, true));
    }

    function testTinyLastRangeOneUnitBuy() public {
        _assertWhole(_tinyVenue("T1b  buy, last range of 1 unit", 1, false));
    }

    function testTinyLastRangeTenUnitsBuy() public {
        _assertWhole(_tinyVenue("T10b buy, last range of 10 units", 10, false));
    }

    // ----- low-decimal pairs -----

    function _rawPrice(address partner, uint256 num, uint256 den)
        internal
        view
        returns (uint160)
    {
        bool szrFirst = address(szr) < partner;
        return uint160(
            FixedPointMathLib.sqrt(
                FixedPointMathLib.fullMulDiv(szrFirst ? num : den, Q192, szrFirst ? den : num)
            )
        );
    }

    /// SZR worth `num / den` of a partner token, a million SZR deep in the focus pool and in
    /// the venue's one thick range, then `count` dust ranges of `dust` units, then nothing.
    /// A sell cycle has SZR dear in the focus pool; a buy cycle cheap.
    function _lowDecimal(string memory name, uint256 num, uint256 den, uint256 dust, bool sell)
        internal
        returns (Result memory)
    {
        TestAsset coin = new TestAsset();
        _approve(coin);
        _untrack(mainPool);
        uint160 fair = _rawPrice(address(coin), num, den);
        uint256 units = FixedPointMathLib.sqrt(1_000_000e18 * (1_000_000e18 * num / den));
        bool szrFirst = address(szr) < address(coin);
        PoolKey memory venue = _register(address(coin), 2_000, fair);
        PoolKey memory focus =
            _register(address(coin), 3_000, _scaled(fair, 20_000, sell ? !szrFirst : szrFirst));
        _provide(focus, units);
        uint256[] memory ranges = new uint256[](4);
        ranges[0] = units;
        for (uint256 index = 1; index < 4; index++) {
            ranges[index] = dust;
        }
        _bands(venue, _push(venue, sell ? address(coin) : address(szr)), ranges);
        Spec memory spec = _direct(name, venue, focus);
        spec.probe = venue;
        spec.slack = den >= 1e17 ? 100 : 0;
        return _measure(spec);
    }

    function testLowDecimalSixPointFiveMinusTwelveTenSell() public {
        _assertWhole(_lowDecimal("P1s  6.5e-13, dust 10, sell", 65, 1e14, 10, true));
    }

    function testLowDecimalSixPointFiveMinusTwelveMillionSell() public {
        _assertWhole(_lowDecimal("P2s  6.5e-13, dust 1e6, sell", 65, 1e14, 1e6, true));
    }

    function testLowDecimalSixPointFiveMinusTwelveTenBuy() public {
        _assertWhole(_lowDecimal("P1b  6.5e-13, dust 10, buy", 65, 1e14, 10, false));
    }

    function testLowDecimalSixPointFiveMinusTwelveMillionBuy() public {
        _assertWhole(_lowDecimal("P2b  6.5e-13, dust 1e6, buy", 65, 1e14, 1e6, false));
    }

    function testLowDecimalMinusSeventeenTenSell() public {
        _assertWhole(_lowDecimal("P3s  1e-17, dust 10, sell", 1, 1e17, 10, true));
    }

    function testLowDecimalMinusSeventeenMillionSell() public {
        _assertWhole(_lowDecimal("P4s  1e-17, dust 1e6, sell", 1, 1e17, 1e6, true));
    }

    function testLowDecimalMinusSeventeenTenBuy() public {
        _assertWhole(_lowDecimal("P3b  1e-17, dust 10, buy", 1, 1e17, 10, false));
    }

    function testLowDecimalMinusSeventeenMillionBuy() public {
        _assertWhole(_lowDecimal("P4b  1e-17, dust 1e6, buy", 1, 1e17, 1e6, false));
    }
}

/// @dev At the tiny minimum profit, where every profitable cycle counts.
contract ArbitrageSizingEdgesTest is SizingEdges { }
