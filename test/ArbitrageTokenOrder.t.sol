// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { ArbitrageHoleEdgeTest } from "./ArbitrageHoleEdge.t.sol";
import { ArbitrageHoleAheadTest } from "./ArbitrageHoleAhead.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IHookVault } from "../src/interfaces/IHookVault.sol";
import { Vm } from "forge-std/Vm.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

/// @dev Token order (docs/specs/hook-fund-safety-tests.md, item 2, 28-T-3). Every other world
/// puts SZR second in its pools; here every token is made above SZR's address, so SZR is
/// currency0 of every pool it is in, and the market's base token is currency0 of its pools.
contract ArbitrageTokenOrderTest is ArbitrageWorld {
    function _newAsset() internal override returns (TestAsset) {
        return _highAsset();
    }

    function _openGap(PoolKey memory pool, address input, uint256 amount) internal {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(pool, input, amount);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
    }

    function testTheWorldPutsSzrFirst() public view {
        assertEq(Currency.unwrap(mainPool.currency0), address(szr), "main pool");
        assertEq(Currency.unwrap(usdPool.currency0), address(szr), "usd pool");
    }

    /// A sale and a purchase each open a gap that `arb` closes, retiring SZR at Core, and
    /// the hook holds nothing.
    function testCyclesInBothDirectionsWithSzrFirst() public {
        uint256 inventory = core.unreleasedSupply();
        _openGap(usdPool, address(szr), 50_000e18);
        assertGt(hook.arb(_id(usdPool)), 0, "sale gap closed");
        assertGt(core.unreleasedSupply(), inventory, "SZR retired");
        _assertHookEmpty();
        inventory = core.unreleasedSupply();
        _openGap(usdPool, address(usd), 50_000e18);
        assertGt(hook.arb(_id(usdPool)), 0, "purchase gap closed");
        assertGt(core.unreleasedSupply(), inventory, "SZR retired again");
        _assertHookEmpty();
    }

    /// The pool below NAV redeems at Core, with SZR as the pool's first token.
    function testCoreRedemptionWithSzrFirst() public {
        uint256 nav = _poolAtNavRatio(0.9e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 cash = core.reserveCash();
        assertGt(hook.arb(_id(usdPool)), 0, "arb redeems at Core");
        assertGt(core.unreleasedSupply(), inventory, "SZR retired");
        assertLt(core.reserveCash(), cash, "Core paid WETH");
        assertGe(core.NAV(), nav, "NAV never falls");
        _assertHookEmpty();
    }

    /// An outside market cannot take a hookless SZR pool, with SZR first in it.
    function testOutsideMarketRefusesAnSzrPoolWithSzrFirst() public {
        vm.prank(address(0xA7));
        uint256 market = hook.openMarket(address(0xA8));
        assertEq(Currency.unwrap(mainPool.currency0), address(szr));
        vm.prank(address(0xA7));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.addVenue(market, mainPool);
    }

    /// A vault cannot be built over a pool of SZR, with SZR as its first token.
    function testVaultRefusesAnSzrPoolWithSzrFirst() public {
        vm.prank(address(0xA7));
        uint256 market = hook.openMarket(address(0xA8));
        PoolKey memory home = PoolKey(
            Currency.wrap(address(szr)),
            Currency.wrap(address(usd)),
            3_000,
            60,
            IHooks(address(hook))
        );
        vm.expectRevert(IHookVault.InvalidPair.selector);
        deployCode(
            "ArbitrageVault.sol:ArbitrageVault",
            abi.encode(hook, market, home, address(0xC0), address(0), uint16(0))
        );
    }
}

/// @dev An outside market whose base (WETH) sorts before its partner coin.
contract ArbitrageTokenOrderOutsideTest is MarketsWorld {
    function _newAsset() internal override returns (TestAsset) {
        return _highAsset();
    }

    function testBaseIsFirstInItsPools() public view {
        assertEq(Currency.unwrap(first.currency0), address(backing), "WETH first");
    }

    /// A sale and a purchase in the market's pools each close with a cycle in WETH, and the
    /// profit splits exactly 30% and 70%.
    function testCyclesInBothDirectionsSplitExactly() public {
        uint256 protocol = backing.balanceOf(address(core));
        _trade(first, address(coin), 50_000e18);
        uint256 kept = backing.balanceOf(treasury);
        uint256 share = backing.balanceOf(address(core)) - protocol;
        assertGt(kept, 0, "team paid for the sale");
        _assertThirty(share, kept + share);
        protocol = backing.balanceOf(address(core));
        uint256 keptBefore = backing.balanceOf(treasury);
        _trade(second, address(backing), 50_000e18);
        uint256 kept2 = backing.balanceOf(treasury) - keptBefore;
        uint256 share2 = backing.balanceOf(address(core)) - protocol;
        assertGt(kept2, 0, "team paid for the purchase");
        _assertThirty(share2, kept2 + share2);
        _assertNothingHeld();
    }

    /// `setLeaders` takes only pools whose first token is the lower of base and partner and
    /// whose second is the higher. A pool of WETH and coin, named as the leader of the
    /// (WETH, USD) group, has the right first token and the wrong second one.
    function testSetLeadersChecksTheSecondToken() public {
        assertEq(Currency.unwrap(first.currency0), address(backing));
        assertTrue(address(backing) < address(usd));
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(id, address(backing), address(usd), _list(_id(first)));
    }
}

/// @dev The stand-in work's edge tests with SZR first in the focus pool: its clamp compares a
/// boundary price with the candidate's limit the other way round.
contract ArbitrageTokenOrderHoleEdgeTest is ArbitrageHoleEdgeTest {
    function _newAsset() internal override returns (TestAsset) {
        return _highAsset();
    }

    /// The upper-edge controls earn 576 to 582 SZR here, against 721 with SZR second; the
    /// check that matters, that the edge swap's gap is taken as well, is unchanged.
    function controlFloor() internal pure override returns (uint256) {
        return 500e18;
    }
}

contract ArbitrageTokenOrderHoleAheadTest is ArbitrageHoleAheadTest {
    function _newAsset() internal override returns (TestAsset) {
        return _highAsset();
    }
}
