// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IndexLiquidityExtension } from "../src/extensions/IndexLiquidityExtension.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { MetricSwapping } from "../src/extensions/MetricSwapping.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Vm } from "forge-std/Vm.sol";
import { ExtensionWorld } from "./V4LiquidityExtension.t.sol";

/// @dev The index extension next to the v4 extension's world: the real Core, Liquidity,
/// pool manager and arbitrage hook, an index pool of two test tokens, and an INDEX/SZR v4
/// pool. This contract is Liquidity's manager.
contract IndexLiquidityExtensionTest is ExtensionWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint128 internal constant UNITS = 100e18;
    uint256 internal constant FAR = type(uint256).max;

    IndexPoolFactory internal indexFactory;
    IndexPositions internal positions;
    IndexLiquidityExtension internal iext;
    IndexPool internal index;
    PoolKey internal key;
    int24 internal lower = TickMath.minUsableTick(60);
    int24 internal upper = TickMath.maxUsableTick(60);

    function setUp() public override {
        super.setUp();
        // Deployed from artifacts so this test contract does not carry their creation code.
        indexFactory = IndexPoolFactory(
            deployCode(
                "IndexPoolFactory.sol:IndexPoolFactory", abi.encode(locker, makeAddr("cut"))
            )
        );
        positions = IndexPositions(
            payable(deployCode(
                    "IndexPositions.sol:IndexPositions", abi.encode(manager, indexFactory)
                ))
        );
        iext = IndexLiquidityExtension(
            payable(deployCode(
                    "IndexLiquidityExtension.sol:IndexLiquidityExtension",
                    abi.encode(locker, address(hook), metricFactory, positions, indexFactory)
                ))
        );
        index = _index();
        index.transfer(address(iext), 1e22);
        szr.transfer(address(iext), 1_000e18);
        coin.mint(address(iext), HELD);
        usd.mint(address(iext), HELD);
        key = _pair(address(index), address(szr), 3_000, address(0));
        manager.initialize(key, uint160(1 << 96));
        index.approve(address(provider), FAR);
        index.approve(address(swapper), FAR);
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, int256(1_000e18), 0), ""
        );
    }

    function _index() internal returns (IndexPool pool) {
        address[] memory list = new address[](2);
        bool coinFirst = address(coin) < address(usd);
        list[0] = coinFirst ? address(coin) : address(usd);
        list[1] = coinFirst ? address(usd) : address(coin);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5e17;
        weights[1] = 5e17;
        pool =
            IndexPool(indexFactory.create("Index", "IDX", list, weights, 3e15, address(0), 0));
        coin.approve(address(pool), FAR);
        usd.approve(address(pool), FAR);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e24;
        amounts[1] = 1e24;
        pool.start(amounts, 1e24, FAR);
    }

    /// Fee-paying swaps through the index pool, which raise its growth index.
    function _grow() internal {
        for (uint256 round; round < 20; round++) {
            (, uint256 got) =
                index.swap(address(coin), address(usd), 5e22, true, 0, address(this), FAR);
            index.swap(address(usd), address(coin), got, true, 0, address(this), FAR);
        }
    }

    function _open() internal returns (uint256 id) {
        id = iext.openIndexPosition(key, lower, upper, UNITS, FAR, FAR, FAR);
    }

    function _assertCleared() internal view {
        assertEq(index.allowance(address(iext), address(positions)), 0, "share allowance");
        assertEq(szr.allowance(address(iext), address(positions)), 0, "SZR allowance");
        assertEq(coin.allowance(address(iext), address(index)), 0, "coin allowance");
        assertEq(usd.allowance(address(iext), address(index)), 0, "usd allowance");
    }

    function testEveryNewFunctionRefusesNonManagers() public {
        uint256 id = _open();
        address stranger = makeAddr("stranger");
        uint256[] memory two = new uint256[](2);
        vm.startPrank(stranger);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.openIndexPosition(key, lower, upper, UNITS, FAR, FAR, FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.increaseIndexPosition(id, UNITS, FAR, FAR, FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.decreaseIndexPosition(id, UNITS, 0, 0, FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.collectIndexPosition(id);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.harvestIndexPosition(id, 0, 0, FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.joinIndex(address(index), 1e18, two, FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.exitIndex(address(index), 1e18, two, new address[](0), FAR);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        iext.claimIndex(address(index), address(coin));
        vm.stopPrank();
    }

    function testApprovalsAreExactAndCleared() public {
        uint256 share = index.balanceOf(address(iext));
        uint256 held = szr.balanceOf(address(iext));
        vm.recordLogs();
        uint256 id = _open();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertCleared();
        // What was approved is exactly what was taken.
        assertEq(_approved(logs, address(index)), share - index.balanceOf(address(iext)));
        assertEq(_approved(logs, address(szr)), held - szr.balanceOf(address(iext)));
        assertApproxEqAbs(held - szr.balanceOf(address(iext)), UNITS, 10);
        _trade(key, address(index), 1e18);
        iext.increaseIndexPosition(id, UNITS, FAR, FAR, FAR);
        _assertCleared();
        uint256[] memory maxIn = new uint256[](2);
        maxIn[0] = FAR;
        maxIn[1] = FAR;
        iext.joinIndex(address(index), 1e21, maxIn, FAR);
        _assertCleared();
        (address owner,,,, uint128 liquidity,,) = positions.position(id);
        assertEq(owner, address(iext));
        assertEq(liquidity, 2 * UNITS);
    }

    /// The first non-zero approval of `token` from the extension to `IndexPositions`.
    function _approved(Vm.Log[] memory logs, address token) internal view returns (uint256) {
        bytes32 topic = keccak256("Approval(address,address,uint256)");
        for (uint256 index_; index_ < logs.length; index_++) {
            Vm.Log memory entry = logs[index_];
            if (entry.emitter != token) continue;
            if (entry.topics[0] != topic) continue;
            if (entry.topics[2] != bytes32(uint256(uint160(address(positions))))) continue;
            uint256 amount = abi.decode(entry.data, (uint256));
            if (amount != 0) return amount;
        }
        return 0;
    }

    function testBoundsAreForwarded() public {
        vm.expectRevert(IndexPositions.AboveMaximum.selector);
        iext.openIndexPosition(key, lower, upper, UNITS, 1, FAR, FAR);
        _assertCleared();
    }

    function testRefusesPoolsOutsideTheFactory() public {
        address stranger = address(coin);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(IndexLiquidityExtension.UnknownIndexPool.selector);
        iext.joinIndex(stranger, 1e18, two, FAR);
        vm.expectRevert(IndexLiquidityExtension.UnknownIndexPool.selector);
        iext.exitIndex(stranger, 1e18, two, new address[](0), FAR);
        vm.expectRevert(IndexLiquidityExtension.UnknownIndexPool.selector);
        iext.claimIndex(stranger, address(coin));
    }

    function testDeferredExitIsClaimedLater() public {
        address[] memory deferring = new address[](1);
        deferring[0] = address(coin);
        uint256 coins = coin.balanceOf(address(iext));
        uint256 usds = usd.balanceOf(address(iext));
        iext.exitIndex(address(index), 1e21, new uint256[](2), deferring, FAR);
        uint256 owed = index.deferred(address(iext), address(coin));
        assertGt(owed, 0);
        assertEq(coin.balanceOf(address(iext)), coins, "deferred, not sent");
        assertGt(usd.balanceOf(address(iext)), usds, "the rest was sent");
        assertEq(iext.claimIndex(address(index), address(coin)), owed);
        assertEq(coin.balanceOf(address(iext)), coins + owed);
        assertEq(index.deferred(address(iext), address(coin)), 0);
    }

    function testHarvestPaysTheExtension() public {
        uint256 id = _open();
        _grow();
        uint256 share = index.balanceOf(address(iext));
        uint256 held = szr.balanceOf(address(iext));
        uint128 removed = iext.harvestIndexPosition(id, 0, 0, FAR);
        assertGt(removed, 0);
        assertGt(index.balanceOf(address(iext)), share, "shares arrived");
        assertGt(szr.balanceOf(address(iext)), held, "SZR arrived");
        assertEq(index.balanceOf(address(positions)), 0);
        assertEq(szr.balanceOf(address(positions)), 0);
        (uint256 got0, uint256 got1) = iext.collectIndexPosition(id);
        assertEq(got0 + got1, 0, "the harvest already took the fees");
        iext.decreaseIndexPosition(id, UNITS - removed, 0, 0, FAR);
        (,,,, uint128 left,,) = positions.position(id);
        assertEq(left, 0);
    }

    /// The protocol's loop: harvest INDEX/SZR, sell the shares for SZR through a
    /// registered route, and retire it through Core.
    function testHarvestSellAndRetire() public {
        uint256 id = _open();
        _grow();
        uint256 share = index.balanceOf(address(iext));
        uint256 held = szr.balanceOf(address(iext));
        iext.harvestIndexPosition(id, 0, 0, FAR);
        uint256 shares = index.balanceOf(address(iext)) - share;
        iext.registerRoute(key);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(index);
        (uint256 spent, uint256 bought) =
            iext.swap(key, zeroForOne, shares, 1, zeroForOne ? FLOOR : CEILING, FAR);
        assertEq(spent, shares);
        uint256 harvested = szr.balanceOf(address(iext)) - held;
        assertGt(harvested, bought);
        uint256 active = core.activeSupply();
        iext.toCore(address(szr), harvested);
        assertEq(active - core.activeSupply(), harvested, "retired");
        assertEq(szr.balanceOf(address(iext)), held);
    }

    /// An ETH-paired position: open forwards exactly the ETH it costs, an increase gets its
    /// earned ETH fees back as a refund, and every ETH payment lands here.
    function testEtherPairedPosition() public {
        PoolKey memory native = _pair(address(0), address(index), 3_000, address(0));
        manager.initialize(native, uint160(1 << 96));
        provider.modifyLiquidity{ value: 2_000e18 }(
            native, IPoolManager.ModifyLiquidityParams(lower, upper, int256(1_000e18), 0), ""
        );
        vm.deal(address(iext), 1_000e18);
        uint256 before = address(iext).balance;
        uint256 id = iext.openIndexPosition(native, lower, upper, UNITS, FAR, FAR, FAR);
        uint256 cost = before - address(iext).balance;
        assertApproxEqAbs(cost, UNITS, 10, "the ETH cost, forwarded exactly");
        _assertNoEther();
        _tradeEther(native, 10e18);
        uint256 earned = _earnedEther(id);
        assertGt(earned, 0);
        before = address(iext).balance;
        iext.increaseIndexPosition(id, UNITS, FAR, FAR, FAR);
        assertEq(
            before - address(iext).balance,
            _etherAmount(native, UNITS, true) - earned,
            "fees refunded"
        );
        _assertNoEther();
        _assertCleared();
        _grow();
        _assertHarvestPaysEther(id);
        _tradeEther(native, 10e18);
        before = address(iext).balance;
        (uint256 fees0,) = iext.collectIndexPosition(id);
        assertGt(fees0, 0);
        assertEq(address(iext).balance - before, fees0, "collected ETH here");
        _assertNoEther();
        (,,,, uint128 liquidity,,) = positions.position(id);
        uint256 out = _etherAmount(native, liquidity, false);
        before = address(iext).balance;
        iext.decreaseIndexPosition(id, liquidity, 0, 0, FAR);
        assertEq(address(iext).balance - before, out, "withdrawn ETH here");
        _assertNoEther();
    }

    /// The ETH fees a collect would pay now, without collecting them.
    function _earnedEther(uint256 id) internal returns (uint256 fees0) {
        uint256 snapshot = vm.snapshotState();
        (fees0,) = iext.collectIndexPosition(id);
        vm.revertToState(snapshot);
    }

    /// The ETH in `units` of full-range liquidity at the pool's price.
    function _etherAmount(PoolKey memory native, uint128 units, bool roundUp)
        internal
        view
        returns (uint256)
    {
        (uint160 price,,,) = manager.getSlot0(native.toId());
        uint160 top = TickMath.getSqrtPriceAtTick(upper);
        return SqrtPriceMath.getAmount0Delta(price, top, units, roundUp);
    }

    function _assertHarvestPaysEther(uint256 id) internal {
        uint256 before = address(iext).balance;
        assertGt(iext.harvestIndexPosition(id, 0, 0, FAR), 0);
        assertGt(address(iext).balance, before, "harvested ETH here");
        _assertNoEther();
    }

    function _assertNoEther() internal view {
        assertEq(address(positions).balance, 0, "IndexPositions kept ETH");
    }

    function _tradeEther(PoolKey memory native, uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap{ value: amount }(
            native, IPoolManager.SwapParams(true, -int256(amount), FLOOR), settings, ""
        );
    }

    function testEtherOnlyFromItsSources() public {
        vm.expectRevert(LiquidityExtension.UnexpectedEther.selector);
        (bool ok,) = address(iext).call{ value: 1 }("");
        ok;
        vm.deal(address(positions), 1);
        vm.prank(address(positions));
        (ok,) = address(iext).call{ value: 1 }("");
        assertTrue(ok);
    }

    function testRefusesAForeignHook() public {
        // Swap permissions only, as the arbitrage hook has, so `IndexPositions` itself would
        // take the pool; only the extension's own rule refuses it.
        address other = address(uint160(0xF0 << 152 | 1 << 7 | 1 << 6));
        PoolKey memory foreign = _pair(address(index), address(szr), 3_000, other);
        manager.initialize(foreign, uint160(1 << 96));
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
        iext.openIndexPosition(foreign, lower, upper, UNITS, FAR, FAR, FAR);
    }

    /// A position handed over with `transferOwner` on a foreign hook's pool is never
    /// funded by the extension.
    function testIncreaseRefusesAGivenPositionOnAForeignHook() public {
        address other = address(uint160(0xF0 << 152 | 1 << 7 | 1 << 6));
        PoolKey memory foreign = _pair(address(index), address(szr), 3_000, other);
        manager.initialize(foreign, uint160(1 << 96));
        address stranger = makeAddr("stranger");
        index.transfer(stranger, 1e21);
        szr.transfer(stranger, 1e21);
        vm.startPrank(stranger);
        index.approve(address(positions), FAR);
        szr.approve(address(positions), FAR);
        uint256 id = positions.open(foreign, lower, upper, UNITS, FAR, FAR, FAR);
        positions.transferOwner(id, address(iext));
        vm.stopPrank();
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
        iext.increaseIndexPosition(id, UNITS, FAR, FAR, FAR);
    }

    function testAcceptsThePoolsOfItsOwnHook() public {
        PoolKey memory hooked = _pair(address(index), address(szr), 3_000, address(hook));
        manager.initialize(hooked, uint160(1 << 96));
        uint256 id = iext.openIndexPosition(hooked, lower, upper, UNITS, FAR, FAR, FAR);
        (address owner,,,, uint128 liquidity,,) = positions.position(id);
        assertEq(owner, address(iext));
        assertEq(liquidity, UNITS);
        _assertCleared();
    }

    function testConstructorChecksPositions() public {
        address other =
            deployCode("IndexPositions.sol:IndexPositions", abi.encode(manager, address(this)));
        vm.expectRevert(IndexLiquidityExtension.InvalidPositions.selector);
        deployCode(
            "IndexLiquidityExtension.sol:IndexLiquidityExtension",
            abi.encode(locker, address(hook), metricFactory, other, indexFactory)
        );
    }

    function testHasNoTransferOwner() public view {
        bytes memory code = address(iext).code;
        bytes4 selector = IndexPositions.transferOwner.selector;
        for (uint256 at; at + 4 <= code.length; at++) {
            bytes4 word =
                bytes4(bytes.concat(code[at], code[at + 1], code[at + 2], code[at + 3]));
            assertTrue(word != selector, "transferOwner is reachable");
        }
    }
}
