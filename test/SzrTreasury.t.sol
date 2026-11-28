// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { SzrWorld } from "./utils/SzrWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { MockMetricFactory, MockMetricPool } from "./utils/metric/MockMetricPool.sol";
import { DeploySzrTreasury } from "../script/DeploySzrTreasury.s.sol";
import { SzrTreasury } from "../src/SzrTreasury.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { SzrEconomics } from "../src/SzrEconomics.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../src/index/IndexPoolFactory.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Built from the artifact: the treasury carries the whole index pool factory in its
/// creation code, which would put every test contract that embeds it over the size limit.
function _treasury(SzrCore core, IPoolManager poolManager, IMetricFactory factory)
    returns (SzrTreasury)
{
    Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    return SzrTreasury(
        payable(vm.deployCode(
                "SzrTreasury.sol:SzrTreasury", abi.encode(core, poolManager, factory)
            ))
    );
}

/// @dev The SZR test world with a treasury, a WETH that wraps, and builders for every venue
/// the treasury can route through. This contract is Liquidity's manager and the team's
/// beneficiary, as in `SzrWorld`.
abstract contract TreasuryWorld is SzrWorld {
    uint256 internal constant FAR = type(uint256).max;

    SzrTreasury internal treasury;
    TestAsset internal coin;
    TestAsset internal usdg;
    TestAsset internal szrToken;
    PoolModifyLiquidityTest internal provider;
    MockMetricFactory internal metricFactory;
    IndexPoolFactory internal indexFactory;
    // Core's reserves and the beneficiary's WETH when a back began.
    uint256 internal reserveBefore;
    uint256 internal paidBefore;

    receive() external payable { }

    function setUp() public virtual override {
        super.setUp();
        // Keeps the balances and adds the real token's wrapping.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(backing), 1_000_000e18);
        vm.deal(address(this), 1_000_000e18);
        metricFactory = new MockMetricFactory();
        treasury = _treasury(core, manager, IMetricFactory(address(metricFactory)));
        indexFactory = treasury.indexFactory();
        provider = new PoolModifyLiquidityTest(manager);
        szrToken = TestAsset(address(core.token()));
        coin = new TestAsset();
        usdg = new TestAsset();
        _approveAll(backing);
        _approveAll(coin);
        _approveAll(usdg);
    }

    function _approveAll(TestAsset asset) internal {
        asset.mint(address(this), 100_000_000e18);
        asset.approve(address(provider), type(uint256).max);
    }

    function _sorted(address one, address two) internal pure returns (address, address) {
        return one < two ? (one, two) : (two, one);
    }

    /// A hookless v4 pool at price one, deep enough that a trade only costs the fee. Either
    /// token may be zero for native ETH.
    function _v4Pool(address one, address two) internal returns (PoolKey memory key) {
        (address low, address high) = _sorted(one, two);
        key = PoolKey(Currency.wrap(low), Currency.wrap(high), 3_000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        uint256 value = low == address(0) ? 20_000e18 : 0;
        provider.modifyLiquidity{ value: value }(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(10_000e18), 0
            ),
            ""
        );
    }

    /// A Metric pool at price one holding plenty of both tokens.
    function _metricPool(address one, address two) internal returns (MockMetricPool pool) {
        (address low, address high) = _sorted(one, two);
        pool = new MockMetricPool(address(metricFactory), low, high, 1, 1, uint128(1 << 64));
        metricFactory.register(address(pool));
        TestAsset(low).mint(address(pool), 1_000_000e18);
        TestAsset(high).mint(address(pool), 1_000_000e18);
    }

    /// A started index pool of two equal-weight tokens whose protocol is the treasury.
    function _indexPool(address one, address two) internal returns (IndexPool pool) {
        (address low, address high) = _sorted(one, two);
        address[] memory list = new address[](2);
        list[0] = low;
        list[1] = high;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        pool = IndexPool(indexFactory.create("T", "T", list, weights, 3e15, address(0), 0));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100_000e18;
        amounts[1] = 100_000e18;
        for (uint256 index; index < 2; index++) {
            TestAsset(list[index]).mint(address(this), 100_000e18);
            TestAsset(list[index]).approve(address(pool), type(uint256).max);
        }
        pool.start(amounts, 1e24, FAR);
    }

    function _noKey() internal pure returns (PoolKey memory key) { }

    function _v4Hop(PoolKey memory key, address out)
        internal
        pure
        returns (SzrTreasury.Hop memory)
    {
        return SzrTreasury.Hop(SzrTreasury.Venue.V4, key, address(0), out);
    }

    function _metricHop(address pool, address out)
        internal
        pure
        returns (SzrTreasury.Hop memory)
    {
        PoolKey memory none;
        return SzrTreasury.Hop(SzrTreasury.Venue.METRIC, none, pool, out);
    }

    function _indexHop(address pool, address out)
        internal
        pure
        returns (SzrTreasury.Hop memory)
    {
        PoolKey memory none;
        return SzrTreasury.Hop(SzrTreasury.Venue.INDEX, none, pool, out);
    }

    function _route(SzrTreasury.Hop memory one)
        internal
        pure
        returns (SzrTreasury.Hop[] memory r)
    {
        r = new SzrTreasury.Hop[](1);
        r[0] = one;
    }

    function _route(SzrTreasury.Hop memory one, SzrTreasury.Hop memory two)
        internal
        pure
        returns (SzrTreasury.Hop[] memory r)
    {
        r = new SzrTreasury.Hop[](2);
        r[0] = one;
        r[1] = two;
    }

    function _empty() internal pure returns (SzrTreasury.Hop[] memory) {
        return new SzrTreasury.Hop[](0);
    }

    function _mark() internal {
        reserveBefore = core.reserveCash();
        paidBefore = backing.balanceOf(core.economics().beneficiary());
    }

    /// Funds the treasury with `amount` of `asset` and backs it along `route`.
    function _back(TestAsset asset, uint256 amount, SzrTreasury.Hop[] memory route)
        internal
        returns (uint256 backed, uint256 teamFee)
    {
        asset.mint(address(treasury), amount);
        _mark();
        return treasury.back(address(asset), amount, route, 1, FAR);
    }

    /// What `back` must have done: the team got Core's own share of what the route made,
    /// Core's reserves got the rest, and nothing stayed behind or went to `SzrEconomics`.
    function _assertBacked(uint256 backed, uint256 teamFee) internal view {
        assertEq(teamFee, core.economics().liquidityTeamFee(backed + teamFee), "team share");
        assertEq(core.reserveCash(), reserveBefore + backed, "reserves");
        assertEq(
            backing.balanceOf(core.economics().beneficiary()), paidBefore + teamFee, "paid"
        );
        assertEq(backing.balanceOf(address(treasury)), 0, "treasury weth");
        assertEq(backing.balanceOf(address(core.economics())), 0, "economics");
        assertEq(address(treasury).balance, 0, "treasury ether");
        assertEq(backing.allowance(address(treasury), address(core)), 0, "approval");
    }
}

