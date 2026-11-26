// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IndexMath } from "../src/index/IndexMath.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexToken, IndexWorld } from "./utils/IndexWorld.sol";

contract IndexPoolTest is IndexWorld {
    using FixedPointMathLib for uint256;

    address internal alice = makeAddr("alice");

    // ---------------------------------------------------------------- construction

    function testRefusesTokenCounts() public {
        address[] memory one = _tokens(_same(18, 1));
        vm.expectRevert(IndexPool.InvalidTokenCount.selector);
        _construct(one, _equal(1), FEE);
        address[] memory nine = _tokens(_same(18, 9));
        uint256[] memory weights = new uint256[](9);
        for (uint256 index; index < 9; index++) {
            weights[index] = index == 0 ? 1e18 - 8 * 11e16 : 11e16;
        }
        vm.expectRevert(IndexPool.InvalidTokenCount.selector);
        _construct(nine, weights, FEE);
        address[] memory eight = _tokens(_same(18, 8));
        _construct(eight, _equal(8), FEE);
    }

    function testRefusesUnsortedAndRepeatedTokens() public {
        address[] memory list = _tokens(_same(18, 2));
        address[] memory swapped = new address[](2);
        swapped[0] = list[1];
        swapped[1] = list[0];
        vm.expectRevert(IndexPool.UnsortedTokens.selector);
        _construct(swapped, _equal(2), FEE);
        swapped[0] = list[0];
        swapped[1] = list[0];
        vm.expectRevert(IndexPool.UnsortedTokens.selector);
        _construct(swapped, _equal(2), FEE);
    }

    function testRefusesNativeEther() public {
        address[] memory list = _tokens(_same(18, 2));
        list[0] = address(0);
        vm.expectRevert(IndexPool.NativeToken.selector);
        _construct(list, _equal(2), FEE);
    }

    function testWeightLimits() public {
        address[] memory list = _tokens(_same(18, 2));
        vm.expectRevert(IndexPool.WeightTooLow.selector);
        _construct(list, _weights(1e16 - 1, 99e16 + 1), FEE);
        _construct(list, _weights(1e16, 99e16), FEE);
        vm.expectRevert(IndexPool.WeightsNotWhole.selector);
        _construct(list, _weights(5e17, 5e17 + 1), FEE);
        vm.expectRevert(IndexPool.WeightsNotWhole.selector);
        _construct(list, _weights(5e17, 5e17 - 1), FEE);
    }

    function testSwapFeeLimits() public {
        address[] memory list = _tokens(_same(18, 2));
        vm.expectRevert(IndexPool.InvalidSwapFee.selector);
        _construct(list, _equal(2), 1e13 - 1);
        vm.expectRevert(IndexPool.InvalidSwapFee.selector);
        _construct(list, _equal(2), 1e17 + 1);
        _construct(list, _equal(2), 1e13);
        _construct(list, _equal(2), 1e17);
    }

    function testDecimalsLimit() public {
        address[] memory list = _tokens(_pair(18, 19));
        vm.expectRevert(IndexPool.TooManyDecimals.selector);
        _construct(list, _equal(2), FEE);
        _construct(_tokens(_pair(18, 0)), _equal(2), FEE);
    }

    // ---------------------------------------------------------------- maths

    /// Every configuration the spec names prices exactly as `IndexMath` does, so the
    /// reference vectors in `IndexMath.t.sol` apply to the pool. The fee only shrinks what
    /// enters the maths.
    function testPoolPricesWithTheMaths() public {
        _checkConfig(_pair(18, 18), _weights(5e17, 5e17));
        _checkConfig(_pair(6, 18), _weights(8e17, 2e17));
        _checkConfig(_pair(18, 6), _weights(99e16, 1e16));
        _checkConfig(_pair(6, 18), _weights(1e16, 99e16));
        _checkConfig(_same(18, 5), _equal(5));
        uint8[] memory mixed = _same(18, 8);
        mixed[3] = 6;
        _checkConfig(mixed, _equal(8));
    }

    // ---------------------------------------------------------------- rounding

    function testExactInThenExactOutBackNeverProfits() public {
        IndexPool pool = _pool(_pair(18, 6), _weights(8e17, 2e17), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        (uint256 paid, uint256 got) = _swap(pool, list[0], list[1], 1234e18, true);
        (uint256 cost,) = _swap(pool, list[1], list[0], paid, false);
        assertGe(cost, got);
    }

    /// 1,000 swaps at `MIN_TRADE`: each pair takes `MIN_TRADE` of A in and then out again,
    /// so any gain would show in B.
    function testDustSwapsNeverProfit() public {
        IndexPool pool = _unstarted(_pair(18, 18), _equal(2));
        address[] memory list = pool.tokens();
        _startUneven(pool, 1000e18, 3000e18);
        uint256 a = _balanceOf(list[0], address(this));
        uint256 b = _balanceOf(list[1], address(this));
        for (uint256 index; index < 500; index++) {
            _swap(pool, list[0], list[1], 1e6, true);
            _swap(pool, list[1], list[0], 1e6, false);
        }
        assertEq(_balanceOf(list[0], address(this)), a);
        assertLe(_balanceOf(list[1], address(this)), b);
    }

    /// 1,000 swaps of one raw unit of a 6-decimal token: out one unit, then back.
    function testRawUnitSwapsNeverProfit() public {
        IndexPool pool = _pool(_pair(6, 18), _equal(2), 1e6, address(0), 0);
        (address usdg, address stock) = _sixFirst(pool);
        uint256 dollars = _balanceOf(usdg, address(this));
        uint256 shares = _balanceOf(stock, address(this));
        for (uint256 index; index < 500; index++) {
            (uint256 paid,) = _swap(pool, stock, usdg, 1, false);
            _swap(pool, usdg, stock, paid, false);
        }
        assertLe(_balanceOf(usdg, address(this)), dollars);
        assertLe(_balanceOf(stock, address(this)), shares);
    }

    // ---------------------------------------------------------------- limits

    function testInRatioOnTheGivenSide() public {
        (IndexPool pool, address hook) = _feeFreePool(_equal(2));
        address[] memory list = pool.tokens();
        uint256 limit = pool.balances()[0].mulWad(30e16);
        vm.prank(hook);
        pool.quoteSwap(list[0], list[1], limit, true);
        vm.prank(hook);
        vm.expectRevert(IndexMath.MaxInRatio.selector);
        pool.quoteSwap(list[0], list[1], limit + 1, true);
    }

    function testOutRatioOnTheGivenSide() public {
        (IndexPool pool, address hook) = _feeFreePool(_weights(99e16, 1e16));
        address[] memory list = pool.tokens();
        uint256 limit = pool.balances()[1].mulWad(30e16);
        vm.prank(hook);
        pool.quoteSwap(list[0], list[1], limit, false);
        vm.prank(hook);
        vm.expectRevert(IndexMath.MaxOutRatio.selector);
        pool.quoteSwap(list[0], list[1], limit + 1, false);
    }

    /// At 1/99 a small exact-out asks for a large amount in; the pool bounds that too.
    function testInRatioOnTheComputedSide() public {
        IndexPool pool = _pool(_pair(18, 18), _weights(1e16, 99e16), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 edge = _edge(pool, list[0], list[1], false, 1e6, 1e24);
        _expectQuoteRevert(
            pool, list[0], list[1], edge + 1, false, IndexMath.MaxInRatio.selector
        );
    }

    /// At 99/1 a 30% exact-in would take almost all of the other token; the pool stops it.
    function testOutRatioOnTheComputedSide() public {
        IndexPool pool = _pool(_pair(18, 18), _weights(99e16, 1e16), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 edge = _edge(pool, list[0], list[1], true, 1e6, 3e23);
        _expectQuoteRevert(
            pool, list[0], list[1], edge + 1, true, IndexMath.MaxOutRatio.selector
        );
    }

    function testMinimumTradeOnBothSides() public {
        IndexPool pool = _unstarted(_pair(18, 18), _equal(2));
        address[] memory list = pool.tokens();
        _startUneven(pool, 1000e18, 500e18);
        _expectQuoteRevert(
            pool, list[0], list[1], 1e6 - 1, true, IndexPool.TradeTooSmall.selector
        );
        _expectQuoteRevert(
            pool, list[0], list[1], 1e6 - 1, false, IndexPool.TradeTooSmall.selector
        );
        pool.quoteSwap(list[0], list[1], 1e6, false);
        // Paying in gives about half as much out, so the computed side binds first.
        uint256 edge = _lowEdge(pool, list[0], list[1], 1e6, 1e8);
        assertGt(edge, 2e6);
        _expectQuoteRevert(
            pool, list[0], list[1], edge - 1, true, IndexPool.TradeTooSmall.selector
        );
    }

    /// A token in below `MIN_BALANCE` refuses the swap first. At the minimum itself the 30%
    /// and minimum-trade limits already bind, so no swap can run there either.
    /// @dev The token-out side of the rule cannot be reached, so it has no test of its own.
    /// At 18 decimals an amount out of at least `MIN_TRADE` (1e6) and at most 30% of the
    /// balance needs a balance of at least 3.33e6, which leaves at least 2.33e6. At fewer
    /// decimals 30% of the balance can never take the last raw unit.
    function testTokenInBelowMinimumBalance() public {
        IndexPool pool = _unstarted(_pair(18, 18), _equal(2));
        address[] memory list = pool.tokens();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e9;
        amounts[1] = 1e9;
        _fund(address(this), pool, amounts);
        pool.start(amounts, 1e12, FAR);
        // Leave exactly 1e6 of each, then one wei less.
        pool.exit(999e9, _zeros(2), _none(), FAR);
        assertEq(pool.balances()[0], 1e6);
        _expectQuoteRevert(pool, list[0], list[1], 3e5, true, IndexPool.TradeTooSmall.selector);
        pool.exit(1e3, _zeros(2), _none(), FAR);
        assertEq(pool.balances()[0], 1e6 - 1);
        _expectQuoteRevert(pool, list[0], list[1], 3e5, true, IndexPool.BalanceTooLow.selector);
    }

    function testDeadSharesStayLocked() public {
        IndexPool pool = _pool(_pair(18, 6), _equal(2), 1e6, address(0), 0);
        pool.exit(pool.balanceOf(address(this)), _zeros(2), _none(), FAR);
        assertEq(pool.totalSupply(), pool.DEAD_SHARES());
        assertEq(pool.balanceOf(pool.DEAD()), pool.DEAD_SHARES());
        vm.expectRevert();
        pool.exit(1, _zeros(2), _none(), FAR);
    }

    // ---------------------------------------------------------------- fees

    function testFeeIsTheSameRateBothWays() public {
        (IndexPool pool, address hook) = _feeFreePool(_equal(2));
        address[] memory list = pool.tokens();
        uint256 amount = 1000e18;
        (, uint256 out) = pool.quoteSwap(list[0], list[1], amount, true);
        uint256 net = amount - amount.mulWadUp(FEE);
        vm.prank(hook);
        (, uint256 freeOut) = pool.quoteSwap(list[0], list[1], net, true);
        assertEq(out, freeOut);
        (uint256 paid,) = pool.quoteSwap(list[0], list[1], 1000e18, false);
        vm.prank(hook);
        (uint256 freePaid,) = pool.quoteSwap(list[0], list[1], 1000e18, false);
        // The fee is `rate` of everything paid, to well within one part in a billion.
        uint256 rate = (paid - freePaid).divWad(paid);
        assertApproxEqRel(rate, FEE, 1e9);
    }

    /// The exact-out fee is rounded up, in a case where rounding down would differ.
    function testExactOutFeeRoundsUp() public {
        (IndexPool pool, address hook) = _feeFreePool(_equal(2));
        address[] memory list = pool.tokens();
        uint256 wanted = 1e18 + 12_345;
        vm.prank(hook);
        (uint256 net,) = pool.quoteSwap(list[0], list[1], wanted, false);
        uint256 up = FixedPointMathLib.fullMulDivUp(net, FEE, 1e18 - FEE);
        uint256 down = FixedPointMathLib.fullMulDiv(net, FEE, 1e18 - FEE);
        assertEq(up, down + 1, "a case where the direction matters");
        (uint256 paid,) = _swap(pool, list[0], list[1], wanted, false);
        assertEq(paid, net + up);
    }

    /// An exact-in swap that would pay nothing in the token's own units is refused (review,
    /// finding 4): 1e11 wei of an 18-decimal token is worth less than one raw unit of a
    /// 6-decimal one, though it clears `MIN_TRADE` in 18 decimals.
    function testZeroPayoutIsRefused() public {
        IndexPool pool = _pool(_pair(18, 6), _equal(2), 1e6, address(0), 0);
        (address six, address eighteen) = _sixFirst(pool);
        vm.expectRevert(IndexPool.TradeTooSmall.selector);
        pool.swap(eighteen, six, 1e11, true, 0, address(this), FAR);
        (, uint256 got) = pool.swap(eighteen, six, 11e11, true, 0, address(this), FAR);
        assertEq(got, 1);
    }

    function testFeeSplitsEightyFiveFifteen() public {
        (IndexPool pool,) = _feeFreePool(_equal(2));
        address[] memory list = pool.tokens();
        uint256 before = pool.balances()[0];
        uint256 amount = 1000e18;
        _swap(pool, list[0], list[1], amount, true);
        uint256 fee = amount.mulWadUp(FEE);
        uint256 cut = fee * 1500 / 10_000;
        assertEq(pool.owed(list[0]), cut);
        assertEq(pool.balances()[0] - before, amount - cut);
        assertEq(pool.owed(list[1]), 0);
    }

    function testPayProtocolPaysOnlyProtocol() public {
        (IndexPool pool,) = _feeFreePool(_equal(2));
        address[] memory list = pool.tokens();
        _swap(pool, list[0], list[1], 1000e18, true);
        uint256 owed = pool.owed(list[0]);
        assertGt(owed, 0);
        vm.prank(alice);
        assertEq(pool.payProtocol(list[0]), owed);
        assertEq(_balanceOf(list[0], protocol), owed);
        assertEq(_balanceOf(list[0], alice), 0);
        assertEq(pool.owed(list[0]), 0);
        assertEq(pool.payProtocol(list[0]), 0);
    }

    // ---------------------------------------------------------------- shares

    function testStartRunsOnceForTheCreator() public {
        IndexPool pool = _create(_tokens(_same(18, 2)), _equal(2), FEE, address(0), 0);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e9;
        amounts[1] = 1e9;
        _fund(address(this), pool, amounts);
        _fund(alice, pool, amounts);
        address first = pool.tokens()[0];
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.donate(first, 1);
        vm.prank(alice);
        vm.expectRevert(IndexPool.NotCreator.selector);
        pool.start(amounts, 1e12, FAR);
        vm.expectRevert(IndexPool.InvalidShares.selector);
        pool.start(amounts, 1e12 - 1, FAR);
        vm.expectRevert(IndexPool.InvalidShares.selector);
        pool.start(amounts, uint256(type(uint128).max) + 1, FAR);
        amounts[1] = 1e9 - 1;
        vm.expectRevert(IndexPool.StartTooSmall.selector);
        pool.start(amounts, 1e12, FAR);
        amounts[1] = 1e9;
        pool.start(amounts, 1e12, FAR);
        assertEq(pool.balanceOf(address(this)), 1e12 - 1e6);
        vm.expectRevert(IndexPool.AlreadyStarted.selector);
        pool.start(amounts, 1e12, FAR);
    }

    function testJoinAndExitMatchPreviews() public {
        IndexPool pool = _pool(_pair(6, 18), _weights(3e17, 7e17), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 shares = 123_456_789e12;
        uint256[] memory expected = pool.previewJoin(shares);
        uint256 a = _balanceOf(list[0], address(this));
        uint256 b = _balanceOf(list[1], address(this));
        pool.join(shares, expected, FAR);
        assertEq(a - _balanceOf(list[0], address(this)), expected[0]);
        assertEq(b - _balanceOf(list[1], address(this)), expected[1]);
        expected = pool.previewExit(shares);
        a = _balanceOf(list[0], address(this));
        b = _balanceOf(list[1], address(this));
        pool.exit(shares, expected, _none(), FAR);
        assertEq(_balanceOf(list[0], address(this)) - a, expected[0]);
        assertEq(_balanceOf(list[1], address(this)) - b, expected[1]);
    }

    function testFuzzJoinThenExitNeverProfits(uint256 shares) public {
        IndexPool pool = _pool(_pair(6, 18), _weights(3e17, 7e17), 1e6, address(0), 0);
        shares = bound(shares, 1, 1e30);
        uint256[] memory paid = pool.previewJoin(shares);
        pool.join(shares, _maxes(2), FAR);
        uint256[] memory back = pool.previewExit(shares);
        assertLe(back[0], paid[0]);
        assertLe(back[1], paid[1]);
    }

    /// The first depositor starts tiny and donates a fortune to make each share dear. A
    /// second depositor names the shares it wants, so it loses at most rounding.
    function testFirstDepositorCannotInflateAgainstTheSecond() public {
        IndexPool pool = _create(_tokens(_same(18, 2)), _equal(2), FEE, address(0), 0);
        address[] memory list = pool.tokens();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e9;
        amounts[1] = 1e9;
        _fundAll(address(this), pool, 1e40);
        pool.start(amounts, 1e12, FAR);
        pool.donate(list[0], 1e30);
        vm.warp(block.timestamp + 3 days);
        _fundAll(alice, pool, 1e40);
        vm.startPrank(alice);
        uint256[] memory paid = pool.previewJoin(1e6);
        pool.join(1e6, _maxes(2), FAR);
        uint256[] memory back = pool.previewExit(1e6);
        vm.stopPrank();
        assertLe(paid[0] - back[0], 1);
        assertLe(paid[1] - back[1], 1);
    }

    // ---------------------------------------------------------------- tokens that misbehave

    function testFeeOnTransferRefused() public {
        IndexPool pool = _create(_tokens(_same(18, 2)), _equal(2), FEE, address(0), 0);
        address[] memory list = pool.tokens();
        _fundAll(address(this), pool, 1e40);
        IndexToken(list[0]).setFee(10);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e21;
        amounts[1] = 1e21;
        vm.expectRevert(IndexPool.TransferMismatch.selector);
        pool.start(amounts, 1e24, FAR);
        IndexToken(list[0]).setFee(0);
        pool.start(amounts, 1e24, FAR);
        IndexToken(list[0]).setFee(10);
        vm.expectRevert(IndexPool.TransferMismatch.selector);
        _swap(pool, list[0], list[1], 1e18, true);
        vm.expectRevert(IndexPool.TransferMismatch.selector);
        pool.join(1e18, _maxes(2), FAR);
        vm.expectRevert(IndexPool.TransferMismatch.selector);
        pool.donate(list[0], 1e18);
    }

    function testTokensSentDirectlyChangeNothing() public {
        IndexPool pool = _pool(_pair(18, 6), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        (, uint256 out) = pool.quoteSwap(list[0], list[1], 1e18, true);
        uint256[] memory exitBefore = pool.previewExit(1e18);
        IndexToken(list[0]).mint(address(pool), 1e30);
        (, uint256 after_) = pool.quoteSwap(list[0], list[1], 1e18, true);
        assertEq(after_, out);
        assertEq(pool.previewExit(1e18)[0], exitBefore[0]);
    }

    function testPausedTokenBlocksOnlyItself() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        pool.transfer(alice, 1e21);
        IndexToken(list[0]).setPaused(true);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _swap(pool, list[0], list[1], 1e18, true);
        _swap(pool, list[1], list[2], 1e18, true);
        vm.startPrank(alice);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        pool.exit(1e21, _zeros(3), _none(), FAR);
        address[] memory deferring = new address[](1);
        deferring[0] = list[0];
        uint256 expected = pool.previewExit(1e21)[0];
        pool.exit(1e21, _zeros(3), deferring, FAR);
        assertEq(pool.deferred(alice, list[0]), expected);
        assertGt(_balanceOf(list[1], alice), 0);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        pool.claim(list[0]);
        vm.stopPrank();
        IndexToken(list[0]).setPaused(false);
        vm.prank(alice);
        assertEq(pool.claim(list[0]), expected);
        assertEq(_balanceOf(list[0], alice), expected);
        assertEq(pool.deferred(alice, list[0]), 0);
        address[] memory holders = new address[](1);
        holders[0] = alice;
        _assertSolvent(pool, holders);
    }

    /// A holder who defers every token leaves without the pool calling anything.
    function testExitDeferringEverythingMakesNoCall() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        for (uint256 index; index < 3; index++) {
            IndexToken(list[index]).setPaused(true);
        }
        for (uint256 index; index < 3; index++) {
            vm.expectCall(list[index], "", 0);
        }
        pool.exit(1e21, _zeros(3), list, FAR);
        assertGt(pool.deferred(address(this), list[2]), 0);
    }

    // ---------------------------------------------------------------- reentrancy

    function testTokenCallingBackIsRefused() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeCall(
            IndexPool.swap, (list[1], list[0], 1e18, true, 0, address(this), FAR)
        );
        calls[1] = abi.encodeCall(IndexPool.join, (1e18, _maxes(2), FAR));
        calls[2] = abi.encodeCall(IndexPool.exit, (1e18, _zeros(2), _none(), FAR));
        calls[3] = abi.encodeCall(IndexPool.balances, ());
        calls[4] = abi.encodeCall(IndexPool.quoteSwap, (list[1], list[0], 1e18, true));
        for (uint256 index; index < calls.length; index++) {
            IndexToken(list[0]).setReenter(address(pool), calls[index]);
            _swap(pool, list[0], list[1], 1e18, true);
            assertTrue(IndexToken(list[0]).reentered());
            assertFalse(IndexToken(list[0]).reenterOk());
            assertEq(
                bytes4(IndexToken(list[0]).reenterResult()), ReentrancyGuard.Reentrancy.selector
            );
        }
        _assertSolvent(pool, _none());
    }

    // ---------------------------------------------------------------- outflow limit

    function testOutflowLimitAtEqualFifths() public {
        _collapse(_same(18, 5), _equal(5));
    }

    function testOutflowLimitAtEightyTwenty() public {
        _collapse(_pair(18, 18), _weights(8e17, 2e17));
        _collapse(_pair(18, 18), _weights(2e17, 8e17));
    }

    function testOutflowLimitAtNinetyNineToOne() public {
        _collapse(_pair(18, 18), _weights(99e16, 1e16));
        _collapse(_pair(18, 18), _weights(1e16, 99e16));
    }

    /// Deposits and withdrawals leave the mark where it was, other pairs carry on, and the
    /// next window starts afresh.
    function testOutflowMarkAndWindow() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        _drain(pool, list[0], list[1]);
        // Token 1 is at its floor: any more out fails, but token 1 in still works.
        _expectQuoteRevert(
            pool, list[0], list[1], _onePercent(pool), true, IndexPool.OutflowLimit.selector
        );
        _swap(pool, list[1], list[2], 1e18, true);
        _swap(pool, list[0], list[2], 1e18, true);
        pool.join(pool.totalSupply(), _maxes(3), FAR);
        _expectQuoteRevert(
            pool, list[0], list[1], _onePercent(pool), true, IndexPool.OutflowLimit.selector
        );
        pool.exit(pool.totalSupply() / 3, _zeros(3), _none(), FAR);
        _expectQuoteRevert(
            pool, list[0], list[1], _onePercent(pool), true, IndexPool.OutflowLimit.selector
        );
        // Two windows on, neither level applies any more and a full 30% is open again.
        vm.warp((block.timestamp / 1 days + 2) * 1 days);
        _swap(pool, list[0], list[1], _onePercent(pool), true);
    }

    /// The review's proof of concept (finding 1): swap X in, record a level with a dust swap
    /// out, swap back. The level was recorded at the first swap in, before the inflow, so
    /// later swaps out are no more restricted than before.
    function testElevatedLevelNoLongerBlocksOutflow() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _inflateAndPin(pool);
        _takeXDownTo(pool, 75e22);
    }

    /// The same move across a boundary: inflate in the last second of one window, record
    /// in the first second of the next, swap back. The previous window's level is the one
    /// from before the inflow.
    function testElevatedLevelAcrossABoundaryNoLongerBlocks() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        vm.warp((block.timestamp / 1 days + 1) * 1 days - 1);
        address attacker = makeAddr("attacker");
        _fundAll(attacker, pool, 1e30);
        vm.startPrank(attacker);
        pool.swap(list[0], list[1], 25e22, true, 0, attacker, FAR);
        pool.swap(list[0], list[1], 17e22, true, 0, attacker, FAR);
        vm.warp(block.timestamp + 1);
        pool.swap(list[1], list[0], 1e12, true, 0, attacker, FAR);
        _swapBackToFloor(pool, attacker);
        vm.stopPrank();
        _takeXDownTo(pool, 75e22);
    }

    /// The bound itself: a token that rose from B to about 1.4B per share in one window may
    /// fall to 0.7B in the next, 30% below the lower level, and no further.
    function testRiseThenFallIsBoundByTheLowerLevel() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        uint256 start = pool.balances()[1];
        _swap(pool, list[1], list[2], 25e22, true);
        _swap(pool, list[1], list[2], 15e22, true);
        assertGe(pool.balances()[1] * 100, start * 139);
        vm.warp(block.timestamp + 1 days);
        _drain(pool, list[0], list[1]);
        assertGe(pool.balances()[1] * 100, start * 70, "no further than 70% of B");
        assertLe(pool.balances()[1] * 1000, start * 705, "down to 70% of B");
    }

    /// A token drained 30% in one window may fall a further 30%, to 49% of where it began,
    /// in the next, and no further.
    function testDrainOverTwoWindowsStopsAtFortyNinePercent() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        uint256 start = pool.balances()[1];
        _drain(pool, list[0], list[1]);
        assertLe(pool.balances()[1] * 1000, start * 705);
        vm.warp(block.timestamp + 1 days);
        _drain(pool, list[0], list[1]);
        assertGe(pool.balances()[1] * 100, start * 49, "no further than 49%");
        assertLe(pool.balances()[1] * 1000, start * 495, "down to 49%");
    }

    /// A level two windows old is not used: after a full drain, a skipped window, the token
    /// can fall another 30% from where it was left.
    function testLevelTwoWindowsOldIsIgnored() public {
        IndexPool pool = _pool(_same(18, 3), _equal3(), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 start = pool.balances()[1];
        _drain(pool, list[0], list[1]);
        uint256 drained = pool.balances()[1];
        assertLe(drained * 100, start * 71);
        vm.warp((block.timestamp / 1 days + 2) * 1 days);
        _drain(pool, list[0], list[1]);
        assertLe(pool.balances()[1] * 100, drained * 71, "fell 30% from the newer level");
        assertGe(pool.balances()[1] * 100, drained * 70);
    }

    /// The attack of finding 1, from its first swap: inflate X, record with dust, swap back
    /// to just above 70% of the inflated balance.
    function _inflateAndPin(IndexPool pool) internal {
        address[] memory list = pool.tokens();
        address attacker = makeAddr("attacker");
        _fundAll(attacker, pool, 1e30);
        vm.startPrank(attacker);
        pool.swap(list[0], list[1], 25e22, true, 0, attacker, FAR);
        pool.swap(list[0], list[1], 17e22, true, 0, attacker, FAR);
        pool.swap(list[1], list[0], 1e12, true, 0, attacker, FAR);
        _swapBackToFloor(pool, attacker);
        vm.stopPrank();
    }

    function _swapBackToFloor(IndexPool pool, address attacker) internal {
        address[] memory list = pool.tokens();
        uint256 balance = pool.balances()[0];
        uint256 floor = balance * 70 / 100;
        pool.swap(list[1], list[0], (balance - floor) / 2, false, FAR, attacker, FAR);
        uint256 rest = pool.balances()[0] - floor - 1e15;
        pool.swap(list[1], list[0], rest, false, FAR, attacker, FAR);
    }

    /// Anyone can still buy X down to `target` (from 1e24), far below the inflated floor.
    function _takeXDownTo(IndexPool pool, uint256 target) internal {
        address[] memory list = pool.tokens();
        while (pool.balances()[0] > target) {
            uint256 piece = pool.balances()[0] - target;
            if (piece > 5e22) piece = 5e22;
            _swap(pool, list[1], list[0], piece, false);
        }
        assertLe(pool.balances()[0], target);
    }

    // ---------------------------------------------------------------- value function

    /// `Σ weight × ln(balance)` never falls across a swap by more than `lnWad`'s own error,
    /// measured by `tools/index_vectors.py` at 1.05 wei per term.
    /// With `feeFree` the swap is made by the pool's hook, so nothing but rounding and the
    /// power margin stands between it and a loss.
    function testFuzzValueFunctionNeverFalls(
        uint256 seed,
        uint256 amount,
        bool exactIn,
        bool feeFree
    ) public {
        address hook = makeAddr("inert hook");
        IndexPool pool = _pool(_mixed3(), _weights3(), 1e6, hook, 1);
        _fundAll(hook, pool, 1e40);
        address[] memory list = pool.tokens();
        uint256 indexIn = seed % 3;
        uint256 indexOut = (indexIn + 1 + (seed >> 8) % 2) % 3;
        uint256 given = exactIn ? indexIn : indexOut;
        // Inside every limit at these weights, so no run is skipped.
        amount = bound(amount, pool.balances()[given] / 1e9, pool.balances()[given] / 50);
        int256 before = _value(pool);
        vm.prank(feeFree ? hook : address(this));
        pool.swap(
            list[indexIn],
            list[indexOut],
            amount,
            exactIn,
            exactIn ? 0 : FAR,
            address(this),
            FAR
        );
        assertGe(_value(pool) + 5, before);
    }

    // ---------------------------------------------------------------- entry rules

    function testEntryPointsRevertBeforeStart() public {
        IndexPool pool = _unstarted(_same(18, 2), _equal(2));
        address[] memory list = pool.tokens();
        vm.expectRevert(IndexPool.NotStarted.selector);
        _swap(pool, list[0], list[1], 1e18, true);
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.join(1e18, _maxes(2), FAR);
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.exit(1e18, _zeros(2), _none(), FAR);
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.claim(list[0]);
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.payProtocol(list[0]);
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.previewExit(1e18);
    }

    function testDeadlineAndRecipientRules() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 late = block.timestamp - 1;
        vm.expectRevert(IndexPool.Expired.selector);
        pool.swap(list[0], list[1], 1e18, true, 0, address(this), late);
        vm.expectRevert(IndexPool.Expired.selector);
        pool.join(1e18, _maxes(2), late);
        vm.expectRevert(IndexPool.Expired.selector);
        pool.exit(1e18, _zeros(2), _none(), late);
        vm.expectRevert(IndexPool.InvalidRecipient.selector);
        pool.swap(list[0], list[1], 1e18, true, 0, address(pool), FAR);
        vm.expectRevert(IndexPool.SameToken.selector);
        _swap(pool, list[0], list[0], 1e18, true);
        address stranger = makeAddr("stranger");
        vm.expectRevert(IndexPool.UnknownToken.selector);
        _swap(pool, stranger, list[0], 1e18, true);
        address[] memory deferring = new address[](1);
        deferring[0] = stranger;
        vm.expectRevert(IndexPool.UnknownToken.selector);
        pool.exit(1e18, _zeros(2), deferring, FAR);
    }

    /// Shares carry no built-in Permit2 allowance.
    function testNoPermit2Allowance() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(pool.allowance(address(this), permit2), 0);
        vm.prank(permit2);
        vm.expectRevert();
        pool.transferFrom(address(this), permit2, 1);
    }

    // ---------------------------------------------------------------- helpers

    function _construct(address[] memory list, uint256[] memory weights, uint256 fee)
        internal
        returns (IndexPool)
    {
        return new IndexPool(
            "Index", "IDX", list, weights, fee, protocol, address(0), 0, false, address(this)
        );
    }

    function _checkConfig(uint8[] memory places, uint256[] memory weights) internal {
        address hook = makeAddr("inert hook");
        IndexPool pool = _create(_tokens(places), weights, FEE, hook, 1);
        uint256[] memory units = new uint256[](places.length);
        for (uint256 index; index < units.length; index++) {
            units[index] = 1e6 + index * 777;
        }
        _start(pool, units, 1e24);
        address[] memory list = pool.tokens();
        uint256[] memory balances = pool.balances();
        for (uint256 index = 1; index < list.length; index++) {
            uint256 amount = balances[0] / 5000;
            vm.prank(hook);
            (, uint256 out) = pool.quoteSwap(list[0], list[index], amount, true);
            assertEq(out, _mathOut(pool, 0, index, amount));
            uint256 wanted = balances[index] / 7000;
            vm.prank(hook);
            (uint256 paid,) = pool.quoteSwap(list[0], list[index], wanted, false);
            assertEq(paid, _mathIn(pool, 0, index, wanted));
        }
    }

    function _mathOut(IndexPool pool, uint256 i, uint256 o, uint256 amount)
        internal
        view
        returns (uint256)
    {
        (uint256 scaleIn, uint256 scaleOut) = _scales(pool, i, o);
        uint256 out = IndexMath.outGivenExactIn(
            pool.balances()[i] * scaleIn,
            pool.weights()[i],
            pool.balances()[o] * scaleOut,
            pool.weights()[o],
            amount * scaleIn
        );
        return out / scaleOut;
    }

    function _mathIn(IndexPool pool, uint256 i, uint256 o, uint256 amount)
        internal
        view
        returns (uint256)
    {
        (uint256 scaleIn, uint256 scaleOut) = _scales(pool, i, o);
        uint256 needed = IndexMath.inGivenExactOut(
            pool.balances()[i] * scaleIn,
            pool.weights()[i],
            pool.balances()[o] * scaleOut,
            pool.weights()[o],
            amount * scaleOut
        );
        return IndexMath.fromWadUp(needed, scaleIn);
    }

    function _scales(IndexPool pool, uint256 i, uint256 o)
        internal
        view
        returns (uint256, uint256)
    {
        address[] memory list = pool.tokens();
        uint256 scaleIn = 10 ** (18 - IndexToken(list[i]).decimals());
        return (scaleIn, 10 ** (18 - IndexToken(list[o]).decimals()));
    }

    /// A started pool whose hook is an address with no code, so pranking it trades fee-free.
    function _feeFreePool(uint256[] memory weights)
        internal
        returns (IndexPool pool, address hook)
    {
        hook = makeAddr("inert hook");
        pool = _create(_tokens(_same(18, 2)), weights, FEE, hook, 1);
        uint256[] memory units = new uint256[](2);
        units[0] = 1e6;
        units[1] = 1e6;
        _start(pool, units, 1e24);
        _fundAll(address(this), pool, 1e40);
    }

    /// Starts a two-token pool from `_unstarted` with uneven balances.
    function _startUneven(IndexPool pool, uint256 first, uint256 second) internal {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = first;
        amounts[1] = second;
        pool.start(amounts, 1e24, FAR);
    }

    function _sixFirst(IndexPool pool) internal view returns (address six, address other) {
        address[] memory list = pool.tokens();
        if (IndexToken(list[0]).decimals() == 6) return (list[0], list[1]);
        return (list[1], list[0]);
    }

    /// The largest amount whose quote passes, searched between `low` (passes) and `high`.
    function _edge(
        IndexPool pool,
        address tokenIn,
        address tokenOut,
        bool exactIn,
        uint256 low,
        uint256 high
    ) internal view returns (uint256) {
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            try pool.quoteSwap(tokenIn, tokenOut, middle, exactIn) {
                low = middle;
            } catch {
                high = middle;
            }
        }
        return low;
    }

    /// The smallest exact-in amount whose quote passes, between `low` (fails) and `high`.
    function _lowEdge(
        IndexPool pool,
        address tokenIn,
        address tokenOut,
        uint256 low,
        uint256 high
    ) internal view returns (uint256) {
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            try pool.quoteSwap(tokenIn, tokenOut, middle, true) {
                high = middle;
            } catch {
                low = middle;
            }
        }
        return high;
    }

    function _expectQuoteRevert(
        IndexPool pool,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn,
        bytes4 error
    ) internal {
        vm.expectRevert(error);
        pool.quoteSwap(tokenIn, tokenOut, amount, exactIn);
    }

    /// Sells `tokenIn` for `tokenOut` in shrinking pieces until the outflow limit stops it.
    function _drain(IndexPool pool, address tokenIn, address tokenOut) internal {
        // Pieces are a share of the growing balance in, so even a 1% token can be sold in
        // amounts large enough to reach the floor of a 99% one.
        uint256 share = 250_000;
        while (share != 0) {
            uint256 piece = pool.balances()[_at(pool, tokenIn)] * share / 1e6;
            try pool.swap(tokenIn, tokenOut, piece, true, 0, address(this), FAR) { }
            catch (bytes memory reason) {
                // At a steep weight a big piece can also hit the 30% limit on what it takes.
                if (bytes4(reason) != IndexMath.MaxOutRatio.selector) {
                    assertEq(bytes4(reason), IndexPool.OutflowLimit.selector);
                }
                share /= 2;
            }
        }
    }

    /// One token collapses: traders sell it for every other until the limit stops them.
    /// Every other token keeps at least 70% of its balance per share, so at any prices the
    /// pool keeps at least 70% of what it would have held without trading.
    function _collapse(uint8[] memory places, uint256[] memory weights) internal {
        IndexPool pool = _pool(places, weights, 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256[] memory start = pool.balances();
        for (uint256 index = 1; index < list.length; index++) {
            _drain(pool, list[0], list[index]);
        }
        uint256[] memory end = pool.balances();
        for (uint256 index = 1; index < list.length; index++) {
            assertGe(end[index] * 100, start[index] * 70, "per share");
            assertLe(end[index] * 100, start[index] * 71, "reached the floor");
        }
    }

    /// More than the last piece `_drain` failed with, so past the floor while the mark holds.
    function _onePercent(IndexPool pool) internal view returns (uint256) {
        return pool.balances()[0] / 100;
    }

    function _at(IndexPool pool, address token) internal view returns (uint256) {
        address[] memory list = pool.tokens();
        for (uint256 index; index < list.length; index++) {
            if (list[index] == token) return index;
        }
        revert("token");
    }

    function _value(IndexPool pool) internal view returns (int256 total) {
        address[] memory list = pool.tokens();
        uint256[] memory balances = pool.balances();
        uint256[] memory weights = pool.weights();
        for (uint256 index; index < list.length; index++) {
            uint256 scale = 10 ** (18 - IndexToken(list[index]).decimals());
            int256 ln = FixedPointMathLib.lnWad(int256(balances[index] * scale));
            total += ln * int256(weights[index]) / 1e18;
        }
    }

    function _equal3() internal pure returns (uint256[] memory list) {
        list = new uint256[](3);
        list[0] = 333333333333333334;
        list[1] = 333333333333333333;
        list[2] = 333333333333333333;
    }

    function _weights3() internal pure returns (uint256[] memory list) {
        list = new uint256[](3);
        list[0] = 6e17;
        list[1] = 3e17;
        list[2] = 1e17;
    }

    function _mixed3() internal pure returns (uint8[] memory list) {
        list = new uint8[](3);
        list[0] = 6;
        list[1] = 18;
        list[2] = 8;
    }
}
