// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev What decides which books a swap opens and in what order they are tried
/// (docs/specs/hook-final-items.md, 1a), on `MultiWorld`'s market of WETH and USD.
contract ArbitrageMultiBooksTest is MultiWorld {
    function _off() internal {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
    }

    /// The centre of the first cycle of a swap in `stable` after two gaps of these sizes.
    function _firstCentre(uint256 wethMove, uint256 usdMove) internal returns (bytes32) {
        _off();
        _trade(first, address(coin), wethMove);
        _trade(usdCoin, address(coin), usdMove);
        _limits(address(backing), 1e15);
        vm.recordLogs();
        _trade(stable, address(coin), 1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) {
                return logs[index].topics[1];
            }
        }
        revert("no cycle");
    }

    /// Two gaps are open when the swap starts, and with room for one cycle the wider is
    /// closed first, whichever book it is in.
    function testWidestGapIsTriedFirst() public {
        uint256 snapshot = vm.snapshotState();
        bytes32 centre = _firstCentre(20_000e18, 200_000e18);
        assertEq(centre, _id(usdDai), "the wider gap was USD's");
        vm.revertToState(snapshot);
        centre = _firstCentre(200_000e18, 20_000e18);
        assertEq(centre, _id(wethDai), "the wider gap was WETH's");
    }

    /// A token whose approval was withdrawn while the market still chooses it opens no book,
    /// so a gap only its book could close is left, and nothing is paid to the zero address.
    function testUnapprovedTokenOpensNoBook() public {
        _off();
        _trade(usdCoin, address(coin), 200_000e18);
        _limits(address(backing), 1e15);
        hook.setProfitToken(address(usd), address(0));
        _trade(stable, address(coin), 1e15);
        assertEq(usd.balanceOf(treasury), 0, "USD was not searched");
        assertEq(usd.balanceOf(address(0)), 0, "nothing sent to nobody");
        assertEq(manager.balanceOf(address(0), uint256(uint160(address(usd)))), 0, "nor held");
        _assertNothingHeld();
    }

    /// With no leader for the pool's lower token, a book is centred on the leader for its
    /// higher one.
    function testBookFallsBackToTheHigherTokensLeader() public {
        bool lowIsCoin = address(coin) < address(dai);
        _lead(address(usd), lowIsCoin ? address(coin) : address(dai), new bytes32[](0));
        (address[] memory bases, bytes32[] memory centres) = _books();
        assertEq(centres[_at(bases, address(usd))], _id(lowIsCoin ? usdDai : usdCoin));
    }

    /// A token with a leader on neither side of the pool opens no book.
    function testBookWithNoLeaderOnEitherSideIsLeftOut() public {
        _lead(address(usd), address(coin), new bytes32[](0));
        _lead(address(usd), address(dai), new bytes32[](0));
        (address[] memory bases,) = _books();
        assertEq(bases.length, 1, "only WETH's book");
        assertEq(bases[0], address(backing));
    }

    function _books() internal returns (address[] memory bases, bytes32[] memory centres) {
        ArbitrageProbe probe = _probeInHook();
        (, bases, centres) = probe.centresOf(id, _id(stable), stable);
        assertTrue(probe.centresAgree(id, _id(stable), stable), "the same books as before");
    }

    function _at(address[] memory bases, address token) internal pure returns (uint256) {
        for (uint256 index; index < bases.length; index++) {
            if (bases[index] == token) return index;
        }
        revert("no book");
    }

    /// WETH's book earns twice, and only then does USD's cycle pass through WETH. The credit
    /// it must leave alone is both gains, so USD's book still earns and nothing fails.
    function testBookThatEarnedTwiceLeavesItsWholeCredit() public {
        PoolKey memory both = _create(address(backing), address(usd), 3_000);
        vm.startPrank(team);
        hook.addVenue(id, publicPool);
        hook.setConnector(id, second, true);
        vm.stopPrank();
        _lead(address(backing), address(usd), _list(_id(both), _id(publicPool)));
        _off();
        _trade(first, address(coin), 100_000e18);
        _trade(second, address(coin), 60_000e18);
        _limits(address(backing), 1e15);
        vm.recordLogs();
        _trade(both, address(backing), 50_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 cycles;
        uint256 failed;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) cycles++;
            if (logs[index].topics[0] == ArbitrageLogic.CycleFailed.selector) failed++;
        }
        emit log_named_uint("cycles", cycles);
        assertEq(failed, 0, "no cycle failed");
        assertGt(cycles, 2, "WETH earned twice and USD once");
        assertGt(usd.balanceOf(treasury), 0, "USD's book earned");
        _assertNothingHeld();
    }

    /// Listing the books costs what `gasForSwap` holds back for it, cold, with one, two and
    /// eight chosen tokens, none of the extra ones with a leader.
    function testCentresCostWithinReserve() public {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _centresWithin(1);
        _centresWithin(2);
        _centresWithin(8);
    }

    function _centresWithin(uint256 count) internal {
        address[] memory tokens = new address[](count);
        tokens[0] = address(backing);
        if (count > 1) tokens[1] = address(usd);
        for (uint256 index = 2; index < count; index++) {
            TestAsset extra = new TestAsset();
            hook.setProfitToken(address(extra), desk);
            tokens[index] = address(extra);
        }
        vm.prank(team);
        hook.setTokens(id, tokens);
        ArbitrageProbe probe = _probeInHook();
        vm.cool(address(hook));
        (uint256 used,,) = probe.centresOf(id, _id(stable), stable);
        (uint256 hop, uint256 overhead, uint256 centre, uint256 base) = probe.swapGasConstants();
        emit log_named_uint("listing books, tokens", count);
        emit log_named_uint("listing books, gas", used);
        assertLe(used, base + count * centre, "within the reserve");
        uint256 search = probe.minimumGasLimit(id) * 64 / 63 + hop;
        uint256 stated = (search + overhead + base + count * centre) * 64 / 63 * 64 / 63;
        assertEq(probe.gasForSwap(id), stated, "and gasForSwap holds it back");
        emit log_named_uint("gasForSwap", stated);
    }

    /// With a gap open in each book, a swap given anything from the least it needs to far
    /// more either passes or fails for gas, and never fails after a smaller amount passed.
    /// Once the search has earned and holds less than its floor, it stops quietly to keep
    /// what the swap itself needs, so it never reports a cut-short search while it has
    /// earned, bar where ranking itself used the gas.
    function testSwapStopsQuietlyOnceEarnedBelowTheFloor() public {
        _off();
        _trade(first, address(coin), 100_000e18);
        _trade(usdCoin, address(coin), 100_000e18);
        _limits(address(backing), 1e15);
        uint256 snapshot = vm.snapshotState();
        uint256 low = hook.gasForSwap(id);
        bool passed;
        uint256 reports;
        for (uint256 gas = low - 3_500_000; gas <= low + 500_000; gas += 100_000) {
            vm.revertToState(snapshot);
            vm.recordLogs();
            (bool ok, bytes memory data) = _tradeWithGas(stable, address(coin), gas);
            if (!ok) {
                assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "for gas");
                assertFalse(passed, "failed with more gas than a swap that passed");
                continue;
            }
            passed = true;
            reports += _reportedAfterEarning(vm.getRecordedLogs());
        }
        // Only where ranking itself used up the last of the gas: 2 here. Without the check
        // every swap that earns below the floor reports, 9 here.
        assertLe(reports, 3, "reported after earning");
        assertTrue(passed, "the largest passed");
    }

    /// How many cut-short events follow a cycle before its search's payout.
    function _reportedAfterEarning(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bool earned;
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.Arbitraged.selector) earned = true;
            if (topic == ArbitrageLogic.ProfitPaid.selector) earned = false;
            if (topic != ArbitrageLogic.SearchCutShort.selector) continue;
            if (earned) count++;
        }
    }
}
