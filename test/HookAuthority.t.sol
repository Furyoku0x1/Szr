// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { HookAuthority } from "../src/HookAuthority.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { DeployArbitrageHook } from "../script/DeployArbitrageHook.s.sol";
import { ConfigureArbitrageHook } from "../script/ConfigureArbitrageHook.s.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A world whose hook runs against a `HookAuthority` instead of SZR's Liquidity
/// (docs/specs/hook-authority.md): nothing of SZR's market is set up, and every other part of
/// the world is as it was. SzrWorld still deploys SZR, so the suites' own assertions about
/// Core keep working; the hook just never uses it.
abstract contract AuthoritySetup is ArbitrageWorld {
    HookAuthority internal authority;

    function _authorityLiquidity() internal returns (Liquidity) {
        // Placed with `deployCodeTo`: a deployment would shift the addresses of every token the
        // world makes after it, and some suites depend on how those order.
        authority = HookAuthority(address(uint160(0xA07A << 24)));
        deployCodeTo(
            "HookAuthority.sol:HookAuthority",
            abi.encode(address(manager), address(backing), address(this)),
            address(authority)
        );
        return Liquidity(address(authority));
    }

    /// Where WETH's protocol share goes. The suites expect Core's balance; the authority's
    /// own tests leave it with the authority, as a new hook has it.
    function _wethShareRecipient() internal view virtual returns (address) {
        return address(core);
    }

    function _authoritySzrMarket() internal {
        usd = _newAsset();
        _approve(usd);
        backing.mint(address(this), 60_000_000e18);
        // The world's WETH/USD pool, which ArbitrageWorld makes beside SZR's USD pool.
        bool wethFirst = address(backing) < address(usd);
        PoolKey memory route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(usd)),
            Currency.wrap(wethFirst ? address(usd) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 50_000_000e18);
        if (_wethShareRecipient() != address(authority)) {
            hook.setProfitToken(address(backing), _wethShareRecipient());
        }
    }
}

import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

