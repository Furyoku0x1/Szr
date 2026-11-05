// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ReleaseSchedule } from "../src/ReleaseSchedule.sol";

contract ScheduleHarness {
    using ReleaseSchedule for ReleaseSchedule.State;
    ReleaseSchedule.State internal state;
    uint256 public immutable opening;

    constructor(uint256 start) {
        opening = start;
        state.updatedAt = start;
    }

    function checkpoint() external {
        state.checkpoint(opening);
    }

    function credit() external view returns (uint256) {
        return ReleaseSchedule.projected(state, opening, block.timestamp);
    }
}

contract ReleaseScheduleTest is Test {
    function testRateHalvesSmoothlyAndStopsAtMinimum() public pure {
        assertEq(ReleaseSchedule.ratePerDay(0), 500_000e18);
        assertApproxEqAbs(ReleaseSchedule.ratePerDay(365 days), 250_000e18, 1e6);
        assertApproxEqAbs(ReleaseSchedule.ratePerDay(730 days), 125_000e18, 1e6);
        uint256 beforeBoundary = ReleaseSchedule.ratePerDay(365 days - 1);
        uint256 afterBoundary = ReleaseSchedule.ratePerDay(365 days + 1);
        assertLt(beforeBoundary - afterBoundary, 5e16);
        assertEq(ReleaseSchedule.ratePerDay(ReleaseSchedule.tailAt()), 100_000e18);
        assertEq(ReleaseSchedule.ratePerDay(36500 days), 100_000e18);
    }

    function testTailCumulativeAllowanceIsExactlyLinear() public pure {
        uint256 tail = ReleaseSchedule.tailAt();
        uint256 start = ReleaseSchedule.cumulativeScaled(tail);
        assertEq(ReleaseSchedule.cumulativeScaled(tail + 1 days) - start, 100_000e18 * 1 days);
        assertEq(ReleaseSchedule.cumulativeScaled(0), 0);
    }

    function testFirstYearMatchesIndependentIntegral() public pure {
        // Python Decimal, precision 100: 500000 * 365 * (1 - 1/2) / ln(2).
        uint256 expectedTokenWei = 131_645_922_481_117_910_921_593_127;
        uint256 actual = ReleaseSchedule.cumulativeScaled(365 days) / 1 days;
        assertApproxEqAbs(actual, expectedTokenWei, 1e9);
    }

    function testFuzzCheckpointsDoNotChangeAccumulatedCredit(uint32 rawTime, uint8 rawParts)
        public
    {
        uint256 duration = bound(rawTime, 1, 3650 days);
        uint256 parts = bound(rawParts, 1, 50);
        uint256 opening = block.timestamp;
        ScheduleHarness one = new ScheduleHarness(opening);
        ScheduleHarness many = new ScheduleHarness(opening);
        for (uint256 i = 1; i <= parts; i++) {
            vm.warp(opening + duration * i / parts);
            many.checkpoint();
        }
        assertEq(one.credit(), many.credit());
    }

    function testAllScheduledAllowanceAccumulatesAfterTheLaunchDelay() public {
        uint256 opening = block.timestamp + 1 days;
        ScheduleHarness harness = new ScheduleHarness(opening);
        assertEq(harness.credit(), 0);
        vm.warp(opening);
        assertEq(harness.credit(), 0);
        vm.warp(opening + 100 days);
        assertEq(harness.credit(), ReleaseSchedule.cumulativeScaled(100 days));
        assertGt(harness.credit(), 500_000e18 * 1 days);
    }

    function testFuzzRateAndIntegralAreMonotonic(uint32 a, uint32 b) public pure {
        uint256 start = bound(a, 0, 18250 days);
        uint256 end = start + bound(b, 0, 18250 days);
        assertLe(ReleaseSchedule.ratePerDay(end), ReleaseSchedule.ratePerDay(start));
        assertGe(ReleaseSchedule.cumulativeScaled(end), ReleaseSchedule.cumulativeScaled(start));
    }
}
