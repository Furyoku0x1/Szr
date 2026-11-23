// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The review's dust-cycle world (docs/security-review-2026-11-21-pocs.md) with a
/// minimum profit set for each token, as item 1 of docs/specs/hook-review-2026-11-21.md
/// requires. A swap in `stable` opens a WETH book and a USD book. A valuable gap is staged in
/// `first` (WETH/coin) and a small one in a thin hookless USD/coin pool that is a second leader
/// of USD's group. The minimum filters the small cycle, so the valuable gap is closed before
/// the fill at every gas value that passes. The rule does not close the hole: a larger push
/// clears the minimum again, and the spec records that as accepted.
contract ArbitrageReviewDustTest is MultiWorld {
    PoolKey internal thin;
    address internal low;

    function _prepare() internal {
        low = address(coin) < address(dai) ? address(coin) : address(dai);
        thin = _pair(address(usd), low, 100, address(0));
        manager.initialize(thin, uint160(1 << 96));
        _provide(thin, 100e18);
        vm.prank(team);
        hook.addVenue(id, thin);
        _lead(address(usd), low, _list(_id(low == address(coin) ? usdCoin : usdDai), _id(thin)));
    }

    function _stage(uint256 dustMove) internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 100_000e18);
        _limits(address(backing), 1e15);
        _trade(thin, low, dustMove);
    }

    /// WETH paid out by the search before the fill, or `type(uint256).max` if the swap failed.
    function _wethBeforeFill(uint256 gas) internal returns (bool ok, uint256 paid) {
        bool zeroForOne = Currency.unwrap(stable.currency0) == address(coin);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(50_000e18),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.recordLogs();
        (ok,) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (stable, params, settings, ""))
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!ok) return (false, 0);
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory log = logs[index];
            if (log.topics[0] == IPoolManager.Swap.selector) {
                if (log.topics[1] != _id(stable)) continue;
                if (address(uint160(uint256(log.topics[2]))) == address(swapper)) break;
            }
            if (log.topics[0] != ArbitrageLogic.ProfitPaid.selector) continue;
            if (address(uint160(uint256(log.topics[2]))) != address(backing)) continue;
            (uint256 amount,) = abi.decode(log.data, (uint256, uint256));
            paid += amount;
        }
    }

    /// Every gas value from `gasForSwap` down to 1M, in steps of 40,000: each passes with the
    /// valuable gap closed before the fill, or fails.
    function testMinimumFiltersTheDustCycleAtEveryGas() public {
        // The rule: a market that is on with two tokens cannot hold a zero minimum.
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setMinimumProfit(id, address(usd), 0);
        vm.prank(team);
        hook.setMinimumProfit(id, address(usd), 100e18);
        _prepare();
        _stage(30e18);
        uint256 snapshot = vm.snapshotState();
        uint256 passed;
        uint256 failed;
        for (uint256 gas = hook.gasForSwap(id); gas > 1_000_000; gas -= 40_000) {
            vm.revertToState(snapshot);
            (bool ok, uint256 paid) = _wethBeforeFill(gas);
            if (!ok) {
                failed++;
                continue;
            }
            passed++;
            assertGt(paid, 2_000e18, "the valuable gap is closed before the fill");
        }
        assertGt(passed, 0, "some gas values pass");
        assertGt(failed, 0, "and some fail");
    }
}
