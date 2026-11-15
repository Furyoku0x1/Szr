// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
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
import { FeeCollector } from "../../src/FeeCollector.sol";
import { TestAsset } from "../utils/TestAsset.sol";

/// @notice Rehearsal of the arbitrage hook on Robinhood Chain itself: the real PoolManager,
/// the real WETH, and the real Safe singleton factory the deploy script goes through.
/// Skipped unless FORK_RPC_URL is set.
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
/// @dev Does what the hook does with ETH profit once it holds it: wraps it and sends the
/// WETH to two recipients. Returns the gas that took.
contract PayoutSim {
    function pay(address asset, address first, address second, uint256 profit, uint256 share)
        external
        returns (uint256 used)
    {
        uint256 start = gasleft();
        (bool ok,) = asset.call{ value: profit }(abi.encodeWithSignature("deposit()"));
        require(ok, "deposit");
        IERC20(asset).transfer(first, share);
        IERC20(asset).transfer(second, profit - share);
        used = start - gasleft();
    }
}

contract ArbitrageHookForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    address internal constant TEAM = address(0x7EA);
    address internal constant TRADER = address(0x7AADE);

    IPoolManager internal manager;
    IERC20 internal weth;
    IERC20 internal szr;
    SzrCore internal core;
    Liquidity internal locker;
    ArbitrageHook internal arbitrage;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal provider;
    PoolKey internal mainPool;
    PoolKey internal hooked;
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

    /// Runs both real deploy scripts, then registers one hooked SZR/WETH pool beside the
    /// hookless main pool, as the manager will after launch.
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
        szr = IERC20(address(core.token()));
        arbitrage = new DeployArbitrageHook().run(block.chainid, locker);
        router = new PoolSwapTest(manager);
        provider = new PoolModifyLiquidityTest(manager);
        mainPool = locker.key(0);
        vm.startPrank(TEAM);
        locker.acceptManager();
        vm.stopPrank();
    }

    function _addHookedPool() internal {
        (uint160 price,,,) = manager.getSlot0(mainPool.toId());
        Liquidity.PoolConfig memory config = Liquidity.PoolConfig({
            partner: address(weth),
            feePips: 3_000,
            tickSpacing: 60,
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            initialSqrtPriceX96: price,
            hooks: IHooks(address(arbitrage))
        });
        FeeCollector.AssetConfig memory unused;
        vm.startPrank(TEAM);
        uint256 id = locker.addPool(config, unused);
        arbitrage.track(0);
        arbitrage.track(id);
        // Both are SZR/WETH pools, so they lead the same group, the main pool first.
        bytes32[] memory leaders = new bytes32[](2);
        leaders[0] = PoolId.unwrap(mainPool.toId());
        leaders[1] = PoolId.unwrap(locker.key(id).toId());
        arbitrage.setLeaders(1, arbitrage.token(), address(weth), leaders);
        vm.stopPrank();
        hooked = locker.key(id);
    }

    function _swap(PoolKey memory pool, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        vm.prank(TRADER);
        router.swap(
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

    /// The native ETH payout wraps the profit and sends the WETH on, which relies on the
    /// real token minting one for one, and must fit in the gas a search holds back for it.
    /// The real token is a proxy, so its first call costs more than a plain contract's.
    /// @dev The measurement covers the wrap and the two transfers only. It leaves out the
    /// pool manager's `take`, the hook's `receive`, `_requireSettled` and the event, which
    /// the local `testEthPayoutFitsInTheRetireReserve` measures with the whole payout. The
    /// 250,000 is `RETIRE_GAS`.
    function testRealWethMintsOneForOneOnDeposit() public {
        if (!live) return vm.skip(true);
        _launch();
        address asset = arbitrage.backingAsset();
        PayoutSim sim = new PayoutSim();
        vm.deal(address(sim), 3 ether);
        address protocol = address(0xC01D1);
        address owner = address(0xC01D2);
        vm.cool(asset);
        vm.cool(protocol);
        vm.cool(owner);
        uint256 used = sim.pay(asset, protocol, owner, 3 ether, 1 ether);
        emit log_named_uint("ETH payout gas (wrap and two transfers)", used);
        assertLt(used, 250_000, "under RETIRE_GAS");
        assertEq(IERC20(asset).balanceOf(protocol), 1 ether, "protocol share");
        assertEq(IERC20(asset).balanceOf(owner), 2 ether, "market share");
        assertEq(address(sim).balance, 0, "ether taken");
    }

    function testHookDeploysAndBackrunsOnTheLiveChain() public {
        if (!live) return vm.skip(true);
        _launch();
        assertEq(uint160(address(arbitrage)) & 0x3FFF, 1 << 7 | 1 << 6, "swap hooks only");
        _addHookedPool();
        deal(address(weth), TRADER, 10e18);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(provider), type(uint256).max);
        szr.approve(address(router), type(uint256).max);
        szr.approve(address(provider), type(uint256).max);
        vm.stopPrank();
        // The trader buys SZR in the main pool, which lifts its price above the new pool's,
        // then puts half of it into the hooked pool as liquidity.
        _swap(mainPool, address(weth), 2e18);
        uint256 bought = szr.balanceOf(TRADER);
        assertGt(bought, 0, "bought SZR");
        (uint160 price,,,) = manager.getSlot0(hooked.toId());
        bool szrFirst = Currency.unwrap(hooked.currency0) == address(szr);
        uint256 units =
            szrFirst ? bought / 2 * price / (1 << 96) : bought / 2 * (1 << 96) / price;
        vm.prank(TRADER);
        provider.modifyLiquidity(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(units), 0
            ),
            ""
        );
        // Any swap in the hooked pool now finds the gap against the main pool.
        uint256 inventory = core.unreleasedSupply();
        _swap(hooked, address(szr), bought / 100);
        uint256 retired = core.unreleasedSupply() - inventory;
        assertGt(retired, 0, "gap retired on chain");
        assertEq(szr.balanceOf(address(arbitrage)), 0, "hook szr");
        assertEq(weth.balanceOf(address(arbitrage)), 0, "hook weth");
        assertEq(arbitrage.arb(PoolId.unwrap(hooked.toId())), 0, "gap closed");
        emit log_named_address("hook", address(arbitrage));
        emit log_named_decimal_uint("SZR retired", retired, 18);
    }

    /// The same on the live chain's pool manager with a triangle: a hooked SZR/USD pool
    /// whose gap against the main SZR/WETH pool is closed through a WETH/USD pool.
    function testTriangleThroughAConnectingPoolOnTheLiveChain() public {
        if (!live) return vm.skip(true);
        _launch();
        TestAsset usd = new TestAsset();
        deal(address(weth), TRADER, 20e18);
        usd.mint(TRADER, 1_000e18);
        vm.startPrank(TRADER);
        weth.approve(address(router), type(uint256).max);
        weth.approve(address(provider), type(uint256).max);
        szr.approve(address(router), type(uint256).max);
        szr.approve(address(provider), type(uint256).max);
        usd.approve(address(router), type(uint256).max);
        usd.approve(address(provider), type(uint256).max);
        vm.stopPrank();
        PoolKey memory route = _addRoute(address(usd));
        PoolKey memory pool = _addUsdPool(address(usd), route);
        // The trader buys SZR in the main pool, lifting its price above the new pool's,
        // then puts half of it into the hooked pool as liquidity.
        _swap(mainPool, address(weth), 2e18);
        uint256 bought = szr.balanceOf(TRADER);
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        bool szrFirst = Currency.unwrap(pool.currency0) == address(szr);
        uint256 units =
            szrFirst ? bought / 2 * price / (1 << 96) : bought / 2 * (1 << 96) / price;
        _provide(pool, units);
        uint256 inventory = core.unreleasedSupply();
        _swap(pool, address(szr), bought / 100);
        uint256 retired = core.unreleasedSupply() - inventory;
        assertGt(retired, 0, "gap retired through the connecting pool");
        assertEq(szr.balanceOf(address(arbitrage)), 0, "hook szr");
        assertEq(weth.balanceOf(address(arbitrage)), 0, "hook weth");
        assertEq(usd.balanceOf(address(arbitrage)), 0, "hook usd");
        emit log_named_decimal_uint("SZR retired through a triangle", retired, 18);
    }

    function _provide(PoolKey memory pool, uint256 units) internal {
        vm.prank(TRADER);
        provider.modifyLiquidity(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(units), 0
            ),
            ""
        );
    }

    /// An outside WETH/USD pool at one for one, registered as a route.
    function _addRoute(address usd) internal returns (PoolKey memory route) {
        bool wethFirst = address(weth) < usd;
        route = PoolKey(
            Currency.wrap(wethFirst ? address(weth) : usd),
            Currency.wrap(wethFirst ? usd : address(weth)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 10e18);
        vm.prank(TEAM);
        locker.registerRoute(route);
    }

    /// A hooked SZR/USD pool priced where the main pool is now, with USD worth one WETH.
    function _addUsdPool(address usd, PoolKey memory route)
        internal
        returns (PoolKey memory pool)
    {
        (uint160 price,,,) = manager.getSlot0(mainPool.toId());
        bool mainSzrFirst = Currency.unwrap(mainPool.currency0) == address(szr);
        uint256 rate = mainSzrFirst ? price : (uint256(1) << 192) / price;
        bool szrFirst = address(szr) < usd;
        Liquidity.PoolConfig memory config = Liquidity.PoolConfig({
            partner: usd,
            feePips: 3_000,
            tickSpacing: 60,
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            initialSqrtPriceX96: uint160(szrFirst ? rate : (uint256(1) << 192) / rate),
            hooks: IHooks(address(arbitrage))
        });
        vm.startPrank(TEAM);
        uint256 id = locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
        arbitrage.track(0);
        arbitrage.track(id);
        arbitrage.setConnector(1, route, true);
        // One leader in each group: the main pool for WETH, the new pool for USD.
        bytes32[] memory leader = new bytes32[](1);
        leader[0] = PoolId.unwrap(mainPool.toId());
        arbitrage.setLeaders(1, arbitrage.token(), address(weth), leader);
        leader[0] = PoolId.unwrap(locker.key(id).toId());
        arbitrage.setLeaders(1, arbitrage.token(), usd, leader);
        vm.stopPrank();
        pool = locker.key(id);
    }
}
