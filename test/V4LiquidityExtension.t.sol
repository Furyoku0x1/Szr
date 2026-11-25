// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricFactory } from "./utils/metric/MockMetricPool.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { MetricSwapping } from "../src/extensions/MetricSwapping.sol";
import { Vm } from "forge-std/Vm.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Stands in for the hook where only its `liquidity()` is read.
contract HookStub {
    address public liquidity;

    constructor(address liquidity_) {
        liquidity = liquidity_;
    }
}

/// @dev The real Core, Liquidity, pool manager and arbitrage hook with a v4 extension next
/// to them. This contract is Liquidity's manager, as in every world. The world's WETH is
/// given the real token's `deposit` and `withdraw`.
abstract contract ExtensionWorld is MarketsWorld {
    V4LiquidityExtension internal ext;
    MockMetricFactory internal metricFactory;
    uint256 internal constant HELD = 1_000_000e18;
    uint160 internal constant FLOOR = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant CEILING = TickMath.MAX_SQRT_PRICE - 1;

    receive() external payable { }

    function setUp() public virtual override {
        super.setUp();
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(this), 1e30);
        metricFactory = new MockMetricFactory();
        // Deployed from artifacts, as the Metric world's extension is, so that test contracts
        // built on this world don't embed its creation code.
        ext = V4LiquidityExtension(
            payable(deployCode(
                    "V4LiquidityExtension.sol:V4LiquidityExtension",
                    abi.encode(locker, address(hook), address(metricFactory))
                ))
        );
        backing.mint(address(ext), HELD);
        coin.mint(address(ext), HELD);
        usd.mint(address(ext), HELD);
        // The extension holds SZR as well, as it would after buying some.
        szr.transfer(address(ext), 1_000e18);
    }

    function _route(PoolKey memory pool) internal {
        ext.registerRoute(pool);
    }

    /// An exact-input swap by the extension with no price limit.
    function _extSwap(PoolKey memory pool, address input, uint256 amount, uint256 minimum)
        internal
        returns (uint256 received)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        (, received) = ext.swap(
            pool, zeroForOne, amount, minimum, zeroForOne ? FLOOR : CEILING, block.timestamp
        );
    }

    /// A hookless pool at price one, with deep liquidity from the test contract.
    function _openPool(address one, address other, uint24 fee)
        internal
        returns (PoolKey memory pool)
    {
        pool = _pair(one, other, fee, address(0));
        manager.initialize(pool, uint160(1 << 96));
        uint256 value = Currency.unwrap(pool.currency0) == address(0) ? 2_000_000e18 : 0;
        provider.modifyLiquidity{ value: value }(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(HELD), 0
            ),
            ""
        );
    }

    function _balances(PoolKey memory pool) internal view returns (uint256 zero, uint256 one) {
        zero = _of(Currency.unwrap(pool.currency0));
        one = _of(Currency.unwrap(pool.currency1));
    }

    function _of(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(ext).balance;
        return TestAsset(asset).balanceOf(address(ext));
    }
}

