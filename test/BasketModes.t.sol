// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Basket } from "../src/basket/Basket.sol";
import { BasketWorld, ClaimDonor, PausableAsset } from "./utils/BasketWorld.sol";

/// @dev The four fee modes (spec, "Fee modes"): hold, compound, to unit, to stocks, and the cap
/// on conversions.
contract BasketModesTest is BasketWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant SWAP = 50_000e18;
    uint8 internal constant COMPOUND = 1;
    uint8 internal constant TO_UNIT = 2;
    uint8 internal constant TO_STOCKS = 3;

    ClaimDonor internal donor;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        donor = new ClaimDonor(manager);
        usd.transfer(address(donor), 1e30);
        for (uint256 index; index < stocks.length; index++) {
            stocks[index].transfer(address(donor), 1e30);
        }
    }

    /// One share in kind by bob: collects fees and runs the mode, and trades nothing itself.
    function _collect(Basket basket) internal {
        _fund(basket, bob, 1e30);
        vm.prank(bob);
        basket.deposit(1, _unbounded(basket.legCount() + 1), block.timestamp);
    }

    function _total(uint256[] memory amounts) internal pure returns (uint256 sum) {
        for (uint256 index; index < amounts.length; index++) {
            sum += amounts[index];
        }
    }

    /// The most a conversion may sell of the token at `index` in `tokens()`, for leg `leg`:
    /// the basket's position's holding of it, read as the full-supply preview less idle.
    function _capOf(Basket basket, uint256 index) internal view returns (uint256) {
        uint256[] memory whole = basket.previewInKind(basket.totalSupply());
        uint256 held = whole[index] - _idle(basket, basket.tokens()[index]);
        return held * 3000 / 4_000_000;
    }

    function test_factoryRecordsTheModeAndRefusesAnUnknownOne() public {
        assertEq(_basket(1, TO_STOCKS).feeMode(), TO_STOCKS, "recorded");
        vm.expectRevert(Basket.InvalidFeeMode.selector);
        factory.create("Basket", "BSKT", address(usd), 4, _legs(1));
    }

    function test_holdKeepsFeesAsTheyCame() public {
        Basket basket = _basket(3);
        _churn(3, SWAP);
        _collect(basket);
        for (uint256 index; index < 3; index++) {
            assertEq(basket.liquidityOf(index), SEED + 1, "liquidity grew only by bob's wei");
            assertGt(_idle(basket, address(stocks[index])), 0, "stock fees kept");
        }
        assertGt(_idle(basket, address(usd)), 0, "unit fees kept");
    }

    function test_compoundAddsFeesToTheLegs() public {
        Basket basket = _basket(3, COMPOUND);
        _churn(3, SWAP);
        _collect(basket);
        for (uint256 index; index < 3; index++) {
            assertGt(basket.liquidityOf(index), SEED + 1, "fees became liquidity");
            // The unit token holds three legs' fees, so each stock runs out first.
            assertLe(_idle(basket, address(stocks[index])), 2, "only what did not fit is idle");
        }
    }

    /// The liquidity a depositor adds must be figured after compounding, or they would buy in
    /// at the old size and share fees earned before they joined.
    function test_compoundRoundTripAcrossACollection() public {
        Basket basket = _basket(3, COMPOUND);
        _fund(basket, alice, 1e30);
        _churn(3, SWAP);
        uint256 start = _total(_balances(basket, alice));
        vm.startPrank(alice);
        basket.deposit(500e18, _unbounded(4), block.timestamp);
        basket.redeem(500e18, _zeros(4), block.timestamp);
        vm.stopPrank();
        assertLe(_total(_balances(basket, alice)), start, "no more than paid");
    }

    function test_compoundLateDepositorGetsNoneOfEarlierFees() public {
        Basket basket = _basket(3, COMPOUND);
        _fund(basket, alice, 1e30);
        _fund(basket, bob, 1e30);
        uint256 aliceStart = _total(_balances(basket, alice));
        vm.prank(alice);
        basket.deposit(500e18, _unbounded(4), block.timestamp);
        _churn(3, SWAP);
        uint256 bobStart = _total(_balances(basket, bob));
        vm.prank(bob);
        basket.deposit(500e18, _unbounded(4), block.timestamp);
        vm.prank(alice);
        basket.redeem(500e18, _zeros(4), block.timestamp);
        vm.prank(bob);
        basket.redeem(500e18, _zeros(4), block.timestamp);
        assertGt(_total(_balances(basket, alice)), aliceStart, "alice earned the fees");
        assertLe(_total(_balances(basket, bob)), bobStart, "bob earned none of them");
    }

    function test_toUnitSellsStockFees() public {
        Basket basket = _basket(3, TO_UNIT);
        _churn(3, SWAP);
        uint256 unitBefore = _claims(basket, address(usd));
        _collect(basket);
        // What is left is the fee the basket's own sale earned its leg.
        for (uint256 index; index < 3; index++) {
            assertLt(_idle(basket, address(stocks[index])), 1e12, "stock fees sold");
        }
        assertGt(_claims(basket, address(usd)), unitBefore, "for the unit token");
        assertEq(basket.convertedAt(), block.timestamp, "recorded");
    }

    function test_toStocksBuysStocksWithUnitFees() public {
        Basket basket = _basket(3, TO_STOCKS);
        _churn(3, SWAP);
        _collect(basket);
        // What is left is the fee the basket's own purchases earned their legs.
        assertLt(_idle(basket, address(usd)), 1e13, "unit fees spent");
        for (uint256 index; index < 3; index++) {
            assertGt(_idle(basket, address(stocks[index])), 0, "on every leg's stock");
        }
    }

    /// A pile far above the cap is sold one capped piece a second.
    function test_toUnitCapAndOncePerSecond() public {
        Basket basket = _basket(1, TO_UNIT);
        address stock = address(stocks[0]);
        donor.donate(address(basket), stock, 100e18);
        uint256 cap = _capOf(basket, 1);
        assertGt(cap, 0, "a cap");
        assertLt(cap, 100e18, "below the pile");
        uint256 pile = _idle(basket, stock);
        _collect(basket);
        uint256 sold = pile - _idle(basket, stock);
        assertGt(sold, 0, "a piece sold");
        assertLe(sold, cap, "no more than the cap");
        pile = _idle(basket, stock);
        _collect(basket);
        // Bob's one share adds at most a wei of idle stock.
        assertApproxEqAbs(_idle(basket, stock), pile, 1, "nothing more in the same second");
        vm.warp(block.timestamp + 1);
        _collect(basket);
        assertLt(_idle(basket, stock), pile, "another piece a second later");
    }

    function test_toStocksCap() public {
        Basket basket = _basket(1, TO_STOCKS);
        donor.donate(address(basket), address(usd), 100e18);
        uint256 cap = _capOf(basket, 0);
        uint256 pile = _idle(basket, address(usd));
        _collect(basket);
        uint256 sold = pile - _idle(basket, address(usd));
        assertGt(sold, 0, "a piece sold");
        assertLe(sold, cap, "no more than the cap");
    }

    function test_inKindRedemptionNeverConverts() public {
        Basket basket = _basket(1, TO_UNIT);
        donor.donate(address(basket), address(stocks[0]), 100e18);
        uint256 before = basket.convertedAt();
        vm.warp(block.timestamp + 10);
        basket.redeem(10e18, _zeros(2), block.timestamp);
        assertEq(basket.convertedAt(), before, "no conversion on an in-kind exit");
    }

    function test_conversionWorksWithAPausedStock() public {
        Basket basket = _basket(1, TO_UNIT);
        _churn(1, SWAP);
        stocks[0].setPaused(true);
        usd.mint(alice, 1e30);
        vm.prank(alice);
        usd.approve(address(basket), type(uint256).max);
        vm.prank(alice);
        basket.depositUnit(10e18, type(uint256).max, block.timestamp);
        assertLt(_idle(basket, address(stocks[0])), 1e12, "sold while paused");
    }

    /// Compounding must never push a tick past v4's per-tick cap, or every later deposit
    /// would revert. Fill both of the leg's ticks to one short of the cap: the fees stay idle
    /// and the collecting deposit still succeeds.
    function test_compoundSkipsALegWithNoRoom() public {
        Basket basket = _basket(1, COMPOUND);
        uint128 cap = Pool.tickSpacingToMaxLiquidityPerTick(SPACING);
        _provide(pools[0], LOWER, UPPER, cap - SEED - 2);
        _churn(1, SWAP);
        _collect(basket);
        assertEq(basket.liquidityOf(0), SEED + 1, "nothing compounded but bob's wei");
        assertGt(_idle(basket, address(stocks[0])), 0, "the fees stayed idle");
    }

    function test_compoundCapAndOncePerSecond() public {
        Basket basket = _basket(1, COMPOUND);
        donor.donate(address(basket), address(usd), 100e18);
        donor.donate(address(basket), address(stocks[0]), 100e18);
        uint256 cap = uint256(SEED) * 3000 / 4_000_000;
        _collect(basket);
        // Bob's one share adds its slice of the liquidity, rounded up: two wei here.
        uint256 added = basket.liquidityOf(0) - SEED - 2;
        assertGt(added, 0, "some compounded");
        assertLe(added, cap, "no more than the cap");
        uint256 now_ = basket.liquidityOf(0);
        _collect(basket);
        assertEq(basket.liquidityOf(0), now_ + 2, "only bob's slice in the same second");
        vm.warp(block.timestamp + 1);
        _collect(basket);
        assertGt(basket.liquidityOf(0), now_ + 2, "more a second later");
    }

    /// With the price past a leg's range edge, a conversion must sell nothing: a sale there
    /// would cost a pusher nothing and could run the price to v4's limit, after which every
    /// swap path would revert until someone swapped it back. The price must stay where the
    /// push left it, and once it is back in range every entry point works.
    function test_conversionStopsAtTheRangeEdge() public {
        for (uint8 mode = TO_UNIT; mode <= TO_STOCKS; mode++) {
            _pastTheEdge(mode, true);
            _pastTheEdge(mode, false);
        }
    }

    function _pastTheEdge(uint8 mode, bool sellStock) internal {
        PausableAsset stock = _asset();
        PoolKey memory pool = _bare(stock);
        Basket.Leg[] memory legs = new Basket.Leg[](1);
        legs[0] = Basket.Leg(pool, -1200, 1200);
        Basket basket = Basket(factory.create("Basket", "BSKT", address(usd), mode, legs));
        _approveAll(basket, address(this));
        uint128[] memory seed = new uint128[](1);
        seed[0] = 1_000_000e18;
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        stock.transfer(address(donor), 1e30);
        donor.donate(address(basket), address(stock), 1e21);
        donor.donate(address(basket), address(usd), 1e21);
        _tradeTo(pool, sellStock ? address(stock) : address(usd), 1800);
        (uint160 pushed,,,) = manager.getSlot0(pool.toId());
        uint256 before = basket.convertedAt();
        _collect(basket);
        vm.warp(block.timestamp + 1);
        _collect(basket);
        assertEq(basket.convertedAt(), before, "nothing sold past the edge");
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        assertEq(price, pushed, "the price stayed where the push left it");
        _tradeTo(pool, sellStock ? address(usd) : address(stock), 0);
        vm.warp(block.timestamp + 1);
        usd.mint(alice, 1e30);
        vm.startPrank(alice);
        usd.approve(address(basket), type(uint256).max);
        basket.depositUnit(1e18, type(uint256).max, block.timestamp);
        basket.redeemUnit(1e18, 0, block.timestamp);
        vm.stopPrank();
        basket.payProtocol(0, block.timestamp);
    }

    /// Sells `input` until the price is `ticks` past price one, in the direction selling it
    /// moves the price.
    function _tradeTo(PoolKey memory pool, address input, int24 ticks) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        int24 target = zeroForOne ? -ticks : ticks;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne, -int256(1e30), TickMath.getSqrtPriceAtTick(target)
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// The hardest case for the cap: the basket is the pool's only LP, so the pusher trades
    /// against nothing else. Push the price down, let a conversion sell stock cheaply, push it
    /// back: the pusher must end with less of the unit token than it began with.
    function test_sandwichLosesThePusherMoney() public {
        PausableAsset stock = _asset();
        PoolKey memory pool = _bare(stock);
        Basket.Leg[] memory legs = new Basket.Leg[](1);
        legs[0] = Basket.Leg(pool, LOWER, UPPER);
        Basket basket = Basket(factory.create("Basket", "BSKT", address(usd), TO_UNIT, legs));
        _approveAll(basket, address(this));
        uint128[] memory seed = new uint128[](1);
        seed[0] = 1_000_000e18;
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        stock.transfer(address(donor), 1e30);
        donor.donate(address(basket), address(stock), 1_000_000e18);
        uint256 unitBefore = usd.balanceOf(address(this));
        uint256 stockBefore = stock.balanceOf(address(this));
        // About a 10% push, then the conversion, then back by buying the same stock.
        uint256 pushed = 50_000e18;
        _trade(pool, address(stock), pushed);
        _collect(basket);
        _buy(pool, address(stock), pushed);
        // Back at about price one, so token counts compare value.
        uint256 before = unitBefore + stockBefore;
        uint256 afterwards = usd.balanceOf(address(this)) + stock.balanceOf(address(this));
        assertLt(afterwards, before, "the pusher lost money");
        emit log_named_uint("pusher's loss", before - afterwards);
    }

    /// A full-range leg on a 0.01% pool with tick spacing 1 ends exactly at v4's price bounds.
    /// Conversions must still work there in both directions, and so must every entry point.
    function test_fullRangeOnSpacingOneConverts() public {
        for (uint8 mode = TO_UNIT; mode <= TO_STOCKS; mode++) {
            PausableAsset stock = _asset();
            PoolKey memory pool = _bare(stock);
            pool.fee = 100;
            pool.tickSpacing = 1;
            manager.initialize(pool, uint160(1 << 96));
            _provide(pool, TickMath.MIN_TICK, TickMath.MAX_TICK, DEPTH);
            Basket.Leg[] memory legs = new Basket.Leg[](1);
            legs[0] = Basket.Leg(pool, TickMath.MIN_TICK, TickMath.MAX_TICK);
            Basket basket = Basket(factory.create("Basket", "BSKT", address(usd), mode, legs));
            _approveAll(basket, address(this));
            uint128[] memory seed = new uint128[](1);
            seed[0] = SEED;
            basket.start(seed, SHARES, _unbounded(2), block.timestamp);
            _trade(pool, address(usd), SWAP);
            _trade(pool, address(stock), SWAP);
            vm.warp(block.timestamp + 1);
            _collect(basket);
            assertEq(basket.convertedAt(), block.timestamp, "converted");
            usd.mint(alice, 1e30);
            vm.startPrank(alice);
            usd.approve(address(basket), type(uint256).max);
            basket.depositUnit(1e18, type(uint256).max, block.timestamp);
            basket.redeemUnit(1e18, 0, block.timestamp);
            vm.stopPrank();
            basket.payProtocol(0, block.timestamp);
        }
    }

    /// A pool of `stock` and the unit token at price one with no liquidity of its own.
    function _bare(PausableAsset stock) internal returns (PoolKey memory pool) {
        (address zero, address one) = address(usd) < address(stock)
            ? (address(usd), address(stock))
            : (address(stock), address(usd));
        pool =
            PoolKey(Currency.wrap(zero), Currency.wrap(one), 3000, SPACING, IHooks(address(0)));
        manager.initialize(pool, uint160(1 << 96));
    }

    /// An exact-output swap by this contract that buys `amount` of `output`.
    function _buy(PoolKey memory pool, address output, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency1) == output;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(zeroForOne, int256(amount), zeroForOne ? FLOOR : CEILING),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }
}
