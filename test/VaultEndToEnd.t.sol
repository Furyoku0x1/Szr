// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { FactoryDeploy } from "./utils/FactoryDeploy.sol";
import { ArbitrageVaultFactory } from "../src/factories/ArbitrageVaultFactory.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { IMarketController } from "../src/interfaces/IMarketController.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A market owner hands its market to a controller made by the factory, two pair
/// vaults sit under it, and real swaps through the real hook pay profit in WETH and USD
/// which flows to holders, the curator and the controller's remainder.
contract VaultEndToEndTest is MarketsWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant DELAY = 3 days;
    uint256 internal constant SEED = 1_000_000e18;
    uint160 internal constant ONE = uint160(1 << 96);

    address internal curator = address(0xC0A7);
    ArbitrageVaultFactory internal factory;
    MarketController internal controller;
    ArbitrageVault internal vaultA;
    ArbitrageVault internal vaultB;
    PoolKey internal dollars;
    address internal token0;
    address internal token1;

    function setUp() public override {
        super.setUp();
        // The profit counted in USD comes from a pool of USD and the team's token.
        dollars = _create(address(usd), address(coin), 3_000);
        PoolKey memory cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        _limits(address(usd), 1e15);
        factory = FactoryDeploy.build(hook, address(0xFAC));
        token0 = address(backing) < address(coin) ? address(backing) : address(coin);
        token1 = address(backing) < address(coin) ? address(coin) : address(backing);
        address[3] memory who = [curator, alice, bob];
        for (uint256 index; index < who.length; index++) {
            backing.mint(who[index], 1e12 ether);
            coin.mint(who[index], 1e12 ether);
        }
    }

    /// Two ranges of the vault's home pool: the widest, and a narrow one.
    function _ranges()
        internal
        pure
        returns (ArbitrageVault.Range[] memory list, uint256[] memory units)
    {
        list = new ArbitrageVault.Range[](2);
        list[0] = ArbitrageVault.Range(TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
        list[1] = ArbitrageVault.Range(-600, 600);
        units = new uint256[](2);
        units[0] = SEED;
        units[1] = SEED;
    }

    function _seed(ArbitrageVault vault) internal {
        (ArbitrageVault.Range[] memory list, uint256[] memory units) = _ranges();
        vm.startPrank(curator);
        backing.approve(address(vault), type(uint256).max);
        coin.approve(address(vault), type(uint256).max);
        vault.seed(list, units, type(uint256).max, type(uint256).max, block.timestamp);
        vault.addRewardToken(address(usd));
        vm.stopPrank();
    }

    function _approveFor(address who, ArbitrageVault vault) internal {
        vm.startPrank(who);
        backing.approve(address(vault), type(uint256).max);
        coin.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _all() internal view returns (address[] memory list) {
        list = new address[](3);
        list[0] = token0;
        list[1] = token1;
        list[2] = address(usd);
    }

    function _setUpMarket() internal {
        vm.prank(team);
        controller = MarketController(factory.createController(id, curator));
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        vm.prank(curator);
        controller.initialize();
        assertEq(hook.market(id).owner, address(controller), "owner");
        assertEq(hook.market(id).recipient, address(controller), "recipient");

        vm.startPrank(curator);
        vaultA = ArbitrageVault(factory.createArbitrageVault(address(controller), first, 1_000));
        vaultB = ArbitrageVault(factory.createArbitrageVault(address(controller), second, 500));
        controller.addVault(address(vaultA), 5_000);
        bytes memory add = abi.encodeCall(controller.addVault, (address(vaultB), 3_000));
        vm.expectRevert(IMarketController.Timelocked.selector);
        controller.addVault(address(vaultB), 3_000);
        controller.queue(add);
        vm.warp(block.timestamp + DELAY);
        controller.execute(add);
        vm.stopPrank();
        _seed(vaultA);
        _seed(vaultB);
        _approveFor(alice, vaultA);
        _approveFor(bob, vaultB);
    }

    function _earn() internal {
        _trade(first, address(coin), 50_000e18);
        _trade(dollars, address(coin), 80_000e18);
    }

    function testFactoryToClaims() public {
        _setUpMarket();
        assertEq(factory.controllerCount(), 1);
        assertEq(factory.vaultCount(), 2);
        assertEq(address(vaultA.controller()), address(controller));
        _earn();
        uint256 weth = backing.balanceOf(address(controller));
        uint256 dollarsEarned = usd.balanceOf(address(controller));
        assertGt(weth, 0, "the hook paid WETH to the controller");
        assertGt(dollarsEarned, 0, "and USD");
        assertEq(backing.balanceOf(treasury), 0, "not to the old recipient");

        // A deposit's checkpoint pulls the profit down to the vaults.
        vm.prank(alice);
        vaultA.deposit(SEED, type(uint256).max, type(uint256).max, block.timestamp);
        assertGt(vaultA.rewardRate(address(backing)), 0, "WETH streams");
        assertGt(vaultA.rewardRate(address(usd)), 0, "USD streams");
        assertEq(usd.balanceOf(address(controller)), controller.owed(address(usd)));
        assertEq(controller.owed(address(usd)), dollarsEarned * 2_000 / 10_000, "remainder");
        assertEq(usd.balanceOf(address(vaultB)), dollarsEarned * 3_000 / 10_000, "B held");

        // Bob's deposit books B's share. Nothing has streamed yet, so a day later
        // each has earned part of it, and after the period all of it.
        vm.prank(bob);
        vaultB.deposit(SEED, type(uint256).max, type(uint256).max, block.timestamp);
        vm.warp(block.timestamp + 1 days);
        uint256 early = vaultA.earned(alice, address(usd));
        assertGt(early, 0, "streaming");
        vm.warp(block.timestamp + 3 days);
        uint256 late = vaultA.earned(alice, address(usd));
        assertGt(late, early, "more streamed");
        // Alice holds half the supply less the locked minimum and the curator's seed.
        assertLe(
            late, dollarsEarned * 5_000 / 10_000 * 9 / 10, "never more than her vault's net"
        );

        uint256 before = usd.balanceOf(alice);
        vm.prank(alice);
        vaultA.claim(_all());
        assertEq(usd.balanceOf(alice) - before, late, "claimed what was earned");
        vm.prank(bob);
        vaultB.claim(_all());
        assertGt(usd.balanceOf(bob), 0);

        // The curator's fee, and the controller's remainder.
        uint256 feeBefore = usd.balanceOf(curator);
        vm.startPrank(curator);
        vaultA.claimFee(_all());
        assertGt(usd.balanceOf(curator), feeBefore, "fee");
        uint256 rest = controller.owed(address(backing));
        controller.claim(address(backing), curator);
        vm.stopPrank();
        assertEq(controller.owed(address(backing)), 0);
        assertGt(rest, 0, "remainder in WETH");
        _assertSolvent(vaultA);
        _assertSolvent(vaultB);
    }

    /// A vault holds at least the principal it owes plus every reward it has reserved.
    function _assertSolvent(ArbitrageVault vault) internal view {
        for (uint256 index; index < 3; index++) {
            address token = _all()[index];
            uint256 idle;
            if (token == token0) (idle,) = vault.principal();
            if (token == token1) (, idle) = vault.principal();
            assertLe(
                idle + vault.owed(token), TestAsset(token).balanceOf(address(vault)), "backed"
            );
        }
    }

    function testRebalanceAfterProfit() public {
        _setUpMarket();
        _earn();
        vm.prank(alice);
        vaultA.deposit(SEED, type(uint256).max, type(uint256).max, block.timestamp);
        (uint160 priceOne,,,) = manager.getSlot0(first.toId());
        ArbitrageVault.Change[] memory list = new ArbitrageVault.Change[](2);
        list[0] = ArbitrageVault.Change(1, 90_000e18);
        list[1] = ArbitrageVault.Change(0, -100_000e18);
        uint160[] memory prices = new uint160[](2);
        prices[0] = priceOne;
        prices[1] = priceOne;
        uint256 unitsBefore = vaultA.unitsOf(0);
        vm.roll(block.number + 1);
        vm.prank(curator);
        vaultA.rebalance(list, prices, block.timestamp);
        assertEq(vaultA.unitsOf(0), unitsBefore - 100_000e18);
        (uint256 idle0, uint256 idle1) = vaultA.principal();
        assertGt(idle0 + idle1, 0, "the difference sits idle");
        // The rebalance harvested nothing it should not: rewards stay reserved.
        _assertSolvent(vaultA);
    }

    function testQueuedTokenChangeExecutesAfterTheDelay() public {
        _setUpMarket();
        address[] memory only = new address[](1);
        only[0] = address(backing);
        bytes memory call = abi.encodeCall(hook.setTokens, (id, only));
        vm.startPrank(curator);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(call);
        controller.queue(call);
        vm.expectRevert(IMarketController.NotReady.selector);
        controller.execute(call);
        vm.warp(block.timestamp + DELAY);
        controller.execute(call);
        vm.stopPrank();
        assertEq(hook.tokensOf(id).length, 1, "tokens changed");
        assertEq(hook.market(id).recipient, address(controller), "recipient untouched");
    }
}
