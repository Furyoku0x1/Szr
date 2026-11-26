// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SizingWalk } from "../../src/arbitrage/lib/SizingWalk.sol";
import { V4Read } from "../../src/arbitrage/lib/V4Read.sol";
import { TestAsset } from "./TestAsset.sol";

/// @dev `SizingWalk` from outside: legs loaded the way the hook's `_load` loads them, and the
/// walk run the way `_walk` runs it, against a real pool manager.
contract SizingWalkHarness {
    IPoolManager public immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    /// A plain pool as a leg: its first state word and liquidity read raw, then its first
    /// boundary found.
    function plainLeg(bytes32 poolId, bool zeroForOne, int24 spacing, uint256 gap)
        external
        view
        returns (SizingWalk.Leg memory leg)
    {
        leg.id = poolId;
        leg.zeroForOne = zeroForOne;
        leg.spacing = spacing;
        bytes32 slot = StateLibrary._getPoolStateSlot(PoolId.wrap(poolId));
        uint256 packed = uint256(manager.extsload(slot));
        uint256 units = uint256(manager.extsload(bytes32(uint256(slot) + 3)));
        SizingWalk._read(leg, packed, units, gap);
        SizingWalk._bound(manager, leg);
    }

    /// A leg read from a pricer's answer, as `_loadWrapped` builds it: no ticks, and the end
    /// of the reported range is the end of the leg.
    function wrappedLeg(
        bytes32 poolId,
        bool zeroForOne,
        uint256 packed,
        uint256 units,
        uint160 end,
        uint256 gap
    ) external pure returns (SizingWalk.Leg memory leg) {
        leg.id = poolId;
        leg.zeroForOne = zeroForOne;
        SizingWalk._read(leg, packed, units, gap);
        leg.target = end;
        leg.edge = true;
        leg.wrapped = true;
        if (leg.target == leg.price) revert SizingWalk.Unsizable();
    }

    /// A leg at a fixed rate with no state, as Core redemption is.
    function fixedLeg(uint256 rate) external pure returns (SizingWalk.Leg memory leg) {
        leg.rate = rate;
        leg.depth = SizingWalk.MAX_DEPTH;
    }

    function read(uint256 packed, uint256 units, bool zeroForOne, uint256 gap)
        external
        pure
        returns (SizingWalk.Leg memory leg)
    {
        leg.zeroForOne = zeroForOne;
        SizingWalk._read(leg, packed, units, gap);
    }

    /// The whole walk over loaded legs, as `_walk` runs it.
    function walk(SizingWalk.Leg[] memory legs, uint256 focus)
        external
        view
        returns (SizingWalk.Walk memory found, SizingWalk.Leg[] memory)
    {
        for (uint256 index; index < legs.length; index++) {
            if (legs[index].wrapped) found.stopped = true;
        }
        for (uint256 round; round <= SizingWalk.SIZING_STEPS; round++) {
            if (!SizingWalk._round(manager, legs, found, focus, round)) break;
        }
        return (found, legs);
    }

    /// One round, for calls made with a set amount of gas.
    function round(SizingWalk.Leg[] memory legs, uint256 focus)
        external
        view
        returns (bool more, SizingWalk.Walk memory found)
    {
        more = SizingWalk._round(manager, legs, found, focus, 0);
    }

    function compose(SizingWalk.Leg[] memory legs)
        external
        pure
        returns (uint256 rate, uint256 depth, bool fits)
    {
        SizingWalk._shapeAll(legs);
        return SizingWalk._compose(legs);
    }

    /// The chain composed as the legs stand, without shaping them first.
    function composed(SizingWalk.Leg[] memory legs)
        external
        pure
        returns (uint256 rate, uint256 depth, bool fits, SizingWalk.Leg[] memory)
    {
        (rate, depth, fits) = SizingWalk._compose(legs);
        return (rate, depth, fits, legs);
    }

    function shape(SizingWalk.Leg memory leg) external pure returns (SizingWalk.Leg memory) {
        SizingWalk._shape(leg);
        return leg;
    }

    function bounded(SizingWalk.Leg[] memory legs, uint256 cycle)
        external
        pure
        returns (uint256 at, uint256 hit, SizingWalk.Leg[] memory)
    {
        (at, hit) = SizingWalk._bounded(legs, cycle);
        return (at, hit, legs);
    }

    function advance(SizingWalk.Leg[] memory legs, uint256 cycle, uint256 focus)
        external
        pure
        returns (uint256 amount, uint256 focusIn)
    {
        return SizingWalk._advance(legs, cycle, legs.length, focus);
    }

    function reach(SizingWalk.Leg memory leg) external pure returns (uint256) {
        return SizingWalk._reach(leg);
    }

    /// Crosses the leg's boundary unless it is the end of the leg.
    function crossed(SizingWalk.Leg memory leg)
        external
        view
        returns (bool ends, SizingWalk.Leg memory)
    {
        ends = SizingWalk._ends(manager, leg);
        if (!ends) SizingWalk._cross(manager, leg);
        return (ends, leg);
    }

    function shaved(uint256 spend) external pure returns (uint256) {
        return SizingWalk._shaved(spend);
    }
}

