// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev What everyone ends up with, not only what the hook holds (docs/specs/
/// hook-fund-safety-tests.md, item 5). Swappers trade in hooked and hookless pools with
/// random gas and price limits, LPs come and go, `arb` and `sweep` run, and Core takes
/// backing, lends and is repaid. After every call the ghosts below say whether a swapper got
/// anything but the pool's own result, whether NAV fell, whether the hook held anything, and
/// whether the profit it made is all accounted for.
contract ConservationHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Stake {
        PoolKey pool;
        int24 lower;
        int24 upper;
        uint256 units;
    }

    ArbitrageApi public hook;
    SzrCore public core;
    IPoolManager public manager;
    PoolSwapTest public swapper;
    PoolModifyLiquidityTest public provider;
    TestAsset public szr;
    TestAsset public weth;
    uint256 public outside;
    PoolKey[] internal pools;
    address[] internal assets;
    Stake[] internal stakes;

    bool public hookHeld;
    bool public swapMismatch;
    bool public pastLimit;
    bool public navFell;

    uint256 public swaps;
    uint256 public swapReverts;
    uint256 public cycles;
    uint256 public redeemCycles;
    uint256 public payouts;
    uint256 public arbs;
    uint256 public sweeps;
    uint256 public loans;
    uint256 public positions;
    /// The sums that must agree: every cycle's profit, what reached Core as SZR, and what
    /// was paid out in the market's token.
    uint256 public earned;
    uint256 public donated;
    uint256 public paid;
    /// What the outside market's recipient and the protocol's recipients must have gained.
    mapping(address asset => uint256 amount) public marketShare;
    mapping(address asset => uint256 amount) public protocolShare;

    struct Watch {
        uint256 backing;
        uint256 supply;
    }

    constructor(ArbitrageApi arbitrage, PoolSwapTest swaps_, uint256 outsideId) {
        hook = arbitrage;
        swapper = swaps_;
        manager = arbitrage.poolManager();
        core = arbitrage.core();
        provider = new PoolModifyLiquidityTest(manager);
        szr = TestAsset(arbitrage.token());
        weth = TestAsset(arbitrage.backingAsset());
        outside = outsideId;
    }

    function addPool(PoolKey calldata pool) external {
        pools.push(pool);
    }

    function addAsset(address asset) external {
        assets.push(asset);
        TestAsset(asset).approve(address(swapper), type(uint256).max);
        TestAsset(asset).approve(address(provider), type(uint256).max);
        TestAsset(asset).approve(address(core), type(uint256).max);
    }

    // ---- observation ----

    function _begin() internal returns (Watch memory watch) {
        watch.backing = core.backingAmount();
        watch.supply = core.activeSupply();
        vm.recordLogs();
    }

    function _end(Watch memory watch) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory entry = logs[index];
            if (entry.emitter == address(hook)) _hookEvent(entry);
            if (entry.emitter != address(core)) continue;
            if (entry.topics[0] != SzrCore.SzrDonated.selector) continue;
            if (entry.topics[1] == bytes32(uint256(uint160(address(hook))))) {
                donated += abi.decode(entry.data, (uint256));
            }
        }
        uint256 supply = core.activeSupply();
        if (watch.supply != 0) {
            if (supply != 0) {
                if (core.backingAmount() * watch.supply < watch.backing * supply) {
                    navFell = true;
                }
            }
        }
        _checkEmpty();
    }

    function _hookEvent(Vm.Log memory entry) internal {
        if (entry.topics[0] == ArbitrageLogic.Arbitraged.selector) {
            (, uint256 gained) = abi.decode(entry.data, (bool, uint256));
            earned += gained;
            cycles++;
            if (entry.topics[2] == bytes32(0)) redeemCycles++;
        }
        if (entry.topics[0] == ArbitrageLogic.ProfitPaid.selector) {
            (uint256 amount, uint256 share) = abi.decode(entry.data, (uint256, uint256));
            address asset = address(uint160(uint256(entry.topics[2])));
            paid += amount;
            payouts++;
            if (uint256(entry.topics[1]) == outside) marketShare[asset] += amount - share;
            protocolShare[asset] += share;
        }
    }

    function _checkEmpty() internal {
        if (address(hook).balance != 0) hookHeld = true;
        for (uint256 index; index < assets.length; index++) {
            address asset = assets[index];
            if (TestAsset(asset).balanceOf(address(hook)) != 0) hookHeld = true;
            if (manager.balanceOf(address(hook), uint256(uint160(asset))) != 0) {
                hookHeld = true;
            }
        }
    }

    // ---- swappers ----

    function swap(
        uint256 poolSeed,
        bool zeroForOne,
        uint256 amountSeed,
        uint256 gasSeed,
        uint256 limitSeed
    ) external {
        PoolKey memory pool = pools[poolSeed % pools.length];
        uint256 amount = _amount(pool, zeroForOne, amountSeed);
        if (amount == 0) return;
        int256 signed = amountSeed % 5 == 0 ? int256(amount) : -int256(amount);
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams(zeroForOne, signed, _limit(pool, zeroForOne, limitSeed));
        _run(pool, params, _gas(pool, gasSeed));
    }

    /// What the handler can pay in, a quarter of its balance at most.
    function _amount(PoolKey memory pool, bool zeroForOne, uint256 seed)
        internal
        view
        returns (uint256 amount)
    {
        address input = Currency.unwrap(zeroForOne ? pool.currency0 : pool.currency1);
        uint256 balance = TestAsset(input).balanceOf(address(this));
        amount = bound(seed, 1e12, 5_000e18);
        if (amount > balance / 4) amount = balance / 4;
    }

    function _run(PoolKey memory pool, IPoolManager.SwapParams memory params, uint256 gas)
        internal
    {
        TestAsset token0 = TestAsset(Currency.unwrap(pool.currency0));
        TestAsset token1 = TestAsset(Currency.unwrap(pool.currency1));
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        Watch memory watch = _begin();
        PoolSwapTest.TestSettings memory settings;
        try swapper.swap{ gas: gas }(pool, params, settings, "") returns (BalanceDelta delta) {
            swaps++;
            if (int256(token0.balanceOf(address(this))) - int256(before0) != delta.amount0()) {
                swapMismatch = true;
            }
            if (int256(token1.balanceOf(address(this))) - int256(before1) != delta.amount1()) {
                swapMismatch = true;
            }
            _checkLimit(pool, params.zeroForOne, params.sqrtPriceLimitX96);
        } catch {
            swapReverts++;
        }
        _end(watch);
    }

    /// A limit anywhere from just inside the price to nearly the edge of its range.
    function _limit(PoolKey memory pool, bool zeroForOne, uint256 seed)
        internal
        view
        returns (uint160)
    {
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        uint256 basis = bound(seed, 1, 9_000);
        if (zeroForOne) {
            uint256 low = uint256(price) * (10_000 - basis) / 10_000;
            return low > TickMath.MIN_SQRT_PRICE ? uint160(low) : TickMath.MIN_SQRT_PRICE + 1;
        }
        uint256 high = uint256(price) * (10_000 + basis) / 10_000;
        return high < TickMath.MAX_SQRT_PRICE ? uint160(high) : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// At or above what a hooked swap needs, plus anything up to three million more.
    function _gas(PoolKey memory pool, uint256 seed) internal view returns (uint256) {
        uint256 extra = bound(seed, 0, 3_000_000);
        if (address(pool.hooks) != address(hook)) return 6_000_000 + extra;
        uint256 market = hook.tracked(1, PoolId.unwrap(pool.toId())) ? 1 : outside;
        return hook.gasForSwap(market) + extra;
    }

    /// In a pool that runs no hook the fill itself ends at or inside the limit. A hooked
    /// pool's own cycles move its price afterwards, so only its balances are checked.
    function _checkLimit(PoolKey memory pool, bool zeroForOne, uint160 limit) internal {
        if (address(pool.hooks) == address(hook)) return;
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        if (zeroForOne) {
            if (price < limit) pastLimit = true;
        } else {
            if (price > limit) pastLimit = true;
        }
    }

    // ---- liquidity ----

    function stake(uint256 poolSeed, uint256 lowerSeed, uint256 widthSeed, uint256 unitsSeed)
        external
    {
        PoolKey memory pool = pools[poolSeed % pools.length];
        (, int24 tick,,) = manager.getSlot0(pool.toId());
        int24 base = tick / 60 * 60;
        int24 lower = base + int24(int256(bound(lowerSeed, 0, 40))) * 60 - 1_200;
        int24 upper = lower + int24(int256(bound(widthSeed, 1, 40))) * 60;
        uint256 units = bound(unitsSeed, 1e15, 1e21);
        Watch memory watch = _begin();
        try provider.modifyLiquidity(
            pool, IPoolManager.ModifyLiquidityParams(lower, upper, int256(units), 0), ""
        ) {
            stakes.push(Stake(pool, lower, upper, units));
            positions++;
        } catch { }
        _end(watch);
    }

    function unstake(uint256 seed) external {
        if (stakes.length == 0) return;
        Stake storage held = stakes[seed % stakes.length];
        if (held.units == 0) return;
        Watch memory watch = _begin();
        try provider.modifyLiquidity(
            held.pool,
            IPoolManager.ModifyLiquidityParams(held.lower, held.upper, -int256(held.units), 0),
            ""
        ) {
            held.units = 0;
        } catch { }
        _end(watch);
    }

    /// Every LP takes everything out. All of it must work.
    function exitAll() external {
        for (uint256 index; index < stakes.length; index++) {
            Stake storage held = stakes[index];
            if (held.units == 0) continue;
            provider.modifyLiquidity(
                held.pool,
                IPoolManager.ModifyLiquidityParams(
                    held.lower, held.upper, -int256(held.units), 0
                ),
                ""
            );
            held.units = 0;
        }
    }

    // ---- hook calls ----

    function arb(uint256 seed) external {
        PoolKey memory pool = pools[seed % pools.length];
        if (address(pool.hooks) != address(hook)) return;
        Watch memory watch = _begin();
        try hook.arb(PoolId.unwrap(pool.toId())) {
            arbs++;
        } catch { }
        _end(watch);
    }

    function sweep(uint256 seed) external {
        Watch memory watch = _begin();
        if (seed % 2 == 0) {
            try hook.sweep(1, address(szr)) {
                sweeps++;
            } catch { }
        } else {
            try hook.sweep(outside, address(weth)) {
                sweeps++;
            } catch { }
        }
        _end(watch);
    }

    // ---- Core ----

    function donate(uint256 seed) external {
        uint256 amount = bound(seed, 1e15, 1_000_000e18);
        weth.mint(address(this), amount);
        Watch memory watch = _begin();
        try core.donateBacking(amount) { } catch { }
        _end(watch);
    }

    function borrow(uint256 seed) external {
        uint256 collateral = bound(seed, 1e18, szr.balanceOf(address(this)) / 20 + 1e18);
        if (collateral > szr.balanceOf(address(this))) return;
        uint256 capacity = collateral * core.backingAmount() / core.activeSupply();
        if (capacity < 1e6) return;
        Watch memory watch = _begin();
        try core.borrow(collateral, capacity / 2) {
            loans++;
        } catch { }
        _end(watch);
    }

    function repay(uint256 seed) external {
        (, uint256 principal,) = core.loans(address(this));
        if (principal == 0) return;
        uint256 part = bound(seed, 1, principal);
        weth.mint(address(this), part);
        Watch memory watch = _begin();
        try core.repayAndReclaim(part) { } catch { }
        _end(watch);
    }

    function elapse(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 1, 2 days));
    }
}

