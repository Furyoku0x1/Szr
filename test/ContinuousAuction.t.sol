// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ContinuousAuction } from "../src/ContinuousAuction.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

contract ContinuousAuctionTest is Test {
    using ContinuousAuction for ContinuousAuction.State;

    function testReferencePurchaseAndFrozenRefill() public pure {
        ContinuousAuction.State memory state = ContinuousAuction.create(21_000e18, 1e16, 1);
        uint256 payment = state.buy(1_000e18);
        assertEq(payment, 10.5e18);
        assertEq(state.depth, 20_000e18);
        assertEq(state.price(), 0.011025e18);
        state.project(0, 21_000e18);
        assertApproxEqAbs(state.price(), 0.011025e18, 1);
    }

    function testDecayReachesPositiveFloorWithinTwoDays() public pure {
        ContinuousAuction.State memory state = ContinuousAuction.create(1_000e18, 1e18, 1e12);
        state.project(1 days, state.depth);
        assertEq(state.price(), 0.5000005e18);
        state.buy(10e18);
        state.project(2 days, state.depth);
        assertEq(state.price(), 1e12);
        assertEq(state.excessTime, 0);
        assertEq(state.decayMass, 0);
        assertGt(state.buy(1), 0);
    }

    function testTinyFillDoesNotRestartCountdown() public pure {
        ContinuousAuction.State memory state = ContinuousAuction.create(1_000e18, 1e18, 1e12);
        state.project(2 days - 60, state.depth);
        state.buy(1);
        uint256 remaining = FixedPointMathLib.divUp(state.excessTime, state.decayMass);
        assertLe(remaining, 61);
        state.project(61, state.depth);
        assertEq(state.price(), 1e12);
    }

    function testCheckpointFrequencyDoesNotChangeFixedDepthDecay() public pure {
        ContinuousAuction.State memory one = ContinuousAuction.create(1_000e18, 1e18, 1);
        ContinuousAuction.State memory many = ContinuousAuction.create(1_000e18, 1e18, 1);
        one.project(1700, one.depth);
        for (uint256 index; index < 100; index++) {
            many.project(17, many.depth);
        }
        assertEq(many.excessTime, one.excessTime);
        assertEq(many.decayMass, one.decayMass);
        assertEq(many.price(), one.price());
    }

    function testRefillPreservesDecayProgress() public pure {
        ContinuousAuction.State memory state = ContinuousAuction.create(1_000e18, 1e18, 1);
        state.project(2 days - 100, state.depth);
        uint256 price = state.price();
        state.project(0, 10_000e18);
        assertApproxEqAbs(state.price(), price, 1);
        assertLe(FixedPointMathLib.divUp(state.excessTime, state.decayMass), 101);
        state.project(101, state.depth);
        assertEq(state.price(), 1);
    }

    function testInvalidPriceAndDepthRevert() public {
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.create(0, 2, 1);
        vm.expectRevert(ContinuousAuction.InvalidPrice.selector);
        this.create(100, 2, 0);
        vm.expectRevert(ContinuousAuction.InvalidPrice.selector);
        this.create(100, 1, 1);
        vm.expectRevert(ContinuousAuction.UnrepresentableCurve.selector);
        this.create(1e30, type(uint256).max, 1);
    }

    function testInvalidPurchaseReverts() public {
        vm.expectRevert(ContinuousAuction.InvalidQuantity.selector);
        this.purchase(0);
        vm.expectRevert(ContinuousAuction.InvalidQuantity.selector);
        this.purchase(100);
    }

    function testFuzzSplittingCannotReduceCost(uint96 rawStock, uint96 rawBuffer, uint96 rawQty)
        public
        pure
    {
        uint256 stock = bound(rawStock, 2, 1e24);
        uint256 buffer = bound(rawBuffer, 1, 1e24);
        uint256 quantity = bound(rawQty, 2, stock);
        ContinuousAuction.State memory one = ContinuousAuction.create(stock + buffer, 1e16, 1);
        ContinuousAuction.State memory two = ContinuousAuction.create(stock + buffer, 1e16, 1);
        uint256 invariant = one.product();
        uint256 combined = one.buy(quantity);
        uint256 first = quantity / 2;
        uint256 split = two.buy(first) + two.buy(quantity - first);
        assertGe(split, combined);
        assertLe(split, combined + 1);
        assertEq(one.product(), invariant);
        assertEq(two.product(), invariant);
        assertEq(one.price(), two.price());
        one.project(2 days, one.depth);
        two.project(2 days, two.depth);
        assertEq(one.price(), 1);
        assertEq(two.price(), 1);
    }

    function testIndependentRationalVectors() public view {
        string memory data = vm.readFile("test/fixtures/continuous-auction.json");
        for (uint256 index; index < 40; index++) {
            _checkVector(data, index);
        }
    }

    function testMalformedDepthCannotEnterOrProjectTheCurve() public {
        uint256 excessive = 818592150592861781622465154682686326;
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.create(excessive, 2, 1);
        ContinuousAuction.State memory state = ContinuousAuction.State(1, 1, 0, 0);
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.projectState(state, 0);
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.projectState(state, excessive);
        state.depth = 0;
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.projectState(state, 1);
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.productOf(state);
        state.depth = excessive;
        vm.expectRevert(ContinuousAuction.InvalidDepth.selector);
        this.productOf(state);
    }

    function testUnrepresentableFloorOrExcessCannotEnterProduct() public {
        ContinuousAuction.State memory state =
            ContinuousAuction.State(1, type(uint256).max, 0, 0);
        vm.expectRevert(ContinuousAuction.UnrepresentableCurve.selector);
        this.productOf(state);
        state.floorWad = 1;
        state.excessTime = type(uint256).max;
        vm.expectRevert(ContinuousAuction.UnrepresentableCurve.selector);
        this.productOf(state);
    }

    function productOf(ContinuousAuction.State memory state) external pure returns (uint256) {
        return state.product();
    }

    function projectState(ContinuousAuction.State memory state, uint256 depth) external pure {
        state.project(0, depth);
    }

    function create(uint256 depth, uint256 opening, uint256 floor) external pure {
        ContinuousAuction.create(depth, opening, floor);
    }

    function purchase(uint256 amount) external pure {
        ContinuousAuction.State memory state = ContinuousAuction.create(100, 2e18, 1e18);
        state.buy(amount);
    }

    function _checkVector(string memory data, uint256 index) internal pure {
        string memory key = string.concat("[", vm.toString(index), "]");
        uint256 depth = vm.parseJsonUint(data, string.concat(key, ".depth"));
        uint256 opening = vm.parseJsonUint(data, string.concat(key, ".price"));
        uint256 floor = vm.parseJsonUint(data, string.concat(key, ".floor"));
        uint256 elapsed = vm.parseJsonUint(data, string.concat(key, ".elapsed"));
        uint256 quantity = vm.parseJsonUint(data, string.concat(key, ".quantity"));
        uint256 expected = vm.parseJsonUint(data, string.concat(key, ".payment"));
        uint256 price = vm.parseJsonUint(data, string.concat(key, ".after"));
        ContinuousAuction.State memory state = ContinuousAuction.create(depth, opening, floor);
        state.project(elapsed, depth);
        uint256 actual = state.buy(quantity);
        assertGe(actual, expected);
        assertLe(actual, expected + 1);
        assertGe(state.price(), price);
        assertLe(state.price(), price + 1);
    }
}
