// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { NoPricer } from "./MetricVenueSearch.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A wrapper hook that only asks for the search before a swap and records what it cost.
contract MeterHook {
    using PoolIdLibrary for PoolKey;

    ArbitrageApi internal immutable arbitrage;
    uint256 public used;
    bool public before;

    function setBefore(bool value) external {
        before = value;
    }

    constructor(ArbitrageApi searcher) {
        arbitrage = searcher;
    }

    function setTrigger(
        PoolKey calldata key,
        uint256 market,
        address token,
        uint32 cap,
        bool on
    ) external {
        arbitrage.setVenueTrigger(market, PoolId.unwrap(key.toId()), token, cap, on);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 start = gasleft();
        try arbitrage.venueSearch(PoolId.unwrap(key.toId()), before, sender) { } catch { }
        used = start - gasleft();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}

/// @dev A trigger's searches share one gas budget, however many groups its market has.
contract MetricVenueBudgetTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;

    MeterHook internal meter;
    PoolKey internal meterKey;
    PoolKey[] internal lows;

    function setUp() public override {
        super.setUp();
        meter = MeterHook(address(uint160(0x5555 << 144 | 1 << 7)));
        deployCodeTo("MetricVenueBudget.t.sol:MeterHook", abi.encode(hook), address(meter));
        hook.setPricer(address(meter), address(new NoPricer()));
        meterKey = _pair(address(backing), address(coin), 100, address(meter));
        manager.initialize(meterKey, uint160(1 << 96));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        vm.prank(team);
        hook.addVenue(id, meterKey);
        // Three more groups, each with two pools.
        for (uint256 index; index < 3; index++) {
            TestAsset partner = new TestAsset();
            _approve(partner);
            PoolKey memory one = _create(address(backing), address(partner), 3_000);
            PoolKey memory two = _create(address(backing), address(partner), 500);
            _lead(address(backing), address(partner), _list(_id(one), _id(two)));
            lows.push(one);
        }
        _limits(address(backing), 1e15);
        meter.setTrigger(meterKey, id, address(backing), 12_000_000, true);
    }

    function _openGaps() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        for (uint256 index; index < lows.length; index++) {
            PoolKey memory pool = lows[index];
            address partner = Currency.unwrap(pool.currency0) == address(backing)
                ? Currency.unwrap(pool.currency1)
                : Currency.unwrap(pool.currency0);
            _trade(pool, partner, 50_000e18);
        }
        _limits(address(backing), 1e15);
    }

    /// Lowers the market's allowance below what `setLimits` allows, to see the budget bite
    /// at a size a test can reach. It is the second field of the first slot of `Settings`,
    /// which is `markets` at storage slot 4.
    function _setAllowance(uint32 gas) internal {
        bytes32 slot = keccak256(abi.encode(id, uint256(4)));
        uint256 word = uint256(vm.load(address(hook), slot));
        word = (word & ~(uint256(type(uint32).max) << 160)) | uint256(gas) << 160;
        vm.store(address(hook), slot, bytes32(word));
        assertEq(hook.market(id).gasLimit, gas, "allowance set");
    }

    function _meterSwap() internal returns (uint256) {
        bool zeroForOne = Currency.unwrap(meterKey.currency0) == address(backing);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            meterKey,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(1e18),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        return meter.used();
    }

    /// What a swap's trigger did with this allowance, from a clean state: the cycles it
    /// ran, the heads it skipped, and the gas the call used.
    function _tryAllowance(uint256 limit)
        internal
        returns (uint256 cycles, uint256 skipped, uint256 used)
    {
        uint256 snapshot = vm.snapshotState();
        _setAllowance(uint32(limit));
        vm.recordLogs();
        used = _meterSwap();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.Arbitraged.selector) cycles++;
            if (topic == ArbitrageLogic.VenueSearchSkipped.selector) skipped++;
        }
        vm.revertToState(snapshot);
    }

    /// A gap is open in all four groups. With an allowance that only just covers the first
    /// head's floor, the first head's search uses more than the margin, so what is left is
    /// below the next head's floor: the rest are skipped, instead of each being given the
    /// whole allowance again. With plenty, every group is searched.
    function testSearchesOfOneTriggerShareOneBudget() public {
        meter.setBefore(false);
        _openGaps();
        (uint256 all,, uint256 usedAll) = _tryAllowance(hook.market(id).gasLimit);
        assertEq(all, 4, "every group searched with the whole allowance");
        // The smallest allowance, to within 50k, at which anything is searched.
        uint256 low;
        uint256 high = hook.market(id).gasLimit;
        while (high - low > 50_000) {
            uint256 middle = (low + high) / 2;
            (uint256 found,,) = _tryAllowance(middle);
            if (found == 0) low = middle;
            else high = middle;
        }
        (uint256 cycles, uint256 skipped, uint256 used) = _tryAllowance(high);
        emit log_named_uint("smallest allowance that searches", high);
        emit log_named_uint("gas used by all four heads", usedAll);
        emit log_named_uint("gas used with the smallest", used);
        assertEq(cycles, 1, "one head searched");
        assertEq(skipped, 1, "the rest skipped, once");
        assertLe(used, high, "within the allowance");
    }
}
