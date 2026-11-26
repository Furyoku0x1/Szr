// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { DrainRouter } from "./utils/ArbitrageDrain.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";

/// @dev The search after a swap cannot tell a drained pool manager from a swapper that has
/// not paid yet: routers pay after swapping. So a shortage there undoes that search and the
/// swap goes on, where before the swap it fails the swap (see `ArbitrageDrainedTest`).
contract ArbitrageDrainedAfterTest is WrapWorld {
    DrainRouter internal drain;

    function setUp() public override {
        super.setUp();
        drain = new DrainRouter(manager);
        vm.deal(address(drain), 1_000e18);
        usd.approve(address(drain), type(uint256).max);
        szr.approve(address(drain), type(uint256).max);
        backing.approve(address(drain), type(uint256).max);
    }

    /// A hooked ETH/USD pool holding 1 ETH, against a WETH/USD venue.
    function _world() internal returns (PoolKey memory hooked, PoolKey memory venue) {
        hooked = _pair(address(0), address(usd), 3_000, address(hook));
        vm.prank(team);
        hook.createPool(id, hooked, uint160(1 << 96));
        provider.modifyLiquidity(
            hooked,
            IPoolManager.ModifyLiquidityParams(-60_000, -60, int256(1_000_000e18), 0),
            ""
        );
        provider.modifyLiquidity{ value: 2e18 }(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(1e18), 0
            ),
            ""
        );
        venue = _make(address(backing), address(usd), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(0), _list(_id(hooked)));
        _lead(address(usd), address(backing), _list(_id(venue)));
        _limits(address(usd), 1e15);
    }

    function _undoneByDrain() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageLogic.SearchUndone.selector) continue;
            if (abi.decode(logs[index].data, (bytes4)) == V4Read.Drained.selector) {
                count++;
            }
        }
    }

    function _assertNoBench(PoolKey memory hooked, PoolKey memory venue) internal view {
        bytes32 own = _id(hooked);
        bytes32 other = _id(venue);
        assertEq(hook.benchedUntil(id, address(usd), own, other, true), 0, "bench buy");
        assertEq(hook.benchedUntil(id, address(usd), own, other, false), 0, "bench sell");
    }

    // ----- the false positive: an honest swap whose input is not yet paid -----

    /// After a plain swapper has sold `amount` ETH the pool manager does not hold it yet
    /// when the hook searches, so the cycle is short of ETH. The swap fills anyway.
    function _sale(uint256 amount) internal {
        (PoolKey memory hooked, PoolKey memory venue) = _world();
        assertEq(address(manager).balance, 1e18, "the pool manager holds 1 ETH");
        vm.recordLogs();
        _in(hooked, address(0), amount);
        assertGt(_undoneByDrain(), 0, "the search after the swap is undone");
        _assertNoBench(hooked, venue);
        _assertHookEmpty();
        // The gap waits for the next swap, which closes it.
        vm.recordLogs();
        _in(hooked, address(usd), 1e15);
        (uint256 bought, uint256 sold,,) = _tally();
        assertGt(bought + sold, 0, "the next swap closes the gap");
    }

    function testSaleOfOnePointTwoEthFills() public {
        _sale(1.2e18);
    }

    function testSaleOfFiveEthFills() public {
        _sale(5e18);
    }

    function testSaleOfTenThousandEthFills() public {
        _sale(10_000e18);
    }

    // ----- a drain that only bites the search after the swap -----

    /// The swap itself opens the gap, so the search before it finds none. The router has
    /// borrowed all the SZR, so retiring the profit after the swap is short: the swap fills.
    function testAfterSwapSzrDrainedSwapFillsAndSearchIsUndone() public {
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        drain.trade(usdPool, address(usd), 50_000e18, address(szr), 0);
        assertEq(_undoneByDrain(), 1, "only the search after the swap is undone");
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        assertEq(hook.benchedUntil(1, address(szr), _id(usdPool), bytes32(0), true), 0, "bench");
        assertEq(_failures(), 0, "no cycle counted as failed");
        _assertHookEmpty();
        // The next swap closes the gap that waited.
        _trade(usdPool, address(usd), 1e18);
        assertGt(core.unreleasedSupply(), inventory, "retired by the next swap");
    }

    /// The same swap without the drain, as the control.
    function testAfterSwapSzrControlRetiresInTheSameSwap() public {
        uint256 inventory = core.unreleasedSupply();
        vm.recordLogs();
        drain.trade(usdPool, address(usd), 50_000e18, address(szr), type(uint256).max);
        assertEq(_undoneByDrain(), 0, "nothing undone");
        assertGt(core.unreleasedSupply(), inventory, "retired");
    }

    // ----- a drain meeting an open gap with a search not capped by the hook -----

    /// With little gas the search is bounded by the swap's gas, not the hook's allowance. A
    /// drain still fails the swap with `Drained`, not `InsufficientGas`.
    function testGasBoundedSearchBeforeTheSwapStillFailsDrained() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        (bool ok, bytes memory data) = address(drain).call{ gas: 7_000_000 }(
            abi.encodeCall(drain.trade, (usdPool, address(usd), 1e18, address(szr), 0))
        );
        assertFalse(ok, "the swap fails");
        assertEq(_has(data, V4Read.Drained.selector), true, "with Drained");
        assertEq(_has(data, ArbitrageLogic.InsufficientGas.selector), false, "not gas");
    }

    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
        return false;
    }

    // ----- Core's redemption -----

    /// The amount to redeem is read from Core after the plan was made. If it is not less
    /// than the SZR the cycle bought, the try fails before the hook takes any SZR.
    function testUnprofitableCoreTryFailsBeforeTheTake() public {
        PoolKey memory pool = _addHooked(address(backing), 500);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(40_000_000e18);
        vm.mockCall(
            address(core), abi.encodeWithSignature("backingAmount()"), abi.encode(uint256(1))
        );
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(
                IPoolManager.take.selector, Currency.wrap(address(szr)), address(hook)
            ),
            0
        );
        vm.recordLogs();
        _trade(pool, address(backing), 1e18);
        assertGt(_failures(), 0, "the try failed");
        _assertHookEmpty();
    }

    // ----- a balance read that fails -----

    function _unwrapGap() internal returns (PoolKey memory hooked) {
        PoolKey memory venue;
        (hooked, venue) = _usdEtherAndWeth();
        _in(venue, address(backing), 50_000e18);
    }

    /// A WETH whose `balanceOf` fails reads as a failed try, not as a drained pool manager.
    function testRevertingBalanceReadIsNotADrain() public {
        PoolKey memory hooked = _unwrapGap();
        vm.mockCallRevert(
            address(backing), abi.encodeCall(backing.balanceOf, (address(manager))), ""
        );
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        assertGt(_failures(), 0, "the try failed");
    }

    function testShortBalanceReturnIsNotADrain() public {
        PoolKey memory hooked = _unwrapGap();
        vm.mockCall(address(backing), abi.encodeCall(backing.balanceOf, (address(manager))), "");
        vm.recordLogs();
        _in(hooked, address(usd), 1e18);
        assertGt(_failures(), 0, "the try failed");
    }
}
