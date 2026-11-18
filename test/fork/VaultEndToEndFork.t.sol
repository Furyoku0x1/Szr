// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { DeployArbitrageHook } from "../../script/DeployArbitrageHook.s.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { ILegacySzrHook, ILegacySzrToken } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { MetricVenueHook } from "../../src/hooks/MetricVenueHook.sol";
import { MetricPricer } from "../../src/pricers/MetricPricer.sol";
import { ArbitrageVault } from "../../src/vaults/ArbitrageVault.sol";
import { MarketController } from "../../src/vaults/MarketController.sol";
import { ArbitrageVaultFactory } from "../../src/factories/ArbitrageVaultFactory.sol";
import { IMetricPool } from "../utils/metric/IMetric.sol";
import { FactoryDeploy } from "../utils/FactoryDeploy.sol";

/// @notice The vault stack end to end on Robinhood Chain: an outside market counting in
/// USDG, its controller and an `ArbitrageVault` made by the factory, and a live-priced
/// Metric venue. A swap in the market's pool pays profit to the controller, a deposit
/// pulls it into the vault, it streams, and a holder claims. Skipped without FORK_RPC_URL,
/// and when the Metric pool's feed is stalled.
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path "test/fork/VaultEndToEndFork.t.sol" -vv
contract VaultEndToEndForkTest is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    IMetricPool internal constant POOL =
        IMetricPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant TEAM = address(0x7EA);
    address internal constant TRADER = address(0x7AADE);
    address internal constant OWNER = address(0x7EA3);
    address internal constant PROTOCOL = address(0x7EA5);
    address internal constant HOOK_OWNER = address(0xA11CE);
    address internal constant CURATOR = address(0xC0A7);
    address internal constant HOLDER = address(0xB0B);
    uint32 internal constant PRICER_GAS = 164_000;

    IPoolManager internal manager;
    IERC20 internal weth;
    SzrCore internal core;
    Liquidity internal locker;
    ArbitrageApi internal arbitrage;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal provider;
    PoolKey internal hooked;
    PoolKey internal wrapped;
    MetricVenueHook internal wrapper;
    MetricPricer internal pricer;
    ArbitrageVaultFactory internal factory;
    MarketController internal controller;
    ArbitrageVault internal vault;
    uint256 internal id;
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        try POOL.getSellAndBuyPrices() returns (uint128, uint128) { }
        catch {
            console.log("WETH/USDG Metric feed is stalled or the pool is paused: skipping");
            return;
        }
        live = true;
        ILegacySzrHook legacy = ILegacySzrHook(ILegacySzrToken(LEGACY).hook());
        weth = IERC20(legacy.weth());
        manager = IPoolManager(address(legacy.poolManager()));
    }

    modifier onlyFork() {
        if (!live) vm.skip(true);
        _;
    }

    function _launch() internal {
        DeploySzr.Config memory config;
        config.chainId = block.chainid;
        config.asset = address(weth);
        config.poolManager = address(manager);
        config.teamBeneficiary = address(0xBEEF);
        config.manager = TEAM;
        config.legacyToken = LEGACY;
        config.marketPrice = 507e9;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = 350_000_000e18;
        config.initialLiquidityTokens = 25_000_000e18;
        config.auction = SzrCore.AuctionConfig(1014e9, 1, 200_000e18);
        config.fundInitialLiquidity = true;
        (core,, locker) = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr")).run(config);
        arbitrage = DeployArbitrageHook(
                deployCode("DeployArbitrageHook.s.sol:DeployArbitrageHook")
            )
            .run(block.chainid, locker);
        router = new PoolSwapTest(manager);
        provider = new PoolModifyLiquidityTest(manager);
        vm.prank(TEAM);
        locker.acceptManager();
    }

    /// A MetricVenueHook bound to the WETH/USDG pool, and a pricer for it.
    function _wrap() internal {
        address at = address(uint160(uint160(0x4444) << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(HOOK_OWNER, METRIC_FACTORY, address(manager), address(arbitrage)),
            at
        );
        wrapped = PoolKey(Currency.wrap(address(weth)), Currency.wrap(USDG), 0, 1, IHooks(at));
        vm.prank(HOOK_OWNER);
        MetricVenueHook(at).bind(wrapped, address(POOL));
        wrapper = MetricVenueHook(at);
        pricer = new MetricPricer(wrapper);
        vm.prank(TEAM);
        arbitrage.setPricer(at, address(pricer));
    }

    /// The pool manager must hold what Metric asks for, as it does from everyone else's
    /// deposits on the real chain.
    function _fund() internal {
        deal(address(weth), address(manager), weth.balanceOf(address(manager)) + 3_000e18);
        deal(USDG, address(manager), IERC20(USDG).balanceOf(address(manager)) + 5_000_000e6);
        address[3] memory who = [TRADER, CURATOR, HOLDER];
        for (uint256 i; i < who.length; i++) {
            deal(address(weth), who[i], 50e18);
            deal(USDG, who[i], 1_000_000e6);
        }
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(provider), type(uint256).max);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(provider), type(uint256).max);
        vm.stopPrank();
    }

    /// An outside market counting in USDG with its hooked WETH/USDG pool at Metric's price
    /// and the Metric venue as its leader.
    function _market() internal {
        _launch();
        _wrap();
        vm.prank(TEAM);
        arbitrage.setProfitToken(USDG, PROTOCOL);
        (uint160 start,,,,) = pricer.price(wrapped);
        hooked = PoolKey(
            Currency.wrap(address(weth)),
            Currency.wrap(USDG),
            3_000,
            60,
            IHooks(address(arbitrage))
        );
        vm.startPrank(OWNER);
        id = arbitrage.openMarket(address(0x7EA4));
        address[] memory chosen = new address[](1);
        chosen[0] = USDG;
        arbitrage.setTokens(id, chosen);
        arbitrage.createPool(id, hooked, start);
        arbitrage.addVenue(id, wrapped);
        bytes32[] memory leaders = new bytes32[](2);
        leaders[0] = PoolId.unwrap(hooked.toId());
        leaders[1] = PoolId.unwrap(wrapped.toId());
        arbitrage.setLeaders(id, USDG, address(weth), leaders);
        arbitrage.setPricerGas(id, PRICER_GAS);
        arbitrage.setLimits(id, USDG, uint32(arbitrage.minimumGasLimit(id)), 1e4, 1.0001e18);
        vm.stopPrank();
        _fund();
        vm.prank(TRADER);
        provider.modifyLiquidity(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 2.1e14, 0
            ),
            ""
        );
    }

    function _stack() internal {
        factory = FactoryDeploy.build(arbitrage, METRIC_FACTORY);
        vm.prank(OWNER);
        controller = MarketController(factory.createController(id, CURATOR));
        vm.prank(OWNER);
        arbitrage.nominateOwner(id, address(controller));
        vm.startPrank(CURATOR);
        controller.initialize();
        vault = ArbitrageVault(factory.createArbitrageVault(address(controller), hooked, 1_000));
        controller.addVault(address(vault), 6_000);
        weth.approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        ArbitrageVault.Range[] memory ranges = new ArbitrageVault.Range[](1);
        ranges[0] = ArbitrageVault.Range(TickMath.minUsableTick(60), TickMath.maxUsableTick(60));
        uint256[] memory units = new uint256[](1);
        units[0] = 1e14;
        vault.seed(ranges, units, type(uint256).max, type(uint256).max, block.timestamp);
        vm.stopPrank();
        vm.startPrank(HOLDER);
        weth.approve(address(vault), type(uint256).max);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testProfitFlowsToAHolder() public onlyFork {
        _market();
        _stack();
        assertEq(arbitrage.market(id).owner, address(controller), "the controller owns it");
        PoolSwapTest.TestSettings memory settings;
        vm.prank(TRADER);
        router.swap(
            hooked,
            IPoolManager.SwapParams(true, -5e17, TickMath.MIN_SQRT_PRICE + 1),
            settings,
            ""
        );
        uint256 paid = IERC20(USDG).balanceOf(address(controller));
        console.log("profit paid to the controller, USDG raw", paid);
        assertGt(paid, 0, "the Metric gap was arbitraged and the controller paid");
        assertEq(IERC20(USDG).balanceOf(address(0x7EA4)), 0, "not to the old recipient");

        // The holder's deposit runs the vault's checkpoint, which pulls the profit down.
        vm.prank(HOLDER);
        vault.deposit(3e13, type(uint256).max, type(uint256).max, block.timestamp);
        assertGt(IERC20(USDG).balanceOf(address(vault)), 0, "the vault was paid");
        assertGt(vault.rewardRate(USDG), 0, "it streams");
        assertEq(controller.owed(USDG), paid * 4_000 / 10_000, "the remainder is the curator's");

        vm.warp(block.timestamp + 4 days);
        uint256 earned = vault.earned(HOLDER, USDG);
        console.log("holder earned, USDG raw", earned);
        assertGt(earned, 0, "streamed to the holder");
        address[] memory tokens = new address[](1);
        tokens[0] = USDG;
        uint256 before = IERC20(USDG).balanceOf(HOLDER);
        vm.prank(HOLDER);
        vault.claim(tokens);
        assertEq(IERC20(USDG).balanceOf(HOLDER) - before, earned, "claimed");
    }
}
