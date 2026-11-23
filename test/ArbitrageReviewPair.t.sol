// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A pool that leads under both of its tokens shows the same failing cycle in two
/// books (docs/specs/hook-review-2026-11-21.md, item 5, withdrawn).
/// P holds WETH and USD, so a swap in
/// it opens a WETH book and a USD book, each centred on P with Q, a fake pool of the same two
/// tokens, as a venue. Q looks far off with liquidity at the edge of its range, so a cycle
/// against it always fails. Z is a second such pool of WETH and coin, and R a real gap.
contract ArbitrageReviewPairTest is MultiWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolKey internal pool;
    PoolKey internal fakeQ;
    PoolKey internal fakeZ;
    PoolKey internal real;

    function _fake(address one, address other, uint24 fee, int24 away, bool down)
        internal
        returns (PoolKey memory fake)
    {
        fake = _pair(one, other, fee, address(0));
        manager.initialize(fake, uint160(1 << 96));
        int24 tick = down ? -away : away;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            fake,
            IPoolManager.SwapParams(down, -1e30, TickMath.getSqrtPriceAtTick(tick)),
            settings,
            ""
        );
        provider.modifyLiquidity(
            fake,
            IPoolManager.ModifyLiquidityParams(
                down ? tick - 60 : tick, down ? tick : tick + 60, 1e22, 0
            ),
            ""
        );
        vm.prank(team);
        hook.addVenue(id, fake);
    }

    function _world(bool withZ, bool withReal) internal {
        address[] memory two = new address[](2);
        two[0] = address(backing);
        two[1] = address(usd);
        vm.prank(team);
        hook.setTokens(id, two);
        pool = _create(address(backing), address(usd), 3_000);
        fakeQ = _fake(address(backing), address(usd), 100, 21_960, false);
        bytes32[] memory wethGroup = new bytes32[](withReal ? 3 : 2);
        wethGroup[0] = _id(pool);
        wethGroup[1] = _id(fakeQ);
        if (withReal) {
            real = _pair(address(backing), address(usd), 500, address(0));
            manager.initialize(real, uint160(1 << 96));
            _provide(real, 1_000_000e18);
            vm.prank(team);
            hook.addVenue(id, real);
            wethGroup[2] = _id(real);
        }
        _lead(address(backing), address(usd), wethGroup);
        _lead(address(usd), address(backing), _list(_id(pool), _id(fakeQ)));
        bytes32[] memory none = new bytes32[](0);
        _lead(address(backing), address(coin), none);
        if (withZ) {
            fakeZ = _fake(address(backing), address(coin), 100, 3_000, false);
            vm.prank(team);
            hook.setConnector(id, usdCoin, true);
            _lead(address(backing), address(coin), _list(_id(fakeZ)));
        }
        _lead(address(usd), address(coin), none);
        _lead(address(usd), address(dai), none);
        _lead(address(backing), address(dai), none);
    }

    function _swap(uint256 gas) internal returns (bool ok, bytes memory data) {
        return _swapWithGas(pool, address(backing), 1e15, gas);
    }

    function _swapWithGas(PoolKey memory key, address input, uint256 amount, uint256 gas)
        internal
        returns (bool ok, bytes memory data)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok, data) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (key, params, settings, ""))
        );
    }

    /// The search before the fill ends at the swapper's own `Swap` event.
    function _before(Vm.Log[] memory logs, bytes32 topic)
        internal
        view
        returns (uint256 count)
    {
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory log = logs[index];
            if (log.topics[0] == IPoolManager.Swap.selector) {
                if (log.topics[1] == _id(pool)) {
                    if (address(uint160(uint256(log.topics[2]))) == address(swapper)) break;
                }
            }
            if (log.topics[0] == topic) count++;
        }
    }

    function _sliver(PoolKey memory key) internal {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        int24 lo = tick / 60 * 60;
        if (tick < 0) {
            if (tick % 60 != 0) lo -= 60;
        }
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lo, lo + 60, 100_000_000e18, 0), ""
        );
    }

    /// The minimum profit is per token, so a pair that fails in WETH's book only because
    /// WETH's minimum is high is still tried in USD's book, and the gap is closed before the
    /// fill. Passing the pair over in the other books (the withdrawn item 5) would leave one
    /// failure and no cycle before the fill.
    function testAPairThatFailedIsStillTriedInTheOtherTokensBook() public {
        _world(false, true);
        _lead(address(backing), address(usd), _list(_id(pool), _id(real)));
        _lead(address(usd), address(backing), _list(_id(pool), _id(real)));
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(real, address(usd), 2_000e18);
        _sliver(real);
        _sliver(pool);
        _limits(address(backing), 1e15);
        vm.prank(team);
        hook.setMinimumProfit(id, address(backing), 0.3e18);
        vm.recordLogs();
        (bool ok,) = _swap(hook.gasForSwap(id) + 500_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "swap passes");
        assertEq(_before(logs, ArbitrageLogic.CycleFailed.selector), 1, "one failed");
        assertEq(_before(logs, ArbitrageLogic.Arbitraged.selector), 1, "one closed");
    }
}
