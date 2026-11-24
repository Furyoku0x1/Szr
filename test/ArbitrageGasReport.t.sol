// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { StartWorld } from "./ArbitrageWrappedStart.t.sol";

/// @dev Reports the cold gas of each path of a hooked swap, for `docs/specs/hook-gas`. The
/// accounts a swap reads are marked cold first, so the figures are what a first read costs.
/// They are logged, not asserted; `testSwapCostDoesNotGrowWithPoolsTracked` holds the limit.
contract ArbitrageGasReportSzrTest is ArbitrageWorld {
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        vm.cool(address(szr));
        vm.cool(address(usd));
        vm.cool(address(backing));
        vm.cool(address(swapper));
    }

    function _six() internal {
        _addHooked(address(backing), 500);
        _addHooked(address(backing), 100);
        _addHooked(address(usd), 500);
        _addHooked(address(usd), 100);
    }

    function testReportSzrNoGapSixPools() public {
        _six();
        _trade(usdPool, address(szr), 1e18);
        _trade(usdPool, address(szr), 1e15);
        _cool();
        uint256 spent = gasleft();
        _trade(usdPool, address(szr), 1e15);
        spent -= gasleft();
        emit log_named_uint("GAS szr no gap, six pools", spent);
    }

    /// A group whose partner token no connecting pool reaches: each search prices a route
    /// to it that is not there.
    function testReportSzrNoGapUnconnectedGroup() public {
        TestAsset lone = new TestAsset();
        _approve(lone);
        _addHooked(address(lone), 3_000);
        _trade(usdPool, address(szr), 1e18);
        _trade(usdPool, address(szr), 1e15);
        _cool();
        uint256 spent = gasleft();
        _trade(usdPool, address(szr), 1e15);
        spent -= gasleft();
        emit log_named_uint("GAS szr no gap, unconnected group", spent);
    }

    function testReportSzrOneGap() public {
        _cool();
        uint256 spent = gasleft();
        _trade(usdPool, address(szr), 50_000e18);
        spent -= gasleft();
        emit log_named_uint("GAS szr one gap", spent);
    }

    function _openGap() internal {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
    }

    function testReportArb() public {
        _openGap();
        _cool();
        uint256 spent = gasleft();
        hook.arb(_id(usdPool));
        spent -= gasleft();
        emit log_named_uint("GAS arb", spent);
    }

    function testReportSweep() public {
        _openGap();
        _cool();
        uint256 spent = gasleft();
        hook.sweep(1, address(szr));
        spent -= gasleft();
        emit log_named_uint("GAS sweep", spent);
    }
}

contract ArbitrageGasReportOutsideTest is MultiWorld {
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(backing));
        vm.cool(address(usd));
        vm.cool(address(coin));
        vm.cool(address(dai));
        vm.cool(address(swapper));
    }

    function testReportOutsideOneBookNoGap() public {
        _trade(first, address(coin), 1e15);
        _trade(first, address(coin), 1e15);
        _cool();
        uint256 spent = gasleft();
        _trade(first, address(coin), 1e15);
        spent -= gasleft();
        emit log_named_uint("GAS outside, swap in first, no gap", spent);
    }

    function testReportOutsideTwoBooksNoGap() public {
        _trade(stable, address(coin), 1e15);
        _trade(stable, address(coin), 1e15);
        _cool();
        uint256 spent = gasleft();
        _trade(stable, address(coin), 1e15);
        spent -= gasleft();
        emit log_named_uint("GAS outside, two books, no gap", spent);
    }

    function testReportOutsideTwoBooksGap() public {
        _cool();
        uint256 spent = gasleft();
        _trade(stable, address(coin), 50_000e18);
        spent -= gasleft();
        emit log_named_uint("GAS outside, two books, gap", spent);
    }

    function testReportOutsideOneBookGap() public {
        _cool();
        uint256 spent = gasleft();
        _trade(first, address(coin), 50_000e18);
        spent -= gasleft();
        emit log_named_uint("GAS outside, one book, gap", spent);
    }
}

contract ArbitrageGasReportWrappedTest is StartWorld {
    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(wrapper));
        vm.cool(address(pricer));
        vm.cool(address(backing));
        vm.cool(address(coin));
        vm.cool(address(swapper));
    }

    function testReportWrappedVenueNoGap() public {
        _on();
        _trade(first, address(coin), 1e15);
        _trade(first, address(coin), 1e15);
        _cool();
        uint256 spent = gasleft();
        _trade(first, address(coin), 1e15);
        spent -= gasleft();
        emit log_named_uint("GAS wrapped venue, no gap", spent);
    }

    function testReportWrappedVenueGap() public {
        _off();
        _trade(first, address(coin), 50_000e18);
        _on();
        _cool();
        uint256 spent = gasleft();
        hook.sweep(id, address(backing));
        spent -= gasleft();
        emit log_named_uint("GAS wrapped venue, sweep of the gap", spent);
    }

    function testReportWrappedSweepTwoHeads() public {
        PoolKey memory daiPool = _create(address(backing), address(dai), 3_000);
        _lead(address(backing), address(dai), _list(_id(daiPool)));
        _on();
        _cool();
        uint256 spent = gasleft();
        hook.sweep(id, address(backing));
        spent -= gasleft();
        emit log_named_uint("GAS wrapped venue, sweep of two heads, no gap", spent);
    }
}