/// @dev The authority and the hook built over it: what each answers, how SZR's market is
/// left, who may move what, and the configure script's authority mode.
contract HookAuthorityTest is MarketsWorld, AuthoritySetup {
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

    /// Nothing that belongs to Core or SZR may be called on the authority (spec item 5).
    function _forbidCoreCalls() internal {
        vm.expectCall(address(authority), abi.encodeWithSignature("donateSzr(uint256)"), 0);
        vm.expectCall(address(authority), abi.encodeWithSignature("redeem(uint256,uint256)"), 0);
        vm.expectCall(address(authority), abi.encodeWithSignature("NAV()"), 0);
        vm.expectCall(address(authority), abi.encodeWithSignature("activeSupply()"), 0);
        vm.expectCall(address(authority), abi.encodeWithSignature("backingAmount()"), 0);
    }

    function _configure() internal {
        ConfigureArbitrageHook.Config memory plan;
        plan.hook = hook;
        plan.treasury = protocol;
        plan.swapGasCeiling = 12_000_000;
        new ConfigureArbitrageHook().run(plan);
    }

    // ----- 1: the hook deploys against the authority -----

    function testTheHookDeploysAgainstTheAuthority() public {
        // Deployed from its artifact so that this contract does not carry the hook's code.
        DeployArbitrageHook deployment =
            DeployArbitrageHook(deployCode("DeployArbitrageHook.s.sol:DeployArbitrageHook"));
        vm.etch(
            deployment.FACTORY(),
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0"
            hex"3601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        ArbitrageApiLike deployed = ArbitrageApiLike(
            address(deployment.run(block.chainid, Liquidity(address(authority))))
        );
        assertEq(uint160(address(deployed)) & 0x3FFF, 0xC0, "the swap permission bits only");
        assertEq(address(deployed.core()), address(authority), "core");
        assertEq(address(deployed.token()), address(authority), "token");
        assertEq(address(deployed.poolManager()), address(manager), "pool manager");
        assertEq(deployed.backingAsset(), address(backing), "WETH");
    }

    // ----- 2: an outside market works end to end -----

    function testAnOutsideMarketWorksEndToEnd() public {
        _forbidCoreCalls();
        _configure();
        vm.prank(team);
        hook.addVenue(id, publicPool);
        assertTrue(hook.tracked(id, _id(publicPool)), "a venue added");
        uint256 before = backing.balanceOf(protocol);
        _trade(first, address(coin), 50_000e18);
        uint256 share = backing.balanceOf(protocol) - before;
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "the market is paid");
        _assertThirty(share, kept + share);
        // `arb` and `sweep` on the market.
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(first, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        assertGt(hook.arb(_id(first)), 0, "arb closes the gap");
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        _trade(second, address(coin), 50_000e18);
        _limits(address(backing), 1e15);
        assertGt(hook.sweep(id, address(backing)), 0, "sweep closes the gap");
        assertEq(coin.balanceOf(address(hook)), 0, "the hook holds nothing");
        _assertHookEmpty();
    }

    // ----- 3: before configure, the share lands in the authority -----

    function testBeforeConfigureTheShareLandsInTheAuthorityAndOnlyTheManagerMovesIt() public {
        uint256 before = backing.balanceOf(address(authority));
        _trade(first, address(coin), 50_000e18);
        uint256 held = backing.balanceOf(address(authority)) - before;
        assertGt(held, 0, "the protocol's 30% is in the authority");
        vm.prank(alice);
        vm.expectRevert(HookAuthority.NotManager.selector);
        authority.recover(address(backing), alice, held);
        vm.expectRevert(HookAuthority.ZeroAddress.selector);
        authority.recover(address(backing), address(0), held);
        authority.recover(address(backing), protocol, held);
        assertEq(backing.balanceOf(protocol), held, "forwarded");
        assertEq(backing.balanceOf(address(authority)), before, "and gone from it");
        // Ether too, with the manager only.
        vm.deal(address(authority), 1 ether);
        vm.prank(alice);
        vm.expectRevert(HookAuthority.NotManager.selector);
        authority.recover(address(0), alice, 1 ether);
        authority.recover(address(0), protocol, 1 ether);
        assertEq(protocol.balance, 1 ether);
    }

    // ----- 4: SZR's market is inert -----

    function testSzrMarketIsInert() public {
        _forbidCoreCalls();
        address token = address(authority);
        vm.expectRevert(HookAuthority.NoPositions.selector);
        hook.track(0);
        vm.expectRevert(HookAuthority.NoPositions.selector);
        hook.track(12_345);
        vm.expectRevert(ArbitrageLogic.PoolNotRegistered.selector);
        hook.setConnector(1, publicPool, true);
        bytes32[] memory leaders = new bytes32[](1);
        leaders[0] = _id(first);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(1, token, address(coin), leaders);
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        hook.arb(_id(publicPool));
        assertEq(hook.sweep(1, token), 0, "nothing to sweep before configure");
        _configure();
        assertEq(hook.sweep(1, token), 0, "and nothing after");
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        hook.arb(_id(publicPool));
    }

    /// An outside market takes no pool that holds the authority's address.
    function testOutsideMarketsRefusePoolsHoldingTheAuthority() public {
        PoolKey memory hooked =
            _pair(address(authority), address(backing), 3_000, address(hook));
        PoolKey memory open = _pair(address(authority), address(backing), 500, address(0));
        vm.startPrank(team);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.createPool(id, hooked, uint160(1 << 96));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.addVenue(id, open);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setConnector(id, open, true);
        vm.stopPrank();
    }

    // ----- 6: the manager hands over -----

    function testManagerHandOver() public {
        authority.nominateManager(alice);
        vm.prank(bob);
        vm.expectRevert(HookAuthority.NotNominee.selector);
        authority.acceptManager();
        authority.cancelManagerNomination();
        vm.prank(alice);
        vm.expectRevert(HookAuthority.NotNominee.selector);
        authority.acceptManager();
        authority.nominateManager(alice);
        vm.prank(alice);
        authority.acceptManager();
        assertEq(authority.manager(), alice);
        assertEq(authority.pendingManager(), address(0));
        vm.prank(alice);
        hook.setProfitToken(address(usd), protocol);
        vm.prank(alice);
        hook.setPricer(address(0xBEEF), address(0xCAFE));
        // The old manager, this contract, can do neither, nor nominate.
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setProfitToken(address(usd), desk);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setPricer(address(0xBEEF), address(0));
        vm.expectRevert(HookAuthority.NotManager.selector);
        authority.nominateManager(bob);
        // A zero nominee, and the manager itself, are refused.
        vm.startPrank(alice);
        vm.expectRevert(HookAuthority.ZeroAddress.selector);
        authority.nominateManager(address(0));
        vm.expectRevert(HookAuthority.InvalidModule.selector);
        authority.nominateManager(alice);
        vm.stopPrank();
    }

    // ----- 7: setProfitToken with the authority as core -----

    function testProfitTokensWithTheAuthorityAsCore() public {
        hook.setProfitToken(address(backing), protocol);
        hook.setProfitToken(address(0), protocol);
        assertEq(hook.shareRecipient(address(backing)), protocol);
        assertEq(hook.shareRecipient(address(0)), protocol);
        TestAsset other = new TestAsset();
        hook.setProfitToken(address(other), protocol);
        assertEq(hook.shareRecipient(address(other)), protocol, "added");
        hook.setProfitToken(address(other), address(0));
        assertEq(hook.shareRecipient(address(other)), address(0), "and removed");
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(other), address(authority));
        // WETH may point at it, as a new hook has it.
        hook.setProfitToken(address(backing), address(authority));
    }

    // ----- 8: configure in authority mode -----

    function testConfigureInAuthorityModeDoesTheFourSteps() public {
        _forbidCoreCalls();
        assertEq(hook.shareRecipient(address(backing)), address(authority), "before");
        assertGt(hook.market(1).gasLimit, 0, "SZR's market is on by default");
        _configure();
        assertEq(hook.shareRecipient(address(backing)), protocol, "WETH to the treasury");
        assertEq(hook.shareRecipient(address(0)), protocol, "ETH to the treasury");
        assertEq(hook.market(1).gasLimit, 0, "SZR's market is off");
        assertEq(hook.swapGasCeiling(), 12_000_000, "the ceiling");
        // A second run changes nothing: no setting is written.
        vm.recordLogs();
        _configure();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            assertTrue(topic != ArbitrageLogic.ProfitTokenSet.selector, "a recipient was set");
            assertTrue(topic != ArbitrageLogic.LimitsSet.selector, "a limit was set");
            assertTrue(topic != ArbitrageLogic.SwapGasCeilingSet.selector, "a ceiling was set");
        }
    }

    function testConfigureInAuthorityModeRefusesWhatIsForSzrsMarket() public {
        ConfigureArbitrageHook script = new ConfigureArbitrageHook();
        ConfigureArbitrageHook.Config memory plan;
        plan.hook = hook;
        vm.expectRevert(ConfigureArbitrageHook.MissingTreasury.selector);
        script.run(plan);
        plan.treasury = protocol;
        plan.positions = new uint256[](1);
        vm.expectRevert(ConfigureArbitrageHook.NotForAuthorityMode.selector);
        script.run(plan);
        plan.positions = new uint256[](0);
        plan.groups = new ConfigureArbitrageHook.Group[](1);
        vm.expectRevert(ConfigureArbitrageHook.NotForAuthorityMode.selector);
        script.run(plan);
        plan.groups = new ConfigureArbitrageHook.Group[](0);
        plan.connectors = new PoolKey[](1);
        vm.expectRevert(ConfigureArbitrageHook.NotForAuthorityMode.selector);
        script.run(plan);
        plan.connectors = new PoolKey[](0);
        plan.gasLimit = 9_000_000;
        vm.expectRevert(ConfigureArbitrageHook.NotForAuthorityMode.selector);
        script.run(plan);
        plan.gasLimit = 0;
        vm.expectRevert(ConfigureArbitrageHook.MissingSwapGasCeiling.selector);
        script.run(plan);
        assertEq(hook.shareRecipient(address(backing)), address(authority), "nothing was set");
    }

    // ----- the authority alone -----

    function testTheAuthorityAnswersWhatTheHookAsks() public view {
        assertEq(authority.core(), address(authority));
        assertEq(authority.token(), address(authority));
        assertEq(authority.poolManager(), address(manager));
        assertEq(authority.backingAsset(), address(backing));
        assertFalse(authority.poolRegistered(bytes32(uint256(1))));
        assertTrue(authority.approve(address(1), 1));
    }

    function testTheAuthorityRefusesBadConstructorArguments() public {
        vm.expectRevert(HookAuthority.MissingCode.selector);
        new HookAuthority(address(0xBAD), address(backing), address(this));
        vm.expectRevert(HookAuthority.MissingCode.selector);
        new HookAuthority(address(manager), address(0xBAD), address(this));
        vm.expectRevert(HookAuthority.ZeroAddress.selector);
        new HookAuthority(address(manager), address(backing), address(0));
    }
}

interface ArbitrageApiLike {
    function core() external view returns (address);
    function token() external view returns (address);
    function poolManager() external view returns (address);
    function backingAsset() external view returns (address);
}
