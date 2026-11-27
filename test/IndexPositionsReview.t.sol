// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { PositionsWorld } from "./IndexPositions.t.sol";

/// @dev A hook with every liquidity callback and no return delta, which calls back into
/// `IndexPositions` from each one once armed and records what happened.
contract HostileHook {
    address public target;
    bytes public reentry;
    uint256 public attempts;
    uint256 public refused;

    function arm(address target_, bytes calldata reentry_) external {
        target = target_;
        reentry = reentry_;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        _reenter();
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _reenter();
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external returns (bytes4) {
        _reenter();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external returns (bytes4, BalanceDelta) {
        _reenter();
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function _reenter() internal {
        if (target == address(0)) return;
        attempts++;
        (bool ok, bytes memory error) = target.call(reentry);
        if (ok) return;
        if (bytes4(error) == ReentrancyGuard.Reentrancy.selector) refused++;
    }
}

/// @dev The review round's cases: an index that cannot be read, a price far from one, a
/// fee-on-transfer token and a hook that calls back in.
contract IndexPositionsReviewTest is PositionsWorld {
    /// A donation past the index's bound makes `growthIndex` revert. The owner can still
    /// decrease and is paid both currencies; only a harvest, which needs the index, reverts.
    function testAnUnreadableIndexNeverLocksLiquidity() public {
        IndexPool share = _pool(_pair(0, 18), _weights(99e16, 1e16), 1e6, address(0), 0);
        PoolKey memory key = _venue(address(share), _plain(), address(0));
        _fund(alice, key);
        (int24 lower, int24 upper) = _full();
        uint256 id = _open(alice, key, lower, upper, UNITS);
        address whole = IndexToken(share.tokens()[0]).decimals() == 0
            ? share.tokens()[0]
            : share.tokens()[1];
        IndexToken(whole).mint(address(this), 1e62);
        share.donate(whole, 1e62);
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert();
        share.growthIndex();
        address zero = Currency.unwrap(key.currency0);
        address one = Currency.unwrap(key.currency1);
        uint256 before0 = _balance(zero, alice);
        uint256 before1 = _balance(one, alice);
        vm.prank(alice);
        positions.decrease(id, UNITS / 2, 0, 0, FAR);
        assertGt(_balance(zero, alice), before0, "paid currency 0");
        assertGt(_balance(one, alice), before1, "paid currency 1");
        (uint256 last0, uint256 last1) = _lasts(id);
        bool first = zero == address(share);
        assertEq(first ? last0 : last1, type(uint256).max, "no growth counts");
        vm.prank(alice);
        positions.increase(id, 1e18, FAR, FAR, FAR);
        vm.prank(alice);
        vm.expectRevert();
        positions.harvest(id, 0, 0, FAR);
        // A new position is refused while the index cannot be read.
        vm.prank(alice);
        vm.expectRevert();
        positions.open(key, lower, upper, UNITS, FAR, FAR, FAR);
    }

    /// In range at a price near 10, against the closed form `v0 / v1 = s (b - s) / (b (s - a))`.
    function testConcentratedAtAPriceFarFromOne() public {
        IndexPool one = _share();
        IndexPool two = _share();
        PoolKey memory key = _key(address(one), address(two), address(0));
        uint160 s = TickMath.getSqrtPriceAtTick(23_040);
        manager.initialize(key, s);
        _fund(alice, key);
        uint256 id = _open(alice, key, 18_000, 30_000, UNITS);
        _grow(IndexPool(Currency.unwrap(key.currency0)), 30);
        _grow(IndexPool(Currency.unwrap(key.currency1)), 5);
        (uint256 last0, uint256 last1) = _lasts(id);
        uint256 f0 = _fraction(last0, IndexPool(Currency.unwrap(key.currency0)).growthIndex());
        uint256 f1 = _fraction(last1, IndexPool(Currency.unwrap(key.currency1)).growthIndex());
        uint256 a = TickMath.getSqrtPriceAtTick(18_000);
        uint256 b = TickMath.getSqrtPriceAtTick(30_000);
        uint256 v0 = FixedPointMathLib.fullMulDiv(s, b - s, b);
        uint256 v1 = s - a;
        uint256 p = (f0 * v0 + f1 * v1) / (v0 + v1);
        vm.prank(alice);
        uint128 removed = positions.harvest(id, 0, 0, FAR);
        assertApproxEqRel(removed, uint256(UNITS) * p / 1e18, 1e6, "p at a price near 10");
        _assertEmpty(key);
    }

    function testFeeOnTransferTokenRefused() public {
        IndexPool share = _share();
        address taxed = _plain();
        PoolKey memory key = _venue(address(share), taxed, address(0));
        _fund(alice, key);
        IndexToken(taxed).setFee(100);
        (int24 lower, int24 upper) = _full();
        vm.prank(alice);
        vm.expectRevert(IndexPositions.TransferAmountMismatch.selector);
        positions.open(key, lower, upper, UNITS, FAR, FAR, FAR);
    }

    /// Every call back in from the hook's liquidity callbacks is refused, and another owner's
    /// position in the same pool is unchanged.
    function testHookCallingBackInIsRefused() public {
        uint160 flags = Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        address at = address(uint160(0xC1 << 152) | flags);
        vm.etch(at, address(new HostileHook()).code);
        HostileHook hook = HostileHook(at);
        IndexPool share = _share();
        PoolKey memory key = _venue(address(share), _plain(), at);
        _fund(alice, key);
        _fund(bob, key);
        (int24 lower, int24 upper) = _full();
        uint256 theirs = _open(bob, key, lower, upper, UNITS);
        (uint256 last0, uint256 last1) = _lasts(theirs);
        hook.arm(
            address(positions),
            abi.encodeCall(IndexPositions.decrease, (theirs, UNITS, 0, 0, FAR))
        );
        uint256 mine = _open(alice, key, lower, upper, UNITS);
        vm.prank(alice);
        positions.decrease(mine, UNITS / 2, 0, 0, FAR);
        assertEq(hook.attempts(), 4, "every callback called back in");
        assertEq(hook.refused(), 4, "and each was refused");
        assertEq(_liquidity(theirs), UNITS, "the other owner's liquidity");
        (uint256 now0, uint256 now1) = _lasts(theirs);
        assertEq(now0, last0);
        assertEq(now1, last1);
        _assertEmpty(key);
    }
}
