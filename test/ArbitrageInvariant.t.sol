// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { PayFirstRouter, PresyncRouter, HostileSyncRouter } from "./utils/Routers.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Everything that can happen around the hook: traders on every SZR pool, outside
/// markets moving the connecting pools, liquidity arriving and leaving in arbitrary ranges,
/// Core sales, redemptions and NAV changes, the manager trading and reconfiguring the hook,
/// stray tokens sent to it, swaps sent with too little gas, and an empty pool whose price
/// anyone can push to an extreme for free.
contract ArbitrageHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Stake {
        PoolKey pool;
        int24 lower;
        int24 upper;
        uint256 units;
    }

    struct Watch {
        uint256 backing;
        uint256 supply;
        uint256 floor;
    }

    ArbitrageHook public hook;
    SzrCore public core;
    Liquidity public locker;
    IPoolManager public manager;
    PoolSwapTest public swapper;
    PoolModifyLiquidityTest public provider;
    PayFirstRouter public payFirst;
    PresyncRouter public presync;
    HostileSyncRouter public hostile;
    TestAsset public szr;
    TestAsset public weth;
    PoolKey[] internal venues;
    uint256[] internal positions;
    PoolKey[] internal links;
    address[] internal assets;
    PoolKey internal hollow;
    Stake[] internal stakes;
    mapping(address asset => uint256 amount) public stray;

    bool public navFell;
    bool public profitBelowFloor;
    bool public donationMismatch;
    bool public managerSwapTouched;
    bool public hookHeld;

    uint256 public swaps;
    uint256 public volume;
    uint256 public cycles;
    uint256 public redeemCycles;
    uint256 public failures;
    uint256 public profit;
    uint256 public swapGas;
    uint256 public maxSwapGas;
    uint256 public starved;
    uint256 public starvedFilled;
    uint256 public managerSwaps;
    uint256 public payFirstSwaps;

    constructor(ArbitrageHook arbitrage, PoolSwapTest swaps_) {
        hook = arbitrage;
        swapper = swaps_;
        locker = arbitrage.liquidity();
        core = arbitrage.core();
        manager = arbitrage.poolManager();
        provider = new PoolModifyLiquidityTest(manager);
        payFirst = new PayFirstRouter(manager);
        presync = new PresyncRouter(manager);
        hostile = new HostileSyncRouter(manager);
        szr = TestAsset(arbitrage.token());
        weth = TestAsset(arbitrage.backingAsset());
    }

    function addVenue(PoolKey calldata pool, uint256 id) external {
        venues.push(pool);
        positions.push(id);
    }

    function addLink(PoolKey calldata pool) external {
        links.push(pool);
    }

    function setHollow(PoolKey calldata pool) external {
        hollow = pool;
    }

    function addAsset(address asset) external {
        assets.push(asset);
        TestAsset(asset).approve(address(swapper), type(uint256).max);
        TestAsset(asset).approve(address(provider), type(uint256).max);
        TestAsset(asset).approve(address(payFirst), type(uint256).max);
        TestAsset(asset).approve(address(presync), type(uint256).max);
        TestAsset(asset).approve(address(hostile), type(uint256).max);
        TestAsset(asset).approve(address(core), type(uint256).max);
    }

    function acceptManagement() external {
        locker.acceptManager();
    }

    function venueCount() external view returns (uint256) {
        return venues.length;
    }

    // ---- observation ----

    function _begin() internal returns (Watch memory watch) {
        watch.backing = core.backingAmount();
        watch.supply = core.activeSupply();
        watch.floor = hook.minimumProfit(1, address(szr));
        vm.recordLogs();
    }

    /// @dev Every cycle must earn at least the floor, every SZR earned must reach Core, NAV
    /// must not fall, and the hook must hold nothing afterwards.
    function _end(Watch memory watch) internal returns (uint256 found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 earned;
        uint256 donated;
        for (uint256 index; index < logs.length; index++) {
            Vm.Log memory entry = logs[index];
            if (entry.topics[0] == ArbitrageHook.Arbitraged.selector) {
                (, uint256 gained) = abi.decode(entry.data, (bool, uint256));
                earned += gained;
                found++;
                if (gained == 0) profitBelowFloor = true;
                if (gained < watch.floor) profitBelowFloor = true;
                if (entry.topics[2] == bytes32(0)) redeemCycles++;
            }
            if (entry.topics[0] == ArbitrageHook.CycleFailed.selector) failures++;
            if (entry.topics[0] == SzrCore.SzrDonated.selector) {
                if (entry.topics[1] == bytes32(uint256(uint160(address(hook))))) {
                    donated += abi.decode(entry.data, (uint256));
                }
            }
        }
        if (earned != donated) donationMismatch = true;
        cycles += found;
        profit += earned;
        _checkNav(watch);
        _checkEmpty();
    }

    function _checkNav(Watch memory watch) internal {
        uint256 supply = core.activeSupply();
        if (watch.supply == 0) return;
        if (supply == 0) return;
        if (core.backingAmount() * watch.supply < watch.backing * supply) navFell = true;
    }

    function _checkEmpty() internal {
        for (uint256 index; index < assets.length; index++) {
            address asset = assets[index];
            if (TestAsset(asset).balanceOf(address(hook)) != stray[asset]) hookHeld = true;
        }
    }

    function _partner(PoolKey memory pool) internal view returns (address) {
        bool first = Currency.unwrap(pool.currency0) == address(szr);
        return Currency.unwrap(first ? pool.currency1 : pool.currency0);
    }

    function _params(PoolKey memory pool, address input, uint256 amount)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        return IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// A pool already at the end of its price range cannot trade further that way.
    function _stuck(PoolKey memory pool, address input) internal view returns (bool) {
        (uint160 price,,,) = manager.getSlot0(pool.toId());
        return price == _params(pool, input, 1).sqrtPriceLimitX96;
    }

    function _fund(address input, uint256 amount) internal returns (bool funded) {
        if (input != address(szr)) {
            TestAsset(input).mint(address(this), amount);
            return true;
        }
        return szr.balanceOf(address(this)) >= amount;
    }

    // ---- traders ----

    function swap(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = venues[seed % venues.length];
        address input = sell ? address(szr) : _partner(pool);
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (_stuck(pool, input)) return;
        if (!_fund(input, amount)) return;
        Watch memory watch = _begin();
        PoolSwapTest.TestSettings memory settings;
        uint256 gas = gasleft();
        swapper.swap(pool, _params(pool, input, amount), settings, "");
        gas -= gasleft();
        swaps++;
        volume += amount;
        swapGas += gas;
        if (gas > maxSwapGas) maxSwapGas = gas;
        _end(watch);
    }

    /// A swap sent with a gas limit that may be too small. It may fail; it must not leave
    /// anything inconsistent behind either way.
    function starve(uint256 seed, bool sell, uint256 raw, uint256 rawGas) external {
        PoolKey memory pool = venues[seed % venues.length];
        address input = sell ? address(szr) : _partner(pool);
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (!_fund(input, amount)) return;
        Watch memory watch = _begin();
        PoolSwapTest.TestSettings memory settings;
        (bool filled,) = address(swapper).call{ gas: bound(rawGas, 150_000, 9_000_000) }(
            abi.encodeCall(swapper.swap, (pool, _params(pool, input, amount), settings, ""))
        );
        starved++;
        if (filled) starvedFilled++;
        _end(watch);
    }

    /// A router that pays the pool manager before it swaps, in SZR or in the partner token.
    function paidFirst(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = venues[seed % venues.length];
        address input = sell ? address(szr) : _partner(pool);
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (_stuck(pool, input)) return;
        if (!_fund(input, amount)) return;
        Watch memory watch = _begin();
        payFirst.trade(pool, input, amount);
        payFirstSwaps++;
        _end(watch);
    }

    /// Anyone can mark SZR as synced with the pool manager before swapping. It must not
    /// switch the hook off.
    function presynced(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = venues[seed % venues.length];
        address input = sell ? address(szr) : _partner(pool);
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (_stuck(pool, input)) return;
        if (!_fund(input, amount)) return;
        Watch memory watch = _begin();
        // Sometimes SZR, sometimes the pool's other token, and sometimes a token written to
        // misreport its balance, revert or burn gas once it has been marked.
        if (seed % 4 == 3) {
            hostile.trade(pool, input, amount, 1 + seed % 3);
            _end(watch);
            return;
        }
        address synced = seed % 3 == 0 ? _partner(pool) : address(szr);
        presync.trade(pool, input, amount, synced);
        _end(watch);
    }

    /// The outside market moves a connecting pool.
    function moveMarket(uint256 seed, bool up, uint256 raw) external {
        PoolKey memory pool = links[seed % links.length];
        address input = Currency.unwrap(up ? pool.currency1 : pool.currency0);
        uint256 amount = bound(raw, 1e15, 300_000e18);
        TestAsset(input).mint(address(this), amount);
        Watch memory watch = _begin();
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(pool, _params(pool, input, amount), settings, "");
        _end(watch);
    }

    function arb(uint256 seed) external {
        bytes32 poolId = PoolId.unwrap(venues[seed % venues.length].toId());
        if (hook.partnerOf(poolId) == address(0)) return;
        Watch memory watch = _begin();
        hook.arb(poolId);
        _end(watch);
    }

    /// Anyone can move an empty pool's price as far as they like for nothing.
    function shove(bool up) external {
        if (manager.getLiquidity(hollow.toId()) != 0) return;
        address input = Currency.unwrap(up ? hollow.currency1 : hollow.currency0);
        if (_stuck(hollow, input)) return;
        Watch memory watch = _begin();
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(hollow, _params(hollow, input, 1e30), settings, "");
        _end(watch);
    }

    // ---- liquidity providers ----

    function stake(uint256 seed, bool link, uint256 rawOffset, uint256 rawWidth, uint256 raw)
        external
    {
        if (stakes.length == 16) return;
        PoolKey memory pool = link ? links[seed % links.length] : venues[seed % venues.length];
        (uint160 price, int24 tick,,) = manager.getSlot0(pool.toId());
        if (price == 0) return;
        int24 spacing = pool.tickSpacing;
        int24 width = int24(int256(bound(rawWidth, 1, 100)));
        int24 offset = int24(int256(bound(rawOffset, 0, 200))) - 100 - width / 2;
        int24 lower = (tick / spacing + offset) * spacing;
        int24 upper = lower + width * spacing;
        if (lower < TickMath.minUsableTick(spacing)) return;
        if (upper > TickMath.maxUsableTick(spacing)) return;
        uint256 units = bound(raw, 1e18, 200_000e18);
        _mintPair(pool);
        IPoolManager.ModifyLiquidityParams memory params =
            IPoolManager.ModifyLiquidityParams(lower, upper, int256(units), 0);
        // Fails only when this actor holds too little SZR for the range.
        try provider.modifyLiquidity(pool, params, "") {
            stakes.push(Stake(pool, lower, upper, units));
        } catch { }
    }

    function _mintPair(PoolKey memory pool) internal {
        address first = Currency.unwrap(pool.currency0);
        address second = Currency.unwrap(pool.currency1);
        if (first != address(szr)) TestAsset(first).mint(address(this), 1_000_000e18);
        if (second != address(szr)) TestAsset(second).mint(address(this), 1_000_000e18);
    }

    function unstake(uint256 seed) external {
        if (stakes.length == 0) return;
        uint256 index = seed % stakes.length;
        Stake memory entry = stakes[index];
        stakes[index] = stakes[stakes.length - 1];
        stakes.pop();
        provider.modifyLiquidity(
            entry.pool,
            IPoolManager.ModifyLiquidityParams(
                entry.lower, entry.upper, -int256(entry.units), 0
            ),
            ""
        );
    }

    // ---- Core ----

    function coreBuy(uint256 raw) external {
        uint256 quantity = core.availableRelease();
        if (quantity == 0) return;
        quantity = bound(raw, 1, quantity > 1_000e18 ? 1_000e18 : quantity);
        (uint256 payment,,) = core.quote(quantity);
        weth.mint(address(this), payment);
        core.buy(quantity, payment, block.timestamp);
    }

    function coreRedeem(uint256 raw) external {
        uint256 held = szr.balanceOf(address(this));
        if (held == 0) return;
        uint256 amount = bound(raw, 1, held > 5_000e18 ? 5_000e18 : held);
        uint256 backing = amount * core.backingAmount() / core.activeSupply();
        if (backing > core.reserveCash()) return;
        core.redeem(amount, 0);
    }

    /// Lifts NAV towards and above pool prices, which is when redemption becomes a venue.
    function liftNav(uint256 raw) external {
        uint256 amount = bound(raw, 1e18, 6_000_000e18);
        weth.mint(address(this), amount);
        core.donateBacking(amount);
    }

    function elapse(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 1, 2 days));
    }

    // ---- manager ----

    function managerSwap(uint256 seed, uint256 raw) external {
        uint256 held = locker.heldPrincipal(address(weth));
        if (held < 2) return;
        PoolKey memory pool = venues[seed % venues.length];
        if (_partner(pool) != address(weth)) return;
        if (_stuck(pool, address(weth))) return;
        Watch memory watch = _begin();
        IPoolManager.SwapParams memory params = _params(pool, address(weth), 1);
        locker.swapPrincipal(
            pool,
            params.zeroForOne,
            bound(raw, 1, held),
            0,
            params.sqrtPriceLimitX96,
            block.timestamp
        );
        managerSwaps++;
        if (_end(watch) != 0) managerSwapTouched = true;
    }

    function configure(uint256 seed, uint256 rawGas, uint256 rawProfit, uint256 rawEdge)
        external
    {
        uint256 gas = seed % 8 == 0 ? 0 : bound(rawGas, hook.minimumGasLimit(1), 14_000_000);
        hook.setLimits(
            1,
            address(szr),
            uint32(gas),
            uint128(bound(rawProfit, 0, 200e18)),
            uint64(bound(rawEdge, 1e18, 1.02e18))
        );
    }

    function toggleTrack(uint256 seed) external {
        uint256 index = seed % venues.length;
        bytes32 poolId = PoolId.unwrap(venues[index].toId());
        if (hook.partnerOf(poolId) == address(0)) {
            hook.track(positions[index]);
            return;
        }
        // A leader has to stand down before it can be untracked.
        _lead(venues[index], false);
        hook.untrack(1, poolId);
    }

    /// The manager changes which pools lead their group.
    function toggleLeader(uint256 seed) external {
        PoolKey memory pool = venues[seed % venues.length];
        bytes32 poolId = PoolId.unwrap(pool.toId());
        if (hook.partnerOf(poolId) == address(0)) return;
        _lead(pool, !_leads(pool));
    }

    function _leads(PoolKey memory pool) internal view returns (bool) {
        bytes32[] memory current = hook.leadersOf(1, address(szr), _partner(pool));
        bytes32 poolId = PoolId.unwrap(pool.toId());
        for (uint256 index; index < current.length; index++) {
            if (current[index] == poolId) return true;
        }
        return false;
    }

    /// Adds a pool to its group's leaders when there is room, or removes it.
    function _lead(PoolKey memory pool, bool wanted) internal {
        if (_leads(pool) == wanted) return;
        address partner = _partner(pool);
        bytes32 poolId = PoolId.unwrap(pool.toId());
        bytes32[] memory current = hook.leadersOf(1, address(szr), partner);
        bytes32[] memory list = new bytes32[](wanted ? current.length + 1 : current.length - 1);
        if (list.length > hook.MAX_LEADERS()) return;
        uint256 kept;
        for (uint256 index; index < current.length; index++) {
            if (current[index] != poolId) list[kept++] = current[index];
        }
        if (wanted) list[kept] = poolId;
        // The allowance must cover the venues a search prices, which this can change.
        uint32 allowance = hook.market(1).gasLimit;
        uint128 floor = hook.minimumProfit(1, address(szr));
        uint64 edge = hook.market(1).minimumEdge;
        hook.setLimits(1, address(szr), 0, floor, edge);
        hook.setLeaders(1, address(szr), partner, list);
        if (allowance == 0) return;
        uint256 needed = hook.minimumGasLimit(1);
        hook.setLimits(
            1, address(szr), uint32(allowance > needed ? allowance : needed), floor, edge
        );
    }

    function toggleLink(uint256 seed) external {
        PoolKey memory pool = links[seed % links.length];
        bytes32 current =
            hook.connector(1, Currency.unwrap(pool.currency0), Currency.unwrap(pool.currency1));
        hook.setConnector(1, pool, current == bytes32(0));
    }

    // ---- strangers ----

    function gift(uint256 seed, uint256 raw) external {
        address asset = assets[seed % assets.length];
        uint256 amount = bound(raw, 1, 10e18);
        if (!_fund(asset, amount)) return;
        TestAsset(asset).transfer(address(hook), amount);
        stray[asset] += amount;
    }

    // ---- end of run ----

    /// Puts the hook back in its normal configuration.
    function restore() external {
        hook.setLimits(1, address(szr), 14_000_000, 10e18, 1.0001e18);
        for (uint256 index; index < venues.length; index++) {
            bytes32 poolId = PoolId.unwrap(venues[index].toId());
            if (hook.partnerOf(poolId) == address(0)) hook.track(positions[index]);
            _lead(venues[index], true);
        }
        for (uint256 index; index < links.length; index++) {
            hook.setConnector(1, links[index], true);
        }
    }

    /// One `arb` on every pool; the SZR it earned.
    function sweep() external returns (uint256 earned) {
        Watch memory watch = _begin();
        for (uint256 index; index < venues.length; index++) {
            earned += hook.arb(PoolId.unwrap(venues[index].toId()));
        }
        _end(watch);
    }
}

