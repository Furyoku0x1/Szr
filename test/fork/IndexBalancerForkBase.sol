// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ISzrLiquidity } from "../../src/interfaces/ISzrModules.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";
import { IndexBalancer } from "../../src/index/IndexBalancer.sol";
import { IndexBalancerState } from "../../src/index/IndexBalancerState.sol";
import { IndexSettings } from "../../src/index/IndexSettings.sol";
import { BalancerHarness, deployBalancer } from "../utils/IndexBalancerWorld.sol";

/// @dev Robinhood Chain at the latest block: the real pool manager, real hookless USDG pools
/// of stock tokens (`docs/research/stock-pools-2026-11-24.md`), Metric's real factory, and
/// a balancer approved on a fresh index pool factory. Skipped unless FORK_RPC_URL is set.
abstract contract IndexBalancerForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager internal constant MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant LIQUIDITY = 0x8c1261C469E83E93aa19Af8f07FD939078Dd1344;
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address internal constant PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    uint32 internal constant HOOK_GAS = 4_200_000;
    uint256 internal constant FAR = type(uint256).max;
    uint256 internal constant Q192 = 1 << 192;

    IndexPoolFactory internal factory;
    BalancerHarness internal balancer;
    IndexSettings internal settings;
    PoolSwapTest internal swapper;
    mapping(address token => PoolKey) internal venueOf;
    bool internal live;
    /// The limits new pools are given.
    uint256 internal minimumGap = 1e15;
    uint256 internal minimumProfit;

    function setUp() public virtual {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        factory = new IndexPoolFactory(ISzrLiquidity(LIQUIDITY), makeAddr("protocol"));
        balancer = deployBalancer(vm, MANAGER, factory, IMetricFactory(METRIC_FACTORY));
        settings = IndexSettings(address(balancer));
        vm.prank(ISzrLiquidity(LIQUIDITY).manager());
        factory.setHookApproved(address(balancer), HOOK_GAS);
        swapper = new PoolSwapTest(MANAGER);
        // The hookless USDG pools of the research appendix, keyed by fee and tick spacing.
        venueOf[NVDA] = _key(NVDA, 3000, 60);
        venueOf[TSLA] = _key(TSLA, 3000, 60);
        venueOf[AAPL] = _key(AAPL, 3000, 60);
        venueOf[META] = _key(META, 3000, 60);
        venueOf[PLTR] = _key(PLTR, 10_000, 200);
    }

    modifier onlyFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    function _key(address token, uint24 fee, int24 spacing)
        internal
        pure
        returns (PoolKey memory)
    {
        (address a, address b) = token < USDG ? (token, USDG) : (USDG, token);
        return PoolKey(Currency.wrap(a), Currency.wrap(b), fee, spacing, IHooks(address(0)));
    }

    /// Raw USDG per raw token, WAD, at the token's venue's mid price.
    function _price(address token) internal view returns (uint256) {
        if (token == USDG) return 1e18;
        (uint160 root,,,) = MANAGER.getSlot0(venueOf[token].toId());
        // Token1 per token0, raw, as a WAD.
        uint256 ratio = FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(root, root, 1 << 64), 1e18, 1 << 128
        );
        if (token < USDG) return ratio;
        return FixedPointMathLib.fullMulDiv(1e18, 1e18, ratio);
    }

    function _value(address token, uint256 amount) internal view returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amount, _price(token), 1e18);
    }

    /// A pool of `list` (sorted) at `weights`, worth `usd` whole dollars at the venues' mid
    /// prices, except that token `off` holds `1 + gap` times its share: cheap in the pool.
    function _pool(
        address[] memory list,
        uint256[] memory weights,
        uint256 usd,
        uint256 off,
        uint256 gap
    ) internal returns (IndexPool pool) {
        pool = IndexPool(
            factory.create("Index", "IDX", list, weights, 3e15, address(balancer), 0)
        );
        uint256[] memory amounts = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            uint256 share = usd * 1e6 * weights[index] / 1e18;
            amounts[index] = FixedPointMathLib.fullMulDiv(share, 1e18, _price(list[index]));
            if (index == off) amounts[index] = amounts[index] * (1e18 + gap) / 1e18;
            _fund(
                list[index],
                address(this),
                amounts[index] * 2 + (list[index] == USDG ? 1e14 : 1e24)
            );
            IERC20(list[index]).approve(address(pool), FAR);
        }
        // Settings before the start apply at once; after it they would wait a day.
        settings.setUnit(address(pool), USDG);
        settings.setLimits(address(pool), minimumGap, minimumProfit);
        for (uint256 index; index < list.length; index++) {
            if (list[index] == USDG) continue;
            settings.setRoutes(address(pool), list[index], _routesFor(list[index]));
        }
        pool.start(amounts, 1e24, FAR);
    }

    /// A token's routes when its pool is made: its v4 venue, unless a test says otherwise.
    function _routesFor(address token)
        internal
        view
        virtual
        returns (IndexBalancerState.Route[] memory routes)
    {
        routes = new IndexBalancerState.Route[](1);
        routes[0] = IndexBalancerState.Route(false, venueOf[token], address(0));
    }

    function _fund(address token, address who, uint256 amount) internal {
        deal(token, who, amount);
        vm.prank(who);
        IERC20(token).approve(address(swapper), FAR);
    }

    /// The pool's value at the venues' mid prices, in raw USDG.
    function _worth(IndexPool pool) internal view returns (uint256 total) {
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        for (uint256 index; index < list.length; index++) {
            total += _value(list[index], held[index]);
        }
    }

    /// What an arbitrageur with unlimited, fee-free outside liquidity would take: the pool's
    /// value now less its value once its prices equal the venues', at the same invariant,
    /// `V* = Π (value_i / w_i) ^ w_i`.
    function _gapValue(IndexPool pool) internal view returns (uint256) {
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        uint256[] memory weights = pool.weights();
        int256 log;
        uint256 now_;
        for (uint256 index; index < list.length; index++) {
            uint256 value = _value(list[index], held[index]);
            now_ += value;
            int256 term = FixedPointMathLib.lnWad(int256(value * 1e18 / weights[index] * 1e18));
            log += term * int256(weights[index]) / 1e18;
        }
        uint256 settled = uint256(FixedPointMathLib.expWad(log)) / 1e18;
        return now_ > settled ? now_ - settled : 0;
    }

    /// Keeper calls on every pair with `token` until a full round earns nothing. Returns the
    /// value donated, in raw USDG at the venues' prices, the cycles and the gas.
    function _close(IndexPool pool, address token)
        internal
        returns (uint256 captured, uint256 cycles, uint256 gas)
    {
        address[] memory list = pool.tokens();
        for (uint256 round; round < 12; round++) {
            bool any;
            for (uint256 index; index < list.length; index++) {
                if (list[index] == token) continue;
                vm.recordLogs();
                uint256 before = gasleft();
                uint256 profit = balancer.balance(address(pool), token, list[index]);
                gas += before - gasleft();
                if (profit == 0) continue;
                any = true;
                cycles++;
                captured += _value(_takenToken(), profit);
            }
            if (!any) break;
        }
    }

    /// The token the last recorded cycle took out of the pool, from its `Balanced` event.
    function _takenToken() internal returns (address take) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != IndexBalancer.Balanced.selector) continue;
            take = address(uint160(uint256(logs[index].topics[3])));
        }
    }

    function _push(PoolKey memory key, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        swapper.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _three(address a, address b) internal pure returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (a, b, USDG);
        _sort(list);
    }

    function _sort(address[] memory list) internal pure {
        for (uint256 index = 1; index < list.length; index++) {
            address moving = list[index];
            uint256 at = index;
            while (at > 0) {
                if (list[at - 1] < moving) break;
                list[at] = list[at - 1];
                at--;
            }
            list[at] = moving;
        }
    }

    function _equalWeights(uint256 count) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = 1e18 / count;
        }
        list[0] += 1e18 - (1e18 / count) * count;
    }

    function _indexOf(address[] memory list, address token) internal pure returns (uint256) {
        for (uint256 index; index < list.length; index++) {
            if (list[index] == token) return index;
        }
        return list.length;
    }
}
