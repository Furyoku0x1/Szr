// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IndexMath } from "../src/index/IndexMath.sol";

contract IndexMathTest is Test {
    using FixedPointMathLib for uint256;

    string internal constant VECTORS = "test/fixtures/index-vectors.json";
    uint256 internal constant WAD = 1e18;

    struct Leg {
        uint256 balanceIn;
        uint256 weightIn;
        uint256 scaleIn;
        uint256 balanceOut;
        uint256 weightOut;
        uint256 scaleOut;
    }

    function testPowerVectors() public view {
        string memory data = vm.readFile(VECTORS);
        uint256[] memory base = vm.parseJsonUintArray(data, ".powers.base");
        uint256[] memory exponent = vm.parseJsonUintArray(data, ".powers.exponent");
        uint256[] memory raw = vm.parseJsonUintArray(data, ".powers.raw");
        uint256[] memory down = vm.parseJsonUintArray(data, ".powers.exactDown36");
        uint256[] memory up = vm.parseJsonUintArray(data, ".powers.exactUp36");
        uint256 worst;
        for (uint256 i; i < base.length; i++) {
            int256 result = FixedPointMathLib.powWad(int256(base[i]), int256(exponent[i]));
            // The script's port of solady must be bit exact, or its sweep says nothing.
            assertEq(uint256(result), raw[i], "port");
            assertLe(IndexMath.powDown(base[i], exponent[i]) * WAD, down[i], "powDown");
            assertGe(IndexMath.powUp(base[i], exponent[i]) * WAD, up[i], "powUp");
            uint256 error = _errorBeyondOneWei(raw[i] * WAD, down[i]);
            if (error > worst) worst = error;
        }
        console2.log("worst powWad relative error beyond 1 wei, 1e36 scale", worst);
        assertLe(worst * 10, IndexMath.POW_MAX_RELATIVE_ERROR * WAD, "margin");
    }

    function testSwapVectors() public view {
        string memory data = vm.readFile(VECTORS);
        bool[] memory exactIn = vm.parseJsonBoolArray(data, ".swaps.exactIn");
        uint256[] memory amount = vm.parseJsonUintArray(data, ".swaps.amount");
        uint256[] memory result = vm.parseJsonUintArray(data, ".swaps.result");
        uint256[] memory power = vm.parseJsonUintArray(data, ".swaps.power36");
        Leg[] memory legs = _legs(data);
        for (uint256 i; i < amount.length; i++) {
            Leg memory leg = legs[i];
            if (exactIn[i]) {
                uint256 out = _out(leg, amount[i]);
                assertLe(out, result[i], "out above exact");
                uint256 slack = _slack(leg.balanceOut, leg.weightIn, leg.weightOut, power[i]);
                assertLe(result[i] - out, slack, "out margin");
                assertLe(IndexMath.fromWadDown(out, leg.scaleOut), result[i] / leg.scaleOut);
            } else {
                uint256 paid = _in(leg, amount[i]);
                assertGe(paid, result[i], "in below exact");
                uint256 slack = _slack(leg.balanceIn, leg.weightOut, leg.weightIn, power[i]);
                assertLe(paid - result[i], slack, "in margin");
                assertGe(IndexMath.fromWadUp(paid, leg.scaleIn), result[i].divUp(leg.scaleIn));
            }
        }
    }

    /// Exact in there, exact in back, on the balances the first leg left.
    function testFuzzRoundTripInIn(uint256 seed, uint256 amount, bool sixIn, bool sixOut)
        public
        pure
    {
        Leg memory leg = _fuzzLeg(seed, sixIn, sixOut);
        uint256 paid = _given(amount, leg.balanceIn.mulWad(30e16), leg.scaleIn);
        uint256 out = _rawOut(leg, paid);
        while (out > leg.balanceOut.mulWad(23e16)) {
            paid = _floorTo(paid / 2, leg.scaleIn);
            out = _rawOut(leg, paid);
        }
        Leg memory back = _reverse(leg, paid, out);
        assertLe(_rawOut(back, out), paid);
    }

    /// Exact in there, then exact out back for everything that was paid.
    function testFuzzRoundTripInOut(uint256 seed, uint256 amount, bool sixIn, bool sixOut)
        public
        pure
    {
        Leg memory leg = _fuzzLeg(seed, sixIn, sixOut);
        uint256 paid = _given(amount, leg.balanceIn.mulWad(30e16), leg.scaleIn);
        uint256 out = _rawOut(leg, paid);
        if (out == 0) return;
        Leg memory back = _reverse(leg, paid, out);
        assertGe(_rawIn(back, paid), out);
    }

    /// Exact out there, then exact in back with everything received.
    function testFuzzRoundTripOutIn(uint256 seed, uint256 amount, bool sixIn, bool sixOut)
        public
        pure
    {
        Leg memory leg = _fuzzLeg(seed, sixIn, sixOut);
        uint256 out = _given(amount, leg.balanceOut.mulWad(23e16), leg.scaleOut);
        uint256 paid = _rawIn(leg, out);
        Leg memory back = _reverse(leg, paid, out);
        assertLe(_rawOut(back, out), paid);
    }

    /// Exact out there, then exact out back for what was paid.
    function testFuzzRoundTripOutOut(uint256 seed, uint256 amount, bool sixIn, bool sixOut)
        public
        pure
    {
        Leg memory leg = _fuzzLeg(seed, sixIn, sixOut);
        uint256 out = _given(amount, leg.balanceOut.mulWad(23e16), leg.scaleOut);
        uint256 paid = _rawIn(leg, out);
        while (paid > (leg.balanceIn + paid).mulWad(30e16)) {
            out = _floorTo(out / 2, leg.scaleOut);
            paid = _rawIn(leg, out);
        }
        if (paid == 0) return;
        Leg memory back = _reverse(leg, paid, out);
        assertGe(_rawIn(back, paid), out);
    }

    /// One raw unit of a 6-decimal token there and back, both kinds, at fuzzed balances.
    function testFuzzRoundTripOneRawUnit(uint256 seed) public pure {
        Leg memory leg = _fuzzLeg(seed, true, true);
        uint256 out = _rawOut(leg, 1e12);
        Leg memory back = _reverse(leg, 1e12, out);
        // On a balance of a few units at a steep weight, one unit in can take so much that
        // selling it back is over the in-ratio limit; only that leg is skipped.
        if (out <= leg.balanceOut.mulWad(23e16)) assertLe(_rawOut(back, out), 1e12);
        uint256 paid = _rawIn(leg, 1e12);
        back = _reverse(leg, paid, 1e12);
        assertLe(_rawOut(back, 1e12), paid);
    }

    function testInRatioLimit() public {
        uint256 balance = 1000e18 + 7;
        uint256 limit = balance.mulWad(30e16);
        this.outGivenExactIn(balance, 5e17, 1000e18, 5e17, limit);
        vm.expectRevert(IndexMath.MaxInRatio.selector);
        this.outGivenExactIn(balance, 5e17, 1000e18, 5e17, limit + 1);
    }

    function testOutRatioLimit() public {
        uint256 balance = 1000e18 + 7;
        uint256 limit = balance.mulWad(30e16);
        this.inGivenExactOut(1000e18, 2e17, balance, 8e17, limit);
        vm.expectRevert(IndexMath.MaxOutRatio.selector);
        this.inGivenExactOut(1000e18, 2e17, balance, 8e17, limit + 1);
    }

    /// Products above 256 bits compare by their high word first, then the low.
    function testProductAtLeastAcrossTheWord() public pure {
        uint256 big = type(uint256).max;
        assertTrue(IndexMath.productAtLeast(big, big, big, big));
        assertTrue(IndexMath.productAtLeast(big, big, big - 1, big));
        assertFalse(IndexMath.productAtLeast(big - 1, big, big, big));
        assertTrue(IndexMath.productAtLeast(2 ** 200, 2 ** 100, 2 ** 150, 2 ** 150));
        assertFalse(IndexMath.productAtLeast(2 ** 200, 2 ** 100 - 1, 2 ** 150, 2 ** 150));
        // Same high word, low words differ: (2^256 + 3) against (2^256 + 2).
        assertTrue(IndexMath.productAtLeast(2 ** 128 + 1, 2 ** 128 + 1, 2 ** 129, 2 ** 127 + 1));
        // 2^256 against 2^256 - 1, and the other way round.
        assertTrue(IndexMath.productAtLeast(2 ** 129, 2 ** 127, 2 ** 128 + 1, 2 ** 128 - 1));
        assertFalse(IndexMath.productAtLeast(2 ** 128 + 1, 2 ** 128 - 1, 2 ** 129, 2 ** 127));
        assertTrue(IndexMath.productAtLeast(0, 5, 0, 7));
        assertFalse(IndexMath.productAtLeast(0, 5, 1, 1));
    }

    function testScalingRoundsAsAsked() public pure {
        assertEq(IndexMath.toWad(3, 1e12), 3e12);
        assertEq(IndexMath.fromWadDown(3e12 + 1, 1e12), 3);
        assertEq(IndexMath.fromWadUp(3e12 + 1, 1e12), 4);
        assertEq(IndexMath.fromWadUp(3e12, 1e12), 3);
        assertEq(IndexMath.fromWadDown(5, 1), 5);
        assertEq(IndexMath.fromWadUp(5, 1), 5);
    }

    function outGivenExactIn(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 a)
        external
        pure
        returns (uint256)
    {
        return IndexMath.outGivenExactIn(bIn, wIn, bOut, wOut, a);
    }

    function inGivenExactOut(uint256 bIn, uint256 wIn, uint256 bOut, uint256 wOut, uint256 a)
        external
        pure
        returns (uint256)
    {
        return IndexMath.inGivenExactOut(bIn, wIn, bOut, wOut, a);
    }

    /// The pool's worst case on a vector: the margin taken twice (the margin itself and the
    /// raw error it covers, which is under a tenth of it) plus the effect of one wei of
    /// rounding on the base and on the exponent, then scaled by the balance.
    function _slack(uint256 balance, uint256 weightGiven, uint256 weightOther, uint256 p36)
        internal
        pure
        returns (uint256)
    {
        uint256 power = p36.divUp(WAD);
        uint256 exponent = weightGiven.divWadUp(weightOther) / WAD + 2;
        uint256 rounding = exponent * (power / WAD + 1);
        uint256 margin = 2 * power.mulWadUp(IndexMath.POW_MAX_RELATIVE_ERROR) + 4;
        return balance.mulWadUp(margin + rounding) + 1;
    }

    /// `(|raw - exact| - 1 wei) / exact` at 1e36 scale, both sides already at 1e36.
    function _errorBeyondOneWei(uint256 raw, uint256 exact) internal pure returns (uint256) {
        uint256 error = raw > exact ? raw - exact : exact - raw;
        if (error <= WAD) return 0;
        return FixedPointMathLib.fullMulDiv(error - WAD, 1e36, exact);
    }

    function _out(Leg memory leg, uint256 amount) internal pure returns (uint256) {
        return IndexMath.outGivenExactIn(
            leg.balanceIn, leg.weightIn, leg.balanceOut, leg.weightOut, amount
        );
    }

    function _in(Leg memory leg, uint256 amount) internal pure returns (uint256) {
        return IndexMath.inGivenExactOut(
            leg.balanceIn, leg.weightIn, leg.balanceOut, leg.weightOut, amount
        );
    }

    /// As the pool will pay it: rounded down to a whole unit of the token out.
    function _rawOut(Leg memory leg, uint256 amount) internal pure returns (uint256) {
        return _floorTo(_out(leg, amount), leg.scaleOut);
    }

    /// As the pool will charge it: rounded up to a whole unit of the token in.
    function _rawIn(Leg memory leg, uint256 amount) internal pure returns (uint256) {
        return IndexMath.fromWadUp(_in(leg, amount), leg.scaleIn) * leg.scaleIn;
    }

    function _floorTo(uint256 amount, uint256 scale) internal pure returns (uint256) {
        return IndexMath.fromWadDown(amount, scale) * scale;
    }

    function _reverse(Leg memory leg, uint256 paid, uint256 out)
        internal
        pure
        returns (Leg memory)
    {
        return Leg(
            leg.balanceOut - out,
            leg.weightOut,
            leg.scaleOut,
            leg.balanceIn + paid,
            leg.weightIn,
            leg.scaleIn
        );
    }

    /// An amount between one whole unit and `cap`, a whole number of units.
    function _given(uint256 amount, uint256 cap, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        return _floorTo(bound(amount, scale, cap), scale);
    }

    function _fuzzLeg(uint256 seed, bool sixIn, bool sixOut)
        internal
        pure
        returns (Leg memory)
    {
        uint256 weightIn = bound(uint256(keccak256(abi.encode(seed, 0))), 1e16, 98e16);
        uint256 weightOut = bound(uint256(keccak256(abi.encode(seed, 1))), 1e16, WAD - weightIn);
        // Shortcut and hand-picked exponents come up often, not only by chance.
        uint256 pick = seed % 4;
        if (pick == 0) weightOut = weightIn;
        if (pick == 1) (weightIn, weightOut) = (8e17, 2e17);
        uint256 scaleIn = sixIn ? 1e12 : 1;
        uint256 scaleOut = sixOut ? 1e12 : 1;
        uint256 balanceIn = _balance(keccak256(abi.encode(seed, 2)), scaleIn);
        uint256 balanceOut = _balance(keccak256(abi.encode(seed, 3)), scaleOut);
        return Leg(balanceIn, weightIn, scaleIn, balanceOut, weightOut, scaleOut);
    }

    /// From five times the minimum balance a swap may leave up to 1e30, over magnitudes.
    function _balance(bytes32 entropy, uint256 scale) internal pure returns (uint256) {
        uint256 floor = 1e6 > scale ? 5e6 : scale * 5;
        uint256 digits = bound(uint256(entropy) >> 128, 0, 30);
        uint256 cap = 10 ** digits;
        if (cap < floor) cap = floor;
        return _floorTo(bound(uint256(uint128(uint256(entropy))), floor, cap), scale);
    }

    function _legs(string memory data) internal pure returns (Leg[] memory legs) {
        uint256[] memory bIn = vm.parseJsonUintArray(data, ".swaps.balanceIn");
        uint256[] memory wIn = vm.parseJsonUintArray(data, ".swaps.weightIn");
        uint256[] memory dIn = vm.parseJsonUintArray(data, ".swaps.decimalsIn");
        uint256[] memory bOut = vm.parseJsonUintArray(data, ".swaps.balanceOut");
        uint256[] memory wOut = vm.parseJsonUintArray(data, ".swaps.weightOut");
        uint256[] memory dOut = vm.parseJsonUintArray(data, ".swaps.decimalsOut");
        legs = new Leg[](bIn.length);
        for (uint256 i; i < bIn.length; i++) {
            legs[i] = Leg(
                bIn[i], wIn[i], 10 ** (18 - dIn[i]), bOut[i], wOut[i], 10 ** (18 - dOut[i])
            );
        }
    }
}
