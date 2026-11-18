// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { DeployArbitrageHook } from "../../script/DeployArbitrageHook.s.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../../src/arbitrage/ArbitrageLogic.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { ILegacySzrHook, ILegacySzrToken } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { MetricVenueHook } from "../../src/hooks/MetricVenueHook.sol";
import { MetricPricer } from "../../src/pricers/MetricPricer.sol";
import { IMetricPool } from "../utils/metric/IMetric.sol";
import { MetricState } from "../utils/metric/MetricState.sol";

/// @notice M2 on Robinhood Chain: `MetricPricer` against the live WETH/USDG Metric pool, and
/// an outside market counting in USDG that arbitrages a v4 WETH/USDG pool against it through
/// `MetricVenueHook`. Skipped unless FORK_RPC_URL is set, and when the pool's feed is stalled.
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///     forge test --match-path "test/fork/MetricPricerFork.t.sol" -vv
contract MetricPricerForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    IMetricPool internal constant POOL =
        IMetricPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant PROVIDER = 0xCafFcc296115b2a12e190Be9735ac6aAAb23bC69;
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant TEAM = address(0x7EA);
    address internal constant TRADER = address(0x7AADE);
    address internal constant OWNER = address(0x7EA3);
    address internal constant TREASURY = address(0x7EA4);
    address internal constant PROTOCOL = address(0x7EA5);
    address internal constant HOOK_OWNER = address(0xA11CE);

    uint256 internal constant Q96 = 1 << 96;
    uint32 internal constant PRICER_GAS = 164_000;
    uint256 internal constant CHAIN_CAP = 32_000_000;

    IPoolManager internal manager;
    IERC20 internal weth;
    SzrCore internal core;
    Liquidity internal locker;
    ArbitrageApi internal arbitrage;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal provider;
    PoolKey internal hooked;
    PoolKey[] internal wrapped;
    MetricVenueHook[] internal wrappers;
    MetricPricer[] internal pricers;
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

    // ---------------------------------------------------------------------------------
    // World
    // ---------------------------------------------------------------------------------

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
    function _wrap(uint160 salt) internal {
        address at = address(uint160(salt << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(HOOK_OWNER, METRIC_FACTORY, address(manager), address(arbitrage)),
            at
        );
        PoolKey memory key =
            PoolKey(Currency.wrap(address(weth)), Currency.wrap(USDG), 0, 1, IHooks(at));
        vm.prank(HOOK_OWNER);
        MetricVenueHook(at).bind(key, address(POOL));
        wrappers.push(MetricVenueHook(at));
        wrapped.push(key);
        pricers.push(new MetricPricer(MetricVenueHook(at)));
        vm.prank(TEAM);
        arbitrage.setPricer(at, address(pricers[pricers.length - 1]));
    }

    /// The pool manager must hold the input Metric asks for, as it does from everyone
    /// else's deposits on the real chain.
    function _fund() internal {
        deal(address(weth), address(manager), weth.balanceOf(address(manager)) + 3_000e18);
        deal(USDG, address(manager), IERC20(USDG).balanceOf(address(manager)) + 5_000_000e6);
        deal(address(weth), TRADER, 20e18);
        deal(USDG, TRADER, 100_000e6);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(provider), type(uint256).max);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(provider), type(uint256).max);
        vm.stopPrank();
    }

    /// An outside market counting in USDG: a hooked WETH/USDG pool at Metric's price with
    /// 5 WETH or so of full-range depth, and `count` Metric venues as its leaders (with the
    /// hooked pool itself too when there is only one).
    function _open(uint256 count, uint32 pricerGas) internal {
        _launch();
        for (uint256 i; i < count; i++) {
            _wrap(uint160(0x4444 + i));
        }
        vm.prank(TEAM);
        arbitrage.setProfitToken(USDG, PROTOCOL);
        (uint160 start,,,,) = pricers[0].price(wrapped[0]);
        hooked = PoolKey(
            Currency.wrap(address(weth)),
            Currency.wrap(USDG),
            3_000,
            60,
            IHooks(address(arbitrage))
        );
        vm.startPrank(OWNER);
        id = arbitrage.openMarket(TREASURY);
        address[] memory chosen = new address[](1);
        chosen[0] = USDG;
        arbitrage.setTokens(id, chosen);
        arbitrage.createPool(id, hooked, start);
        bytes32[] memory leaders = new bytes32[](count == 1 ? 2 : count);
        uint256 at;
        if (count == 1) leaders[at++] = PoolId.unwrap(hooked.toId());
        for (uint256 i; i < count; i++) {
            arbitrage.addVenue(id, wrapped[i]);
            leaders[at++] = PoolId.unwrap(wrapped[i].toId());
        }
        arbitrage.setLeaders(id, USDG, address(weth), leaders);
        arbitrage.setPricerGas(id, pricerGas);
        arbitrage.setLimits(id, USDG, uint32(arbitrage.minimumGasLimit(id)), 1e4, 1.0001e18);
        vm.stopPrank();
        _fund();
        // About 5 WETH and 9,000 USDG at the price just read, across the full range.
        vm.prank(TRADER);
        provider.modifyLiquidity(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 2.1e14, 0
            ),
            ""
        );
    }

    function _swap(PoolKey memory pool, bool zeroForOne, uint256 amount, uint256 gas)
        internal
        returns (bool ok)
    {
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(TRADER);
        (ok,) = address(router).call{ gas: gas }(
            abi.encodeCall(router.swap, (pool, params, settings, ""))
        );
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(arbitrage));
        vm.cool(address(POOL));
        vm.cool(PROVIDER);
        vm.cool(USDG);
        vm.cool(address(weth));
        for (uint256 i; i < wrappers.length; i++) {
            vm.cool(address(wrappers[i]));
            vm.cool(address(pricers[i]));
        }
    }

    // ---------------------------------------------------------------------------------
    // Price: against getSellAndBuyPrices, and against real fills
    // ---------------------------------------------------------------------------------

    function _deployOne() internal {
        _launch();
        _wrap(0x4444);
        _fund();
    }

    function testPriceAgreesWithMetric() public onlyFork {
        _deployOne();
        (uint128 sell, uint128 buy) = POOL.getSellAndBuyPrices();
        (uint160 root, uint24 fee, uint128 depth, uint160 lower, uint160 upper) =
            pricers[0].price(wrapped[0]);
        // USDG per WETH from the root: root^2 / 2^192 is raw, times 1e12 for the decimals.
        uint256 usdgPerWeth = FullMath.mulDiv(root, root, Q96) * 1e12 / Q96;
        uint256 mid = (uint256(sell) + buy) / 2;
        console.log(
            "Metric sell, buy (whole USDG per WETH, millionths)", _micro(sell), _micro(buy)
        );
        console.log("pricer root^2 as USDG per WETH, millionths", usdgPerWeth * 1e6);
        console.log("pricer fee in pips", fee);
        console.log("pricer liquidity", depth);
        console.log("lower, upper, root (x 1e6 / 2^96)", _lim(lower), _lim(upper), _lim(root));
        // A U64.64 price to whole units.
        assertApproxEqRel(usdgPerWeth, mid >> 64, 1e12, "root is Metric's midpoint");
        uint256 tight = 1e6 - (uint256(sell) * 1e6) / mid;
        uint256 wide = (uint256(buy) * 1e6) / mid - 1e6;
        assertGe(fee, tight > wide ? tight : wide, "fee covers the worse side");
        assertLe(fee, 1e4, "fee is sane");
        assertLe(lower, root);
        assertGe(upper, root);
        assertGt(depth, 0, "the bin has depth");
    }

    function _micro(uint256 priceX64) internal pure returns (uint256) {
        return priceX64 * 1e6 >> 64;
    }

    function _lim(uint256 value) internal pure returns (uint256) {
        return value * 1e6 / Q96;
    }

    function testColdPriceGas() public onlyFork {
        _deployOne();
        // The first read in a transaction is the cold one; the pool, its provider and the
        // oracle are not touched yet in this test.
        _cool();
        uint256 start = gasleft();
        pricers[0].price(wrapped[0]);
        uint256 cold = start - gasleft();
        start = gasleft();
        pricers[0].price(wrapped[0]);
        uint256 warm = start - gasleft();
        console.log("MetricPricer.price gas, cold", cold);
        console.log("MetricPricer.price gas, warm", warm);
        assertLt(cold, 150_000, "spec stop: cold price over 150k");
        assertLe(cold * 12 / 10, PRICER_GAS, "recommended pricer gas covers cold + 20%");
    }

    struct Bin {
        uint256 x;
        uint256 y;
    }

    function _reserves() internal view returns (Bin memory b) {
        MetricState.Slot0 memory s = MetricState.slot0(POOL);
        MetricState.Bin memory bin = MetricState.bin(POOL, s.curBinIdx);
        b.x = bin.token0Scaled;
        b.y = bin.token1Scaled / 1e12;
    }

    /// What a v4 pool with the pricer's liquidity, price and fee would give for `amount` in.
    function _predict(bool zeroForOne, uint256 amount) internal returns (uint256) {
        (uint160 root, uint24 fee, uint128 liq,,) = pricers[0].price(wrapped[0]);
        uint256 net = amount * (1e6 - fee) / 1e6;
        if (zeroForOne) {
            uint256 next =
                FullMath.mulDiv(uint256(liq) << 96, root, (uint256(liq) << 96) + net * root);
            return FullMath.mulDiv(liq, root - next, Q96);
        }
        uint256 up = root + net * Q96 / liq;
        return FullMath.mulDiv(FullMath.mulDiv(liq, Q96, 1), up - root, root) / up;
    }

    /// A real swap through the wrapped pool, and its output.
    function _fill(bool zeroForOne, uint256 amount) internal returns (uint256 out) {
        address tokenOut = zeroForOne ? USDG : address(weth);
        uint256 before = IERC20(tokenOut).balanceOf(TRADER);
        assertTrue(_swap(wrapped[0], zeroForOne, amount, 30_000_000), "swap fills");
        out = IERC20(tokenOut).balanceOf(TRADER) - before;
    }

    /// The bin as a constant-liquidity range: for several sizes, what the five words predict
    /// against what Metric really pays, in both directions. The sizes are fractions of the
    /// bin's reserve of the token that comes out.
    function testPredictedOutputMatchesRealFills() public onlyFork {
        _deployOne();
        Bin memory bin = _reserves();
        (uint160 root,,,,) = pricers[0].price(wrapped[0]);
        console.log("bin reserves: WETH raw, USDG raw", bin.x, bin.y);
        uint256[3] memory fractions = [uint256(1), 10, 40];
        for (uint256 i; i < 3; i++) {
            uint256 f = fractions[i];
            // Selling WETH for USDG: the size that pays out f% of the bin's USDG.
            uint256 sellIn =
                FullMath.mulDiv(FullMath.mulDiv(bin.y * f / 100, Q96, root), Q96, root);
            uint256 sellPred = _predict(true, sellIn);
            uint256 sellReal = _fill(true, sellIn);
            _compare("sell WETH, percent of bin", f, sellPred, sellReal);
            (root,,,,) = pricers[0].price(wrapped[0]);
            // Buying WETH with USDG: the size that pays out f% of the bin's WETH.
            uint256 buyIn =
                FullMath.mulDiv(FullMath.mulDiv(bin.x * f / 100, root, Q96), root, Q96);
            uint256 buyPred = _predict(false, buyIn);
            uint256 buyReal = _fill(false, buyIn);
            _compare("buy WETH, percent of bin", f, buyPred, buyReal);
            (root,,,,) = pricers[0].price(wrapped[0]);
        }
    }

    function _compare(string memory label, uint256 pct, uint256 predicted, uint256 real)
        internal
    {
        console.log(label, pct);
        console.log("   predicted out, real out", predicted, real);
        uint256 gap = predicted > real ? predicted - real : real - predicted;
        console.log("   off by parts per million", gap * 1e6 / real);
        console.log("   predicted under real:", predicted <= real);
        assertLe(predicted, real, "predicted never above real");
        assertLe(gap * 1e6 / real, 5, "within 5 ppm");
    }

    // ---------------------------------------------------------------------------------
    // End to end
    // ---------------------------------------------------------------------------------

    function _gapPips() internal returns (uint256) {
        (uint160 venue,,,,) = pricers[0].price(wrapped[0]);
        (uint160 own,,,) = manager.getSlot0(hooked.toId());
        uint256 big = venue > own ? venue : own;
        uint256 small = venue > own ? own : venue;
        // Prices are the roots squared: a gap in the roots counts twice.
        return (big - small) * 2e6 / small;
    }

    function _arbCount(Vm.Log[] memory logs, bool afterSwap) internal view returns (uint256 n) {
        uint256 swapAt = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager)) continue;
            if (logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            if (logs[i].topics[2] != bytes32(uint256(uint160(address(router))))) continue;
            swapAt = i;
        }
        require(swapAt != type(uint256).max, "no swap");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(arbitrage)) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic != ArbitrageLogic.Arbitraged.selector) {
                assertTrue(topic != ArbitrageLogic.CycleFailed.selector, "a cycle failed");
                assertTrue(topic != ArbitrageLogic.SearchUndone.selector, "a search undone");
                assertTrue(topic != ArbitrageLogic.SearchCutShort.selector, "cut short");
                continue;
            }
            assertEq(logs[i].topics[2], PoolId.unwrap(wrapped[0].toId()), "against Metric");
            if (afterSwap == (i > swapAt)) n++;
        }
    }

    /// Takes the pricer away, opens a gap with a swap nobody can arbitrage, and puts it
    /// back: the next search finds a gap that was already there.
    function _openGapQuietly() internal {
        vm.prank(TEAM);
        arbitrage.setPricer(address(wrappers[0]), address(0));
        assertTrue(_swap(hooked, true, 5e17, 30_000_000), "swap");
        vm.prank(TEAM);
        arbitrage.setPricer(address(wrappers[0]), address(pricers[0]));
        console.log("gap opened, in pips", _gapPips());
        assertGt(_gapPips(), 10_000, "a real gap");
    }

    function _assertClean() internal view {
        assertEq(weth.balanceOf(address(arbitrage)), 0, "hook weth");
        assertEq(IERC20(USDG).balanceOf(address(arbitrage)), 0, "hook usdg");
        assertEq(address(arbitrage).balance, 0, "hook ether");
    }

    function _assertSplit(uint256 market0, uint256 protocol0) internal view {
        uint256 market = IERC20(USDG).balanceOf(TREASURY) - market0;
        uint256 protocol = IERC20(USDG).balanceOf(PROTOCOL) - protocol0;
        console.log("profit USDG raw: market, protocol", market, protocol);
        assertGt(market, 0, "market paid");
        assertGt(protocol, 0, "protocol paid");
        assertGe(protocol * 100, (market + protocol) * 30, "protocol under 30%");
        assertLe(protocol * 100, (market + protocol) * 30 + 200, "protocol over 30%");
    }

    /// The gap was there before the swap, and the search that runs before it closes it.
    function testGapClosedBeforeTheSwap() public onlyFork {
        _open(1, PRICER_GAS);
        _openGapQuietly();
        uint256 market0 = IERC20(USDG).balanceOf(TREASURY);
        uint256 protocol0 = IERC20(USDG).balanceOf(PROTOCOL);
        vm.recordLogs();
        // Too small to open a gap of its own.
        assertTrue(_swap(hooked, true, 1e12, 30_000_000), "swap");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 before = _arbCount(logs, false);
        console.log("cycles before the swap", before);
        assertGt(before, 0, "closed in the search before the swap");
        _assertSplit(market0, protocol0);
        _assertClean();
        console.log("gap left, in pips", _gapPips());
        assertLt(_gapPips(), 10_000, "gap closed");
    }

    /// The swap itself opens the gap, and the search after it closes it.
    function testGapClosedAfterTheSwap() public onlyFork {
        _open(1, PRICER_GAS);
        uint256 market0 = IERC20(USDG).balanceOf(TREASURY);
        uint256 protocol0 = IERC20(USDG).balanceOf(PROTOCOL);
        vm.recordLogs();
        assertTrue(_swap(hooked, true, 5e17, 30_000_000), "swap");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 afterwards = _arbCount(logs, true);
        console.log("cycles after the swap", afterwards);
        assertGt(afterwards, 0, "closed in the search after the swap");
        assertEq(_arbCount(logs, false), 0, "nothing to close before it");
        _assertSplit(market0, protocol0);
        _assertClean();
        console.log("gap left, in pips", _gapPips());
        assertLt(_gapPips(), 10_000, "gap closed");
    }

    /// A sweep closes a gap that no swap in the hooked pool is there to trigger.
    function testSweepClosesTheGap() public onlyFork {
        _open(1, PRICER_GAS);
        _openGapQuietly();
        uint256 market0 = IERC20(USDG).balanceOf(TREASURY);
        uint256 protocol0 = IERC20(USDG).balanceOf(PROTOCOL);
        uint256 start = gasleft();
        uint256 profit = arbitrage.sweep(id, USDG);
        console.log("sweep gas", start - gasleft());
        console.log("sweep profit, USDG raw", profit);
        assertGt(profit, 0, "sweep earned");
        _assertSplit(market0, protocol0);
        _assertClean();
        console.log("gap left, in pips", _gapPips());
        assertLt(_gapPips(), 10_000, "gap closed");
    }

    function testReverseGapIsClosed() public onlyFork {
        _open(1, PRICER_GAS);
        vm.recordLogs();
        assertTrue(_swap(hooked, false, 800e6, 30_000_000), "swap");
        uint256 cycles = _arbCount(vm.getRecordedLogs(), true);
        console.log("cycles after a USDG sale", cycles);
        assertGt(cycles, 0);
        _assertClean();
        assertLt(_gapPips(), 10_000, "gap closed");
    }

    // ---------------------------------------------------------------------------------
    // P8 again, with the real pricer
    // ---------------------------------------------------------------------------------

    function _report(string memory label) internal {
        console.log(label);
        console.log("   pricerGas set", arbitrage.market(id).pricerGas);
        console.log("   minimumGasLimit", arbitrage.minimumGasLimit(id));
        uint256 stated = arbitrage.gasForSwap(id);
        console.log("   gasForSwap", stated);
        console.log("   gasForSwap over the cap:", stated > CHAIN_CAP);
        console.log("   gasForSwap, share of the cap in ppm", stated * 1e6 / CHAIN_CAP);
        uint256 gas = stated + 300_000 > CHAIN_CAP ? CHAIN_CAP : stated + 300_000;
        _cool();
        uint256 start = gasleft();
        assertTrue(_swap(hooked, true, 1e12, gas), "no-gap swap");
        console.log("   swap with no gap, gas", start - gasleft());
        _cool();
        vm.recordLogs();
        start = gasleft();
        assertTrue(_swap(hooked, true, 5e17, gas), "gap swap");
        console.log("   swap that opens a gap, gas", start - gasleft());
        console.log("   cycles after it", _arbCount(vm.getRecordedLogs(), true));
        assertLe(stated, CHAIN_CAP, "spec stop: gasForSwap over the chain cap");
    }

    function testP8OneVenue() public onlyFork {
        _open(1, PRICER_GAS);
        _report("P8 one Metric venue, real MetricPricer, pricerGas 164000");
    }

    function testP8ThreeVenues() public onlyFork {
        _open(3, PRICER_GAS);
        _report("P8 three Metric venues, real MetricPricer, pricerGas 164000");
    }
}
