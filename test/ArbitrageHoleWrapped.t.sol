// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { StartWorld, StartProbe } from "./ArbitrageWrappedStart.t.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

/// @dev A search that starts from a wrapped pool compares it with plain pools only, and
/// stays as it was: a thin plain pool next to it makes no stand-in
/// (docs/specs/hook-hole-edge.md, spec test 7).
contract ArbitrageHoleWrappedTest is StartWorld {
    function _probeInPlace() internal returns (StartProbe) {
        address at = address(uint160(0xA4B3 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageWrappedStart.t.sol:StartProbe", abi.encode(locker), at);
        vm.etch(address(hook), at.code);
        return StartProbe(payable(address(hook)));
    }

    /// The plain pool is left with a hundred-millionth of its liquidity, so the wrapped
    /// pool, a million of each token, is the whole depth of any cycle between them.
    function _thin() internal {
        provider.modifyLiquidity(
            first,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60),
                TickMath.maxUsableTick(60),
                -int256(poolUnits - 1e16),
                0
            ),
            ""
        );
        _off();
        _trade(first, address(coin), 1e15);
        _on();
    }

    function testAThinPlainPoolMakesNoStandInFromAWrappedStart() public {
        _thin();
        StartProbe probe = _probeInPlace();
        StartProbe.Ranked memory plain =
            probe.rank(id, address(backing), _id(first), address(coin));
        assertGt(plain.score, 0, "a plain start from the thin pool makes a stand-in");
        StartProbe.Ranked memory swapped =
            probe.rank(id, address(backing), _id(wrapped), address(coin));
        assertEq(swapped.score, 0, "a wrapped start makes none");
    }
}