contract SzrTreasuryTest is TreasuryWorld {
    function test_constructorReadsCore() public view {
        assertEq(treasury.szr(), address(core.token()));
        assertEq(treasury.weth(), address(backing));
        assertEq(address(treasury.core()), address(core));
        assertEq(treasury.manager(), address(this));
    }

    function test_deployScriptBuildsATreasuryForCore() public {
        DeploySzrTreasury script =
            DeploySzrTreasury(deployCode("DeploySzrTreasury.s.sol:DeploySzrTreasury"));
        SzrTreasury made = script.run(core, IMetricFactory(address(metricFactory)));
        assertEq(made.szr(), address(core.token()));
        assertEq(made.weth(), address(backing));
        assertEq(address(made.poolManager()), address(manager));
        vm.expectRevert(DeploySzrTreasury.MissingCore.selector);
        script.run(SzrCore(address(0xdead)), IMetricFactory(address(metricFactory)));
        vm.expectRevert(DeploySzrTreasury.MissingMetricFactory.selector);
        script.run(core, IMetricFactory(address(0xbeef)));
        // The treasury made its factory, so the protocol check cannot be made to fail here.
        assertEq(made.indexFactory().protocol(), address(made));
        // A Core that was never initialized has no Liquidity.
        SzrCore bare = SzrCore(
            deployCode(
                "SzrCore.sol:SzrCore",
                abi.encode(
                    address(backing),
                    uint256(1e12),
                    address(this),
                    SzrCore.AuctionConfig(4e12, 1, 200_000e18)
                )
            )
        );
        vm.expectRevert(DeploySzrTreasury.MissingLiquidity.selector);
        script.run(bare, IMetricFactory(address(metricFactory)));
    }

    function test_onlyTheManagerMayCall() public {
        backing.mint(address(treasury), 10e18);
        vm.startPrank(alice);
        vm.expectRevert(SzrTreasury.NotManager.selector);
        treasury.back(address(backing), 10e18, _empty(), 0, FAR);
        vm.expectRevert(SzrTreasury.NotManager.selector);
        treasury.retire(address(szrToken), 10e18, _empty(), 0, FAR);
        vm.stopPrank();
    }

    function test_aNewManagerTakesOverWithNoChangeHere() public {
        backing.mint(address(treasury), 10e18);
        locker.nominateManager(alice);
        vm.prank(alice);
        locker.acceptManager();
        vm.expectRevert(SzrTreasury.NotManager.selector);
        treasury.back(address(backing), 10e18, _empty(), 0, FAR);
        vm.prank(alice);
        treasury.back(address(backing), 10e18, _empty(), 0, FAR);
    }

    function test_backWithNoHopsSplitsHeldWeth() public {
        uint256 navBefore = core.NAV();
        (uint256 backed, uint256 fee) = _back(backing, 1_000e18, _empty());
        assertEq(fee, 330e18);
        assertEq(backed, 670e18);
        _assertBacked(backed, fee);
        assertGt(core.NAV(), navBefore, "nav rose");
        assertEq(core.economics().claimableFees(), 0, "nothing claimable");
    }

    function test_backPaysTheNewBeneficiaryAfterAHandover() public {
        SzrEconomics economics = core.economics();
        economics.nominateBeneficiary(alice);
        vm.prank(alice);
        economics.acceptBeneficiary();
        uint256 before = backing.balanceOf(alice);
        (, uint256 fee) = _back(backing, 1_000e18, _empty());
        assertEq(backing.balanceOf(alice), before + fee);
    }

    function test_retireWithNoHopsReturnsSzrToTheSale() public {
        szrToken.transfer(address(treasury), 500e18);
        uint256 supply = core.activeSupply();
        uint256 inventory = core.unreleasedSupply();
        uint256 team = szrToken.balanceOf(address(this));
        uint256 teamWeth = backing.balanceOf(address(this));
        uint256 retired = treasury.retire(address(szrToken), 500e18, _empty(), 500e18, FAR);
        assertEq(retired, 500e18);
        assertEq(core.activeSupply(), supply - 500e18);
        assertEq(core.unreleasedSupply(), inventory + 500e18);
        assertEq(szrToken.balanceOf(address(this)), team, "beneficiary szr");
        assertEq(backing.balanceOf(address(this)), teamWeth, "beneficiary weth");
        assertEq(szrToken.balanceOf(address(treasury)), 0);
        assertEq(szrToken.allowance(address(treasury), address(core)), 0);
    }

    function test_retireOnTheSzrPoolWithAPlainHop() public {
        PoolKey memory pool = locker.key(0);
        backing.mint(address(treasury), 100e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 retired = treasury.retire(
            address(backing), 100e18, _route(_v4Hop(pool, address(szrToken))), 90e18, FAR
        );
        assertEq(core.unreleasedSupply(), inventory + retired);
        assertEq(szrToken.balanceOf(address(treasury)), 0);
    }

    function test_routeChecks() public {
        coin.mint(address(treasury), 10);
        usdg.mint(address(treasury), 10);
        SzrTreasury.Hop[] memory five = new SzrTreasury.Hop[](5);
        vm.expectRevert(SzrTreasury.TooManyHops.selector);
        treasury.back(address(coin), 1, five, 0, FAR);
        vm.expectRevert(SzrTreasury.ZeroAmount.selector);
        treasury.back(address(coin), 0, _empty(), 0, FAR);
        // Not WETH, and not SZR.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(coin), 1, _empty(), 0, FAR);
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.retire(address(coin), 1, _empty(), 0, FAR);
        // Native ETH is never held between hops.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(0), 1, _empty(), 0, FAR);
        PoolKey memory pool = _v4Pool(address(backing), address(coin));
        // A route that ends in the wrong token.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.retire(address(coin), 1, _route(_v4Hop(pool, address(backing))), 0, FAR);
        // The pool does not hold the token the hop starts from.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(usdg), 1, _route(_v4Hop(pool, address(backing))), 0, FAR);
        // A hop that goes nowhere.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(backing), 1, _route(_v4Hop(pool, address(backing))), 0, FAR);
        // A Metric pool of other tokens, and an index hop to a token of no pool (the pool says no).
        address metric = address(_metricPool(address(usdg), address(backing)));
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(coin), 1, _route(_metricHop(metric, address(backing))), 0, FAR);
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(usdg), 1, _route(_metricHop(metric, address(coin))), 0, FAR);
        address index = address(_indexPool(address(usdg), address(backing)));
        vm.expectRevert(IndexPool.UnknownToken.selector);
        treasury.back(address(usdg), 1, _route(_indexHop(index, address(coin))), 0, FAR);
        // Native ETH out of a hop that is not a v4 hop.
        vm.expectRevert(SzrTreasury.BadRoute.selector);
        treasury.back(address(usdg), 1, _route(_metricHop(metric, address(0))), 0, FAR);
    }

    function test_minimumAndDeadline() public {
        PoolKey memory pool = _v4Pool(address(backing), address(coin));
        coin.mint(address(treasury), 100e18);
        SzrTreasury.Hop[] memory route = _route(_v4Hop(pool, address(backing)));
        uint256 reserve = core.reserveCash();
        vm.expectRevert(SzrTreasury.BelowMinimum.selector);
        treasury.back(address(coin), 100e18, route, 100e18, FAR);
        assertEq(coin.balanceOf(address(treasury)), 100e18, "input kept");
        assertEq(backing.balanceOf(address(treasury)), 0);
        assertEq(core.reserveCash(), reserve);
        vm.expectRevert(SzrTreasury.DeadlinePassed.selector);
        treasury.back(address(coin), 100e18, route, 1, block.timestamp - 1);
        vm.expectRevert(SzrTreasury.DeadlinePassed.selector);
        treasury.retire(address(coin), 100e18, route, 1, block.timestamp - 1);
    }

    function test_etherOnlyFromWethAndThePoolManager() public {
        (bool ok,) = address(treasury).call{ value: 1 }("");
        assertFalse(ok, "stranger");
        vm.prank(address(backing));
        (ok,) = address(treasury).call{ value: 1 }("");
        assertTrue(ok, "weth");
        vm.deal(address(manager), 1);
        vm.prank(address(manager));
        (ok,) = address(treasury).call{ value: 1 }("");
        assertTrue(ok, "pool manager");
    }

    function test_callsFromStrangersToTheCallbacksRevert() public {
        vm.expectRevert(SzrTreasury.NotPool.selector);
        treasury.unlockCallback("");
        vm.expectRevert(SzrTreasury.NotPool.selector);
        treasury.metricOmmSwapCallback(1, 0, "");
        vm.prank(address(manager));
        vm.expectRevert(SzrTreasury.NotPool.selector);
        treasury.unlockCallback("");
    }
}

