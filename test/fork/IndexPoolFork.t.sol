// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ISzrLiquidity } from "../../src/interfaces/ISzrModules.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../../src/index/IndexPositions.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { MockIndexHook } from "../utils/IndexWorld.sol";

/// @dev A three-token index pool of two real Robinhood stock tokens and USDG, at the latest
/// block: start, swaps each way and of each kind, join, exit and donate, with the gas of
/// each. Skipped unless FORK_RPC_URL is set:
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path
///   "test/fork/IndexPoolFork.t.sol" -vv
contract IndexPoolForkTest is Test {
    address internal constant LIQUIDITY = 0x8c1261C469E83E93aa19Af8f07FD939078Dd1344;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    uint256 internal constant FAR = type(uint256).max;
    uint128 internal constant UNITS = 1e21;

    IndexPoolFactory internal factory;
    address internal protocol = makeAddr("protocol");
    address internal alice = makeAddr("alice");
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        live = true;
        factory = new IndexPoolFactory(ISzrLiquidity(LIQUIDITY), protocol);
    }

    function testRealTokensWithoutAHook() public {
        if (!live) return vm.skip(true);
        IndexPool pool = _pool(address(0));
        _exercise(pool, "no hook");
    }

    function testRealTokensWithAHook() public {
        if (!live) return vm.skip(true);
        MockIndexHook hook = new MockIndexHook();
        vm.prank(ISzrLiquidity(LIQUIDITY).manager());
        factory.setHookApproved(address(hook), 1_000_000);
        IndexPool pool = _pool(address(hook));
        hook.setMode(MockIndexHook.Mode.Idle);
        _exercise(pool, "idle hook");
    }

    /// The locked swap step with real tokens, cold, must fit inside `SWAP_GAS`, the gas a
    /// hooked swap keeps back for it.
    function testSwapGasCoversTheLockedStep() public {
        if (!live) return vm.skip(true);
        IndexPool pool = _pool(address(0));
        address[] memory list = pool.tokens();
        uint256 worst;
        for (uint256 i; i < 3; i++) {
            for (uint256 o; o < 3; o++) {
                if (i == o) continue;
                worst = _max(worst, _swapGas(pool, list[i], list[o], true));
                worst = _max(worst, _swapGas(pool, list[i], list[o], false));
            }
        }
        console2.log("most gas a swap with real tokens used, cold", worst);
        // The dearest case: the window after one that recorded a level for every token, so
        // both tokens of the swap write a new level and keep the old one beside it.
        for (uint256 index; index < 3; index++) {
            vm.prank(alice);
            pool.swap(list[index], list[(index + 1) % 3], 1e6, false, FAR, alice, FAR);
        }
        vm.warp(block.timestamp + 1 days);
        uint256 later;
        for (uint256 i; i < 3; i++) {
            for (uint256 o; o < 3; o++) {
                if (i == o) continue;
                later = _max(later, _swapGas(pool, list[i], list[o], true));
                later = _max(later, _swapGas(pool, list[i], list[o], false));
            }
        }
        console2.log("the same in the next window, levels kept", later);
        assertLt(_max(worst, later), pool.SWAP_GAS());
    }

    /// An ordinary owner's full-range INDEX/WETH position on the live pool manager: fees
    /// paid in the index pool raise its growth index, and the harvest pays the owner half
    /// that growth of the position, as the share is half its value.
    function testOrdinaryOwnerHarvestsAnIndexWethPosition() public {
        if (!live) return vm.skip(true);
        IndexPool pool = _pool(address(0));
        address weth = Liquidity(LIQUIDITY).backingAsset();
        (IndexPositions positions, uint256 id) = _openWeth(pool, weth);
        uint256 last = _baseline(positions, id, pool);
        _payFees(pool);
        uint256 current = pool.growthIndex();
        uint256 f = (current - last) * 1e18 / current;
        console2.log("growth fraction, WAD", f);
        uint256 shares = pool.balanceOf(alice);
        uint256 wethBefore = IERC20(weth).balanceOf(alice);
        vm.prank(alice);
        uint128 removed = positions.harvest(id, 0, 0, FAR);
        console2.log("liquidity harvested", removed);
        assertApproxEqRel(removed, uint256(UNITS) * f / 2e18, 1e6, "f / 2");
        // At a price of one, the position holds `UNITS` of each, so each payment is the
        // liquidity removed, less rounding.
        assertApproxEqAbs(pool.balanceOf(alice) - shares, removed, 2, "shares paid");
        assertApproxEqAbs(IERC20(weth).balanceOf(alice) - wethBefore, removed, 2, "weth paid");
        assertEq(pool.balanceOf(address(positions)), 0);
        assertEq(IERC20(weth).balanceOf(address(positions)), 0);
    }

    function _openWeth(IndexPool pool, address weth)
        internal
        returns (IndexPositions positions, uint256 id)
    {
        IPoolManager manager = Liquidity(LIQUIDITY).poolManager();
        positions = new IndexPositions(manager, address(factory));
        bool shareFirst = address(pool) < weth;
        PoolKey memory key = PoolKey(
            Currency.wrap(shareFirst ? address(pool) : weth),
            Currency.wrap(shareFirst ? weth : address(pool)),
            3000,
            60,
            IHooks(address(0))
        );
        manager.initialize(key, uint160(1 << 96));
        pool.transfer(alice, 1e23);
        deal(weth, alice, 1e23);
        vm.startPrank(alice);
        pool.approve(address(positions), FAR);
        IERC20(weth).approve(address(positions), FAR);
        id = positions.open(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), UNITS, FAR, FAR, FAR
        );
        vm.stopPrank();
    }

    function _baseline(IndexPositions positions, uint256 id, IndexPool pool)
        internal
        view
        returns (uint256)
    {
        (, PoolKey memory key,,,, uint256 last0, uint256 last1) = positions.position(id);
        return Currency.unwrap(key.currency0) == address(pool) ? last0 : last1;
    }

    function _payFees(IndexPool pool) internal {
        address[] memory list = pool.tokens();
        vm.startPrank(alice);
        for (uint256 round; round < 10; round++) {
            (, uint256 got) = pool.swap(list[0], list[2], 50e18, true, 1, alice, FAR);
            pool.swap(list[2], list[0], got, true, 1, alice, FAR);
        }
        vm.stopPrank();
    }

    function _pool(address hook) internal returns (IndexPool pool) {
        address[] memory list = _sorted();
        uint256[] memory weights = new uint256[](3);
        weights[0] = 333_333_333_333_333_334;
        weights[1] = 333_333_333_333_333_333;
        weights[2] = 333_333_333_333_333_333;
        pool = IndexPool(factory.create("Index", "IDX", list, weights, 3e15, hook, 0));
        _fund(address(this), pool);
        _fund(alice, pool);
        uint256[] memory amounts = new uint256[](3);
        for (uint256 index; index < 3; index++) {
            amounts[index] = list[index] == USDG ? 300_000e6 : 1000e18;
        }
        uint256 start = gasleft();
        pool.start(amounts, 1e24, FAR);
        console2.log("start", start - gasleft());
        if (hook != address(0)) MockIndexHook(hook).setPool(pool);
    }

    function _exercise(IndexPool pool, string memory label) internal {
        address[] memory list = pool.tokens();
        vm.startPrank(alice);
        for (uint256 i; i < 3; i++) {
            uint256 o = (i + 1) % 3;
            uint256 amount = list[i] == USDG ? 1000e6 : 2e18;
            uint256 start = gasleft();
            (, uint256 got) = pool.swap(list[i], list[o], amount, true, 1, alice, FAR);
            console2.log(label, "swap exact in", start - gasleft());
            assertGt(got, 0);
            uint256 wanted = list[i] == USDG ? 500e6 : 1e18;
            start = gasleft();
            (uint256 paid,) = pool.swap(list[o], list[i], wanted, false, FAR, alice, FAR);
            console2.log(label, "swap exact out", start - gasleft());
            assertGt(paid, 0);
        }
        uint256[] memory maxIn = pool.previewJoin(1e22);
        uint256 gas = gasleft();
        pool.join(1e22, maxIn, FAR);
        console2.log(label, "join", gas - gasleft());
        uint256[] memory minOut = pool.previewExit(1e22);
        gas = gasleft();
        pool.exit(1e22, minOut, new address[](0), FAR);
        console2.log(label, "exit", gas - gasleft());
        gas = gasleft();
        pool.donate(NVDA, 1e18);
        console2.log(label, "donate", gas - gasleft());
        vm.stopPrank();
        assertGe(pool.owed(NVDA), 3e17);
        for (uint256 index; index < 3; index++) {
            uint256 recorded =
                pool.balances()[index] + pool.owed(list[index]) + pool.unreleased(list[index]);
            assertGe(IERC20(list[index]).balanceOf(address(pool)), recorded);
        }
    }

    function _swapGas(IndexPool pool, address tokenIn, address tokenOut, bool exactIn)
        internal
        returns (uint256 used)
    {
        uint256 snapshot = vm.snapshotState();
        uint256 amount = tokenIn == USDG ? 1000e6 : 2e18;
        if (!exactIn) amount = tokenOut == USDG ? 500e6 : 1e18;
        uint256 limit = exactIn ? 0 : FAR;
        // Everything the swap touches starts cold, as in a transaction of its own.
        vm.cool(address(pool));
        vm.cool(tokenIn);
        vm.cool(tokenOut);
        vm.prank(alice);
        uint256 start = gasleft();
        pool.swap(tokenIn, tokenOut, amount, exactIn, limit, alice, FAR);
        used = start - gasleft();
        vm.revertToState(snapshot);
    }

    function _fund(address who, IndexPool pool) internal {
        deal(USDG, who, 1e15);
        deal(NVDA, who, 1e24);
        deal(TSLA, who, 1e24);
        vm.startPrank(who);
        IERC20(USDG).approve(address(pool), FAR);
        IERC20(NVDA).approve(address(pool), FAR);
        IERC20(TSLA).approve(address(pool), FAR);
        vm.stopPrank();
    }

    function _sorted() internal pure returns (address[] memory list) {
        // Sorted by address: TSLA (0x32…), USDG (0x5f…), NVDA (0xd0…).
        list = new address[](3);
        list[0] = TSLA;
        list[1] = USDG;
        list[2] = NVDA;
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
