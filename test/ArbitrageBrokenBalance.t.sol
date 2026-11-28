// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { BrokenBalanceAsset } from "./utils/ArbitrageBrokenBalance.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { Vm } from "forge-std/Vm.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A balance read that fails inside a cycle (backlog: "a failing balance read inside a
/// cycle"). The cycle here unwraps WETH, which takes it out of the pool manager (`_take`,
/// after the read in `V4Read._funded`). Away from payout a failed read is a bare revert, which
/// fails the cycle like one that ran out of gas; the swap goes on. This documents today's
/// behaviour, so it passes on the current code. `_legLimit`'s read is only for wrapped pools
/// and is not reached here.
contract ArbitrageBrokenBalanceTest is WrapWorld {
    function _world() internal returns (PoolKey memory hooked, PoolKey memory venue) {
        hooked = _make(address(0), address(usd), 3_000, address(hook));
        venue = _make(address(backing), address(usd), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(0), _list(_id(hooked)));
        _lead(address(usd), address(backing), _list(_id(venue)));
        _limits(address(usd), 1e15);
    }

    /// The control: the same world with WETH readable closes the gap through the unwrap.
    function testTheCycleUnwrapsWhileWethIsReadable() public {
        (PoolKey memory hooked, PoolKey memory venue) = _world();
        _in(venue, address(backing), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        (uint256 bought, uint256 sold,, uint256 unwraps) = _tally();
        assertGt(bought + sold, 0, "a cycle completed");
        assertGt(unwraps, 0, "through the unwrap");
    }

    /// With WETH's `balanceOf` reverting for the hook, the cycle fails, the swap fills, and
    /// nothing is paid or left held.
    function testAFailingBalanceReadFailsTheCycleNotTheSwap() public {
        (PoolKey memory hooked, PoolKey memory venue) = _world();
        _in(venue, address(backing), 50_000e18);
        vm.etch(address(backing), address(new BrokenBalanceAsset()).code);
        BrokenBalanceAsset(address(backing)).breakFor(address(hook));
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 bought, uint256 sold,,) = _tallyOf(logs);
        assertEq(bought + sold, 0, "no cycle completed");
        uint256 failed;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.CycleFailed.selector) failed++;
        }
        assertGt(failed, 0, "the cycle failed");
        assertEq(usd.balanceOf(treasury), 0, "nothing paid");
        _assertClean();
    }
}
