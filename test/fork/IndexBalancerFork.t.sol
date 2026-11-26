// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexBalancerForkBase } from "./IndexBalancerForkBase.sol";

/// @dev The balancer against real Robinhood stock pools: what it captures of a gap, and what
/// an attacker who moves a venue's price makes or loses. Reports, not gates. Skipped unless
/// FORK_RPC_URL is set:
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path
///   "test/fork/IndexBalancerFork.t.sol" -vv
contract IndexBalancerForkTest is IndexBalancerForkBase {
    uint256[3] internal sizes = [uint256(100_000), 1_000_000, 5_000_000];
    uint256[3] internal gaps = [uint256(0.01e18), 0.05e18, 0.2e18];

    /// Capture: pools of NVDA, TSLA and USDG at a third each, and of NVDA, TSLA, AAPL, META
    /// and USDG at a fifth, started at market and then NVDA put out of line.
    function testCapture() public onlyFork {
        address[] memory three = _three(NVDA, TSLA);
        address[] memory five = new address[](5);
        (five[0], five[1], five[2], five[3], five[4]) = (NVDA, TSLA, AAPL, META, USDG);
        _sort(five);
        console.log("pool, size $, gap (bps), gap value, captured, cycles, gas (raw USDG)");
        for (uint256 kind; kind < 2; kind++) {
            address[] memory list = kind == 0 ? three : five;
            for (uint256 s; s < 3; s++) {
                for (uint256 g; g < 3; g++) {
                    _captureCase(list, sizes[s], gaps[g]);
                }
            }
        }
    }

    function _captureCase(address[] memory list, uint256 usd, uint256 gap) internal {
        uint256 snapshot = vm.snapshotState();
        IndexPool pool = _pool(list, _equalWeights(list.length), usd, _indexOf(list, NVDA), gap);
        uint256 value = _gapValue(pool);
        (uint256 captured, uint256 cycles, uint256 gas) = _close(pool, NVDA);
        console.log(list.length, usd, gap / 1e14);
        console.log("  ", value, captured);
        console.log("  ", cycles, gas);
        vm.revertToState(snapshot);
    }

    /// Venue manipulation: an attacker buys NVDA (thin) or AAPL (deep) on its real venue to
    /// push its price up 5%, triggers the hook with a dust swap, sells the token it bought
    /// into the index pool at the moved price, and sells the rest back on the venue. The
    /// attacker's result and the depositors' are at the venue's starting price.
    function testVenueManipulation() public onlyFork {
        console.log("token, size $, attacker P&L (raw USDG, signed), depositors P&L");
        address[2] memory tokens = [NVDA, AAPL];
        for (uint256 t; t < 2; t++) {
            for (uint256 s; s < 3; s++) {
                _manipulate(tokens[t], sizes[s]);
            }
        }
    }

    function _manipulate(address token, uint256 usd) internal {
        uint256 snapshot = vm.snapshotState();
        address[] memory list = new address[](2);
        (list[0], list[1]) = token < USDG ? (token, USDG) : (USDG, token);
        IndexPool pool = _pool(list, _equalWeights(2), usd, 0, 0);
        uint256 start = _price(token);
        uint256 worthBefore = _worthAt(pool, token, start);
        int256 attackerPnl = _attack(pool, token, start);
        int256 depositors = int256(_worthAt(pool, token, start)) - int256(worthBefore);
        console.log(token == NVDA ? "NVDA (thin)" : "AAPL (deep)", usd);
        console.logInt(attackerPnl);
        console.logInt(depositors);
        vm.revertToState(snapshot);
    }

    function _attack(IndexPool pool, address token, uint256 start) internal returns (int256) {
        address attacker = makeAddr("attacker");
        _fund(USDG, attacker, 50_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDG).approve(address(pool), FAR);
        IERC20(token).approve(address(pool), FAR);
        IERC20(token).approve(address(swapper), FAR);
        vm.stopPrank();
        uint256 cash = IERC20(USDG).balanceOf(attacker);
        _pushTo(attacker, token, start * 105 / 100);
        // A dust swap sets the hook off at the moved price.
        vm.prank(attacker);
        pool.swap(USDG, token, 10e6, true, 0, attacker, FAR);
        // A quarter of what it bought goes into the index pool at its new price.
        uint256 sell = IERC20(token).balanceOf(attacker) / 4;
        vm.prank(attacker);
        try pool.swap(token, USDG, sell, true, 0, attacker, FAR) { } catch { }
        uint256 held = IERC20(token).balanceOf(attacker);
        if (held != 0) {
            vm.prank(attacker);
            swapper.swap(venueOf[token], _params(venueOf[token], token, held), _none(), "");
        }
        return int256(IERC20(USDG).balanceOf(attacker)) - int256(cash);
    }

    /// The bench window. The tries are made to fail (every pool-manager swap reverts, by a
    /// mocked call: what a real attacker would need to do this is not reproduced) while NVDA
    /// is 2% dear on its venue, which sets the pair aside. Inside the three minutes the same
    /// real gap, under twice the failed one, is taken by the attacker; the same trade with no
    /// pair set aside is the baseline. Raw USDG.
    function testBenchWindow() public onlyFork {
        console.log("size $, attacker P&L with the pair set aside, without");
        for (uint256 s; s < 3; s++) {
            int256 benched = _window(sizes[s], true);
            int256 open = _window(sizes[s], false);
            console.log(sizes[s]);
            console.logInt(benched);
            console.logInt(open);
        }
    }

    function _window(uint256 usd, bool aside) internal returns (int256 pnl) {
        uint256 snapshot = vm.snapshotState();
        address[] memory list = new address[](2);
        (list[0], list[1]) = (USDG, NVDA);
        IndexPool pool = _pool(list, _equalWeights(2), usd, 0, 0);
        address mover = makeAddr("market");
        _fund(USDG, mover, 50_000_000e6);
        _pushTo(mover, NVDA, _price(NVDA) * 102 / 100);
        address attacker = makeAddr("attacker");
        _fund(USDG, attacker, 50_000_000e6);
        vm.startPrank(attacker);
        IERC20(USDG).approve(address(pool), FAR);
        IERC20(NVDA).approve(address(swapper), FAR);
        if (aside) {
            vm.mockCallRevert(
                address(MANAGER), abi.encodeWithSelector(IPoolManager.swap.selector), "no"
            );
        }
        pool.swap(USDG, NVDA, 10e6, true, 0, attacker, FAR);
        vm.clearMockedCalls();
        (uint64 until,) = settings.benched(keccak256(abi.encode(address(pool), USDG, NVDA)));
        assertEq(until != 0, aside, "set aside only when the tries failed");
        vm.warp(block.timestamp + 60);
        uint256 cash = IERC20(USDG).balanceOf(attacker);
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(attacker);
        // Buys about the gap's worth of NVDA from the index pool, sells it on the venue.
        uint256 spend = pool.balances()[0] / 100;
        pool.swap(USDG, NVDA, spend, true, 0, attacker, FAR);
        uint256 bought = IERC20(NVDA).balanceOf(attacker) - nvdaBefore;
        swapper.swap(venueOf[NVDA], _params(venueOf[NVDA], NVDA, bought), _none(), "");
        vm.stopPrank();
        pnl = int256(IERC20(USDG).balanceOf(attacker)) - int256(cash);
        vm.revertToState(snapshot);
    }

    /// The pool's worth with `token` priced at `price`, and its donations still to come.
    function _worthAt(IndexPool pool, address token, uint256 price)
        internal
        view
        returns (uint256 total)
    {
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        for (uint256 index; index < list.length; index++) {
            uint256 amount = held[index] + pool.unreleased(list[index]);
            total += list[index] == token ? amount * price / 1e18 : amount;
        }
    }

    /// Buys `token` on its venue with USDG until its price reaches `target`.
    function _pushTo(address who, address token, uint256 target) internal {
        for (uint256 step; step < 40; step++) {
            if (_price(token) >= target) return;
            vm.prank(who);
            swapper.swap(venueOf[token], _params(venueOf[token], USDG, 2000e6), _none(), "");
        }
    }

    function _params(PoolKey memory key, address input, uint256 amount)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        return IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    function _none() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }
}
