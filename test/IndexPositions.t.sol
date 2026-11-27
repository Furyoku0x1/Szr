// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { LiquidityAmounts } from "../lib/v4-core/test/utils/LiquidityAmounts.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IndexToken, IndexWorld } from "./utils/IndexWorld.sol";

/// @dev A real pool manager, `IndexPositions` on the test factory, and v4 pools that pair
/// index shares with plain tokens or each other. Shared by the `IndexPositions*` tests.
abstract contract PositionsWorld is IndexWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant PRICE_ONE = uint160(1 << 96);
    int24 internal constant SPACING = 60;
    uint128 internal constant UNITS = 1e21;
    uint256 internal constant Q96 = 1 << 96;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal provider;
    PoolSwapTest internal swapper;
    IndexPositions internal positions;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual override {
        super.setUp();
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        provider = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        positions = new IndexPositions(manager, address(factory));
    }

    /// A started two-token index pool at a growth index of 1e18; this contract holds its
    /// shares and tokens.
    function _share() internal returns (IndexPool pool) {
        pool = _pool(_pair(18, 18), _equal(2), 1e6, address(0), 0);
    }

    function _plain() internal returns (address token) {
        token = address(new IndexToken(18));
    }

    /// Fee-paying swaps back and forth through `pool`, which raise its growth index.
    function _grow(IndexPool pool, uint256 rounds) internal {
        address[] memory list = pool.tokens();
        for (uint256 index; index < rounds; index++) {
            (, uint256 got) = _swap(pool, list[0], list[1], 5e22, true);
            _swap(pool, list[1], list[0], got, true);
        }
    }

    /// A v4 pool of `a` and `b` at a price of one, with no liquidity.
    function _venue(address a, address b, address hooks) internal returns (PoolKey memory key) {
        key = _key(a, b, hooks);
        manager.initialize(key, PRICE_ONE);
    }

    function _key(address a, address b, address hooks) internal pure returns (PoolKey memory) {
        (address first, address second) = a < b ? (a, b) : (b, a);
        return
            PoolKey(Currency.wrap(first), Currency.wrap(second), 3000, SPACING, IHooks(hooks));
    }

    /// Gives `who` plenty of both currencies of `key` and approves `positions` for them.
    function _fund(address who, PoolKey memory key) internal {
        _give(who, Currency.unwrap(key.currency0));
        _give(who, Currency.unwrap(key.currency1));
    }

    function _give(address who, address token) internal {
        if (token == address(0)) return vm.deal(who, 1e30);
        if (factory.isPool(token)) IndexPool(token).transfer(who, 1e23);
        else IndexToken(token).mint(who, 1e30);
        vm.prank(who);
        IndexToken(token).approve(address(positions), type(uint256).max);
    }

    function _open(address who, PoolKey memory key, int24 lower, int24 upper, uint128 units)
        internal
        returns (uint256 id)
    {
        uint256 value = Currency.unwrap(key.currency0) == address(0) ? 1e24 : 0;
        vm.prank(who);
        id = positions.open{ value: value }(key, lower, upper, units, FAR, FAR, FAR);
    }

    function _full() internal pure returns (int24, int24) {
        return (TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING));
    }

    function _liquidity(uint256 id) internal view returns (uint128 liquidity) {
        (,,,, liquidity,,) = positions.position(id);
    }

    function _lasts(uint256 id) internal view returns (uint256 last0, uint256 last1) {
        (,,,,, last0, last1) = positions.position(id);
    }

    /// `1 - last / now` as WAD, rounded the other way to the contract, for a reference.
    function _fraction(uint256 last, uint256 current) internal pure returns (uint256) {
        if (current <= last) return 0;
        return (current - last) * 1e18 / current;
    }

    /// The position's amounts at the pool's price, from v4's own test library.
    function _amounts(PoolKey memory key, uint256 id) internal view returns (uint256, uint256) {
        (, PoolKey memory stored, int24 lower, int24 upper, uint128 liquidity,,) =
            positions.position(id);
        assertEq(PoolId.unwrap(stored.toId()), PoolId.unwrap(key.toId()));
        (uint160 price,,,) = manager.getSlot0(key.toId());
        return LiquidityAmounts.getAmountsForLiquidity(
            price,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            liquidity
        );
    }

    /// Value in currency 1 at the pool's price.
    function _value(PoolKey memory key, uint256 amount0, uint256 amount1)
        internal
        view
        returns (uint256)
    {
        (uint160 price,,,) = manager.getSlot0(key.toId());
        uint256 ratio = FixedPointMathLib.fullMulDiv(price, price, Q96);
        return FixedPointMathLib.fullMulDiv(amount0, ratio, Q96) + amount1;
    }

    function _balance(address token, address who) internal view returns (uint256) {
        if (token == address(0)) return who.balance;
        return _balanceOf(token, who);
    }

    /// Invariant 6: the contract keeps nothing of a position's tokens between calls.
    function _assertEmpty(PoolKey memory key) internal view {
        assertEq(_balance(Currency.unwrap(key.currency0), address(positions)), 0, "kept 0");
        assertEq(_balance(Currency.unwrap(key.currency1), address(positions)), 0, "kept 1");
        assertEq(address(positions).balance, 0, "kept ETH");
    }
}

