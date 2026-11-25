// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Position } from "v4-core/libraries/Position.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Basket } from "../src/basket/Basket.sol";
import { BasketFactory } from "../src/basket/BasketFactory.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { BasketWorld, ClaimDonor, PausableAsset } from "./utils/BasketWorld.sol";

/// @dev Construction, start, and deposits and redemptions by both paths.
contract BasketTest is BasketWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
    }

    // ---------------------------------------------------------------- construction

    function _refused(Basket.Leg[] memory legs) internal {
        vm.expectRevert(Basket.InvalidLeg.selector);
        factory.create("Basket", "BSKT", address(usd), 0, legs);
    }

    function _one(PoolKey memory pool, int24 lower, int24 upper)
        internal
        pure
        returns (Basket.Leg[] memory legs)
    {
        legs = new Basket.Leg[](1);
        legs[0] = Basket.Leg(pool, lower, upper);
    }

    function test_refusesNoLegs() public {
        _refused(new Basket.Leg[](0));
    }

    function test_refusesMoreThanTenLegs() public {
        Basket.Leg[] memory legs = new Basket.Leg[](11);
        for (uint256 index; index < 10; index++) {
            legs[index] = Basket.Leg(pools[index], LOWER, UPPER);
        }
        legs[10] = Basket.Leg(_pool(_asset()), LOWER, UPPER);
        _refused(legs);
    }

    function test_refusesPoolWithoutUnit() public {
        (address zero, address one) = address(stocks[0]) < address(stocks[1])
            ? (address(stocks[0]), address(stocks[1]))
            : (address(stocks[1]), address(stocks[0]));
        PoolKey memory pool =
            PoolKey(Currency.wrap(zero), Currency.wrap(one), 3000, SPACING, IHooks(address(0)));
        manager.initialize(pool, uint160(1 << 96));
        _refused(_one(pool, LOWER, UPPER));
    }

    function test_refusesNativeEther() public {
        PoolKey memory pool = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(usd)),
            3000,
            SPACING,
            IHooks(address(0))
        );
        manager.initialize(pool, uint160(1 << 96));
        _refused(_one(pool, LOWER, UPPER));
    }

    /// An initialised pool on a hook other than the arbitrage hook: an address with no
    /// permission bits is a valid hook only with a dynamic fee, and it is never called.
    function test_refusesOtherHook() public {
        PoolKey memory pool = pools[0];
        pool.hooks = IHooks(address(0x4000));
        pool.fee = 0x800000;
        manager.initialize(pool, uint160(1 << 96));
        _refused(_one(pool, LOWER, UPPER));
    }

    function test_refusesUninitialisedPool() public {
        PoolKey memory pool = pools[0];
        pool.fee = 500;
        _refused(_one(pool, LOWER, UPPER));
    }

    function test_refusesRepeatedStock() public {
        Basket.Leg[] memory legs = new Basket.Leg[](2);
        legs[0] = Basket.Leg(pools[0], LOWER, UPPER);
        legs[1] = Basket.Leg(pools[0], LOWER - SPACING, UPPER + SPACING);
        _refused(legs);
    }

    function test_refusesBadRanges() public {
        _refused(_one(pools[0], LOWER + 1, UPPER));
        _refused(_one(pools[0], LOWER, UPPER - 1));
        _refused(_one(pools[0], UPPER, LOWER));
        _refused(_one(pools[0], LOWER, LOWER));
        int24 below = TickMath.minUsableTick(SPACING) - SPACING;
        _refused(_one(pools[0], below, UPPER));
        int24 above = TickMath.maxUsableTick(SPACING) + SPACING;
        _refused(_one(pools[0], LOWER, above));
    }

    function test_factoryRecordsBasket() public {
        Basket basket = _make(_legs(2));
        assertTrue(factory.isBasket(address(basket)), "recorded");
        assertFalse(factory.isBasket(address(this)), "not a basket");
        assertEq(basket.creator(), address(this), "creator");
        assertEq(basket.protocol(), address(protocol), "protocol");
        assertEq(basket.legCount(), 2, "legs");
        address[] memory list = basket.tokens();
        assertEq(list[0], address(usd), "unit first");
        assertEq(list[2], address(stocks[1]), "leg order");
    }

    function test_factoryRefusesMissingProtocol() public {
        vm.expectRevert(BasketFactory.ZeroAddress.selector);
        new BasketFactory(manager, address(0), address(0), type(Basket).creationCode);
    }

    // ---------------------------------------------------------------- start

    function test_startSeedsEveryLeg() public {
        Basket basket = _basket(3);
        assertTrue(basket.started(), "started");
        assertEq(basket.balanceOf(address(this)), SHARES, "creator shares");
        assertEq(basket.balanceOf(basket.DEAD()), basket.DEAD_SHARES(), "dead shares");
        for (uint256 index; index < 3; index++) {
            assertEq(basket.liquidityOf(index), SEED, "held");
            bytes32 key = Position.calculatePositionKey(address(basket), LOWER, UPPER, 0);
            assertEq(manager.getPositionLiquidity(pools[index].toId(), key), SEED, "position");
        }
    }

    function test_startOnlyOnceAndOnlyByCreator() public {
        Basket basket = _make(_legs(1));
        uint128[] memory seed = new uint128[](1);
        seed[0] = SEED;
        vm.prank(alice);
        vm.expectRevert(Basket.NotCreator.selector);
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        _approveAll(basket, address(this));
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        vm.expectRevert(Basket.AlreadyStarted.selector);
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
    }

    function test_startRefusesEmptyLeg() public {
        Basket basket = _make(_legs(2));
        uint128[] memory seed = new uint128[](2);
        seed[0] = SEED;
        vm.expectRevert(Basket.InvalidAmount.selector);
        basket.start(seed, SHARES, _unbounded(3), block.timestamp);
    }

    function test_nothingWorksBeforeStart() public {
        Basket basket = _make(_legs(1));
        vm.expectRevert(Basket.NotStarted.selector);
        basket.deposit(1, _unbounded(2), block.timestamp);
        vm.expectRevert(Basket.NotStarted.selector);
        basket.depositUnit(1, type(uint256).max, block.timestamp);
        vm.expectRevert(Basket.NotStarted.selector);
        basket.redeem(1, _zeros(2), block.timestamp);
        vm.expectRevert(Basket.NotStarted.selector);
        basket.redeemUnit(1, 0, block.timestamp);
        vm.expectRevert(Basket.NotStarted.selector);
        basket.payProtocol(0, block.timestamp);
        vm.expectRevert(Basket.NotStarted.selector);
        basket.previewInKind(1);
    }

    // ---------------------------------------------------------------- in kind

    function _depositMatchesPreview(uint256 count) internal {
        Basket basket = _basket(count);
        _fund(basket, alice, 1e30);
        uint256 shares = 250e18;
        uint256[] memory preview = basket.previewInKind(shares);
        uint256[] memory before = _balances(basket, alice);
        uint256 supply = basket.totalSupply();
        vm.prank(alice);
        basket.deposit(shares, preview, block.timestamp);
        uint256[] memory afterwards = _balances(basket, alice);
        for (uint256 index; index <= count; index++) {
            assertEq(before[index] - afterwards[index], preview[index], "paid the preview");
        }
        uint256 added = (uint256(SEED) * shares + supply - 1) / supply;
        assertEq(basket.liquidityOf(count - 1), SEED + added, "rounded up");
        assertEq(basket.balanceOf(alice), shares, "minted");
    }

    function test_depositInKindOneLeg() public {
        _depositMatchesPreview(1);
    }

    function test_depositInKindThreeLegs() public {
        _depositMatchesPreview(3);
    }

    function test_depositInKindTenLegs() public {
        _depositMatchesPreview(10);
    }

    function test_depositEnforcesLimitsAndDeadline() public {
        Basket basket = _basket(3);
        _fund(basket, alice, 1e30);
        uint256[] memory preview = basket.previewInKind(100e18);
        preview[2] -= 1;
        vm.prank(alice);
        vm.expectRevert(Basket.AboveMaximum.selector);
        basket.deposit(100e18, preview, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(Basket.DeadlinePassed.selector);
        basket.deposit(100e18, _unbounded(4), block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(Basket.InvalidAmount.selector);
        basket.deposit(100e18, _unbounded(3), block.timestamp);
        vm.prank(alice);
        vm.expectRevert(Basket.InvalidAmount.selector);
        basket.deposit(0, _unbounded(4), block.timestamp);
    }

    function test_redeemInKindRoundTrip() public {
        Basket basket = _basket(3);
        _fund(basket, alice, 1e30);
        uint256[] memory start = _balances(basket, alice);
        vm.startPrank(alice);
        basket.deposit(400e18, _unbounded(4), block.timestamp);
        basket.redeem(400e18, _zeros(4), block.timestamp);
        vm.stopPrank();
        uint256[] memory end = _balances(basket, alice);
        for (uint256 index; index < 4; index++) {
            assertLe(end[index], start[index], "no more than paid");
            assertApproxEqAbs(end[index], start[index], 10, "only rounding kept");
        }
        assertEq(basket.balanceOf(alice), 0, "burnt");
    }

    function test_redeemEnforcesMinimum() public {
        Basket basket = _basket(2);
        uint256[] memory floor = _zeros(3);
        floor[1] = type(uint256).max;
        vm.expectRevert(Basket.BelowMinimum.selector);
        basket.redeem(1e18, floor, block.timestamp);
    }

    // ---------------------------------------------------------------- unit token only

    function _fundUnit(Basket basket, address who) internal {
        usd.mint(who, 1e30);
        vm.prank(who);
        usd.approve(address(basket), type(uint256).max);
    }

    function test_unitPathsMoveNoStock() public {
        Basket basket = _basket(3);
        _fundUnit(basket, alice);
        for (uint256 index; index < 3; index++) {
            vm.expectCall(
                address(stocks[index]), abi.encodeWithSelector(ERC20.transfer.selector), 0
            );
            vm.expectCall(
                address(stocks[index]), abi.encodeWithSelector(ERC20.transferFrom.selector), 0
            );
        }
        uint256 stocks0 = _stocksHeld(basket);
        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = basket.depositUnit(300e18, type(uint256).max, block.timestamp);
        assertEq(before - usd.balanceOf(alice), paid, "paid in the unit token");
        assertEq(basket.balanceOf(alice), 300e18, "minted");
        assertEq(_stocksHeld(basket), stocks0, "no stock moved in");
        vm.prank(alice);
        uint256 received = basket.redeemUnit(300e18, 0, block.timestamp);
        assertEq(_stocksHeld(basket), stocks0, "no stock moved out");
        assertLe(received, paid, "no more than paid");
        // Two trips through 0.3% pools: about 1.2% of the stock half.
        assertGt(received, paid * 98 / 100, "lost only fees and slippage");
        for (uint256 index; index < 3; index++) {
            assertEq(stocks[index].balanceOf(alice), 0, "alice never held a stock");
        }
    }

    function test_unitPathsEnforceLimits() public {
        Basket basket = _basket(2);
        _fundUnit(basket, alice);
        vm.prank(alice);
        vm.expectRevert(Basket.AboveMaximum.selector);
        basket.depositUnit(100e18, 1, block.timestamp);
        vm.prank(alice);
        basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        vm.prank(alice);
        vm.expectRevert(Basket.BelowMinimum.selector);
        basket.redeemUnit(100e18, type(uint256).max, block.timestamp);
    }

    function test_roundTripsAtSkewedPrices() public {
        Basket basket = _basket(3);
        _trade(pools[0], address(usd), 300_000e18);
        _trade(pools[1], address(stocks[1]), 300_000e18);
        _fund(basket, alice, 1e30);
        uint256 before = usd.balanceOf(alice);
        vm.startPrank(alice);
        uint256 paid = basket.depositUnit(200e18, type(uint256).max, block.timestamp);
        uint256 received = basket.redeemUnit(200e18, 0, block.timestamp);
        vm.stopPrank();
        assertLe(received, paid, "unit trip");
        assertLe(usd.balanceOf(alice), before, "unit balance");
        uint256[] memory start = _balances(basket, alice);
        vm.startPrank(alice);
        basket.deposit(200e18, _unbounded(4), block.timestamp);
        basket.redeem(200e18, _zeros(4), block.timestamp);
        vm.stopPrank();
        uint256[] memory end = _balances(basket, alice);
        for (uint256 index; index < 4; index++) {
            assertLe(end[index], start[index], "in kind, token by token");
        }
    }

    function test_outOfRangeLegStillWorks() public {
        Basket basket = _basket(2);
        // Far past 16 times: the basket's leg 0 is now all one token.
        _trade(pools[0], address(usd), 100_000_000e18);
        (, int24 tick,,) = manager.getSlot0(pools[0].toId());
        assertTrue(tick > UPPER || tick < LOWER, "out of range");
        _fund(basket, alice, 1e30);
        vm.startPrank(alice);
        basket.deposit(100e18, _unbounded(3), block.timestamp);
        uint256 paid = basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        uint256 received = basket.redeemUnit(100e18, 0, block.timestamp);
        basket.redeem(100e18, _zeros(3), block.timestamp);
        vm.stopPrank();
        assertLe(received, paid, "no more than paid");
    }

    /// A leg whose pool has no liquidity outside the basket's own range can't absorb a
    /// large sale; the redemption reverts with a named error instead of leaving a debt.
    function test_partialFillReverts() public {
        PausableAsset stock = _asset();
        PoolKey memory pool = _key(address(stock));
        manager.initialize(pool, uint160(1 << 96));
        _provide(pool, LOWER, UPPER, 1e18);
        Basket basket = _make(_one(pool, LOWER, UPPER));
        _approveAll(basket, address(this));
        uint128[] memory seed = new uint128[](1);
        seed[0] = SEED;
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        vm.expectRevert(Basket.PartialFill.selector);
        basket.redeemUnit(SHARES, 0, block.timestamp);
    }

    /// The exact-output check: a deposit in the unit token must buy each leg's slice of idle
    /// stock claims, and a thin leg can't supply a donated pile of them.
    function test_partialFillRevertsOnABuy() public {
        PausableAsset stock = _asset();
        PoolKey memory pool = _key(address(stock));
        manager.initialize(pool, uint160(1 << 96));
        _provide(pool, LOWER, UPPER, 1e18);
        Basket basket = _make(_one(pool, LOWER, UPPER));
        _approveAll(basket, address(this));
        uint128[] memory seed = new uint128[](1);
        seed[0] = SEED;
        basket.start(seed, SHARES, _unbounded(2), block.timestamp);
        ClaimDonor donor = new ClaimDonor(manager);
        stock.mint(address(donor), 1e30);
        donor.donate(address(basket), address(stock), 1e30);
        _fundUnit(basket, alice);
        vm.prank(alice);
        vm.expectRevert(Basket.PartialFill.selector);
        basket.depositUnit(SHARES, type(uint256).max, block.timestamp);
    }

    function test_outOfRangeBelowStillWorks() public {
        Basket basket = _basket(2);
        _trade(pools[1], address(stocks[1]), 100_000_000e18);
        (, int24 tick,,) = manager.getSlot0(pools[1].toId());
        assertTrue(tick < LOWER || tick > UPPER, "out of range");
        _fundUnit(basket, alice);
        vm.startPrank(alice);
        uint256 paid = basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        uint256 received = basket.redeemUnit(100e18, 0, block.timestamp);
        vm.stopPrank();
        assertLe(received, paid, "no more than paid");
    }

    function test_everyPathEnforcesItsDeadline() public {
        Basket basket = _basket(1);
        uint256 late = block.timestamp - 1;
        vm.expectRevert(Basket.DeadlinePassed.selector);
        basket.depositUnit(1e18, type(uint256).max, late);
        vm.expectRevert(Basket.DeadlinePassed.selector);
        basket.redeem(1e18, _zeros(2), late);
        vm.expectRevert(Basket.DeadlinePassed.selector);
        basket.redeemUnit(1e18, 0, late);
    }

    function test_startRefusesAnOversizedShareCount() public {
        Basket basket = _make(_legs(1));
        uint128[] memory seed = new uint128[](1);
        seed[0] = SEED;
        _approveAll(basket, address(this));
        vm.expectRevert(Basket.InvalidAmount.selector);
        basket.start(seed, uint256(type(uint128).max) + 1, _unbounded(2), block.timestamp);
    }

    function test_noImplicitPermit2Allowance() public {
        Basket basket = _basket(1);
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        assertEq(basket.allowance(address(this), permit2), 0, "no Permit2 allowance");
    }

    function test_gasWithTenLegs() public {
        Basket basket = _basket(10);
        _fundUnit(basket, alice);
        vm.prank(alice);
        uint256 gas = gasleft();
        basket.depositUnit(100e18, type(uint256).max, block.timestamp);
        uint256 depositGas = gas - gasleft();
        vm.prank(alice);
        gas = gasleft();
        basket.redeemUnit(100e18, 0, block.timestamp);
        uint256 redeemGas = gas - gasleft();
        emit log_named_uint("depositUnit gas, 10 legs", depositGas);
        emit log_named_uint("redeemUnit gas, 10 legs", redeemGas);
        assertLt(depositGas, 5_000_000, "deposit gas");
        assertLt(redeemGas, 5_000_000, "redeem gas");
    }
}
