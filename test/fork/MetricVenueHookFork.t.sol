// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { MetricVenueHook } from "../../src/hooks/MetricVenueHook.sol";
import { IMetricPool, MetricImmutables } from "../../src/interfaces/metric/IMetricPool.sol";

/// Metric's own refusal when a limit leaves nothing to fill.
error FinalAmountIsZero();

/// Metric's refusal while a pool is paused.
error PoolPaused();

/// Metric wraps a price provider's failure in this; `FeedStalled()` is 0x9a0423af.
error PriceProviderFailed(bytes reason);

interface IMetricPause {
    function setPause(uint8 level) external;
}

/// @notice MetricVenueHook on Robinhood Chain: the real PoolManager, and the WETH/USDG
/// Metric pool filling v4 swaps. Skipped unless FORK_RPC_URL is set.
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path "test/fork/MetricVenueHookFork.t.sol" -vv
contract MetricVenueHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IMetricPool internal constant POOL =
        IMetricPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    IPoolManager internal constant MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant OWNER = address(0xA11CE);

    bool internal live;
    MetricVenueHook internal hook;
    PoolSwapTest internal router;
    PoolKey internal key;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        // An address whose low bits are the hook's five permissions.
        address at = address(uint160(0x4444 << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(OWNER, FACTORY, address(MANAGER), address(0)),
            at
        );
        hook = MetricVenueHook(at);
        router = new PoolSwapTest(MANAGER);
        key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDG), 0, 1, IHooks(at));
        vm.prank(OWNER);
        hook.bind(key, address(POOL));
        // The pool manager must hold the input when Metric asks for it, as it does on
        // mainnet from everyone else's deposits.
        deal(WETH, address(MANAGER), IERC20(WETH).balanceOf(address(MANAGER)) + 3_000e18);
        deal(USDG, address(MANAGER), IERC20(USDG).balanceOf(address(MANAGER)) + 5_000_000e6);
        deal(WETH, address(this), 1_000e18);
        deal(USDG, address(this), 1_000_000e6);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(router), type(uint256).max);
    }

    modifier onlyFork() {
        if (!live) return;
        _;
    }

    function _swap(bool zeroForOne, int256 amount, uint160 limit)
        internal
        returns (uint256 used)
    {
        uint256 start = gasleft();
        router.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, amount, limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        used = start - gasleft();
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

    /// Runs a swap as the trader and returns its WETH and USDG balance changes.
    function _trade(bool zeroForOne, int256 amount, uint160 limit)
        internal
        returns (int256 weth, int256 usdg, uint256 used)
    {
        uint256 w = IERC20(WETH).balanceOf(address(this));
        uint256 u = IERC20(USDG).balanceOf(address(this));
        vm.txGasPrice(0);
        used = _swap(zeroForOne, amount, limit);
        weth = int256(IERC20(WETH).balanceOf(address(this))) - int256(w);
        usdg = int256(IERC20(USDG).balanceOf(address(this))) - int256(u);
        assertEq(IERC20(WETH).balanceOf(address(hook)), 0);
        assertEq(IERC20(USDG).balanceOf(address(hook)), 0);
    }

    function testBindRecordsTheMetricPool() public view onlyFork {
        MetricImmutables memory imm = POOL.getImmutables();
        console.log("token0 is WETH:", imm.token0 == WETH);
        console.log("scale0", imm.token0ScaleMultiplier);
        console.log("scale1", imm.token1ScaleMultiplier);
        (address pool, bool flipped,,,) = hook.bindings(key.toId());
        assertEq(pool, address(POOL));
        assertFalse(flipped);
        (uint160 sqrtPrice,,,) = MANAGER.getSlot0(key.toId());
        // Raw USDG per raw WETH is about 1816e6 / 1e18 = 1.8e-9.
        uint256 usdgPerWeth = uint256(sqrtPrice) * uint256(sqrtPrice) >> 96;
        usdgPerWeth = usdgPerWeth * 1e18 >> 96;
        console.log("v4 mid, raw USDG per WETH", usdgPerWeth);
        assertGt(usdgPerWeth, 1_000e6);
        assertLt(usdgPerWeth, 10_000e6);
    }

    function testExactInputBothWays() public onlyFork {
        (int256 w, int256 u, uint256 used) = _trade(true, -0.1e18, _open(true));
        assertEq(w, -0.1e18);
        assertGt(u, 100e6);
        console.log("sell 0.1 WETH, USDG out", uint256(u));
        console.log("gas of a v4 swap through the hook, first in the test", used);
        (w, u, used) = _trade(false, -200e6, _open(false));
        assertEq(u, -200e6);
        assertGt(w, 0.05e18);
        console.log("buy WETH with 200 USDG, WETH out", uint256(w));
        console.log("gas of the next swap", used);
    }

    function testExactOutputBothWays() public onlyFork {
        (int256 w, int256 u, uint256 used) = _trade(true, 150e6, _open(true));
        assertEq(u, 150e6);
        assertLt(w, 0);
        console.log("buy 150 USDG, WETH paid", uint256(-w));
        console.log("gas", used);
        (w, u, used) = _trade(false, 0.05e18, _open(false));
        assertEq(w, 0.05e18);
        assertLt(u, 0);
        console.log("buy 0.05 WETH, USDG paid", uint256(-u));
        console.log("gas", used);
    }

    /// Metric's own price is 1816 whole USDG per whole WETH, so a swap's average price has
    /// to agree with the v4 pool's mid to within the spread.
    function testAveragePriceMatchesTheMid() public onlyFork {
        (int256 w, int256 u,) = _trade(true, -1e18, _open(true));
        assertEq(w, -1e18);
        (uint160 mid,,,) = MANAGER.getSlot0(key.toId());
        uint256 midUsdg = uint256(mid) * uint256(mid) / (1 << 64) * 1e18 / (1 << 128);
        assertApproxEqRel(uint256(u), midUsdg, 0.01 ether);
    }

    function testLimitUnitsAreRight() public onlyFork {
        (uint160 mid,,,) = MANAGER.getSlot0(key.toId());
        // Selling WETH needs a price above the limit. Metric's sell price is a few hundredths
        // of a percent under its mid, so a limit 0.01% over the mid is out of reach.
        uint160 over = uint160(uint256(mid) * 100_005 / 100_000);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(FinalAmountIsZero.selector)));
        _swap(true, -1e18, over);
        // 0.1% under it is within reach, and so is a far one.
        (int256 w,,) = _trade(true, -1e18, uint160(uint256(mid) * 99_900 / 100_000));
        assertEq(w, -1e18);
        (w,,) = _trade(true, -1e18, uint160(uint256(mid) / 2));
        assertEq(w, -1e18);
        // Buying WETH is the other way round: a limit under the mid is out of reach.
        vm.expectRevert(_wrapped(abi.encodeWithSelector(FinalAmountIsZero.selector)));
        _swap(false, -1000e6, uint160(uint256(mid) * 99_995 / 100_000));
        (, int256 u,) = _trade(false, -1000e6, uint160(uint256(mid) * 100_100 / 100_000));
        assertEq(u, -1000e6);
    }

    function testPausedPoolReverts() public onlyFork {
        vm.prank(FACTORY);
        IMetricPause(address(POOL)).setPause(1);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(PoolPaused.selector)));
        _swap(true, -0.1e18, _open(true));
        vm.prank(FACTORY);
        IMetricPause(address(POOL)).setPause(0);
        _trade(true, -0.1e18, _open(true));
    }

    function swapExternal(bool zeroForOne, int256 amount, uint160 limit) external {
        _swap(zeroForOne, amount, limit);
    }

    /// Walks the limit of a 100 WETH sale down from just over Metric's sell price. At first
    /// nothing can fill, then only a part can, then all of it; the live price moves from
    /// block to block, so the zone is found rather than named. The part must revert.
    function testLimitStopsALargeSaleShort() public onlyFork {
        (uint160 mid,,,) = MANAGER.getSlot0(key.toId());
        bytes memory incomplete =
            _wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector));
        bool sawPartial;
        bool filled;
        for (uint256 factor = 10_000_000; factor > 9_998_000; factor -= 2) {
            try this.swapExternal(true, -100e18, uint160(uint256(mid) * factor / 10_000_000)) {
                filled = true;
                break;
            } catch (bytes memory reason) {
                if (keccak256(reason) == keccak256(incomplete)) sawPartial = true;
            }
        }
        assertTrue(filled, "a loose enough limit fills");
        assertTrue(sawPartial, "a limit in between must stop the sale short");
    }

    /// A stock token's anchored feed halts outside market hours, which is no fault of the
    /// hook, so a stalled or paused pool skips the test. Any other failure is rethrown.
    function _skipIfStalled(IMetricPool pool) internal {
        try pool.getSellAndBuyPrices() {
            return;
        } catch (bytes memory reason) {
            bool stalled;
            if (bytes4(reason) == PoolPaused.selector) stalled = true;
            if (bytes4(reason) == PriceProviderFailed.selector) {
                bytes memory body = new bytes(reason.length - 4);
                for (uint256 i; i < body.length; i++) {
                    body[i] = reason[i + 4];
                }
                bytes memory inner = abi.decode(body, (bytes));
                if (bytes4(inner) == 0x9a0423af) stalled = true;
            }
            if (!stalled) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            console.log(
                "QQQ feed stalled (market closed); flipped orientation not checked at this block"
            );
            vm.skip(true);
        }
    }

    /// The QQQ/USDG pool lists QQQ (address above USDG's) as Metric's token0, while v4 sorts
    /// USDG first, so this is the flipped orientation.
    function testFlippedOrientationOnQqqUsdg() public onlyFork {
        address qqq = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
        IMetricPool pool = IMetricPool(0x74f5f207a1038C08F9980579a50D2719bfC15774);
        MetricImmutables memory imm = pool.getImmutables();
        _skipIfStalled(pool);
        assertEq(imm.token0, qqq);
        assertEq(imm.token1, USDG);
        assertTrue(qqq > USDG);
        PoolKey memory k =
            PoolKey(Currency.wrap(USDG), Currency.wrap(qqq), 0, 1, IHooks(address(hook)));
        vm.prank(OWNER);
        hook.bind(k, address(pool));
        (, bool flipped,,,) = hook.bindings(k.toId());
        assertTrue(flipped);
        deal(qqq, address(MANAGER), IERC20(qqq).balanceOf(address(MANAGER)) + 10_000e18);
        deal(USDG, address(MANAGER), IERC20(USDG).balanceOf(address(MANAGER)) + 5_000_000e6);
        deal(qqq, address(this), 1_000e18);
        IERC20(qqq).approve(address(router), type(uint256).max);

        // Exact input, USDG for QQQ (v4 zeroForOne), then QQQ back for USDG.
        uint256 q = IERC20(qqq).balanceOf(address(this));
        uint256 u = IERC20(USDG).balanceOf(address(this));
        router.swap(
            k,
            IPoolManager.SwapParams(true, -100e6, _open(true)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(u - IERC20(USDG).balanceOf(address(this)), 100e6);
        uint256 got = IERC20(qqq).balanceOf(address(this)) - q;
        assertGt(got, 0);
        console.log("flipped: 100 USDG bought QQQ wei", got);
        u = IERC20(USDG).balanceOf(address(this));
        router.swap(
            k,
            IPoolManager.SwapParams(false, -int256(got) / 2, _open(false)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertGt(IERC20(USDG).balanceOf(address(this)), u);
        // The price agrees with the v4 mid within 1%: 100 USDG bought `got` QQQ.
        (uint160 mid,,,) = MANAGER.getSlot0(k.toId());
        uint256 qqqPerUsdg = uint256(mid) * uint256(mid) / (1 << 64) * 1e6 / (1 << 128);
        assertApproxEqRel(got, qqqPerUsdg * 100, 0.01 ether);
    }

    function testMoreThanThePoolHoldsReverts() public onlyFork {
        vm.expectRevert(_wrapped(abi.encodeWithSelector(MetricVenueHook.Incomplete.selector)));
        _swap(true, -900e18, _open(true));
    }
}