contract IndexPositionsTest is PositionsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- full range

    function testFullRangeHarvestRemovesHalfTheGrowth() public {
        IndexPool share = _share();
        PoolKey memory key = _venue(address(share), _plain(), address(0));
        _fund(alice, key);
        (int24 lower, int24 upper) = _full();
        uint256 id = _open(alice, key, lower, upper, UNITS);
        (uint256 a0, uint256 a1) = _amounts(key, id);
        uint256 before = _value(key, a0, a1);
        _grow(share, 20);
        uint256 f = _shareFraction(share, key, id);
        assertGt(f, 1e15, "growth too small to measure");
        uint128 expected = positions.harvestable(id);
        (uint128 removed, uint256 paid) = _harvestValue(alice, key, id);
        assertEq(removed, expected, "harvestable");
        // A full range holds equal values of both, so p is f / 2 at any price; the range's
        // finite ends move it by less than 1e-18.
        assertApproxEqRel(removed, uint256(UNITS) * f / 2e18, 1e6, "f / 2");
        assertEq(_liquidity(id), UNITS - removed, "left");
        // What was paid is the growth's value: f of the share's half of the position.
        assertApproxEqRel(paid, before * f / 2e18, 1e9, "value");
        _assertEmpty(key);
        vm.prank(alice);
        assertEq(positions.harvest(id, 0, 0, FAR), 0, "second harvest");
        assertEq(_liquidity(id), UNITS - removed);
    }

    function _shareFraction(IndexPool share, PoolKey memory key, uint256 id)
        internal
        view
        returns (uint256)
    {
        (uint256 last0, uint256 last1) = _lasts(id);
        bool first = Currency.unwrap(key.currency0) == address(share);
        return _fraction(first ? last0 : last1, share.growthIndex());
    }

    /// Harvests as `who` and returns what was removed and the value paid, in currency 1.
    function _harvestValue(address who, PoolKey memory key, uint256 id)
        internal
        returns (uint128 removed, uint256 paid)
    {
        address zero = Currency.unwrap(key.currency0);
        address one = Currency.unwrap(key.currency1);
        uint256 got0 = _balance(zero, who);
        uint256 got1 = _balance(one, who);
        removed = _harvest(who, id);
        paid = _value(key, _balance(zero, who) - got0, _balance(one, who) - got1);
    }

    function testFullRangeWithTwoShares() public {
        IndexPool one = _share();
        IndexPool two = _share();
        PoolKey memory key = _venue(address(one), address(two), address(0));
        _fund(alice, key);
        (int24 lower, int24 upper) = _full();
        uint256 id = _open(alice, key, lower, upper, UNITS);
        _grow(IndexPool(Currency.unwrap(key.currency0)), 30);
        _grow(IndexPool(Currency.unwrap(key.currency1)), 10);
        (uint256 last0, uint256 last1) = _lasts(id);
        uint256 f0 = _fraction(last0, IndexPool(Currency.unwrap(key.currency0)).growthIndex());
        uint256 f1 = _fraction(last1, IndexPool(Currency.unwrap(key.currency1)).growthIndex());
        assertGt(f0, f1 * 2, "different growth");
        vm.prank(alice);
        uint128 removed = positions.harvest(id, 0, 0, FAR);
        assertApproxEqRel(removed, uint256(UNITS) * (f0 + f1) / 2e18, 1e6, "(f0 + f1) / 2");
        (last0, last1) = _lasts(id);
        assertEq(last0, IndexPool(Currency.unwrap(key.currency0)).growthIndex());
        assertEq(last1, IndexPool(Currency.unwrap(key.currency1)).growthIndex());
        _assertEmpty(key);
    }

    // ---------------------------------------------------------------- concentrated

    function testConcentratedInRange() public {
        (uint128 removed, uint256 f0, uint256 f1) = _concentrated(-600, 1200);
        // The reference values each side from the closed form for a position in range,
        // v0 / v1 = s (b - s) / (b (s - a)), not from the amounts the contract uses.
        uint256 s = PRICE_ONE;
        uint256 a = TickMath.getSqrtPriceAtTick(-600);
        uint256 b = TickMath.getSqrtPriceAtTick(1200);
        uint256 v0 = FixedPointMathLib.fullMulDiv(s, b - s, b);
        uint256 v1 = s - a;
        uint256 p = (f0 * v0 + f1 * v1) / (v0 + v1);
        assertApproxEqRel(removed, uint256(UNITS) * p / 1e18, 1e6, "p in range");
        assertGt(v0, v1, "value is uneven, so p is not the plain average");
    }

    function testConcentratedAboveThePrice() public {
        // The range is above the price, so the position is all currency 0 and p is f0.
        (uint128 removed, uint256 f0,) = _concentrated(600, 1200);
        assertApproxEqRel(removed, uint256(UNITS) * f0 / 1e18, 1e6, "f0");
    }

    function testConcentratedBelowThePrice() public {
        // The range is below the price, so the position is all currency 1 and p is f1.
        (uint128 removed,, uint256 f1) = _concentrated(-1200, -600);
        assertApproxEqRel(removed, uint256(UNITS) * f1 / 1e18, 1e6, "f1");
    }

    /// Two index shares grown by different amounts, then one harvest of a position over
    /// `lower..upper` at a price of one.
    function _concentrated(int24 lower, int24 upper)
        internal
        returns (uint128 removed, uint256 f0, uint256 f1)
    {
        IndexPool one = _share();
        IndexPool two = _share();
        PoolKey memory key = _venue(address(one), address(two), address(0));
        _fund(alice, key);
        uint256 id = _open(alice, key, lower, upper, UNITS);
        _grow(IndexPool(Currency.unwrap(key.currency0)), 30);
        _grow(IndexPool(Currency.unwrap(key.currency1)), 5);
        (uint256 last0, uint256 last1) = _lasts(id);
        f0 = _fraction(last0, IndexPool(Currency.unwrap(key.currency0)).growthIndex());
        f1 = _fraction(last1, IndexPool(Currency.unwrap(key.currency1)).growthIndex());
        assertGt(f0, f1 * 3, "different growth");
        assertEq(positions.harvestable(id), _harvest(alice, id));
        removed = UNITS - _liquidity(id);
        _assertEmpty(key);
    }

    function _harvest(address who, uint256 id) internal returns (uint128) {
        vm.prank(who);
        return positions.harvest(id, 0, 0, FAR);
    }

    // ---------------------------------------------------------------- other providers

    /// A second owner's position and liquidity held directly are worth exactly what they
    /// were without the first owner's harvest: removing liquidity at a price moves no
    /// other position's amounts.
    function testOtherProvidersUntouched() public {
        IndexPool share = _share();
        PoolKey memory key = _venue(address(share), _plain(), address(0));
        _fund(alice, key);
        _fund(bob, key);
        _approveProvider(key);
        (int24 lower, int24 upper) = _full();
        uint256 mine = _open(alice, key, lower, upper, UNITS);
        uint256 theirs = _open(bob, key, -1200, 1200, UNITS);
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-600, 600, int256(uint256(UNITS)), 0), ""
        );
        _grow(share, 20);
        _trade(key, 1e20);
        uint256 snapshot = vm.snapshotState();
        uint256[4] memory without = _withdrawOthers(key, theirs);
        vm.revertToState(snapshot);
        uint128 liquidity = _liquidity(theirs);
        (uint256 last0, uint256 last1) = _lasts(theirs);
        assertGt(_harvest(alice, mine), 0);
        (uint256 after0, uint256 after1) = _lasts(theirs);
        assertEq(_liquidity(theirs), liquidity, "second owner's liquidity");
        assertEq(after0, last0, "second owner's baseline 0");
        assertEq(after1, last1, "second owner's baseline 1");
        uint256[4] memory with = _withdrawOthers(key, theirs);
        for (uint256 index; index < 4; index++) {
            assertEq(with[index], without[index], "withdrawn");
        }
    }

    function _approveProvider(PoolKey memory key) internal {
        IndexToken(Currency.unwrap(key.currency0)).approve(address(provider), FAR);
        IndexToken(Currency.unwrap(key.currency1)).approve(address(provider), FAR);
        IndexToken(Currency.unwrap(key.currency0)).approve(address(swapper), FAR);
        IndexToken(Currency.unwrap(key.currency1)).approve(address(swapper), FAR);
        IndexToken(_other(key)).mint(address(this), 1e30);
    }

    function _other(PoolKey memory key) internal view returns (address) {
        address zero = Currency.unwrap(key.currency0);
        return factory.isPool(zero) ? Currency.unwrap(key.currency1) : zero;
    }

    /// v4 fees for every position, so the withdrawals include some.
    function _trade(PoolKey memory key, uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings;
        for (uint256 index; index < 2; index++) {
            bool zeroForOne = index == 0;
            swapper.swap(
                key,
                IPoolManager.SwapParams(
                    zeroForOne,
                    -int256(amount),
                    zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                ),
                settings,
                ""
            );
        }
    }

    /// The second owner closes and the direct provider withdraws everything.
    function _withdrawOthers(PoolKey memory key, uint256 theirs)
        internal
        returns (uint256[4] memory got)
    {
        address zero = Currency.unwrap(key.currency0);
        address one = Currency.unwrap(key.currency1);
        uint256 bob0 = _balance(zero, bob);
        uint256 bob1 = _balance(one, bob);
        vm.prank(bob);
        positions.decrease(theirs, UNITS, 0, 0, FAR);
        got[0] = _balance(zero, bob) - bob0;
        got[1] = _balance(one, bob) - bob1;
        uint256 own0 = _balance(zero, address(this));
        uint256 own1 = _balance(one, address(this));
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-600, 600, -int256(uint256(UNITS)), 0), ""
        );
        got[2] = _balance(zero, address(this)) - own0;
        got[3] = _balance(one, address(this)) - own1;
    }
}
