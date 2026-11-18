// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { IVenuePricer } from "../src/interfaces/IVenuePricer.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Answers as `inner` does, after spending `cost` gas, so that a search pays what a
/// pricer that reads a Metric pool would: P1 measured 82,898 gas for `getSellAndBuyPrices()`.
/// Like that read it needs a normal call: a transient write, which a static call refuses.
contract CostlyPricer {
    IVenuePricer internal immutable inner;
    uint256 internal immutable cost;

    constructor(IVenuePricer answers, uint256 gas) {
        inner = answers;
        cost = gas;
    }

    function price(PoolKey calldata pool)
        external
        returns (uint160, uint24, uint128, uint160, uint160)
    {
        uint256 start = gasleft();
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        while (start - gasleft() < cost) { }
        return inner.price(pool);
    }
}

/// @notice P8 of docs/specs/metric.md, the local part: what a market with Metric-priced
/// venues must reserve in gas. The venues are mock wrapped pools; the pricer's gas is set
/// to P1's measured cost plus about 20%, and answers only to a normal call, as live pricers
/// are asked (`docs/specs/hook-live-pricers.md`). Not a fork test. The chain's per-transaction cap
/// is read in test/fork/MetricProbe.t.sol.
contract MetricProbeGasTest is MarketsWorld {
    /// What the real chain allows one transaction (ArbGasInfo.getMaxTxGasLimit, see P8).
    uint256 internal constant CHAIN_CAP = 32_000_000;
    /// P1's cold cost of one `getSellAndBuyPrices()` call, and 20% on top, to a whole unit.
    uint256 internal constant P1_GAS = 82_898;
    uint32 internal constant PRICER_GAS = 100_000;

    WrappedPool internal wrapper;
    WrappedPricer internal mock;
    CostlyPricer internal costly;
    PoolKey[] internal venues;

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        mock = new WrappedPricer(wrapper);
        costly = new CostlyPricer(mock, P1_GAS);
    }

    function _wrapVenue(uint24 fee) internal returns (PoolKey memory pool) {
        pool = _pair(address(backing), address(coin), fee, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        TestAsset(address(backing)).mint(address(wrapper), 1_000_000e18);
        TestAsset(address(coin)).mint(address(wrapper), 1_000_000e18);
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
    }

    /// Opens `count` wrapped venues in the market's (WETH, coin) group, as its leaders
    /// beside the market's own pool when there is room, and sets the pricer's gas.
    function _open(uint256 count, address pricer, uint32 pricerGas) internal {
        hook.setPricer(address(wrapper), pricer);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        bytes32[] memory leaders = new bytes32[](count == 3 ? 3 : 2);
        if (count == 1) leaders[0] = _id(first);
        for (uint256 i; i < count; i++) {
            venues.push(_wrapVenue(uint24(3_000 + i)));
            hook.addVenue(id, venues[i]);
            leaders[count == 1 ? 1 : i] = _id(venues[i]);
        }
        hook.setPricerGas(id, pricerGas);
        vm.stopPrank();
        _lead(address(backing), address(coin), leaders);
        _limits(address(backing), 1e15);
    }

    function _swapGas(uint256 amount) internal returns (uint256 gas, uint256 cycles) {
        vm.recordLogs();
        gas = gasleft();
        _trade(first, address(coin), amount);
        gas -= gasleft();
        cycles = _cycles();
    }

    function _report(string memory label) internal {
        console.log(label);
        console.log("   pricerGas set", hook.market(id).pricerGas);
        console.log("   minimumGasLimit", hook.minimumGasLimit(id));
        console.log("   market gasLimit", hook.market(id).gasLimit);
        console.log("   gasForSwap", hook.gasForSwap(id));
        (uint256 quiet, uint256 quietCycles) = _swapGas(1e15);
        console.log("   swap with no gap: gas, cycles", quiet, quietCycles);
        (uint256 gap, uint256 gapCycles) = _swapGas(50_000e18);
        console.log("   swap that opens a gap: gas, cycles", gap, gapCycles);
        console.log("   chain cap", CHAIN_CAP);
        console.log("   minimumGasLimit over the cap:", hook.minimumGasLimit(id) > CHAIN_CAP);
        console.log("   gasForSwap over the cap:", hook.gasForSwap(id) > CHAIN_CAP);
        console.log(
            "   gasForSwap as a share of the cap, in parts per million",
            hook.gasForSwap(id) * 1e6 / CHAIN_CAP
        );
    }

    /// What the allowance is for other pricer gas, with the market switched off while it
    /// is changed, since the hook refuses a setting that leaves it unworkable.
    function _sweep(string memory label) internal {
        console.log(label);
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        uint32[6] memory gases = [uint32(20_000), 50_000, 100_000, 150_000, 200_000, 250_000];
        for (uint256 i; i < gases.length; i++) {
            hook.setPricerGas(id, gases[i]);
            uint256 stated = hook.gasForSwap(id);
            console.log(
                "   pricerGas, minimumGasLimit, gasForSwap",
                gases[i],
                hook.minimumGasLimit(id),
                stated
            );
            console.log("   over the cap:", stated > CHAIN_CAP);
        }
        vm.stopPrank();
    }

    function testP8OneVenueMockPricer() public {
        _open(1, address(mock), PRICER_GAS);
        _report("P8 one wrapped venue, mock pricer (cheap answers), pricerGas 100000");
    }

    function testP8OneVenueCostlyPricer() public {
        _open(1, address(costly), PRICER_GAS);
        _report("P8 one wrapped venue, pricer burning P1's 82898 gas, pricerGas 100000");
    }

    function testP8ThreeVenuesMockPricer() public {
        _open(3, address(mock), PRICER_GAS);
        _report("P8 three wrapped venues, mock pricer (cheap answers), pricerGas 100000");
    }

    function testP8ThreeVenuesCostlyPricer() public {
        _open(3, address(costly), PRICER_GAS);
        _report("P8 three wrapped venues, pricer burning P1's 82898 gas, pricerGas 100000");
    }

    /// A pricer that also reads a few bins (M2's design) is given more: 200000 per answer.
    function testP8ThreeVenuesCostlyPricerAt200k() public {
        _open(3, address(costly), 200_000);
        _report("P8 three wrapped venues, pricer burning P1's 82898 gas, pricerGas 200000");
    }

    function testP8SweepOneVenue() public {
        _open(1, address(mock), PRICER_GAS);
        _sweep("P8 sweep, one wrapped venue (4 venues priced per search)");
    }

    function testP8SweepThreeVenues() public {
        _open(3, address(mock), PRICER_GAS);
        _sweep("P8 sweep, three wrapped venues (5 venues priced per search)");
    }
}
