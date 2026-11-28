// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { TryMeter } from "./utils/ArbitrageSizing.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";

/// @dev 28-T-1: `execute` refuses a try whose realised profit is under the market's minimum.
/// A real search never reaches such a try (the gate, the sizing walk and `PLAN_MARGIN` keep
/// the estimate well above the minimum, and a scan of minimums with the check removed found no
/// realised profit below one), so the try is run on the probe, the way `tryCost` runs one:
/// the plan a search makes, shrunk by hand so that it earns less than the minimum.
contract ArbitrageMinimumProfitTest is ArbitrageWorld {
    function testATryEarningLessThanTheMinimumIsRefused() public {
        hook.setLimits(1, address(szr), 0, 10e18, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        ArbitrageProbe probe = _probeInHook();
        ArbitrageLogic.Plan memory plan = probe.planFrom(_id(usdPool), address(usd));
        assertGt(plan.score, 0, "a plan");
        TryMeter meter = new TryMeter(manager, probe);
        uint256 snapshot = vm.snapshotState();
        (, bytes4 reason) = meter.measure(1, address(szr), _id(usdPool), plan);
        assertEq(reason, bytes4(0), "the whole size earns more than the minimum");
        vm.revertToState(snapshot);
        plan.spend /= 1000;
        uint256 inventory = core.unreleasedSupply();
        (, reason) = meter.measure(1, address(szr), _id(usdPool), plan);
        assertEq(reason, ArbitrageLogic.Unprofitable.selector, "a try under the minimum fails");
        assertEq(core.unreleasedSupply(), inventory, "and retires nothing");
    }
}