contract ArbitrageInvariantTest is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;

    ArbitrageHandler internal handler;

    function setUp() public override {
        super.setUp();
        // This contract holds a limited amount of SZR to spread over the pools and traders.
        poolUnits = 400_000e18;
        // Deployed from its artifact so that this contract does not carry its code.
        handler = ArbitrageHandler(
            deployCode("ArbitrageInvariant.t.sol:ArbitrageHandler", abi.encode(hook, swapper))
        );
        handler.addAsset(address(szr));
        handler.addAsset(address(backing));
        handler.addVenue(mainPool, 0);
        _join(usdPool, usd);
        handler.addVenue(_addHooked(address(backing), 500), locker.poolCount() - 1);
        TestAsset eur = new TestAsset();
        _join(_addPartner(eur), eur);
        // A partner whose address sorts above SZR, so SZR is that pool's first token.
        address high = address(uint160(address(szr)) + 1);
        deployCodeTo("TestAsset.sol:TestAsset", high);
        _join(_addPartner(TestAsset(high)), TestAsset(high));
        PoolKey memory hollow = _register(address(backing), 100, uint160(1 << 96));
        handler.addVenue(hollow, locker.poolCount() - 1);
        handler.setHollow(hollow);
        szr.transfer(address(handler), szr.balanceOf(address(this)));
        locker.nominateManager(address(handler));
        handler.acceptManagement();
        _target();
    }

    /// A hooked SZR/partner pool together with its WETH/partner connecting pool.
    function _join(PoolKey memory pool, TestAsset partner) internal {
        handler.addAsset(address(partner));
        handler.addVenue(pool, locker.poolCount() - 1);
        bool wethFirst = address(backing) < address(partner);
        handler.addLink(
            PoolKey(
                Currency.wrap(wethFirst ? address(backing) : address(partner)),
                Currency.wrap(wethFirst ? address(partner) : address(backing)),
                3_000,
                60,
                IHooks(address(0))
            )
        );
    }

    function _target() internal virtual {
        bytes4[] memory selectors = new bytes4[](21);
        selectors[20] = handler.toggleLeader.selector;
        selectors[18] = handler.paidFirst.selector;
        selectors[19] = handler.presynced.selector;
        selectors[16] = handler.gift.selector;
        selectors[17] = handler.toggleLink.selector;
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.starve.selector;
        selectors[4] = handler.moveMarket.selector;
        selectors[5] = handler.arb.selector;
        selectors[6] = handler.shove.selector;
        selectors[7] = handler.stake.selector;
        selectors[8] = handler.unstake.selector;
        selectors[9] = handler.coreBuy.selector;
        selectors[10] = handler.coreRedeem.selector;
        selectors[11] = handler.liftNav.selector;
        selectors[12] = handler.elapse.selector;
        selectors[13] = handler.managerSwap.selector;
        selectors[14] = handler.configure.selector;
        selectors[15] = handler.toggleTrack.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// The hook never loses, never keeps anything, never lowers NAV, and never touches a
    /// swap made by Liquidity. Core's and Liquidity's own books stay balanced throughout.
    function invariantHookStaysWholeAndBooksBalance() public view {
        assertFalse(handler.profitBelowFloor(), "a cycle earned less than the floor");
        assertFalse(handler.donationMismatch(), "earned SZR did not all reach Core");
        assertFalse(handler.navFell(), "NAV fell");
        assertFalse(handler.hookHeld(), "the hook kept a balance");
        assertFalse(handler.managerSwapTouched(), "a manager swap was searched");
        _assertCash();
    }

    /// Every group has between one and the most leaders allowed, each one a tracked pool
    /// of that group's partner token, listed once.
    function invariantGroupsAndLeadersAreConsistent() public view {
        uint256 count = hook.groupsOf(1, address(szr)).length;
        assertLe(count, hook.MAX_GROUPS());
        for (uint256 index; index < count; index++) {
            address partner = hook.groupsOf(1, address(szr))[index];
            bytes32[] memory list = hook.leadersOf(1, address(szr), partner);
            assertGt(list.length, 0, "group without a leader");
            assertLe(list.length, hook.MAX_LEADERS());
            for (uint256 place; place < list.length; place++) {
                assertEq(
                    hook.partnerOf(list[place]), partner, "leader not tracked in its group"
                );
                for (uint256 other; other < place; other++) {
                    assertTrue(list[other] != list[place], "leader listed twice");
                }
            }
        }
    }

    /// With everything tracked again, repeated sweeps must run out of gaps.
    function afterInvariant() public {
        handler.restore();
        uint256 passes;
        while (handler.sweep() != 0) {
            passes++;
            assertLt(passes, 12, "sweeps did not converge");
        }
        invariantHookStaysWholeAndBooksBalance();
        console2.log("swaps", handler.swaps());
        console2.log("  volume, in input tokens", handler.volume() / 1e18);
        uint256 volume = handler.volume();
        console2.log(
            "  SZR retired per 10,000 traded", volume == 0 ? 0 : handler.profit() * 1e4 / volume
        );
        console2.log(
            "  average gas", handler.swaps() == 0 ? 0 : handler.swapGas() / handler.swaps()
        );
        console2.log("  highest gas", handler.maxSwapGas());
        console2.log("cycles", handler.cycles());
        console2.log("  through Core redemption", handler.redeemCycles());
        console2.log("  failed at every size", handler.failures());
        console2.log("  SZR retired", handler.profit() / 1e18);
        console2.log("short-gas swaps", handler.starved());
        console2.log("  of which filled", handler.starvedFilled());
        console2.log("manager swaps", handler.managerSwaps());
        console2.log("pay-first swaps", handler.payFirstSwaps());
    }
}

/// @dev The same world with only ordinary market activity: traders, outside markets,
/// liquidity providers, Core sales and redemptions, and time. Nothing lifts NAV in jumps,
/// reconfigures the hook, or pushes empty pools around, so the figures it logs are closer
/// to what the hook would earn day to day.
contract ArbitrageMarketInvariantTest is ArbitrageInvariantTest {
    function _target() internal override {
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.swap.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.swap.selector;
        selectors[3] = handler.swap.selector;
        selectors[4] = handler.moveMarket.selector;
        selectors[5] = handler.stake.selector;
        selectors[6] = handler.unstake.selector;
        selectors[7] = handler.coreBuy.selector;
        selectors[8] = handler.coreRedeem.selector;
        selectors[9] = handler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }
}
