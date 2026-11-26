// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { ProtocolFeeLibrary } from "v4-core/libraries/ProtocolFeeLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { LibraryWorld, V4ReadHarness } from "./utils/ArbitrageLibraries.sol";
import { TestAsset } from "./utils/TestAsset.sol";

/// @dev A token whose balance cannot be read.
contract UnreadableAsset {
    function balanceOf(address) external pure returns (uint256) {
        revert("no");
    }
}

/// @dev How the hook reads and trades a v4 pool, on its own, against a real pool manager.
contract ArbitrageV4ReadTest is LibraryWorld {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    V4ReadHarness internal reader;
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        reader = new V4ReadHarness(manager);
        key = _pool(3000, 60, uint160(Q96 * 11 / 10), 1e24);
        _fund(TestAsset(token0), address(reader));
        _fund(TestAsset(token1), address(reader));
    }

    function _word() internal view returns (bytes32) {
        return manager.extsload(StateLibrary._getPoolStateSlot(PoolId.wrap(_id(key))));
    }

    /// A real pool's first word unpacks to its price, its fee and the protocol's, and the
    /// fee a swap pays is the two combined as the pool manager combines them.
    function testUnpackAndFeesFromARealPool() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 300 | (700 << 12));
        (uint160 price,, uint24 levied, uint24 own) = manager.getSlot0(PoolId.wrap(_id(key)));
        (uint256 rate, uint24 fee, uint24 levy) = reader.unpack(_word(), true);
        assertEq(rate, price, "rate, base first");
        assertEq(fee, own, "fee");
        assertEq(fee, 3000, "the pool's fee");
        assertEq(levy, levied, "protocol fee");
        (rate,,) = reader.unpack(_word(), false);
        assertEq(rate, Q192 / price, "rate, base second");
        // The larger direction counts for both, and the overlap rounds in the payer's
        // disfavour, as `ProtocolFeeLibrary` does.
        uint24 total = reader.swapFee(fee, levy);
        assertEq(total, ProtocolFeeLibrary.calculateSwapFee(700, 3000), "as v4 combines them");
        assertEq(total, 3698, "700 + 3000 - 2");
        assertEq(reader.swapFee(fee, 0), 3000, "no protocol fee");
    }

    /// A price outside the band the pricing arithmetic allows is no price.
    function testUnpackDropsAPriceOutOfBand() public view {
        (uint256 rate, uint24 fee,) =
            reader.unpack(bytes32(uint256(1) << 39 | 500 << 208), true);
        assertEq(rate, 0, "too low");
        assertEq(fee, 500, "the fee is still read");
        (rate,,) = reader.unpack(bytes32(0), true);
        assertEq(rate, 0, "no pool");
    }

    /// The table of common tiers is exactly the square root it stands for.
    function testKeepTiers() public view {
        uint24[4] memory tiers = [uint24(100), 500, 3_000, 10_000];
        for (uint256 index; index < 4; index++) {
            assertEq(reader.keepFast(tiers[index]), reader.keep(tiers[index]), "tier");
        }
        assertEq(reader.keep(3000), 998498873309329277, "0.3%");
        assertEq(reader.keep(1234), FixedPointMathLib.sqrt((1e6 - 1234) * 1e30), "rounded down");
        assertEq(reader.keep(1e6), 0, "nothing kept");
    }

    /// A leg's limit is its price moved against it by `(1 + gap)²`, inside the tick range.
    function testLimitFrom() public view {
        uint160 price = uint160(Q96);
        assertEq(reader.limitFrom(price, true, 0.1e18), Q96 * 100 / 121, "down by 1.21");
        assertEq(reader.limitFrom(price, false, 0.1e18), Q96 * 121 / 100, "up by 1.21");
        assertEq(
            reader.limitFrom(TickMath.MIN_SQRT_PRICE + 5, true, 1e18),
            TickMath.MIN_SQRT_PRICE + 1,
            "the lowest limit"
        );
        assertEq(
            reader.limitFrom(TickMath.MAX_SQRT_PRICE - 5, false, 1e18),
            TickMath.MAX_SQRT_PRICE - 1,
            "the highest limit"
        );
    }

    function testHarmonic() public view {
        assertEq(reader.harmonic(6, 3), 2);
        assertEq(reader.harmonic(0, 3), 0);
        assertEq(reader.harmonic(3, 0), 0);
    }

    /// `_trade` reports what the swap took and paid, for exact inputs and exact outputs.
    function testTradeReportsWhatMoved() public {
        uint256 before = TestAsset(token1).balanceOf(address(reader));
        (uint256 spent, uint256 received) = reader.trade(key, token0, -1e18, 0);
        assertEq(spent, 1e18, "exact input");
        assertEq(TestAsset(token1).balanceOf(address(reader)) - before, received, "received");
        (spent, received) = reader.trade(key, token1, 1e18, 0);
        assertEq(received, 1e18, "exact output");
        assertGt(spent, 1e18, "token0 is dearer");
    }

    /// The pool manager must hold what is about to be taken. A balance that cannot be read
    /// at payout, with gas to spare, is `Unsettled`; anywhere else it reverts empty.
    function testFundedChecksThePoolManager() public {
        assertEq(V4Read.Drained.selector, bytes4(keccak256("Drained()")));
        assertEq(V4Read.Unsettled.selector, bytes4(keccak256("Unsettled()")));
        assertEq(V4Read.InvalidDelta.selector, bytes4(keccak256("InvalidDelta()")));
        uint256 held = TestAsset(token0).balanceOf(address(manager));
        reader.funded(Currency.wrap(token0), held, false);
        vm.expectRevert(V4Read.Drained.selector);
        reader.funded(Currency.wrap(token0), held + 1, false);
        reader.funded(Currency.wrap(address(0)), 0, false);
        vm.expectRevert(V4Read.Drained.selector);
        reader.funded(Currency.wrap(address(0)), 1, false);
        address unreadable = address(new UnreadableAsset());
        vm.expectRevert(V4Read.Unsettled.selector);
        reader.funded(Currency.wrap(unreadable), 1, true);
        vm.expectRevert(bytes(""));
        reader.funded(Currency.wrap(unreadable), 1, false);
    }
}
