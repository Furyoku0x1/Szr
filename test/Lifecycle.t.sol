// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { LaunchWorld } from "./utils/LaunchWorld.sol";

/// @notice The whole launch, start to finish, through the real deploy script, with SZR on
/// either side of the pool. On Robinhood Chain WETH's address is low, so SZR will almost
/// certainly be currency1; both orderings must behave the same.
contract LifecycleTest is LaunchWorld {
    function _lifecycle(bool szrFirst) internal {
        PoolKey memory pool = locker.key(0);
        assertEq(Currency.unwrap(pool.currency0) == address(szr), szrFirst, "ordering");
        assertTrue(locker.initialLiquidityFunded());
        uint256 genesis = core.activeSupply();
        assertGt(genesis, GENESIS - 1e18);
        assertEq(core.NAV(), 0);
        _books();

        // Migration: NAV is what was recovered, shared with the genesis tokens.
        vm.prank(alice);
        uint256 recovered = migrator.migrate(100_000_000e18, 0, block.timestamp);
        vm.prank(bob);
        recovered += migrator.migrate(50_000_000e18, 0, block.timestamp);
        assertEq(core.NAV(), recovered * 1e18 / (genesis + 150_000_000e18));
        _books();

        // The genesis pool: the first buy pays at least the configured start price.
        uint256 before = szr.balanceOf(carol);
        _poolSwap(carol, true, 1e18);
        uint256 bought = szr.balanceOf(carol) - before;
        assertGt(bought, 0);
        assertLe(bought, 1e18 * 1e18 / PRICE, "bought below the genesis start price");
        assertGt(bought, 1e18 * 1e18 / PRICE * 95 / 100, "genesis start far above the setting");
        _poolSwap(carol, false, bought / 2);
        uint256 cash = core.reserveCash();
        uint256 inventory = core.unreleasedSupply();
        locker.collect(locker.INITIAL_POSITION());
        assertGt(core.reserveCash(), cash, "weth fees reached reserves");
        assertGt(core.unreleasedSupply(), inventory, "szr fees were recycled");
        assertGt(core.economics().claimableFees(), 0);
        _books();

        // Closing opens the sale; every sale pays at least 1.5x NAV and raises NAV.
        vm.prank(team);
        core.closeMigration();
        vm.warp(block.timestamp + 3 days);
        uint256 nav = core.NAV();
        (uint256 payment,, uint256 funding) = core.quote(500_000e18);
        assertGe(payment * 2, core.backingRequired(500_000e18) * 3);
        vm.prank(carol);
        core.buy(500_000e18, payment, block.timestamp);
        assertGt(core.NAV(), nav);
        assertEq(locker.unallocatedFunding(), funding);
        _books();
        _manage(pool, funding);
        _loansAndExits();
    }

    /// The team turns sale funding into liquidity in one batch, then unwinds part of it.
    function _manage(PoolKey memory pool, uint256 funding) internal {
        bool wethIn = Currency.unwrap(pool.currency0) == address(backing);
        Liquidity.Bounds memory open =
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            locker.swapPrincipal,
            (
                pool,
                wethIn,
                funding / 2,
                1,
                wethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                block.timestamp
            )
        );
        calls[1] = abi.encodeCall(locker.deployPrincipal, (0, 1e18, open));
        uint256 nav = core.NAV();
        vm.prank(team);
        locker.multicall(calls);
        assertEq(locker.liquidityHeld(0), 1e18);
        vm.prank(team);
        locker.withdrawPrincipal(0, 5e17, 0, 0, block.timestamp);
        assertGe(core.NAV(), nav);
        _books();
    }

    function _loansAndExits() internal {
        uint256 nav = core.NAV();
        vm.startPrank(alice);
        core.borrow(1_000_000e18, core.backingRequired(1_000_000e18) - 1);
        vm.stopPrank();
        (,, uint256 expiry) = core.loans(alice);
        vm.warp(expiry);
        core.settleExpired(alice);
        assertGe(core.NAV(), nav);
        _books();
        address[3] memory users = [alice, bob, carol];
        for (uint256 index; index < 3; index++) {
            uint256 held = szr.balanceOf(users[index]);
            uint256 expected =
                FixedPointMathLib.fullMulDiv(held, core.backingAmount(), core.activeSupply());
            vm.prank(users[index]);
            assertEq(core.redeem(held, 0), expected);
        }
        assertGe(core.NAV(), nav);
        _books();
    }

    function testLifecycleWithSzrAsCurrency0() public {
        _world(address(uint160(type(uint160).max - 4096)));
        _lifecycle(true);
    }

    function testLifecycleWithSzrAsCurrency1() public {
        _world(address(0x1000));
        _lifecycle(false);
    }
}
