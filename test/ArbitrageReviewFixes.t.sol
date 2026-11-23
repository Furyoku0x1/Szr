// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ClaimHelper } from "./ArbitrageClaims.t.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A token whose balance read fails for one caller: cheaply (mode 1) or by using all
/// the gas it is given (mode 2).
contract ReadFailAsset is TestAsset {
    address internal reader;
    uint8 internal mode;

    function arm(address who, uint8 how) external {
        reader = who;
        mode = how;
    }

    function balanceOf(address who) public view override returns (uint256) {
        if (msg.sender == reader) {
            if (mode == 1) revert("read");
            if (mode == 2) {
                assembly {
                    invalid()
                }
            }
        }
        return super.balanceOf(who);
    }
}

/// @dev Shared helpers: a swap with chosen gas, and the events of one swap split at the fill.
abstract contract ReviewWorld is MarketsWorld {
    function _swapWithGas(PoolKey memory pool, address input, uint256 amount, uint256 gas)
        internal
        returns (bool ok, bytes memory data)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok, data) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (pool, params, settings, ""))
        );
    }

    /// The pool manager wraps a hook's error, so look for its selector inside the data.
    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 found = bytes4(
                bytes.concat(data[index], data[index + 1], data[index + 2], data[index + 3])
            );
            if (found == wanted) return true;
        }
        return false;
    }
}

/// @dev A payout whose balance read fails (docs/specs/hook-review-2026-11-21.md, item 4).
contract ArbitrageReadFailTest is ReviewWorld {
    ReadFailAsset internal ink;
    PoolKey internal inkPool;
    PoolKey internal inkCheap;

    function setUp() public override {
        super.setUp();
        ink = new ReadFailAsset();
        _approve(ink);
        hook.setProfitToken(address(ink), desk);
        address[] memory only = new address[](1);
        only[0] = address(ink);
        vm.startPrank(team);
        hook.setMinimumProfit(id, address(ink), 1e15);
        hook.setTokens(id, only);
        vm.stopPrank();
        inkPool = _create(address(ink), address(coin), 3_000);
        inkCheap = _create(address(ink), address(coin), 500);
        _lead(address(ink), address(coin), _list(_id(inkPool), _id(inkCheap)));
        // An allowance above what the swap brings, so the search is not capped by it.
        vm.prank(team);
        hook.setLimits(id, address(ink), 30_000_000, 1e15, 1.0001e18);
    }

    function _undone() internal returns (bool seen, bytes4 reason, uint256 paid) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.ProfitPaid.selector) paid++;
            if (topic != ArbitrageLogic.SearchUndone.selector) continue;
            seen = true;
            reason = abi.decode(logs[index].data, (bytes4));
        }
    }

    function _ample() internal view returns (uint256) {
        return hook.gasForSwap(id) + 200_000;
    }

    /// Control: the same swap with a healthy token closes the gap and pays.
    function testHealthyTokenIsPaid() public {
        vm.recordLogs();
        (bool ok,) = _swapWithGas(inkPool, address(coin), 50_000e18, _ample());
        (bool seen,, uint256 paid) = _undone();
        assertTrue(ok, "swap passes");
        assertFalse(seen, "nothing undone");
        assertGt(paid, 0, "paid");
    }

    /// A read that fails on purpose, with gas to spare, undoes the search and the swap goes
    /// on. Without the change it reverted `InsufficientGas`.
    function testCheapFailingReadUndoesTheSearchOnly() public {
        ink.arm(address(hook), 1);
        vm.recordLogs();
        (bool ok,) = _swapWithGas(inkPool, address(coin), 50_000e18, _ample());
        (bool seen, bytes4 reason, uint256 paid) = _undone();
        assertTrue(ok, "swap passes");
        assertTrue(seen, "search undone");
        assertEq(reason, ArbitrageLogic.Unsettled.selector, "named Unsettled");
        assertEq(paid, 0, "nothing paid");
    }

    /// A read that uses all its gas is too little gas, not an undone search.
    function testReadThatBurnsItsGasStillFailsTheSwap() public {
        ink.arm(address(hook), 2);
        (bool ok, bytes memory data) = _swapWithGas(inkPool, address(coin), 50_000e18, _ample());
        assertFalse(ok, "swap fails");
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "InsufficientGas");
    }

    /// A healthy token with the gas tuned so that the payout's read itself runs short:
    /// every gas value either passes or fails without `Unsettled`, and some do fail.
    function testHealthyPayoutNeverReadsAsUnsettledAtAnyGas() public {
        address probeAt = address(uint160(0xA4B2 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), probeAt);
        ArbitrageProbe probe = ArbitrageProbe(payable(probeAt));
        probe.setProfitToken(address(ink), desk);
        vm.prank(team);
        uint256 market = probe.openMarket(address(0xC01D2));
        ClaimHelper helper = new ClaimHelper(manager);
        ink.mint(address(helper), 1e18);
        uint256 snapshot = vm.snapshotState();
        uint256 failed;
        uint256 passed;
        for (uint256 gas = 40_000; gas <= 400_000; gas += 250) {
            vm.revertToState(snapshot);
            vm.cool(address(ink));
            (bool ok, bytes memory data) = address(helper).call{ gas: gas }(
                abi.encodeCall(helper.measure, (probe, market, address(ink), 1e18))
            );
            if (ok) {
                passed++;
                continue;
            }
            failed++;
            assertFalse(_has(data, ArbitrageLogic.Unsettled.selector), "quiet pass");
        }
        assertGt(failed, 0, "some gas values fail");
        assertGt(passed, 0, "and some pass");
    }

    /// The same, driven by a real swap with a profitable cycle open and a healthy token: each
    /// outcome is a normal payout or `InsufficientGas`, never a settled swap with the search
    /// undone as `Unsettled` and the gap left open. The window is the one where this swap goes
    /// from passing to refused, in steps of 2,000 gas.
    function testRealSwapAtEveryGasIsPaidOrRefused() public {
        uint256 snapshot = vm.snapshotState();
        uint256 paidCount;
        uint256 refused;
        for (uint256 gas = 2_100_000; gas >= 1_600_000; gas -= 2_000) {
            vm.revertToState(snapshot);
            vm.recordLogs();
            (bool ok, bytes memory data) = _swapWithGas(inkPool, address(coin), 50_000e18, gas);
            (bool seen, bytes4 reason, uint256 paid) = _undone();
            if (!ok) {
                assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "for gas");
                refused++;
                continue;
            }
            if (seen) assertTrue(reason != ArbitrageLogic.Unsettled.selector, "quiet pass");
            assertGt(paid, 0, "settled without paying");
            paidCount++;
        }
        assertGt(paidCount, 0, "some are paid");
        assertGt(refused, 0, "some are refused");
    }
}
