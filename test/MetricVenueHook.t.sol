// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricFactory, MockMetricPool } from "./utils/metric/MockMetricPool.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

/// @dev Both orientations run the same tests. The mock is built so the raw rate is the same
/// in each: 1e18 of the lower token is worth 2.048e9 of the higher one.
abstract contract MetricVenueHookBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal FACTORY;
    MockMetricFactory internal factoryMock;
    address internal constant OWNER = address(0x0123);
    uint256 internal constant IN = 1e18;
    uint256 internal constant OUT = 2_048_000_000;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    MetricVenueHook internal hook;
    MockMetricPool internal metric;
    TestAsset internal low;
    TestAsset internal high;
    PoolKey internal key;

    function flipped() internal pure virtual returns (bool);

    function setUp() public {
        factoryMock = new MockMetricFactory();
        FACTORY = address(factoryMock);
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        router = new PoolSwapTest(manager);
        TestAsset x = new TestAsset();
        TestAsset y = new TestAsset();
        (low, high) = address(x) < address(y) ? (x, y) : (y, x);

        address hookAddress = address(uint160(0x4444 << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(OWNER, FACTORY, address(manager), address(0)),
            hookAddress
        );
        hook = MetricVenueHook(hookAddress);
        key = PoolKey(
            Currency.wrap(address(low)), Currency.wrap(address(high)), 0, 1, IHooks(hookAddress)
        );
        // Metric's token0 is the v4 pool's currency0 unless flipped. Its scale multipliers
        // stand in for decimals: the higher token counts as 6-decimal.
        metric = flipped()
            ? new MockMetricPool(
                FACTORY, address(high), address(low), 1e12, 1, uint128((1 << 64) / 2048)
            )
            : new MockMetricPool(
                FACTORY, address(low), address(high), 1, 1e12, uint128(2048 << 64)
            );

        factoryMock.register(address(metric));
        low.mint(address(metric), 1_000_000e18);
        high.mint(address(metric), 1_000_000e18);
        low.mint(address(manager), 1_000_000e18);
        high.mint(address(manager), 1_000_000e18);
        low.mint(address(this), 1_000e18);
        high.mint(address(this), 1_000e18);
        low.approve(address(router), type(uint256).max);
        high.approve(address(router), type(uint256).max);
        vm.prank(OWNER);
        hook.bind(key, address(metric));
    }

    // ---------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------

    function _swap(bool zeroForOne, int256 amount, uint160 limit) internal {
        router.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, amount, limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _open(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _wrapped(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _wrappedAt(bytes4 selector, bytes memory reason)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// Runs a swap and returns the swapper's and the pool manager's balance changes, and the
    /// Metric pool's, of (low, high).
    function _run(bool zeroForOne, int256 amount)
        internal
        returns (int256 myLow, int256 myHigh, int256 pmLow, int256 pmHigh)
    {
        uint256[6] memory before_ = _balances();
        _swap(zeroForOne, amount, _open(zeroForOne));
        uint256[6] memory after_ = _balances();
        myLow = int256(after_[0]) - int256(before_[0]);
        myHigh = int256(after_[1]) - int256(before_[1]);
        pmLow = int256(after_[2]) - int256(before_[2]);
        pmHigh = int256(after_[3]) - int256(before_[3]);
        // The hook never keeps anything, and the Metric pool is the other side of the pool
        // manager's change.
        assertEq(low.balanceOf(address(hook)), 0);
        assertEq(high.balanceOf(address(hook)), 0);
        assertEq(int256(after_[4]) - int256(before_[4]), -(myLow + pmLow));
        assertEq(int256(after_[5]) - int256(before_[5]), -(myHigh + pmHigh));
    }

    function _balances() internal view returns (uint256[6] memory b) {
        b[0] = low.balanceOf(address(this));
        b[1] = high.balanceOf(address(this));
        b[2] = low.balanceOf(address(manager));
        b[3] = high.balanceOf(address(manager));
        b[4] = low.balanceOf(address(metric));
        b[5] = high.balanceOf(address(metric));
    }

    // ---------------------------------------------------------------------------------
    // the four swap cases
    // ---------------------------------------------------------------------------------

    function testExactInputSellingLow() public {
        (int256 myLow, int256 myHigh,,) = _run(true, -int256(IN));
        assertEq(myLow, -int256(IN));
        assertEq(myHigh, int256(OUT));
    }

    function testExactOutputBuyingHigh() public {
        (int256 myLow, int256 myHigh,,) = _run(true, int256(OUT));
        assertEq(myLow, -int256(IN));
        assertEq(myHigh, int256(OUT));
    }

    function testExactInputSellingHigh() public {
        (int256 myLow, int256 myHigh,,) = _run(false, -int256(OUT));
        assertEq(myHigh, -int256(OUT));
        assertEq(myLow, int256(IN));
    }

    function testExactOutputBuyingLow() public {
        (int256 myLow, int256 myHigh,,) = _run(false, int256(IN));
        assertEq(myHigh, -int256(OUT));
        assertEq(myLow, int256(IN));
    }

    function testPoolManagerBalancesMatchTheSwap() public {
        (,, int256 pmLow, int256 pmHigh) = _run(true, -int256(IN));
        assertEq(pmLow, int256(IN) - int256(IN));
        assertEq(pmHigh, 0);
    }

    // ---------------------------------------------------------------------------------
    // price limits
    // ---------------------------------------------------------------------------------

    function _mid() internal view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = manager.getSlot0(key.toId());
    }

    function testInitialPriceIsTheMetricMid() public view {
        // 2.048e-9 raw per raw, whichever way round Metric lists the tokens.
        uint256 expected = FixedPointMathLib.sqrt((uint256(2048) << 192) / 1e12);
        assertApproxEqRel(uint256(_mid()), expected, 1e-9 ether);
    }

    function testLimitJustPastThePriceIsIncomplete() public {
        uint160 mid = _mid();
        // Selling the lower token wants at least the limit price; buying it wants at most.
        uint160 sellLimit = uint160(uint256(mid) * 1_000_001 / 1_000_000);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector)));
        _swap(true, -int256(IN), sellLimit);
        uint160 buyLimit = uint160(uint256(mid) * 999_999 / 1_000_000);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector)));
        _swap(false, -int256(OUT), buyLimit);
    }

    function testLimitBeyondThePriceFills() public {
        uint160 mid = _mid();
        uint256 start = high.balanceOf(address(this));
        _swap(true, -int256(IN), uint160(uint256(mid) * 999_999 / 1_000_000));
        assertEq(high.balanceOf(address(this)) - start, OUT);
        start = low.balanceOf(address(this));
        _swap(false, -int256(OUT), uint160(uint256(mid) * 1_000_001 / 1_000_000));
        assertEq(low.balanceOf(address(this)) - start, IN);
    }

    function testFarLimitsFill() public {
        uint160 mid = _mid();
        uint256 start = high.balanceOf(address(this));
        _swap(true, -int256(IN), uint160(uint256(mid) / 2));
        assertEq(high.balanceOf(address(this)) - start, OUT);
        start = low.balanceOf(address(this));
        _swap(false, -int256(OUT), uint160(uint256(mid) * 2));
        assertEq(low.balanceOf(address(this)) - start, IN);
    }

    // ---------------------------------------------------------------------------------
    // failures
    // ---------------------------------------------------------------------------------

    function testPartialFillRevertsIncomplete() public {
        metric.setMaxFill(IN / 2);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector)));
        _swap(true, -int256(IN), _open(true));
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector)));
        _swap(true, int256(OUT), _open(true));
    }

    function testDrainedWhenThePoolManagerIsShort() public {
        deal(address(low), address(manager), IN - 1);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Drained.selector)));
        _swap(true, -int256(IN), _open(true));
        // Exactly enough is not short.
        deal(address(low), address(manager), IN);
        _swap(true, -int256(IN), _open(true));
    }

    function testForgedCallbackIsRefused() public {
        vm.expectRevert(MetricVenueHook.NotMetricPool.selector);
        hook.metricOmmSwapCallback(int256(IN), 0, "");
        // The bound pool itself, with no swap of the hook's in progress.
        vm.prank(address(metric));
        vm.expectRevert(MetricVenueHook.NotMetricPool.selector);
        hook.metricOmmSwapCallback(int256(IN), 0, "");
    }

    function testAddLiquidityReverts() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        low.approve(address(lp), type(uint256).max);
        high.approve(address(lp), type(uint256).max);
        vm.expectRevert(
            _wrappedAt(
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(MetricVenueHook.LiquidityNotAllowed.selector)
            )
        );
        lp.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams(-1, 1, 1e6, 0), "");
    }

    function testInitializeByAnyoneElseIsRefused() public {
        PoolKey memory other = key;
        other.fee = 500;
        vm.expectRevert(
            _wrappedAt(
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(MetricVenueHook.NotInitializer.selector)
            )
        );
        manager.initialize(other, 1 << 96);
    }

    function testSwapsOnlyThroughThePoolManager() public {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams(true, -1, _open(true));
        vm.expectRevert(MetricVenueHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(MetricVenueHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
    }

    // ---------------------------------------------------------------------------------
    // bind
    // ---------------------------------------------------------------------------------

    function _mock(address t0, address t1) internal returns (MockMetricPool) {
        MockMetricPool pool = new MockMetricPool(FACTORY, t0, t1, 1, 1e12, uint128(2048 << 64));
        factoryMock.register(address(pool));
        return pool;
    }

    function testBindIsOwnerOnly() public {
        vm.expectRevert(MetricVenueHook.NotOwner.selector);
        hook.bind(key, address(metric));
    }

    function testBindEmitsAndRefusesARepeat() public {
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.AlreadyBound.selector);
        hook.bind(key, address(metric));
        (address pool,,,,) = hook.bindings(key.toId());
        assertEq(pool, address(metric));
    }

    function testBindRefusesAForeignHook() public {
        PoolKey memory k = key;
        k.hooks = IHooks(address(0x1234));
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.InvalidKey.selector);
        hook.bind(k, address(metric));
    }

    function testBindRefusesAFee() public {
        PoolKey memory k = key;
        k.fee = 100;
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.InvalidKey.selector);
        hook.bind(k, address(metric));
    }

    function testBindRefusesATickSpacing() public {
        PoolKey memory k = key;
        k.tickSpacing = 60;
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.InvalidKey.selector);
        hook.bind(k, address(metric));
    }

    function testBindRefusesNativeEth() public {
        PoolKey memory k = key;
        k.currency0 = Currency.wrap(address(0));
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.InvalidKey.selector);
        hook.bind(k, address(metric));
    }

    function testBindRefusesOtherTokens() public {
        TestAsset third = new TestAsset();
        MockMetricPool wrong = _mock(address(low), address(third));
        PoolKey memory k = key;
        k.fee = 0;
        k.tickSpacing = 1;
        // A new pair under the same hook, so the pool is not yet bound.
        (address a, address b) = address(third) < address(high)
            ? (address(third), address(high))
            : (address(high), address(third));
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.WrongTokens.selector);
        hook.bind(k, address(wrong));
    }

    function testBindRefusesAForeignFactory() public {
        TestAsset third = new TestAsset();
        MockMetricPool foreign =
            new MockMetricPool(address(0xBAD), address(third), address(high), 1, 1e12, 1 << 64);
        // Registered with the real factory, so only the pool's own claim is wrong.
        factoryMock.register(address(foreign));
        PoolKey memory k = key;
        (address a, address b) = address(third) < address(high)
            ? (address(third), address(high))
            : (address(high), address(third));
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.WrongFactory.selector);
        hook.bind(k, address(foreign));
    }

    function _otherKey(TestAsset third) internal view returns (PoolKey memory k) {
        k = key;
        (address a, address b) = address(third) < address(high)
            ? (address(third), address(high))
            : (address(high), address(third));
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
    }

    /// A pool that says it is Metric's but that the factory did not make.
    function testBindRefusesAPoolTheFactoryDoesNotKnow() public {
        TestAsset third = new TestAsset();
        MockMetricPool fake = new MockMetricPool(
            FACTORY, address(third), address(high), 1, 1e12, uint128(2048 << 64)
        );
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.WrongFactory.selector);
        hook.bind(_otherKey(third), address(fake));
    }

    function testUnbindStopsSwapsAndCannotBeUndone() public {
        _swap(true, -int256(IN), _open(true));
        vm.expectRevert(MetricVenueHook.NotOwner.selector);
        hook.unbind(key);
        vm.prank(OWNER);
        hook.unbind(key);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.NotBound.selector)));
        _swap(true, -int256(IN), _open(true));
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.AlreadyBound.selector);
        hook.bind(key, address(metric));
        TestAsset third = new TestAsset();
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.NotBound.selector);
        hook.unbind(_otherKey(third));
    }

    // ---------------------------------------------------------------------------------
    // a pool that misbehaves
    // ---------------------------------------------------------------------------------

    function testAmountTooLargeReverts() public {
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(MetricVenueHook.AmountTooLarge.selector))
        );
        _swap(true, -int256(uint256(1) << 127), _open(true));
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(MetricVenueHook.AmountTooLarge.selector))
        );
        _swap(true, int256(uint256(1) << 127), _open(true));
    }

    function testNegativeInputReportedIsABadFill() public {
        metric.setMode(1, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.BadFill.selector)));
        _swap(true, -int256(IN), _open(true));
    }

    function testNegativeOutputReportedIsABadFill() public {
        metric.setMode(2, 0);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.BadFill.selector)));
        _swap(true, -int256(IN), _open(true));
    }

    /// The hook pays what the pool asks for; the swapper is only charged what it reported,
    /// so the hook is left owing and the unlock cannot close.
    function testAskingMoreThanItReportedLeavesTheUnlockOpen() public {
        metric.setMode(3, 1);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        _swap(true, -int256(IN), _open(true));
    }

    /// A pool that swaps on another binding of the hook before it asks for its input finds
    /// the hook no longer waiting for it.
    function testNestedSwapThroughASecondBindingFailsClosed() public {
        TestAsset third = new TestAsset();
        MockMetricPool second = _mock(address(third), address(high));
        PoolKey memory other = _otherKey(third);
        if (Currency.unwrap(other.currency0) != address(third)) {
            second = new MockMetricPool(
                FACTORY, address(high), address(third), 1e12, 1, uint128((1 << 64) / 2048)
            );
            factoryMock.register(address(second));
        }
        third.mint(address(second), 1_000_000e18);
        high.mint(address(second), 1_000_000e18);
        third.mint(address(manager), 1_000_000e18);
        vm.prank(OWNER);
        hook.bind(other, address(second));
        metric.setMode(4, 0);
        metric.setNested(
            manager,
            other,
            IPoolManager.SwapParams(
                Currency.unwrap(other.currency0) == address(third),
                -1e12,
                _open(Currency.unwrap(other.currency0) == address(third))
            )
        );
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(MetricVenueHook.NotMetricPool.selector))
        );
        _swap(true, -int256(IN), _open(true));
    }

    /// The hook forgets the pool when its swap ends, so a call to the callback later in the
    /// same transaction is refused even from the bound pool.
    function testCallbackAfterTheSwapIsRefusedInTheSameTransaction() public {
        ReplayProbe probe = new ReplayProbe();
        low.mint(address(probe), 10e18);
        high.mint(address(probe), 10e18);
        bytes memory reason = probe.run(
            router, key, metric, address(hook), IERC20(address(low)), IERC20(address(high))
        );
        assertEq(reason, abi.encodeWithSelector(MetricVenueHook.NotMetricPool.selector));
    }

    function testOwnerTransfersInTwoSteps() public {
        address next = address(0x9999);
        vm.expectRevert(MetricVenueHook.NotOwner.selector);
        hook.nominateOwner(next);
        vm.prank(OWNER);
        hook.nominateOwner(next);
        assertEq(hook.owner(), OWNER);
        vm.expectRevert(MetricVenueHook.NotNominee.selector);
        hook.acceptOwnership();
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
        assertEq(hook.nominee(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(MetricVenueHook.NotOwner.selector);
        hook.nominateOwner(OWNER);
        // With no nominee, nobody can take over.
        vm.prank(address(0));
        vm.expectRevert(MetricVenueHook.NotNominee.selector);
        hook.acceptOwnership();
    }

    /// 23-L-5: a searcher with no code would make every swap revert for good.
    function testConstructorRefusesASearcherWithNoCode() public {
        address at = address(uint160(0x4445 << 144 | 0x2888 | 1 << 6));
        vm.expectRevert(MetricVenueHook.NoHook.selector);
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(OWNER, FACTORY, address(manager), address(0xBEEF)),
            at
        );
    }

    /// Zero is the supported "no arbitrage hook": it is accepted, and swaps run without a search.
    function testNoSearcherIsAcceptedAndSwapsWork() public {
        assertEq(hook.arbitrage(), address(0));
        (,, int256 pmLow, int256 pmHigh) = _run(true, -int256(IN));
        assertEq(pmLow, 0);
        assertEq(pmHigh, 0);
    }

    function testConstructorRefusesAWrongAddress() public {
        vm.expectRevert(MetricVenueHook.InvalidHookAddress.selector);
        new MetricVenueHook(OWNER, FACTORY, manager, address(0));
    }
}

/// @dev Swaps through the router and then has the bound pool call the hook's callback, all
/// in one call, because transient storage does not survive a second call from a test.
contract ReplayProbe {
    function run(
        PoolSwapTest router,
        PoolKey calldata key,
        MockMetricPool pool,
        address hook,
        IERC20 low,
        IERC20 high
    ) external returns (bytes memory reason) {
        low.approve(address(router), type(uint256).max);
        high.approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        try pool.poke(hook) {
            revert("the callback was accepted");
        } catch (bytes memory data) {
            reason = data;
        }
    }
}

contract MetricVenueHookTest is MetricVenueHookBase {
    function flipped() internal pure override returns (bool) {
        return false;
    }
}

contract MetricVenueHookFlippedTest is MetricVenueHookBase {
    function flipped() internal pure override returns (bool) {
        return true;
    }
}
