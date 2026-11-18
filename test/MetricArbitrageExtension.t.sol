// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { MetricArbitrageExtension } from "../src/hooks/MetricArbitrageExtension.sol";
import {
    IFill,
    MockExtensionPool,
    UnlockedCaller,
    FailingSweep,
    CountingSweep,
    BurningSweep
} from "./utils/metric/MockExtensionPool.sol";
import {
    IMetricOmmExtensions,
    IMetricAfterSwap,
    IMetricLiquidityPoints
} from "../src/interfaces/metric/IMetricOmmExtensions.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

// No fork test: the oracle answers only pools registered with it, so a real Metric pool made
// with this extension cannot swap on a fork, and `createPool`'s parameters (packed bin data,
// extension orders and init data, a price provider) are too large to build for a check that
// would only show `initialize` being called.
contract MetricArbitrageExtensionTest is MarketsWorld, IFill {
    address internal constant FACTORY = address(0xFAC7);
    MetricArbitrageExtension internal extension;
    MockExtensionPool internal pool;
    PoolKey internal open;
    /// What `onFill` does: 0 nothing, 1 opens a gap on the hookless pool.
    uint256 internal constant RESERVE = 1_000_000;
    uint256 internal fillMode;
    uint256 internal paidDuringFill;

    function setUp() public override {
        super.setUp();
        open = _pair(address(backing), address(coin), 1_000, address(0));
        manager.initialize(open, uint160(1 << 96));
        _provide(open, 1_000_000e18);
        vm.prank(team);
        hook.addVenue(id, open);
        _lead(address(backing), address(coin), _list(_id(open), _id(first), _id(second)));
        (extension, pool) = _install(address(hook), 2_000_000);
    }

    function _list(bytes32 one, bytes32 two, bytes32 three)
        internal
        pure
        returns (bytes32[] memory list)
    {
        list = new bytes32[](3);
        list[0] = one;
        list[1] = two;
        list[2] = three;
    }

    function _install(address target, uint32 gasCap)
        internal
        returns (MetricArbitrageExtension made, MockExtensionPool madePool)
    {
        made = new MetricArbitrageExtension(target, FACTORY);
        madePool = new MockExtensionPool(IMetricOmmExtensions(address(made)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(backing);
        vm.prank(FACTORY);
        made.initialize(address(madePool), abi.encode(id, tokens, gasCap, RESERVE));
    }

    function onFill() external {
        paidDuringFill = backing.balanceOf(treasury);
        if (fillMode == 1) _trade(open, address(coin), 50_000e18);
    }

    function _openGap() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
    }

    function testSweepBeforeTheSwapClosesAGap() public {
        _openGap();
        pool.swap(false);
        assertEq(pool.swaps(), 1);
        assertGt(paidDuringFill, 0, "gap closed");
        _assertNothingHeld();
    }

    function testSweepAfterTheSwapClosesTheGapItOpened() public {
        fillMode = 1;
        pool.swap(false);
        assertEq(paidDuringFill, 0, "nothing to close before the fill");
        assertGt(backing.balanceOf(treasury), 0, "closed after the fill");
        _assertNothingHeld();
    }

    function testSimulationIsSkipped() public {
        _openGap();
        vm.recordLogs();
        pool.swap(true);
        assertEq(pool.swaps(), 1, "the swap itself completes");
        assertEq(_cycles(), 0, "no sweep");
        assertEq(backing.balanceOf(treasury), 0);
        pool.swap(false);
        assertGt(backing.balanceOf(treasury), 0, "a real swap sweeps");
    }

    function testUnregisteredCallerIsIgnored() public {
        _openGap();
        MockExtensionPool stranger =
            new MockExtensionPool(IMetricOmmExtensions(address(extension)));
        stranger.swap(false);
        assertEq(stranger.swaps(), 1);
        assertEq(backing.balanceOf(treasury), 0, "no sweep");
        // An address with no code is not a pool either.
        vm.prank(address(0xBEEF));
        extension.beforeSwap(address(0), address(0), true, 1, 0, 0, 1, 1, 1, "");
    }

    function testAFailingSweepNeverRevertsTheSwap() public {
        FailingSweep failing = new FailingSweep();
        (, MockExtensionPool bad) = _install(address(failing), 2_000_000);
        bad.swap(false);
        assertEq(bad.swaps(), 1);
    }

    function testOutOfGasSweepNeverRevertsTheSwap() public {
        _openGap();
        (, MockExtensionPool poor) = _install(address(hook), 50_000);
        poor.swap(false);
        assertEq(poor.swaps(), 1);
        assertEq(backing.balanceOf(treasury), 0, "the sweep could not finish");
        assertLe(poor.lastBeforeGas(), 50_000 + 25_000, "the cap bounds the sweep");
    }

    function testGasCapHolds() public {
        _openGap();
        (, MockExtensionPool capped) = _install(address(hook), 100_000);
        capped.swap(false);
        assertLe(capped.lastBeforeGas(), 100_000 + 25_000, "before");
        assertLe(capped.lastAfterGas(), 100_000 + 25_000, "after");
    }

    function testTooLittleGasCallsNothingAndTheSwapCompletes() public {
        _openGap();
        // Plenty for the mock's own work, not for the cap plus the reserve.
        pool.swap{ gas: 600_000 }(false);
        assertEq(pool.swaps(), 1);
        assertEq(backing.balanceOf(treasury), 0, "no sweep ran");
        assertLt(pool.lastBeforeGas(), 60_000, "nothing was called");
    }

    function testMoreGasStillSweeps() public {
        _openGap();
        pool.swap{ gas: 8_000_000 }(false);
        assertGt(backing.balanceOf(treasury), 0);
    }

    function testInsideAnUnlockTheSweepIsCaught() public {
        _openGap();
        UnlockedCaller caller = new UnlockedCaller(manager);
        caller.run(pool);
        assertEq(pool.swaps(), 1, "the swap completed");
        assertEq(backing.balanceOf(treasury), 0, "no sweep inside an unlock");
    }

    function testAfterSwapSelectorMatchesMetric() public view {
        assertEq(extension.AFTER_SWAP(), IMetricAfterSwap.afterSwap.selector);
    }

    function testOtherCallsRevert() public {
        (bool ok,) = address(extension).call(hex"12345678");
        assertFalse(ok);
    }

    function testOnlyTheFactoryInitializes() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(backing);
        vm.expectRevert(MetricArbitrageExtension.NotFactory.selector);
        extension.initialize(address(0x1234), abi.encode(id, tokens, uint32(1), RESERVE));
    }

    function testBadDataAndSecondRegistrationRevert() public {
        address[] memory none = new address[](0);
        address[] memory three = new address[](3);
        address[] memory one = new address[](1);
        vm.startPrank(FACTORY);
        vm.expectRevert(MetricArbitrageExtension.BadTokens.selector);
        extension.initialize(address(0x1), abi.encode(id, none, uint32(1), RESERVE));
        vm.expectRevert(MetricArbitrageExtension.BadTokens.selector);
        extension.initialize(address(0x1), abi.encode(id, three, uint32(1), RESERVE));
        vm.expectRevert(MetricArbitrageExtension.GasCapTooHigh.selector);
        extension.initialize(address(0x1), abi.encode(id, one, uint32(20_000_001), RESERVE));
        vm.expectRevert();
        extension.initialize(address(0x1), hex"1234");
        vm.expectRevert(MetricArbitrageExtension.ReserveTooLow.selector);
        extension.initialize(address(0x1), abi.encode(id, one, uint32(1), RESERVE - 1));
        vm.expectRevert(MetricArbitrageExtension.ReserveTooHigh.selector);
        extension.initialize(address(0x1), abi.encode(id, one, uint32(1), type(uint256).max));
        vm.expectRevert(MetricArbitrageExtension.ReserveTooHigh.selector);
        extension.initialize(address(0x1), abi.encode(id, one, uint32(1), 30_000_001));
        vm.expectRevert(MetricArbitrageExtension.AlreadyRegistered.selector);
        extension.initialize(address(pool), abi.encode(id, one, uint32(1), RESERVE));
        extension.initialize(address(0x1), abi.encode(id, one, uint32(12_000_000), RESERVE));
        vm.stopPrank();
    }

    function testRegisteredEventAndTwoTokens() public {
        MetricArbitrageExtension made = new MetricArbitrageExtension(address(hook), FACTORY);
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        vm.expectEmit(true, false, false, true);
        emit MetricArbitrageExtension.Registered(address(0x77), id, tokens, 1_000, RESERVE);
        vm.prank(FACTORY);
        made.initialize(address(0x77), abi.encode(id, tokens, uint32(1_000), RESERVE));
        (bool registered, uint8 count,,,, address one, address two) =
            made.configs(address(0x77));
        assertTrue(registered);
        assertEq(count, 2);
        assertEq(one, address(backing));
        assertEq(two, address(usd));
    }

    function testBothTokensAreSwept() public {
        CountingSweep counter = new CountingSweep();
        MetricArbitrageExtension made = new MetricArbitrageExtension(address(counter), FACTORY);
        MockExtensionPool two = new MockExtensionPool(IMetricOmmExtensions(address(made)));
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        vm.prank(FACTORY);
        made.initialize(address(two), abi.encode(id, tokens, uint32(100_000), RESERVE));
        two.swap(false);
        assertEq(counter.calls(), 4, "two tokens, before and after");
    }

    /// With a rest of 400k and the default reserve, just below the threshold nothing is
    /// called and just above it the sweep runs; the swap completes on both sides.
    function testReserveThresholdIsPinned() public {
        uint256 below;
        uint256 above;
        for (uint256 limit = 1_000_000; limit < 1_400_000; limit += 2_000) {
            CountingSweep counter = new CountingSweep();
            MetricArbitrageExtension made =
                new MetricArbitrageExtension(address(counter), FACTORY);
            MockExtensionPool probe = new MockExtensionPool(IMetricOmmExtensions(address(made)));
            address[] memory tokens = new address[](1);
            tokens[0] = address(backing);
            vm.prank(FACTORY);
            made.initialize(address(probe), abi.encode(id, tokens, uint32(100_000), RESERVE));
            probe.setRest(400_000);
            probe.swap{ gas: limit }(false);
            assertEq(probe.swaps(), 1, "the swap completes");
            if (counter.calls() != 0) {
                above = limit;
                break;
            }
            below = limit;
        }
        assertGt(above, 0, "the sweep ran at some level");
        assertEq(above - below, 2_000, "a sharp threshold");
        // The threshold is the cap plus the reserve, less the 63/64 rule and the mock's work.
        assertGt(above, 100_000 + RESERVE);
        assertLt(above, 100_000 + RESERVE + 60_000);
    }

    function testLiquidityPointsAreNoOpsAndOthersRevert() public {
        bytes4[4] memory points = [
            IMetricLiquidityPoints.beforeAddLiquidity.selector,
            IMetricLiquidityPoints.afterAddLiquidity.selector,
            IMetricLiquidityPoints.beforeRemoveLiquidity.selector,
            IMetricLiquidityPoints.afterRemoveLiquidity.selector
        ];
        for (uint256 index; index < 4; index++) {
            (bool ok, bytes memory out) =
                address(extension).call(abi.encodePacked(points[index]));
            assertTrue(ok, "no-op");
            assertEq(abi.decode(out, (bytes4)), points[index], "returns its selector");
        }
        (bool bad,) = address(extension).call(hex"0a2a56a7");
        assertFalse(bad);
    }

    function testConstructorRefusesNoHookOrNoFactory() public {
        vm.expectRevert(MetricArbitrageExtension.NoHook.selector);
        new MetricArbitrageExtension(address(0xDEAD), FACTORY);
        vm.expectRevert(MetricArbitrageExtension.NoFactory.selector);
        new MetricArbitrageExtension(address(hook), address(0));
    }

    /// A sweep that burns its whole cap, with a rest just under the reserve: as the gas
    /// given to the swap rises through the threshold, the swap never fails. The scan starts
    /// where the swap has enough gas for its rest even with the sweep skipped.
    function testSwapNeverFailsAsGasRisesWithABurningSweep() public {
        BurningSweep burner = new BurningSweep();
        MetricArbitrageExtension made = new MetricArbitrageExtension(address(burner), FACTORY);
        address[] memory tokens = new address[](1);
        tokens[0] = address(backing);
        uint256 burned;
        for (uint256 limit = 1_100_000; limit <= 1_400_000; limit += 2_000) {
            MockExtensionPool probe = new MockExtensionPool(IMetricOmmExtensions(address(made)));
            vm.prank(FACTORY);
            made.initialize(address(probe), abi.encode(id, tokens, uint32(100_000), RESERVE));
            // The mock's own work between two extension calls counts against the reserve.
            probe.setRest(RESERVE - 50_000);
            probe.swap{ gas: limit }(false);
            assertEq(probe.swaps(), 1, "the swap completes");
            if (probe.lastBeforeGas() > 100_000) burned++;
        }
        assertGt(burned, 0, "the burning sweep ran at the higher levels");
    }

    /// The largest cap and reserve together neither overflow nor fail a swap: the sweep is
    /// simply never affordable.
    function testMaximumCapAndReserveWork() public {
        MetricArbitrageExtension made = new MetricArbitrageExtension(address(hook), FACTORY);
        MockExtensionPool big = new MockExtensionPool(IMetricOmmExtensions(address(made)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(backing);
        bytes memory data = abi.encode(id, tokens, made.MAX_GAS_CAP(), made.MAX_RESERVE());
        vm.prank(FACTORY);
        made.initialize(address(big), data);
        big.swap(false);
        assertEq(big.swaps(), 1);
    }
}
