// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { MetricPricer } from "../src/pricers/MetricPricer.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { MetricBook } from "../src/pricers/lib/MetricBook.sol";

/// @dev A Metric pool that answers with set prices and set storage words.
contract MockBook {
    uint128 public sell;
    uint128 public buy;
    bool public broken;
    mapping(bytes32 => bytes32) internal words;

    function setPrices(uint128 s, uint128 b) external {
        sell = s;
        buy = b;
    }

    function setBroken(bool value) external {
        broken = value;
    }

    /// Slot 0 as `PoolStateLibrary` packs it, and the one bin's word at slot 4.
    function setBin(
        int16 idx,
        uint104 pos,
        int24 dist,
        uint104 token0,
        uint104 token1,
        uint16 length
    ) external {
        words[bytes32(0)] = bytes32(
            uint256(uint16(idx)) << 8 | uint256(pos) << 24 | uint256(uint24(dist)) << 128
        );
        words[keccak256(abi.encode(int256(idx), uint256(4)))] =
            bytes32(uint256(token0) | uint256(token1) << 104 | uint256(length) << 208);
    }

    function setPause(uint8 value) external {
        words[bytes32(0)] = bytes32(uint256(words[bytes32(0)]) | value);
    }

    function getSellAndBuyPrices() external view returns (uint128, uint128) {
        require(!broken, "feed");
        return (sell, buy);
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        return words[slot];
    }
}

/// @dev A wrapper's `bindings`, as `MetricVenueHook` keeps them.
contract MockWrapper {
    struct Binding {
        address pool;
        bool flipped;
        bool disabled;
        uint128 scale0;
        uint128 scale1;
    }

    mapping(PoolId => Binding) public bindings;

    function bind(PoolId id, Binding calldata binding) external {
        bindings[id] = binding;
    }
}

