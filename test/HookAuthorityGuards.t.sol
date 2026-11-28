// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { AuthoritySetup } from "./HookAuthority.t.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { HookAuthority } from "../src/HookAuthority.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { DeployHookAuthority } from "../script/DeployHookAuthority.s.sol";
import { ConfigureArbitrageHook } from "../script/ConfigureArbitrageHook.s.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The rest of `HookAuthorityTest`, in a file of its own because that contract is near
/// the size limit: the documented `addVenue(1, ...)` case and the deploy script's checks.
contract HookAuthorityGuardsTest is MarketsWorld, AuthoritySetup {
    address internal protocol = address(0x7EA7);

    function _wethShareRecipient() internal view override returns (address) {
        return address(authority);
    }

    function setUp() public override(MarketsWorld, ArbitrageWorld) {
        MarketsWorld.setUp();
    }

    function _hookLiquidity() internal override returns (Liquidity) {
        return _authorityLiquidity();
    }

    function _setupSzrMarket() internal override {
        _authoritySzrMarket();
    }

    function _configure() internal {
        ConfigureArbitrageHook.Config memory plan;
        plan.hook = hook;
        plan.treasury = protocol;
        plan.swapGasCeiling = 12_000_000;
        new ConfigureArbitrageHook().run(plan);
    }

    /// The documented case: the manager can add a priced pool that holds the authority's address
    /// to market 1 (market 1 is off once configured). Nothing moves; switching the market on
    /// makes `arb` revert on the authority's missing `NAV`; an outside market still works.
    function testTheManagerCanAddAnAuthorityPoolToMarketOneAndNothingMoves() public {
        _configure();
        WrappedPool wrapper =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        hook.setPricer(address(wrapper), address(new WrappedPricer(wrapper)));
        PoolKey memory pool =
            _pair(address(authority), address(backing), 3_000, address(wrapper));
        manager.initialize(pool, uint160(1 << 96));
        wrapper.seed(pool, 1_000_000e18, 1_000_000e18);
        vm.prank(alice);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.addVenue(1, pool);
        uint256 authorityWeth = backing.balanceOf(address(authority));
        uint256 hookWeth = backing.balanceOf(address(hook));
        hook.addVenue(1, pool);
        assertTrue(hook.tracked(1, _id(pool)), "added by the manager");
        hook.setLimits(1, address(authority), uint32(hook.minimumGasLimit(1)), 10e18, 1.0001e18);
        vm.expectRevert();
        hook.arb(_id(pool));
        // `sweep` runs its searches in caught calls, so it ends quietly with nothing.
        assertEq(hook.sweep(1, address(authority)), 0, "nothing swept");
        _trade(first, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "an outside market still pays");
        assertEq(backing.balanceOf(address(hook)), hookWeth, "the hook holds nothing");
        assertGe(
            backing.balanceOf(address(authority)), authorityWeth, "nothing left the authority"
        );
    }

    function testTheDeployScriptChecksItsInputs() public {
        DeployHookAuthority script = new DeployHookAuthority();
        vm.expectRevert(DeployHookAuthority.WrongChain.selector);
        script.run(block.chainid + 1, address(manager), address(backing), address(this));
        vm.expectRevert(DeployHookAuthority.MissingPoolManager.selector);
        script.run(block.chainid, address(0xBAD), address(backing), address(this));
        vm.expectRevert(DeployHookAuthority.MissingWeth.selector);
        script.run(block.chainid, address(manager), address(0xBAD), address(this));
        // The world's WETH has no `deposit()`; a WETH has to wrap.
        vm.expectRevert(DeployHookAuthority.WethDoesNotWrap.selector);
        script.run(block.chainid, address(manager), address(backing), address(this));
        vm.etch(address(backing), address(new WrappingAsset()).code);
        HookAuthority made =
            script.run(block.chainid, address(manager), address(backing), address(0xA7));
        assertEq(made.manager(), address(0xA7));
    }
}
