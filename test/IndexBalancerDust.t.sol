// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console } from "forge-std/console.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { BalancerWorld } from "./utils/IndexBalancerWorld.sol";

/// @dev L-4, measured only: a venue stuffed with dust positions across the range a cycle
/// trades through, and the gas of one try and of a whole failing call against the
/// recommended `hookGas` of 4,200,000. Recorded, not a gate.
contract IndexBalancerDustTest is BalancerWorld {
    address internal token;
    address internal unit;

    function setUp() public override {
        super.setUp();
        address[] memory list = _two(18, 18);
        (token, unit) = (list[0], list[1]);
    }

    /// A pool with the token 5% cheap against a tick-spacing-1 venue holding `ticks`
    /// initialised ticks of dust between its price and the pool's.
    function _stuffed(uint256 ticks, uint256 minimumProfit) internal returns (IndexPool pool) {
        address[] memory list = new address[](2);
        (list[0], list[1]) = token < unit ? (token, unit) : (unit, token);
        pool = _create(list, _equal(2), FEE, address(balancer), 4_200_000);
        IndexToken(token).approve(address(pool), type(uint256).max);
        IndexToken(unit).approve(address(pool), type(uint256).max);
        PoolKey memory key = _key();
        uint256 price = 1.05e18;
        uint256 ratio = token < unit ? price : 1e36 / price;
        manager.initialize(key, uint160(_sqrt(ratio)));
        int24 top = TickMath.maxUsableTick(1);
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-top, top, 1e22, 0), ""
        );
        // The cycle sells the token there, from about tick 488 towards 240 (or the
        // reverse): each dust position adds two initialised ticks inside that path.
        for (uint256 index; index < ticks / 2; index++) {
            int24 at = int24(int256(478 - index * 2));
            if (token > unit) at = -at - 1;
            provider.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams(at, at + 1, 1e3, 0), ""
            );
        }
        _attach(pool, unit, token, key, 1e15, minimumProfit);
        pool.start(_amounts(1000e18, 1000e18), 1e24, FAR);
    }

    function _key() internal view returns (PoolKey memory) {
        (address a, address b) = token < unit ? (token, unit) : (unit, token);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 3000, 1, IHooks(address(0)));
    }

    function _sqrt(uint256 ratio) internal pure returns (uint256 z) {
        uint256 x = ratio * (1 << 96) / 1e18 * (1 << 96);
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    function testDustGas() public {
        uint256[4] memory counts = [uint256(0), 10, 50, 200];
        console.log("ticks, one try (gas), whole failing call (gas), failing as hook call");
        for (uint256 run; run < 4; run++) {
            uint256 snapshot = vm.snapshotState();
            IndexPool pool = _stuffed(counts[run], 0);
            uint256 before = gasleft();
            uint256 profit = balancer.balance(address(pool), token, unit);
            uint256 one = before - gasleft();
            vm.revertToState(snapshot);
            pool = _stuffed(counts[run], 1e30);
            before = gasleft();
            balancer.balance(address(pool), token, unit);
            uint256 failing = before - gasleft();
            // The same as the pool makes it, with exactly the allowance.
            vm.prank(address(pool));
            before = gasleft();
            balancer.beforeSwap{ gas: 4_200_000 }(address(this), token, unit);
            uint256 capped = before - gasleft();
            console.log(counts[run], one, failing);
            console.log("  ", capped, profit);
            vm.revertToState(snapshot);
        }
    }
}