/// @dev Positions in pools without SZR: hookless, on the arbitrage hook and in native ETH.
contract V4LiquidityExtensionTest is ExtensionWorld {
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    uint128 internal constant UNITS = 10_000e18;

    function _position(PoolKey memory pool) internal returns (uint256 pid) {
        _route(pool);
        pid = ext.addPosition(pool, LOWER, UPPER);
    }

    /// Deploy, earn fees from a swap by someone else, collect, withdraw: tokens only ever
    /// move between the extension and the pool manager.
    function _cycle(PoolKey memory pool, address input) internal {
        uint256 pid = _position(pool);
        (uint256 before0, uint256 before1) = _balances(pool);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        (uint256 deployed0, uint256 deployed1) = _balances(pool);
        assertLt(deployed0, before0, "token0 deployed");
        assertLt(deployed1, before1, "token1 deployed");
        _tradeBy(pool, input, 20_000e18);
        (uint256 beforeCollect0, uint256 beforeCollect1) = _balances(pool);
        ext.collect(pid);
        (uint256 afterCollect0, uint256 afterCollect1) = _balances(pool);
        assertGe(afterCollect0, beforeCollect0, "fees landed here");
        assertGe(afterCollect1, beforeCollect1, "fees landed here");
        assertGt(afterCollect0 + afterCollect1, beforeCollect0 + beforeCollect1, "some fee");
        ext.withdraw(pid, UNITS, 0, 0, block.timestamp);
        (uint256 end0, uint256 end1) = _balances(pool);
        assertGt(end0, afterCollect0, "token0 came back");
        assertGt(end1, afterCollect1, "token1 came back");
    }

    function _tradeBy(PoolKey memory pool, address input, uint256 amount) internal {
        uint256 value = input == address(0) ? amount : 0;
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        swapper.swap{ value: value }(
            pool,
            IPoolManager.SwapParams(zeroForOne, -int256(amount), zeroForOne ? FLOOR : CEILING),
            _settings(),
            ""
        );
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory settings) { }

    function testHooklessPositionLifecycle() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        _cycle(pool, address(coin));
    }

    function testArbitrageHookPositionLifecycle() public {
        // `second` is a hooked pool of the world's market.
        _cycle(second, address(coin));
    }

    /// A pool of ETH: the extension pays by `settle{value}`, takes ETH back, and its own
    /// ETH balance moves with the position.
    function testNativeEthPosition() public {
        PoolKey memory pool = _openPool(address(0), address(coin), 3_000);
        assertEq(Currency.unwrap(pool.currency0), address(0), "ETH first");
        vm.deal(address(ext), 10_000e18);
        _route(pool);
        uint256 coinBefore = coin.balanceOf(address(ext));
        uint256 got = _extSwap(pool, address(0), 1_000e18, 1);
        assertEq(address(ext).balance, 9_000e18, "ETH paid by settle");
        assertEq(coin.balanceOf(address(ext)), coinBefore + got, "coin received");
        // Swapping back takes ETH.
        uint256 ethBack = _extSwap(pool, address(coin), got / 2, 1);
        assertGt(ethBack, 0);
        assertEq(address(ext).balance, 9_000e18 + ethBack, "ETH taken");
        _cycle(pool, address(0));
    }

    function testBoundsAndDeadlineAreEnforced() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        uint256 pid = _position(pool);
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        ext.deploy(pid, UNITS, 1, 1, block.timestamp);
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp - 1);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        ext.withdraw(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        vm.expectRevert(LiquidityExtension.DeadlinePassed.selector);
        ext.withdraw(pid, UNITS, 0, 0, block.timestamp - 1);
        vm.expectRevert(V4LiquidityExtension.UnknownPosition.selector);
        ext.collect(7);
        vm.expectRevert(V4LiquidityExtension.ZeroLiquidity.selector);
        ext.deploy(pid, 0, 1, 1, block.timestamp);
    }

    /// Fees owed to the position offset what a deploy costs, and the bounds see only the
    /// principal: the same bound that fits the principal passes however large the fees are.
    function testBoundsExcludeFees() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        uint256 pid = _position(pool);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        _tradeBy(pool, address(coin), 200_000e18);
        _tradeBy(pool, address(backing), 200_000e18);
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        (uint256 cost0, uint256 cost1) = _deployed();
        (uint256 end0, uint256 end1) = _balances(pool);
        vm.revertToState(snapshot);
        (uint256 start0, uint256 start1) = _balances(pool);
        assertLt(start0 - end0 + start1 - end1, cost0 + cost1, "fees offset the cost");
        vm.expectRevert(LiquidityExtension.AboveMaximum.selector);
        ext.deploy(pid, UNITS, cost0 - 1, cost1, block.timestamp);
        ext.deploy(pid, UNITS, cost0, cost1, block.timestamp);
        // A withdrawal's minimum is the principal returned, not the fees paid out with it.
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        ext.withdraw(pid, UNITS, type(uint256).max, 0, block.timestamp);
    }

    /// A funded position with fees accrued on both sides by outside trades. The trades
    /// differ in size so the two sides' fees differ and a swapped pair shows.
    function _earned(PoolKey memory pool) internal returns (uint256 pid) {
        vm.deal(address(ext), 10_000e18);
        pid = _position(pool);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        _tradeBy(pool, Currency.unwrap(pool.currency0), 20_000e18);
        _tradeBy(pool, Currency.unwrap(pool.currency1), 5_000e18);
    }

    /// What a plain `collect` pays from this exact state, found on a snapshot that is
    /// reverted, so a deploy or withdraw from the same state can be held to it.
    function _learnFees(uint256 pid, PoolKey memory pool)
        internal
        returns (uint256 fees0, uint256 fees1)
    {
        uint256 snapshot = vm.snapshotState();
        (uint256 before0, uint256 before1) = _balances(pool);
        ext.collect(pid);
        (uint256 after0, uint256 after1) = _balances(pool);
        fees0 = after0 - before0;
        fees1 = after1 - before1;
        vm.revertToState(snapshot);
    }

    /// Sums the `Collected` fees and counts them, then reads the principal that `Deployed`
    /// or `Withdrawn` reported.
    function _reported(bytes32 principalEvent)
        internal
        returns (uint256 fees0, uint256 fees1, uint256 count, uint256 p0, uint256 p1)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == V4LiquidityExtension.Collected.selector) {
                (uint256 one, uint256 two) = abi.decode(logs[index].data, (uint256, uint256));
                fees0 += one;
                fees1 += two;
                count++;
            }
            if (topic == principalEvent) {
                (p0, p1) = abi.decode(logs[index].data, (uint256, uint256));
            }
        }
    }

    function _collectReports(PoolKey memory pool) internal {
        uint256 pid = _earned(pool);
        (uint256 before0, uint256 before1) = _balances(pool);
        vm.recordLogs();
        ext.collect(pid);
        (uint256 fees0, uint256 fees1, uint256 count,,) = _reported(bytes32(0));
        (uint256 after0, uint256 after1) = _balances(pool);
        assertEq(count, 1, "one Collected");
        assertGt(fees0, 0, "fees0");
        assertGt(fees1, 0, "fees1");
        assertTrue(fees0 != fees1, "sides differ");
        assertEq(after0 - before0, fees0, "fees0 are the balance change");
        assertEq(after1 - before1, fees1, "fees1 are the balance change");
    }

    function _deployReports(PoolKey memory pool) internal {
        uint256 pid = _earned(pool);
        (uint256 owed0, uint256 owed1) = _learnFees(pid, pool);
        (uint256 before0, uint256 before1) = _balances(pool);
        vm.recordLogs();
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        (uint256 fees0, uint256 fees1, uint256 count, uint256 cost0, uint256 cost1) =
            _reported(V4LiquidityExtension.Deployed.selector);
        (uint256 after0, uint256 after1) = _balances(pool);
        assertEq(count, 1, "one Collected");
        assertGt(fees0, 0, "fees0");
        assertGt(fees1, 0, "fees1");
        assertEq(fees0, owed0, "fees0 match a plain collect");
        assertEq(fees1, owed1, "fees1 match a plain collect");
        assertEq(before0 + fees0 - cost0, after0, "token0: fees less principal");
        assertEq(before1 + fees1 - cost1, after1, "token1: fees less principal");
    }

    function _withdrawReports(PoolKey memory pool) internal {
        uint256 pid = _earned(pool);
        (uint256 owed0, uint256 owed1) = _learnFees(pid, pool);
        (uint256 before0, uint256 before1) = _balances(pool);
        vm.recordLogs();
        ext.withdraw(pid, UNITS, 0, 0, block.timestamp);
        (uint256 fees0, uint256 fees1, uint256 count, uint256 got0, uint256 got1) =
            _reported(V4LiquidityExtension.Withdrawn.selector);
        (uint256 after0, uint256 after1) = _balances(pool);
        assertEq(count, 1, "one Collected");
        assertGt(fees0, 0, "fees0");
        assertGt(fees1, 0, "fees1");
        assertEq(fees0, owed0, "fees0 match a plain collect");
        assertEq(fees1, owed1, "fees1 match a plain collect");
        assertEq(before0 + fees0 + got0, after0, "token0: fees plus principal");
        assertEq(before1 + fees1 + got1, after1, "token1: fees plus principal");
    }

    function testCollectReportsTheFeesItPulledIn() public {
        _collectReports(_openPool(address(backing), address(coin), 3_000));
    }

    function testDeployReportsFeesApartFromPrincipal() public {
        _deployReports(_openPool(address(backing), address(coin), 3_000));
    }

    function testWithdrawReportsFeesApartFromPrincipal() public {
        _withdrawReports(_openPool(address(backing), address(coin), 3_000));
    }

    function testNativeEthPoolReportsFeesInEveryAction() public {
        uint256 snapshot = vm.snapshotState();
        _collectReports(_openPool(address(0), address(coin), 3_000));
        vm.revertToState(snapshot);
        _deployReports(_openPool(address(0), address(coin), 3_000));
        vm.revertToState(snapshot);
        _withdrawReports(_openPool(address(0), address(coin), 3_000));
    }

    /// Fees in one currency only take the branch where the first amount is zero.
    function _oneSided(bool inputIsCurrency1) internal {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        uint256 pid = _position(pool);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        address input = Currency.unwrap(inputIsCurrency1 ? pool.currency1 : pool.currency0);
        _tradeBy(pool, input, 20_000e18);
        (uint256 before0, uint256 before1) = _balances(pool);
        vm.recordLogs();
        ext.collect(pid);
        (uint256 fees0, uint256 fees1, uint256 count,,) = _reported(bytes32(0));
        (uint256 after0, uint256 after1) = _balances(pool);
        assertEq(count, 1, "one Collected");
        assertEq(fees0, inputIsCurrency1 ? 0 : after0 - before0, "fees0");
        assertEq(fees1, inputIsCurrency1 ? after1 - before1 : 0, "fees1");
        assertGt(fees0 + fees1, 0, "some fee");
    }

    function testCollectReportsFeesInCurrency1Only() public {
        _oneSided(true);
    }

    function testCollectReportsFeesInCurrency0Only() public {
        _oneSided(false);
    }

    function testCollectWithNothingAccruedEmitsNoCollected() public {
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        uint256 pid = _position(pool);
        ext.deploy(pid, UNITS, type(uint256).max, type(uint256).max, block.timestamp);
        vm.recordLogs();
        ext.collect(pid);
        (,, uint256 count,,) = _reported(bytes32(0));
        assertEq(count, 0, "no Collected");
    }

    function _deployed() internal returns (uint256 amount0, uint256 amount1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != V4LiquidityExtension.Deployed.selector) continue;
            (amount0, amount1) = abi.decode(logs[index].data, (uint256, uint256));
        }
    }

    function testConstructorRefusesAHookOfAnotherLiquidity() public {
        HookStub other = new HookStub(address(coin));
        vm.expectRevert(LiquidityExtension.InvalidHook.selector);
        new V4LiquidityExtension(locker, address(other), IMetricFactory(address(metricFactory)));
    }

    function testRefusesSzrForeignHooksUnregisteredAndBadTicks() public {
        // An SZR pair belongs to Liquidity.
        PoolKey memory mainKey = locker.key(0);
        _route(mainKey);
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
        ext.addPosition(mainKey, LOWER, UPPER);
        // A pool on a hook that is not the arbitrage hook.
        address foreign = address(uint160(0xBEEF << 24 | 1 << 7));
        PoolKey memory odd = PoolKey(
            Currency.wrap(address(backing) < address(coin) ? address(backing) : address(coin)),
            Currency.wrap(address(backing) < address(coin) ? address(coin) : address(backing)),
            3_000,
            60,
            IHooks(foreign)
        );
        manager.initialize(odd, uint160(1 << 96));
        _route(odd);
        vm.expectRevert(MetricSwapping.InvalidPool.selector);
        ext.addPosition(odd, LOWER, UPPER);
        // A pool that was never registered.
        PoolKey memory open = _pair(address(backing), address(coin), 100, address(0));
        manager.initialize(open, uint160(1 << 96));
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        ext.addPosition(open, LOWER, UPPER);
        _route(open);
        vm.expectRevert(V4LiquidityExtension.InvalidRange.selector);
        ext.addPosition(open, UPPER, LOWER);
        vm.expectRevert(V4LiquidityExtension.InvalidRange.selector);
        ext.addPosition(open, LOWER + 1, UPPER);
        vm.expectRevert(V4LiquidityExtension.InvalidRange.selector);
        ext.addPosition(open, TickMath.minUsableTick(60) - 60, UPPER);
        // Registering a pool that does not exist is refused too.
        PoolKey memory ghost = _pair(address(backing), address(coin), 4_321, address(0));
        vm.expectRevert(LiquidityExtension.UnknownPool.selector);
        ext.registerRoute(ghost);
    }
}