contract ArbitrageConservationInvariantTest is MarketsWorld {
    ConservationHandler internal handler;
    /// What Core's WETH balance holds beyond its counted cash before any profit reaches it.
    uint256 internal coreExcess;

    function setUp() public override {
        super.setUp();
        // The launch regime: SZR's pool a little under NAV, so Core is worth using, and the
        // market drifts across NAV as it trades.
        _poolAtNavRatio(0.95e18);
        // Deployed by name: embedding the handler's code would put this contract over the
        // size limit.
        handler = ConservationHandler(
            deployCode(
                "ArbitrageConservationInvariant.t.sol:ConservationHandler",
                abi.encode(hook, swapper, id)
            )
        );
        handler.addPool(mainPool);
        handler.addPool(usdPool);
        handler.addPool(first);
        handler.addPool(second);
        handler.addPool(publicPool);
        handler.addAsset(address(szr));
        handler.addAsset(address(backing));
        handler.addAsset(address(usd));
        handler.addAsset(address(coin));
        backing.mint(address(handler), 10_000_000e18);
        usd.mint(address(handler), 10_000_000e18);
        coin.mint(address(handler), 10_000_000e18);
        szr.transfer(address(handler), szr.balanceOf(address(this)));
        coreExcess = backing.balanceOf(address(core)) - core.reserveCash();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.swap.selector;
        selectors[4] = handler.stake.selector;
        selectors[5] = handler.unstake.selector;
        selectors[6] = handler.arb.selector;
        selectors[7] = handler.sweep.selector;
        selectors[8] = handler.donate.selector;
        selectors[9] = handler.borrow.selector;
        selectors[10] = handler.repay.selector;
        selectors[11] = handler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_theHookHoldsNothing() public view {
        assertFalse(handler.hookHeld(), "the hook held a token or a claim");
    }

    function invariant_swappersGetExactlyThePoolsResult() public view {
        assertFalse(handler.swapMismatch(), "a swapper's balance moved by other than its delta");
        assertFalse(handler.pastLimit(), "a hookless pool filled past the price limit");
    }

    function invariant_navNeverFalls() public view {
        assertFalse(handler.navFell(), "NAV fell");
    }

    /// Every cycle's profit reached Core as SZR or was paid out, and the recipients gained
    /// exactly their shares: the market's recipient and the protocol's, in each token.
    function invariant_profitIsAccountedFor() public view {
        assertEq(handler.earned(), handler.donated() + handler.paid(), "profit and what moved");
        assertEq(
            backing.balanceOf(treasury),
            handler.marketShare(address(backing)) + handler.marketShare(address(0)),
            "the market's WETH"
        );
        assertEq(usd.balanceOf(treasury), handler.marketShare(address(usd)), "the market's USD");
        assertEq(usd.balanceOf(desk), handler.protocolShare(address(usd)), "the protocol's USD");
        assertEq(
            backing.balanceOf(address(core)) - core.reserveCash(),
            coreExcess + handler.protocolShare(address(backing))
                + handler.protocolShare(address(0)),
            "the protocol's WETH reached Core"
        );
    }

    /// Everyone can exit: every LP takes all its liquidity out, and nothing reverts.
    function afterInvariant() public {
        console2.log("swaps", handler.swaps(), "reverted", handler.swapReverts());
        console2.log("cycles", handler.cycles(), "Core redemptions", handler.redeemCycles());
        console2.log("payouts", handler.payouts(), "arbs", handler.arbs());
        console2.log("sweeps", handler.sweeps(), "loans", handler.loans());
        uint256 snapshot = vm.snapshotState();
        handler.exitAll();
        assertGe(backing.balanceOf(address(manager)), 0);
        vm.revertToState(snapshot);
    }

    /// The handler does reach cycles, Core redemptions and payouts, in a scripted run (the
    /// invariants are worth nothing if it cannot).
    function testTheHandlerReachesCyclesRedemptionsAndPayouts() public {
        for (uint256 round; round < 6; round++) {
            handler.swap(1, round % 2 == 0, 1e21 + round, 4_000_000, 9_000);
            handler.arb(1);
            handler.swap(2, round % 2 == 1, 3e21 + round, 4_000_000, 9_000);
            handler.sweep(round);
        }
        assertGt(handler.cycles(), 0, "cycles");
        assertGt(handler.redeemCycles(), 0, "Core redemptions");
        assertGt(handler.payouts(), 0, "payouts");
        assertFalse(handler.hookHeld());
        assertFalse(handler.swapMismatch());
        assertEq(handler.earned(), handler.donated() + handler.paid());
    }
}