/// @dev A Core that is set up but not launched, and one launched with no holders.
contract SzrTreasuryLaunchTest is TreasuryWorld {
    function _bare(bool launch) internal returns (SzrTreasury bare) {
        TestAsset asset = new TestAsset();
        SzrCore fresh = SzrCore(
            deployCode(
                "SzrCore.sol:SzrCore",
                abi.encode(
                    address(asset),
                    uint256(1e12),
                    address(this),
                    SzrCore.AuctionConfig(4e12, 1, 200_000e18)
                )
            )
        );
        FeeCollector fees = new FeeCollector(fresh);
        Liquidity pools = new Liquidity(fresh, fees, manager, address(this));
        fresh.initialize(address(pools), address(fees));
        if (launch) fresh.launch();
        bare = _treasury(fresh, manager, IMetricFactory(address(metricFactory)));
        asset.mint(address(bare), 100e18);
    }

    function test_bothCallsRevertBeforeLaunch() public {
        SzrTreasury bare = _bare(false);
        address weth = bare.weth();
        vm.expectRevert(SzrCore.NotLaunched.selector);
        bare.back(weth, 100e18, _empty(), 0, FAR);
        assertEq(TestAsset(weth).balanceOf(address(bare)), 100e18);
        address szr = bare.szr();
        vm.expectRevert(SzrCore.NotLaunched.selector);
        bare.retire(szr, 1, _empty(), 0, FAR);
    }

    function test_backWithNoHoldersRevertsAndTheWethWaits() public {
        SzrTreasury bare = _bare(true);
        address weth = bare.weth();
        vm.expectRevert(SzrCore.NoActiveSupply.selector);
        bare.back(weth, 100e18, _empty(), 0, FAR);
        assertEq(TestAsset(weth).balanceOf(address(bare)), 100e18);
    }
}
