// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { DeployArbitrageHook } from "../../script/DeployArbitrageHook.s.sol";
import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { ILegacySzrHook, ILegacySzrToken } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { AggregatorPricer, IAggregatorHook } from "../utils/ArbitrageAggregator.sol";

interface IQuoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice The wrapped-pool seam against a deployed aggregator hook on Robinhood Chain:
/// the WETH/USDG pool on the Slipstream aggregator, priced from the pool it wraps by a
/// test pricer. Skipped unless FORK_RPC_URL is set.
contract ArbitrageAggregatorForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    address internal constant AGGREGATOR = 0xA117C4f25474b1283345E4DF8D88b9aeC4F62888;
    address internal constant OUTSIDE = 0xFAE65eAa11943f45E83D5B45DC7A7C801C51bfB0;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant TEAM = address(0x7EA);
    address internal constant TRADER = address(0x7AADE);
    address internal constant OWNER = address(0x7EA3);
    address internal constant TREASURY = address(0x7EA4);

    uint32 internal constant PRICER_GAS = 32_000;

    IPoolManager internal manager;
    IERC20 internal weth;
    SzrCore internal core;
    Liquidity internal locker;
    ArbitrageHook internal arbitrage;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal provider;
    AggregatorPricer internal pricer;
    PoolKey internal wrapped;
    PoolKey internal hooked;
    uint256 internal id;
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        live = true;
        ILegacySzrHook legacy = ILegacySzrHook(ILegacySzrToken(LEGACY).hook());
        weth = IERC20(legacy.weth());
        manager = IPoolManager(address(legacy.poolManager()));
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
        arbitrage = new DeployArbitrageHook().run(block.chainid, locker);
        router = new PoolSwapTest(manager);
        provider = new PoolModifyLiquidityTest(manager);
        vm.prank(TEAM);
        locker.acceptManager();
    }

    /// The deployed pool is there and initialized, then an outside market counting in WETH
    /// holds a hooked WETH/USDG pool at the wrapped pool's price and the wrapped pool as a
    /// venue, both leaders of one group.
    function _open() internal {
        _openWith(PRICER_GAS);
    }

    function _openWith(uint32 pricerGas) internal {
        _launch();
        wrapped = PoolKey(
            Currency.wrap(address(weth)), Currency.wrap(USDG), 0x800000, 1, IHooks(AGGREGATOR)
        );
        assertGt(AGGREGATOR.code.length, 0, "aggregator hook has code");
        assertGt(OUTSIDE.code.length, 0, "outside pool has code");
        (uint160 root,,,) = manager.getSlot0(wrapped.toId());
        assertGt(root, 0, "wrapped pool initialized");
        pricer = new AggregatorPricer(IAggregatorHook(AGGREGATOR), 1_000);
        vm.startPrank(TEAM);
        arbitrage.setPricer(AGGREGATOR, address(pricer));
        vm.stopPrank();
        (uint160 outsideRoot,,,,) = pricer.price(wrapped);
        hooked = PoolKey(wrapped.currency0, wrapped.currency1, 3_000, 60, arbitrage);
        vm.startPrank(OWNER);
        id = arbitrage.openMarket(TREASURY);
        address[] memory chosen = new address[](1);
        chosen[0] = address(weth);
        arbitrage.setTokens(id, chosen);
        arbitrage.createPool(id, hooked, outsideRoot);
        arbitrage.addVenue(id, wrapped);
        bytes32[] memory leaders = new bytes32[](2);
        leaders[0] = PoolId.unwrap(hooked.toId());
        leaders[1] = PoolId.unwrap(wrapped.toId());
        arbitrage.setLeaders(id, address(weth), USDG, leaders);
        arbitrage.setPricerGas(id, pricerGas);
        arbitrage.setLimits(
            id, address(weth), uint32(arbitrage.minimumGasLimit(id)), 1e12, 1.0001e18
        );
        vm.stopPrank();
        _fund();
    }

    function _fund() internal {
        deal(address(weth), TRADER, 20e18);
        deal(USDG, TRADER, 100_000e6);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(provider), type(uint256).max);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(provider), type(uint256).max);
        // About 5 WETH and 9,000 USDG at the price just read, across the full range.
        provider.modifyLiquidity(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 2.1e14, 0
            ),
            ""
        );
        vm.stopPrank();
    }

    function _swap(PoolKey memory pool, address input, uint256 amount, uint256 gas)
        internal
        returns (bool ok)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        _cool();
        vm.prank(TRADER);
        (ok,) = address(router).call{ gas: gas }(
            abi.encodeCall(router.swap, (pool, params, settings, ""))
        );
    }

    function _quote(uint128 amount) internal returns (uint256 out) {
        (out,) = IQuoter(QUOTER)
            .quoteExactInputSingle(IQuoter.QuoteExactSingleParams(wrapped, true, amount, ""));
    }

    /// What the pricer's price and fee say a small sale of WETH should fetch.
    function _implied(uint128 amount) internal view returns (uint256) {
        (uint160 root, uint24 fee,,,) = pricer.price(wrapped);
        uint256 spot = uint256(root) * root / (1 << 96) * amount / (1 << 96);
        return spot * (1e6 - fee) / 1e6;
    }

    function testPricerAgreesWithTheQuoter() public {
        if (!live) return vm.skip(true);
        _open();
        (uint160 root, uint24 fee, uint128 depth,,) = pricer.price(wrapped);
        emit log_named_uint("outside sqrtPriceX96", root);
        emit log_named_uint("pricer fee (hundredths of a bip)", fee);
        emit log_named_uint("outside liquidity", depth);
        uint256 quoted = _quote(1e15);
        uint256 implied = _implied(1e15);
        emit log_named_uint("quoter USDG out for 1e15 WETH", quoted);
        emit log_named_uint("pricer-implied USDG out", implied);
        assertApproxEqRel(implied, quoted, 5e14, "within 0.05%");
    }

    function _logs() internal view returns (uint256 cycles, uint256 failures, uint256 other) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(arbitrage)) continue;
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageHook.Arbitraged.selector) {
                cycles++;
                assertEq(
                    logs[index].topics[2], PoolId.unwrap(wrapped.toId()), "against wrapped"
                );
            } else if (topic == ArbitrageHook.CycleFailed.selector) {
                failures++;
            } else if (topic == ArbitrageHook.SearchUndone.selector) {
                other++;
            } else if (topic == ArbitrageHook.SearchCutShort.selector) {
                other++;
            } else if (topic == ArbitrageHook.TryRanOut.selector) {
                other++;
            }
        }
    }

    function _assertClean() internal view {
        assertEq(weth.balanceOf(address(arbitrage)), 0, "hook weth");
        assertEq(IERC20(USDG).balanceOf(address(arbitrage)), 0, "hook usdg");
        assertEq(address(arbitrage).balance, 0, "hook ether");
    }

    /// A sale in the hooked pool opens a gap against the wrapped pool, and the search after
    /// the swap closes it by a cycle through the real aggregator hook: profit is paid to the
    /// market and the protocol 70/30, the hook keeps nothing and the swap does not fail.
    function testGapAgainstTheWrappedPoolIsClosed() public {
        if (!live) return vm.skip(true);
        _open();
        uint256 team = weth.balanceOf(TREASURY);
        uint256 core0 = weth.balanceOf(address(core));
        vm.recordLogs();
        assertTrue(_swap(hooked, address(weth), 5e17, 30_000_000), "swap");
        (uint256 cycles, uint256 failures, uint256 other) = _logs();
        emit log_named_uint("cycles through the wrapped pool", cycles);
        emit log_named_uint("cycle failures", failures);
        assertGt(cycles, 0, "a cycle through the wrapped pool");
        assertEq(failures, 0, "no failed cycle");
        assertEq(other, 0, "no search undone or cut short");
        uint256 market = weth.balanceOf(TREASURY) - team;
        uint256 protocol = weth.balanceOf(address(core)) - core0;
        assertGt(market, 0, "market paid");
        assertGt(protocol, 0, "protocol paid");
        assertGe(protocol * 100, (market + protocol) * 30, "protocol took less than 30%");
        assertLe(protocol * 100, (market + protocol) * 30 + 200, "protocol took more than 30%");
        _assertClean();
        assertEq(arbitrage.arb(PoolId.unwrap(hooked.toId())), 0, "gap closed");
    }

    function _cool() internal {
        vm.cool(address(manager));
        vm.cool(address(arbitrage));
        vm.cool(AGGREGATOR);
        vm.cool(OUTSIDE);
        vm.cool(USDG);
        vm.cool(address(weth));
        vm.cool(address(pricer));
    }

    /// A swap given what `gasForSwap` states, and the router's own overhead, closes the gap
    /// through the real aggregator hook. Reports what the real read and cycle cost.
    function testStatedGasIsEnoughAndWhatItCosts() public {
        if (!live) return vm.skip(true);
        _open();
        _cool();
        uint256 start = gasleft();
        pricer.price(wrapped);
        emit log_named_uint("pricer call gas, cold", start - gasleft());
        emit log_named_uint("pricerGas of the market", arbitrage.market(id).pricerGas);
        emit log_named_uint("minimumGasLimit", arbitrage.minimumGasLimit(id));
        uint256 stated = arbitrage.gasForSwap(id);
        emit log_named_uint("gasForSwap", stated);
        _cool();
        vm.recordLogs();
        start = gasleft();
        bool ok = _swap(hooked, address(weth), 5e17, stated + 200_000);
        emit log_named_uint(
            "swap closing a gap through the wrapped pool, gas", start - gasleft()
        );
        assertTrue(ok, "swap given the stated gas");
        (uint256 cycles, uint256 failures, uint256 other) = _logs();
        assertGt(cycles, 0, "cycle through the wrapped pool");
        assertEq(failures + other, 0, "nothing failed or cut short");
        _assertClean();
    }

    /// The other way: USDG into the hooked pool leaves WETH dear there, so the cycle sells
    /// it in the hooked pool and ends at the wrapped pool.
    function testReverseGapIsClosed() public {
        if (!live) return vm.skip(true);
        _open();
        vm.recordLogs();
        assertTrue(_swap(hooked, USDG, 1_000e6, 30_000_000), "swap");
        (uint256 cycles, uint256 failures,) = _logs();
        assertGt(cycles, 0, "cycle through the wrapped pool");
        assertEq(failures, 0, "no failed cycle");
        assertGt(weth.balanceOf(TREASURY), 0, "market paid");
        _assertClean();
    }

    /// The default 20,000 for a pricer's answer is less than the real read costs, so the
    /// wrapped pool gets no price and is passed over quietly: no cycle and no failure.
    function testDefaultPricerGasHidesTheWrappedPool() public {
        if (!live) return vm.skip(true);
        _openWith(20_000);
        emit log_named_uint(
            "minimumGasLimit at pricerGas 20,000", arbitrage.minimumGasLimit(id)
        );
        vm.recordLogs();
        assertTrue(_swap(hooked, address(weth), 5e17, 30_000_000), "swap still fills");
        (uint256 cycles, uint256 failures,) = _logs();
        assertEq(cycles, 0, "no cycle");
        assertEq(failures, 0, "nothing tried");
    }
}