contract MetricPricerTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant Q96 = 1 << 96;
    uint104 internal constant MAX_POS = type(uint104).max;

    MockBook internal book;
    MockWrapper internal wrapper;
    MetricPricer internal pricer;
    PoolKey internal key;

    function setUp() public {
        book = new MockBook();
        wrapper = new MockWrapper();
        pricer = new MetricPricer(MetricVenueHook(payable(address(wrapper))));
        key = PoolKey(
            Currency.wrap(address(0xA0)), Currency.wrap(address(0xB0)), 0, 1, IHooks(address(1))
        );
    }

    function _bind(bool flipped, uint128 s0, uint128 s1) internal {
        wrapper.bind(key.toId(), MockWrapper.Binding(address(book), flipped, false, s0, s1));
    }

    /// Mid 4, a tenth of a percent either side, and a bin 0.5% either way of the reference
    /// with the position in the middle, holding 2 token0 and 1 token1 (18 decimals each).
    function _standard(bool flipped) internal {
        _bind(flipped, 1, 1);
        book.setPrices(uint128(4 * Q64 * 999 / 1000), uint128(4 * Q64 * 1001 / 1000));
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
    }

    function _close(uint256 actual, uint256 expected, uint256 tolerance) internal pure {
        uint256 gap = actual > expected ? actual - expected : expected - actual;
        assertLe(gap * 1e18 / expected, tolerance);
    }

    function testMidpointAndFee() public {
        _standard(false);
        (uint160 root, uint24 fee,,,) = pricer.price(key);
        _close(root, 2 * Q96, 1e9);
        // A tenth of a percent either side of the midpoint, rounded up to a pip, plus 15 pips
        // for a bin 1% wide.
        assertGe(fee, 1015);
        assertLe(fee, 1016);
    }

    function testRangeAndLiquidityAgainstHandValues() public {
        _standard(false);
        (uint160 root, uint24 fee, uint128 liquidity, uint160 lower, uint160 upper) =
            pricer.price(key);
        // The bin runs 0.995 to 1.005 of the reference, which is 4: edges at sqrt(3.98) and
        // sqrt(4.02), taken from the midpoint at the middle of the bin.
        _close(lower, 19_949_937_343_260_002 * Q96 / 1e16, 1e9);
        _close(upper, 20_049_937_655_763_420 * Q96 / 1e16, 1e9);
        assertLt(lower, root);
        assertGt(upper, root);
        assertGt(fee, 0);
        // The token1 side limits: 1e18 over (2 - 1.99499373) is about 1.9975e20; the token0
        // side would give 1.606e21.
        _close(liquidity, 1.99749686716e20, 1e12);
    }

    function testFlippedPoolIsInverted() public {
        _standard(true);
        (uint160 root,, uint128 liquidity, uint160 lower, uint160 upper) = pricer.price(key);
        // The v4 price is the inverse: root 0.5, the edges swap ends, and the reserves swap
        // roles, so the token0 side (Metric's token1, 1e18) limits.
        _close(root, Q96 / 2, 1e9);
        _close(lower, 4_987_546_680_538_164 * Q96 / 1e16, 1e9);
        _close(upper, 5_012_547_071_170_855 * Q96 / 1e16, 1e9);
        _close(liquidity, 1.99749686716e20, 1e12);
    }

    /// WETH has 18 decimals and USDG 6: Metric's scaled amounts are raw times a multiplier,
    /// 1 and 1e12, and a price of 2000 is 2e-9 raw USDG per raw WETH.
    function testDecimalsScaling() public {
        _bind(false, 1, 1e12);
        book.setPrices(
            uint128(2000 * Q64 * 9999 / 10_000), uint128(2000 * Q64 * 10_001 / 10_000)
        );
        book.setBin(0, MAX_POS / 2, -1000, 5e18, 5000e18, 2000);
        (uint160 root,, uint128 liquidity, uint160 lower,) = pricer.price(key);
        // sqrt(2e-9) in Q96.
        _close(root, Q96 * 44_721_359_549_995_800 / 1e21, 1e9);
        // Raw reserves are 5 WETH and 5000 USDG, 5e18 and 5e9 raw units.
        uint256 y = uint256(liquidity) * (root - lower) / Q96;
        assertLe(y, 5000e6, "never claims more than the bin holds");
        assertGt(y, 4999e6);
    }

    function testFlippedDecimals() public {
        _bind(true, 1, 1e12);
        book.setPrices(
            uint128(2000 * Q64 * 9999 / 10_000), uint128(2000 * Q64 * 10_001 / 10_000)
        );
        book.setBin(0, MAX_POS / 2, -1000, 5e18, 5000e18, 2000);
        // v4's token0 is USDG: 6 decimals, 0.0005 WETH raw per raw USDG is 5e8, so a root of
        // sqrt(5e8) = 22360.68 times 2^96.
        (uint160 root,, uint128 liquidity, uint160 lower, uint160 upper) = pricer.price(key);
        _close(root, 22_360_679_774_997 * Q96 / 1e9, 1e9);
        // The token0 side is 5000e6 USDG: it never claims more than that.
        uint256 x = uint256(liquidity) * Q96 / root - uint256(liquidity) * Q96 / upper;
        assertLe(x, 5000e6 + 1);
        assertGt(x, 4999e6);
        assertLt(lower, root);
        assertGt(upper, root);
    }

    function testNoPriceWhenTheFeedReverts() public {
        _standard(false);
        book.setBroken(true);
        vm.expectRevert();
        pricer.price(key);
    }

    function testNoPriceForAnUnboundPool() public {
        vm.expectRevert(MetricPricer.Unbound.selector);
        pricer.price(key);
    }

    function testNoPriceForADisabledBinding() public {
        _standard(false);
        wrapper.bind(key.toId(), MockWrapper.Binding(address(book), false, true, 1, 1));
        vm.expectRevert(MetricPricer.Unbound.selector);
        pricer.price(key);
    }

    function testNoPriceWhenTheFeeReachesOneHundredPercent() public {
        _standard(false);
        // A sell price of zero is the whole midpoint away.
        book.setPrices(0, uint128(8 * Q64));
        vm.expectRevert(MetricBook.NoPrice.selector);
        pricer.price(key);
    }

    function testNoPriceWithoutABin() public {
        _standard(false);
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 0);
        vm.expectRevert(MetricBook.NoPrice.selector);
        pricer.price(key);
    }

    /// 300.5 pips is reported as 301, never 300.
    function testFeeRoundsUp() public {
        _bind(false, 1, 1);
        uint128 mid = uint128(4 * Q64);
        uint128 gap = uint128(uint256(mid) * 3005 / 10_000_000);
        book.setPrices(mid - gap, mid + gap);
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
        (, uint24 fee,,,) = pricer.price(key);
        assertEq(fee, 316);
    }

    /// A bin 5% wide adds ceil(0.15 * 0.05^2 * 1e6) = 375 pips; a narrow one adds 1.
    function testWideBinAddsFee() public {
        _standard(false);
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 50_000);
        (, uint24 fee,,,) = pricer.price(key);
        assertGe(fee, 1375);
        assertLe(fee, 1376);
        book.setBin(7, MAX_POS / 2, -5000, 2e18, 1e18, 100);
        (, fee,,,) = pricer.price(key);
        assertGe(fee, 1001);
        assertLe(fee, 1002);
    }

    function testNoPriceWhenPaused() public {
        _standard(false);
        book.setPause(1);
        vm.expectRevert(MetricBook.NoPrice.selector);
        pricer.price(key);
    }

    /// A negative bin index must be sign extended to find the bin's word.
    function testNegativeBinIndex() public {
        _standard(false);
        (uint160 rootA,, uint128 liqA,,) = pricer.price(key);
        book.setBin(-3, MAX_POS / 2, -5000, 2e18, 1e18, 10_000);
        (uint160 rootB,, uint128 liqB,,) = pricer.price(key);
        assertEq(rootB, rootA);
        assertEq(liqB, liqA);
    }

    function testNoPriceWhenTheBinReachesZeroPrice() public {
        _standard(false);
        book.setBin(7, MAX_POS / 2, -1_000_000, 2e18, 1e18, 10_000);
        vm.expectRevert(MetricBook.NoPrice.selector);
        pricer.price(key);
        book.setBin(7, MAX_POS / 2, -1_500_000, 2e18, 1e18, 10_000);
        vm.expectRevert(MetricBook.NoPrice.selector);
        pricer.price(key);
    }

    /// The liquidity never claims more of a side than the bin holds.
    function testLiquidityRoundsDown() public {
        _standard(false);
        (uint160 root,, uint128 liquidity, uint160 lower, uint160 upper) = pricer.price(key);
        assertLe(uint256(liquidity) * (root - lower) / Q96, 1e18);
        uint256 x = uint256(liquidity) * Q96 / root - uint256(liquidity) * Q96 / upper;
        assertLe(x, 2e18);
    }

    /// At the bin's lower end there is no token1 to walk down through, and the range's
    /// lower edge is the price itself; the token0 side still gives a liquidity.
    function testPositionAtTheLowerEdge() public {
        _standard(false);
        book.setBin(7, 0, -5000, 2e18, 0, 10_000);
        (uint160 root,, uint128 liquidity, uint160 lower, uint160 upper) = pricer.price(key);
        assertEq(lower, root);
        assertGt(upper, root);
        assertGt(liquidity, 0);
    }

    function testPositionAtTheUpperEdge() public {
        _standard(false);
        book.setBin(7, MAX_POS, -5000, 0, 1e18, 10_000);
        (uint160 root,, uint128 liquidity, uint160 lower, uint160 upper) = pricer.price(key);
        assertEq(upper, root);
        assertLt(lower, root);
        assertGt(liquidity, 0);
    }

    function testRangeStaysInsideTickMath() public {
        _standard(false);
        (uint160 root,,, uint160 lower, uint160 upper) = pricer.price(key);
        assertGt(lower, TickMath.MIN_SQRT_PRICE);
        assertLt(upper, TickMath.MAX_SQRT_PRICE);
        assertLe(lower, root);
        assertGe(upper, root);
    }
}
