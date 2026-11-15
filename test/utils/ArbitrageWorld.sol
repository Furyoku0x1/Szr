// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { SzrWorld } from "./SzrWorld.sol";
import { TestAsset } from "./TestAsset.sol";
import { ArbitrageHook } from "../../src/ArbitrageHook.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { FeeCollector } from "../../src/FeeCollector.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The real PoolManager with three pools: the hookless SZR/WETH main pool, a hooked
/// SZR/USD pool, and an outside WETH/USD pool connecting the two partner tokens. Helpers add
/// more.
abstract contract ArbitrageWorld is SzrWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ArbitrageHook internal hook;
    TestAsset internal usd;
    TestAsset internal szr;
    PoolKey internal mainPool;
    PoolKey internal usdPool;
    PoolModifyLiquidityTest internal provider;
    /// Liquidity given to each new hooked pool.
    uint256 internal poolUnits = 1_000_000e18;

    function setUp() public virtual override {
        super.setUp();
        szr = TestAsset(address(core.token()));
        // Only the beforeSwap and afterSwap permission bits are set in the address.
        hook = ArbitrageHook(payable(address(uint160(0xA4B1 << 24 | 1 << 7 | 1 << 6))));
        deployCodeTo("ArbitrageHook.sol:ArbitrageHook", abi.encode(locker), address(hook));
        provider = new PoolModifyLiquidityTest(manager);
        _approve(backing);
        // SZR cannot be minted; this contract still holds what it migrated.
        szr.approve(address(provider), type(uint256).max);
        szr.approve(address(swapper), type(uint256).max);
        mainPool = locker.key(0);
        hook.track(0);
        _lead(mainPool);
        usd = new TestAsset();
        usdPool = _addPartner(usd);
    }

    function _approve(TestAsset asset) internal {
        asset.mint(address(this), 100_000_000e18);
        asset.approve(address(provider), type(uint256).max);
        asset.approve(address(swapper), type(uint256).max);
    }

    /// A hooked SZR/partner pool plus the outside WETH/partner pool that connects it.
    function _addPartner(TestAsset asset) internal returns (PoolKey memory pool) {
        _approve(asset);
        backing.mint(address(this), 60_000_000e18);
        pool = _addHooked(address(asset), 3_000);
        bool wethFirst = address(backing) < address(asset);
        PoolKey memory route = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(asset)),
            Currency.wrap(wethFirst ? address(asset) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        // Outside markets are much deeper than a new SZR pool.
        _provide(route, 50_000_000e18);
        locker.registerRoute(route);
        hook.setConnector(1, route, true);
    }

    function _addHooked(address partner, uint24 fee) internal returns (PoolKey memory pool) {
        pool = _register(partner, fee, uint160(1 << 96));
        _provide(pool, poolUnits);
    }

    /// A hooked, tracked pool with no liquidity yet.
    function _register(address partner, uint24 fee, uint160 price)
        internal
        returns (PoolKey memory pool)
    {
        Liquidity.PoolConfig memory config = _config();
        config.partner = partner;
        config.feePips = fee;
        config.initialSqrtPriceX96 = price;
        config.hooks = IHooks(address(hook));
        FeeCollector.AssetConfig memory fees;
        if (partner != address(backing)) {
            fees = FeeCollector.AssetConfig(1e18, 20_000e18, 1e12);
        }
        uint256 id = locker.addPool(config, fees);
        pool = locker.key(id);
        hook.track(id);
        _lead(pool);
    }

    function _provide(PoolKey memory pool, uint256 units) internal {
        provider.modifyLiquidity(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(units), 0
            ),
            ""
        );
    }

    function _trade(PoolKey memory pool, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
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

    function _id(PoolKey memory pool) internal pure returns (bytes32) {
        return PoolId.unwrap(pool.toId());
    }

    /// SZR per partner token would differ by token order, so compare partner per SZR.
    function _price(PoolKey memory pool) internal view returns (uint256) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(pool.toId());
        uint256 ratio = uint256(sqrtPrice) * 1e9 / (1 << 96);
        if (Currency.unwrap(pool.currency0) == address(szr)) return ratio * ratio;
        return 1e36 / (ratio * ratio);
    }

    function _assertHookEmpty() internal view {
        assertEq(szr.balanceOf(address(hook)), 0, "hook szr");
        assertEq(usd.balanceOf(address(hook)), 0, "hook usd");
        assertEq(backing.balanceOf(address(hook)), 0, "hook weth");
        assertEq(address(hook).balance, 0, "hook ether");
        _assertCash();
    }

    /// A sale into the hooked pool leaves SZR cheap there. The hook buys it back with the
    /// partner token, sells it in the main pool for WETH and converts that WETH to repay.
    function _assertSaleBackrun(PoolKey memory pool) internal {
        uint256 inventory = core.unreleasedSupply();
        uint256 untouched = _price(pool);
        _trade(pool, address(szr), 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "profit retired");
        // A 50k sale into 1M of liquidity moves the price about 10%. The backrun undid most.
        assertGt(_price(pool), untouched * 97 / 100, "price restored");
        _assertHookEmpty();
        assertEq(hook.arb(_id(pool)), 0, "gap closed");
    }

    /// A purchase leaves SZR expensive in the hooked pool. The hook sells SZR there, turns
    /// the proceeds into WETH and buys more SZR back in the main pool.
    function _assertPurchaseBackrun(PoolKey memory pool, address partner) internal {
        uint256 inventory = core.unreleasedSupply();
        uint256 untouched = _price(pool);
        _trade(pool, partner, 50_000e18);
        assertGt(core.unreleasedSupply(), inventory, "profit retired");
        assertLt(_price(pool), untouched * 103 / 100, "price restored");
        _assertHookEmpty();
    }

    /// An empty tracked pool is moved to a chosen price for free and given liquidity that
    /// sits on the edge of its range, so it costs almost nothing but looks deep. `away` is
    /// how many ticks from the market it is placed.
    function _fakeVenue(int24 away, uint256 units) internal returns (PoolKey memory) {
        return _fakeVenueWithFee(away, units, 100);
    }

    function _fakeVenueWithFee(int24 away, uint256 units, uint24 fee)
        internal
        returns (PoolKey memory fake)
    {
        // On the same partner token as the pool the tests search, so it is one of the
        // leaders that pool is compared with.
        fake = _register(address(usd), fee, uint160(1 << 96));
        bool szrFirst = Currency.unwrap(fake.currency0) == address(szr);
        // SZR is made to look cheap: fewer WETH per SZR than anywhere else.
        int24 tick = szrFirst ? -away : away;
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            fake,
            IPoolManager.SwapParams(szrFirst, -1e30, TickMath.getSqrtPriceAtTick(tick)),
            settings,
            ""
        );
        provider.modifyLiquidity(
            fake,
            IPoolManager.ModifyLiquidityParams(
                szrFirst ? tick - 60 : tick, szrFirst ? tick : tick + 60, int256(units), 0
            ),
            ""
        );
    }

    function _failures() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.CycleFailed.selector) count++;
        }
    }

    function _buySzr() internal returns (uint256 received) {
        uint256 held = szr.balanceOf(address(this));
        _trade(usdPool, address(usd), 1_000e18);
        received = szr.balanceOf(address(this)) - held;
    }

    function _partnerOf(PoolKey memory pool) internal view returns (address) {
        bool szrFirst = Currency.unwrap(pool.currency0) == address(szr);
        return Currency.unwrap(szrFirst ? pool.currency1 : pool.currency0);
    }

    /// Makes a pool a leader of its partner token's group, if there is room for another.
    function _lead(PoolKey memory pool) internal {
        address partner = _partnerOf(pool);
        bytes32[] memory current = hook.leadersOf(1, address(szr), partner);
        if (current.length == hook.MAX_LEADERS()) return;
        if (current.length == 0) {
            if (hook.groupsOf(1, address(szr)).length == hook.MAX_GROUPS()) return;
        }
        bytes32[] memory list = new bytes32[](current.length + 1);
        for (uint256 index; index < current.length; index++) {
            list[index] = current[index];
        }
        list[current.length] = _id(pool);
        _setLeaders(partner, list);
    }

    /// Stops a pool leading, then stops tracking it.
    function _untrack(PoolKey memory pool) internal {
        address partner = _partnerOf(pool);
        bytes32[] memory current = hook.leadersOf(1, address(szr), partner);
        bytes32[] memory list = new bytes32[](current.length);
        uint256 kept;
        for (uint256 index; index < current.length; index++) {
            if (current[index] != _id(pool)) list[kept++] = current[index];
        }
        if (kept != current.length) {
            assembly ("memory-safe") {
                mstore(list, kept)
            }
            _setLeaders(partner, list);
        }
        hook.untrack(1, _id(pool));
    }

    /// Sets leaders, raising the gas allowance when the new set of venues needs more.
    function _setLeaders(address partner, bytes32[] memory list) internal {
        uint32 allowance = hook.market(1).gasLimit;
        uint128 profit = hook.minimumProfit(1, address(szr));
        uint64 edge = hook.market(1).minimumEdge;
        hook.setLimits(1, address(szr), 0, profit, edge);
        hook.setLeaders(1, address(szr), partner, list);
        if (allowance == 0) return;
        uint256 needed = hook.minimumGasLimit(1);
        hook.setLimits(
            1, address(szr), uint32(allowance > needed ? allowance : needed), profit, edge
        );
    }
}