/// @dev `V4Read` from outside. Trades run inside the pool manager's unlock and are settled
/// from the harness's own balance, which the test funds.
contract V4ReadHarness is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function unpack(bytes32 word, bool baseFirst)
        external
        pure
        returns (uint256 rate, uint24 fee, uint24 levy)
    {
        return V4Read._unpack(word, baseFirst);
    }

    function swapFee(uint24 fee, uint24 levy) external pure returns (uint24) {
        return V4Read._swapFee(fee, levy);
    }

    function keepFast(uint24 fee) external pure returns (uint256) {
        return V4Read._keepFast(fee);
    }

    function keep(uint24 fee) external pure returns (uint256) {
        return V4Read._keep(fee);
    }

    function limitFrom(uint160 price, bool zeroForOne, uint256 gap)
        external
        pure
        returns (uint160)
    {
        return V4Read._limitFrom(price, zeroForOne, gap);
    }

    function harmonic(uint256 a, uint256 b) external pure returns (uint256) {
        return V4Read._harmonic(a, b);
    }

    function funded(Currency asset, uint256 amount, bool payout) external view {
        V4Read._funded(manager, asset, amount, payout);
    }

    /// Runs `_trade` and settles it: pays what it spent and takes what it received.
    function trade(PoolKey memory pool, address input, int256 amount, uint160 limit)
        external
        returns (uint256 spent, uint256 received)
    {
        bytes memory result = manager.unlock(abi.encode(pool, input, amount, limit));
        return abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory pool, address input, int256 amount, uint160 limit) =
            abi.decode(data, (PoolKey, address, int256, uint160));
        (uint256 spent, uint256 received) = V4Read._trade(manager, pool, input, amount, limit);
        bool first = Currency.unwrap(pool.currency0) == input;
        Currency output = first ? pool.currency1 : pool.currency0;
        manager.sync(Currency.wrap(input));
        TestAsset(input).transfer(address(manager), spent);
        manager.settle();
        manager.take(output, address(this), received);
        return abi.encode(spent, received);
    }
}

/// @dev A bare pool manager and two tokens, for tests of the libraries alone, with helpers
/// to open hookless pools and give them liquidity.
abstract contract LibraryWorld is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal provider;
    PoolSwapTest internal swapper;
    TestAsset internal tokenA;
    TestAsset internal tokenB;
    /// The pools' token order: `token0` sorts below `token1`.
    address internal token0;
    address internal token1;

    function setUp() public virtual {
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        provider = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        tokenA = new TestAsset();
        tokenB = new TestAsset();
        (token0, token1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));
        _fund(tokenA, address(this));
        _fund(tokenB, address(this));
    }

    function _fund(TestAsset asset, address holder) internal {
        asset.mint(holder, 1e36);
        vm.prank(holder);
        asset.approve(address(provider), type(uint256).max);
        vm.prank(holder);
        asset.approve(address(swapper), type(uint256).max);
    }

    /// A hookless pool of the two tokens at `price`, with `units` of liquidity over the whole
    /// tick range. `fee` also tells pools of the same price apart.
    function _pool(uint24 fee, int24 spacing, uint160 price, uint128 units)
        internal
        returns (PoolKey memory key)
    {
        key = PoolKey(
            Currency.wrap(token0), Currency.wrap(token1), fee, spacing, IHooks(address(0))
        );
        manager.initialize(key, price);
        int24 top = TickMath.maxUsableTick(spacing);
        _position(key, -top, top, units);
    }

    function _position(PoolKey memory key, int24 lower, int24 upper, uint128 units) internal {
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, upper, int256(uint256(units)), 0), ""
        );
    }

    function _id(PoolKey memory key) internal pure returns (bytes32) {
        return PoolId.unwrap(key.toId());
    }

    /// An exact-input swap to `limit` through the test router, and what it paid in.
    function _swapTo(PoolKey memory key, bool zeroForOne, uint160 limit)
        internal
        returns (uint256 spent)
    {
        uint256 before = TestAsset(zeroForOne ? token0 : token1).balanceOf(address(this));
        swapper.swap(
            key,
            IPoolManager.SwapParams(zeroForOne, -int256(uint256(1e30)), limit),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        spent = before - TestAsset(zeroForOne ? token0 : token1).balanceOf(address(this));
    }
}
