// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { ArbitrageMarketsTest, MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { ArbitrageMultiTokenTest, MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { AuthoritySetup } from "./HookAuthority.t.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { ConfigureArbitrageHook } from "../script/ConfigureArbitrageHook.s.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The existing outside-market suites, run unchanged on a hook built over a
/// `HookAuthority` (docs/specs/hook-authority.md, test 9). The world differs only in what the
/// hook is deployed against and in SZR's market being left empty. SZR's Core is still in the
/// world, as the place the suites expect WETH's protocol share. The authority has no Core
/// functions, but a call to one that reverted inside a caught search would be swallowed, not
/// fail a suite: the `vm.expectCall(..., 0)` checks in `HookAuthority.t.sol` are the
/// evidence that none is made.
contract HookAuthorityMarketsSuite is ArbitrageMarketsTest, AuthoritySetup {
    function setUp() public override(MarketsWorld, ArbitrageWorld) {
        MarketsWorld.setUp();
    }

    function _hookLiquidity() internal override returns (Liquidity) {
        return _authorityLiquidity();
    }

    function _setupSzrMarket() internal override {
        _authoritySzrMarket();
    }

    /// These three are about SZR's market and its pools (`usdPool`, `mainPool`, Core), which
    /// the authority's world does not have.
    function testConnectingPoolRules() public override {
        vm.skip(true);
    }

    function testHookedPoolsJoinOnlyByBeingCreatedThroughTheHook() public override {
        vm.skip(true);
    }

    function testMarketsAreSearchedApart() public override {
        vm.skip(true);
    }
}

contract HookAuthorityMultiTokenSuite is ArbitrageMultiTokenTest, AuthoritySetup {
    function setUp() public override(MultiWorld, ArbitrageWorld) {
        MultiWorld.setUp();
    }

    function _hookLiquidity() internal override returns (Liquidity) {
        return _authorityLiquidity();
    }

    function _setupSzrMarket() internal override {
        _authoritySzrMarket();
    }

    /// The base test asserts the price fell, which holds only for one order of the two tokens'
    /// addresses, and that order differs from one test contract to another. Here the pool's
    /// price moves, in whichever direction, and nothing is searched or paid.
    function testPoolThatIsNotAConnectorIsNotSearched() public override {
        vm.prank(team);
        hook.setConnector(id, stable, false);
        uint256 price = _price(stable);
        _trade(stable, address(coin), 50_000e18);
        assertTrue(_price(stable) != price, "the swap moved its pool");
        assertEq(backing.balanceOf(treasury), 0, "no search in WETH");
        assertEq(usd.balanceOf(treasury), 0, "nor in USD");
        _assertNothingHeld();
    }
}

/// @dev Native ETH as a profit token under the authority. `ArbitrageNativeTest` is too large
/// to inherit (its constructor passes the contract size limit), so this is a representative
/// part of it: the ETH split test, after authority-mode configure.
contract HookAuthorityNativeTest is MarketsWorld, AuthoritySetup {
    address internal protocol = address(0x7EA7);

    receive() external payable { }

    function setUp() public override(MarketsWorld, ArbitrageWorld) {
        MarketsWorld.setUp();
        // The world's WETH has no `deposit()`; the real one does.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(this), 1e30);
        ConfigureArbitrageHook.Config memory plan;
        plan.hook = hook;
        plan.treasury = protocol;
        plan.swapGasCeiling = 12_000_000;
        new ConfigureArbitrageHook().run(plan);
        vm.startPrank(team);
        id = hook.openMarket(treasury);
        address[] memory only = new address[](1);
        only[0] = address(0);
        hook.setTokens(id, only);
        vm.stopPrank();
    }

    function _hookLiquidity() internal override returns (Liquidity) {
        return _authorityLiquidity();
    }

    function _setupSzrMarket() internal override {
        _authoritySzrMarket();
    }

    function _make(address one, address other, uint24 fee, address hooks)
        internal
        returns (PoolKey memory pool)
    {
        pool = _pair(one, other, fee, hooks);
        if (hooks == address(hook)) {
            vm.prank(team);
            hook.createPool(id, pool, uint160(1 << 96));
        } else {
            manager.initialize(pool, uint160(1 << 96));
        }
        uint256 units = 1_000_000e18;
        uint256 value = Currency.unwrap(pool.currency0) == address(0) ? units * 2 : 0;
        provider.modifyLiquidity{ value: value }(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(units), 0
            ),
            ""
        );
    }

    function _in(PoolKey memory pool, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap{ value: input == address(0) ? amount : 0 }(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
    }

    /// Native ETH as a profit token: after authority-mode configure the market is paid 70%
    /// and the treasury 30% of an ETH profit, both as WETH, never as ether.
    function testEthProfitIsPaidAsWethAndSplit() public {
        PoolKey memory hooked = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory open = _make(address(0), address(coin), 500, address(0));
        vm.prank(team);
        hook.addVenue(id, open);
        _lead(address(0), address(coin), _list(_id(hooked), _id(open)));
        _limits(address(0), 1e15);
        _in(open, address(coin), 50_000e18);
        _in(hooked, address(coin), 1_000e18);
        uint256 share = backing.balanceOf(protocol);
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "the market is paid in WETH");
        _assertThirty(share, kept + share);
        assertEq(address(hook).balance, 0, "no ether held");
        assertEq(protocol.balance, 0, "the treasury was paid WETH, not ether");
        assertEq(treasury.balance, 0, "and so was the market");
    }
}
