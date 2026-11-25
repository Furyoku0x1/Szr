// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { Basket } from "../../src/basket/Basket.sol";
import { BasketFactory } from "../../src/basket/BasketFactory.sol";
import { ClaimDonor, ProtocolStub } from "../utils/BasketWorld.sol";

interface IManaged {
    function manager() external view returns (address);
}

/// @dev A basket over three real hookless USDG/stock pools on Robinhood Chain (NVDA, AAPL,
/// TSLA, all 0.30%), with the deployed Liquidity naming the manager who may pay the cut. The
/// suite runs only with a `FORK_RPC_URL`, at the latest block, and spends nothing real:
///     FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///         forge test --match-path test/fork/BasketFork.t.sol -vv
contract BasketForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal constant MANAGER =
        IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant LIQUIDITY = 0x8c1261C469E83E93aa19Af8f07FD939078Dd1344;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address internal constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    int24 internal constant SPACING = 60;
    // About 16 times either way, in ticks.
    int24 internal constant WIDTH = 27_720;
    uint128 internal constant SEED = 1e14;

    bool internal live;
    Basket internal basket;
    BasketFactory internal factory;
    PoolSwapTest internal swapper;
    PoolKey[] internal pools;
    address internal alice = makeAddr("alice");

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        address[3] memory stocks = [NVDA, AAPL, TSLA];
        Basket.Leg[] memory legs = new Basket.Leg[](3);
        for (uint256 index; index < 3; index++) {
            PoolKey memory pool = _key(stocks[index]);
            pools.push(pool);
            legs[index] = _leg(pool);
        }
        ProtocolStub protocol = new ProtocolStub(LIQUIDITY);
        factory = new BasketFactory(
            MANAGER, address(0), address(protocol), type(Basket).creationCode
        );
        swapper = new PoolSwapTest(MANAGER);
        basket = _started(0, legs);
    }

    function _started(uint8 mode, Basket.Leg[] memory legs) internal returns (Basket made) {
        made = Basket(factory.create("Stock Basket", "BSKT", USDG, mode, legs));
        Basket previous = basket;
        basket = made;
        _fund(address(this));
        basket = previous;
        uint128[] memory seed = new uint128[](legs.length);
        uint256[] memory limits = new uint256[](legs.length + 1);
        for (uint256 index; index < legs.length; index++) {
            seed[index] = SEED;
            limits[index] = type(uint256).max;
        }
        limits[legs.length] = type(uint256).max;
        made.start(seed, 1_000e18, limits, block.timestamp);
    }

    function _allLegs() internal view returns (Basket.Leg[] memory legs) {
        legs = new Basket.Leg[](3);
        for (uint256 index; index < 3; index++) {
            legs[index] = basket.leg(index);
        }
    }

    modifier onlyFork() {
        if (!live) return;
        _;
    }

    function _key(address stock) internal pure returns (PoolKey memory) {
        (address zero, address one) = USDG < stock ? (USDG, stock) : (stock, USDG);
        return
            PoolKey(Currency.wrap(zero), Currency.wrap(one), 3000, SPACING, IHooks(address(0)));
    }

    /// A range of about 1/16 to 16 times the pool's current price.
    function _leg(PoolKey memory pool) internal view returns (Basket.Leg memory) {
        (, int24 tick,,) = MANAGER.getSlot0(pool.toId());
        int24 centre = tick / SPACING * SPACING;
        return Basket.Leg(pool, centre - WIDTH, centre + WIDTH);
    }

    function _fund(address who) internal {
        deal(USDG, who, 1e15);
        deal(NVDA, who, 1e24);
        deal(AAPL, who, 1e24);
        deal(TSLA, who, 1e24);
        vm.startPrank(who);
        IERC20(USDG).approve(address(basket), type(uint256).max);
        IERC20(NVDA).approve(address(basket), type(uint256).max);
        IERC20(AAPL).approve(address(basket), type(uint256).max);
        IERC20(TSLA).approve(address(basket), type(uint256).max);
        vm.stopPrank();
    }

    function _stocksHeld() internal view returns (uint256) {
        address manager = address(MANAGER);
        return IERC20(NVDA).balanceOf(manager) + IERC20(AAPL).balanceOf(manager)
            + IERC20(TSLA).balanceOf(manager);
    }

    function test_unitRoundTripOnRealPools() public onlyFork {
        deal(USDG, alice, 1e12);
        vm.prank(alice);
        IERC20(USDG).approve(address(basket), type(uint256).max);
        uint256 stocks0 = _stocksHeld();
        vm.prank(alice);
        uint256 paid = basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        assertEq(_stocksHeld(), stocks0, "no stock moved in");
        vm.prank(alice);
        uint256 received = basket.redeemUnit(100e18, 0, block.timestamp);
        assertEq(_stocksHeld(), stocks0, "no stock moved out");
        emit log_named_uint("USDG paid (6 decimals)", paid);
        emit log_named_uint("USDG received (6 decimals)", received);
        assertGt(paid, 0, "paid");
        assertLe(received, paid, "no more than paid");
        // Two trips through 0.3% pools, plus slippage on real depth.
        assertGt(received, paid * 95 / 100, "lost only fees and slippage");
    }

    function test_inKindRoundTripOnRealPools() public onlyFork {
        _fund(alice);
        uint256 before = IERC20(USDG).balanceOf(alice);
        vm.startPrank(alice);
        basket.deposit(100e18, _limits(type(uint256).max), block.timestamp);
        basket.redeem(100e18, _limits(0), block.timestamp);
        vm.stopPrank();
        assertLe(IERC20(USDG).balanceOf(alice), before, "no more than paid");
    }

    function test_managerPaysTheCut() public onlyFork {
        // Someone else's trade through a leg earns it a fee.
        deal(USDG, alice, 1e12);
        vm.prank(alice);
        IERC20(USDG).approve(address(basket), type(uint256).max);
        vm.prank(alice);
        basket.depositUnit(500e18, type(uint256).max, block.timestamp);
        vm.prank(IManaged(LIQUIDITY).manager());
        uint256 paid = basket.payProtocol(0, block.timestamp);
        assertGt(paid, 0, "the basket's own swaps earned it fees, and 15% was paid");
    }

    /// Filling v4's per-tick liquidity cap at either end of a leg's range must cost real
    /// money, or anyone could lock every deposit out. Valued in USDG at the current price.
    function test_tickCapAtEitherEndIsExpensive() public onlyFork {
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        for (uint256 index; index < 3; index++) {
            Basket.Leg memory entry = basket.leg(index);
            (uint256 low, uint256 high) = _fillCost(entry, cap);
            emit log_named_uint("USDG to fill the lower end (6 decimals)", low);
            emit log_named_uint("USDG to fill the upper end (6 decimals)", high);
            assertGt(low, 1e6 * 1e6, "lower end costs over a million USDG");
            assertGt(high, 1e6 * 1e6, "upper end costs over a million USDG");
        }
    }

    function _fillCost(Basket.Leg memory entry, uint128 cap)
        internal
        view
        returns (uint256 low, uint256 high)
    {
        (uint160 price,,,) = MANAGER.getSlot0(entry.pool.toId());
        uint160 lowA = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 lowB = TickMath.getSqrtPriceAtTick(entry.tickLower + SPACING);
        uint160 highA = TickMath.getSqrtPriceAtTick(entry.tickUpper - SPACING);
        uint160 highB = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        // Below the price a position is all token1; above it, all token0.
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(lowA, lowB, cap, true);
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(highA, highB, cap, true);
        bool usdgFirst = Currency.unwrap(entry.pool.currency0) == USDG;
        low = usdgFirst ? _toUnit1(amount1, price) : amount1;
        high = usdgFirst ? amount0 : _toUnit0(amount0, price);
    }

    /// Token1 into token0 at the pool price (token0 per token1 is 2^192 / price²).
    function _toUnit1(uint256 amount, uint160 price) internal pure returns (uint256) {
        uint256 step = FixedPointMathLib.mulDiv(amount, 1 << 96, price);
        return FixedPointMathLib.mulDiv(step, 1 << 96, price);
    }

    /// Token0 into token1 at the pool price (price² / 2^192).
    function _toUnit0(uint256 amount, uint160 price) internal pure returns (uint256) {
        uint256 step = FixedPointMathLib.mulDiv(amount, price, 1 << 96);
        return FixedPointMathLib.mulDiv(step, price, 1 << 96);
    }

    function _limits(uint256 value) internal pure returns (uint256[] memory limits) {
        limits = new uint256[](4);
        for (uint256 index; index < 4; index++) {
            limits[index] = value;
        }
    }

    /// A USDG deposit's own swaps earn the legs fees; the next collection compounds them.
    function test_compoundOnRealPools() public onlyFork {
        Basket compounding = _started(1, _allLegs());
        deal(USDG, alice, 1e12);
        vm.prank(alice);
        IERC20(USDG).approve(address(compounding), type(uint256).max);
        vm.prank(alice);
        compounding.depositUnit(500e18, type(uint256).max, block.timestamp);
        uint256 before = compounding.liquidityOf(0);
        uint256 supplyBefore = compounding.totalSupply();
        vm.prank(alice);
        compounding.redeemUnit(1e18, 0, block.timestamp);
        uint256 afterwards = compounding.liquidityOf(0);
        uint256 supplyAfter = compounding.totalSupply();
        assertGt(afterwards * supplyBefore, before * supplyAfter, "liquidity per share rose");
        emit log_named_uint(
            "NVDA leg liquidity per 1e18 shares, before", before * 1e18 / supplyBefore
        );
        emit log_named_uint(
            "NVDA leg liquidity per 1e18 shares, after", afterwards * 1e18 / supplyAfter
        );
    }

    /// The cap against real NVDA depth: push the price down about 5%, let a conversion sell a
    /// huge donated pile of NVDA claims, then buy the same NVDA back. The pusher loses.
    function test_sandwichOnRealDepthLoses() public onlyFork {
        Basket.Leg[] memory legs = new Basket.Leg[](1);
        legs[0] = basket.leg(0);
        Basket selling = _started(2, legs);
        ClaimDonor donor = new ClaimDonor(MANAGER);
        deal(NVDA, address(donor), 1e24);
        donor.donate(address(selling), NVDA, 1e24);
        vm.warp(block.timestamp + 1);
        PoolKey memory pool = legs[0].pool;
        address attacker = makeAddr("attacker");
        deal(NVDA, attacker, 1e30);
        deal(USDG, attacker, 1e18);
        vm.startPrank(attacker);
        IERC20(NVDA).approve(address(swapper), type(uint256).max);
        IERC20(USDG).approve(address(swapper), type(uint256).max);
        uint256 usdgBefore = IERC20(USDG).balanceOf(attacker);
        uint256 nvdaBefore = IERC20(NVDA).balanceOf(attacker);
        _push(pool, NVDA, 9_746);
        uint256 sold = nvdaBefore - IERC20(NVDA).balanceOf(attacker);
        vm.stopPrank();
        deal(USDG, alice, 1e12);
        vm.prank(alice);
        IERC20(USDG).approve(address(selling), type(uint256).max);
        vm.prank(alice);
        selling.depositUnit(1e15, type(uint256).max, block.timestamp);
        assertEq(selling.convertedAt(), block.timestamp, "the conversion ran");
        vm.startPrank(attacker);
        _buyBack(pool, NVDA, sold);
        vm.stopPrank();
        assertEq(IERC20(NVDA).balanceOf(attacker), nvdaBefore, "same NVDA");
        assertLt(IERC20(USDG).balanceOf(attacker), usdgBefore, "the pusher lost USDG");
        emit log_named_uint(
            "pusher's loss (6 decimals)", usdgBefore - IERC20(USDG).balanceOf(attacker)
        );
    }

    /// Sells `input` until the price has moved to `ratio` (in units of 1e-4) of where it was,
    /// measured on the square root price.
    function _push(PoolKey memory pool, address input, uint256 ratio) internal {
        (uint160 price,,,) = MANAGER.getSlot0(pool.toId());
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        uint160 limit = zeroForOne
            ? uint160(uint256(price) * ratio / 10_000)
            : uint160(uint256(price) * 10_000 / ratio);
        swapper.swap(
            pool,
            IPoolManager.SwapParams(zeroForOne, -int256(1e30), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _buyBack(PoolKey memory pool, address output, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency1) == output;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
