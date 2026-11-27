// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { ISzrLiquidity } from "../src/interfaces/ISzrModules.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { IndexToken } from "./utils/IndexWorld.sol";

/// @dev A position on a pool of the real arbitrage hook, which has only swap permissions.
contract IndexPositionsHookTest is ArbitrageWorld {
    uint256 internal constant FAR = type(uint256).max;

    function testAcceptsAPoolOnTheArbitrageHook() public {
        IndexPoolFactory indexFactory =
            new IndexPoolFactory(ISzrLiquidity(address(locker)), makeAddr("protocol"));
        IndexPool share = _share(indexFactory);
        IndexPositions positions = new IndexPositions(manager, address(indexFactory));
        bool shareFirst = address(share) < address(usd);
        PoolKey memory key = PoolKey(
            Currency.wrap(shareFirst ? address(share) : address(usd)),
            Currency.wrap(shareFirst ? address(usd) : address(share)),
            3000,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, uint160(1 << 96));
        share.approve(address(positions), FAR);
        usd.approve(address(positions), FAR);
        share.approve(address(swapper), FAR);
        uint256 id = positions.open(
            key, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 1e21, FAR, FAR, FAR
        );
        // Swaps through the pool run the hook.
        vm.expectCall(address(hook), abi.encodePacked(IHooks.beforeSwap.selector));
        _trade(key, address(share), 1e18);
        _trade(key, address(usd), 1e18);
        address[] memory list = share.tokens();
        for (uint256 index; index < 10; index++) {
            (, uint256 got) = share.swap(list[0], list[1], 5e22, true, 0, address(this), FAR);
            share.swap(list[1], list[0], got, true, 0, address(this), FAR);
        }
        assertGt(positions.harvest(id, 0, 0, FAR), 0);
        assertEq(share.balanceOf(address(positions)), 0);
        assertEq(usd.balanceOf(address(positions)), 0);
    }

    function _share(IndexPoolFactory indexFactory) internal returns (IndexPool pool) {
        address one = address(new IndexToken(18));
        address two = address(new IndexToken(18));
        address[] memory list = new address[](2);
        (list[0], list[1]) = one < two ? (one, two) : (two, one);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5e17;
        weights[1] = 5e17;
        pool = IndexPool(
            indexFactory.create("Index", "IDX", list, weights, 3e15, address(0), 0)
        );
        uint256[] memory amounts = new uint256[](2);
        for (uint256 index; index < 2; index++) {
            IndexToken(list[index]).mint(address(this), 1e30);
            IndexToken(list[index]).approve(address(pool), FAR);
            amounts[index] = 1e24;
        }
        pool.start(amounts, 1e24, FAR);
    }
}
