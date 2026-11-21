// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
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
    uint256 internal constant HELD = 1_000_000e18;
    uint160 internal constant FLOOR = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant CEILING = TickMath.MAX_SQRT_PRICE - 1;

    receive() external payable { }

    function setUp() public virtual override {
        super.setUp();
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(this), 1e30);
        ext = new V4LiquidityExtension(locker, address(hook));
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
        new V4LiquidityExtension(locker, address(other));
    }

    function testRefusesSzrForeignHooksUnregisteredAndBadTicks() public {
        // An SZR pair belongs to Liquidity.
        PoolKey memory mainKey = locker.key(0);
        _route(mainKey);
        vm.expectRevert(V4LiquidityExtension.InvalidPool.selector);
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
        vm.expectRevert(V4LiquidityExtension.InvalidPool.selector);
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
