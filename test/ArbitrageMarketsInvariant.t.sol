// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { PayFirstRouter } from "./utils/Routers.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

/// @dev A token whose balance can be made to misreport: a huge figure, a revert, or a
/// loop that burns gas. Anyone can open a market for a token like this.
contract HostileAsset is TestAsset {
    uint256 public mode;

    function arm(uint256 value) external {
        mode = value;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        if (mode == 1) return 1 << 200;
        if (mode == 2) revert("hostile");
        if (mode == 3) {
            uint256 spin;
            while (gasleft() > 2_000) spin++;
            return spin;
        }
        return super.balanceOf(owner);
    }
}

/// @dev Marks the hostile token as synced, switches its misbehaviour on, swaps, then
/// switches it off and pays in the ordinary way.
contract HostileHomeRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(PoolKey calldata pool, HostileAsset coin, uint256 amount, uint256 mode)
        external
    {
        manager.unlock(abi.encode(msg.sender, pool, coin, amount, mode));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, HostileAsset coin, uint256 amount, uint256 mode) =
            abi.decode(data, (address, PoolKey, HostileAsset, uint256, uint256));
        Currency input = Currency.wrap(address(coin));
        manager.sync(input);
        coin.arm(mode);
        bool zeroForOne = pool.currency0 == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        coin.arm(0);
        manager.sync(input);
        coin.transferFrom(
            payer, address(manager), uint128(-(zeroForOne ? delta.amount0() : delta.amount1()))
        );
        manager.settle();
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (received != 0) {
            manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        }
        return "";
    }
}

/// @dev Trades in SZR's market and in an open market whose own token is hostile, and
/// plays that market's owner. The market has pools against WETH and against USD, counts
/// profit in both, and trades against a public pool that SZR's market also uses. Each
/// action records whether it reached across markets.
contract MarketsHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ArbitrageHook public hook;
    SzrCore public core;
    IPoolManager public manager;
    PoolSwapTest public swapper;
    PayFirstRouter public payFirst;
    HostileHomeRouter public hostile;
    TestAsset public szr;
    TestAsset public weth;
    TestAsset public usd;
    HostileAsset public coin;
    uint256 public id;
    address public treasury = address(0x7EA4);
    PoolKey[] internal own;
    PoolKey[] internal theirs;
    PoolKey internal shared;

    bool public leaked;
    uint256 public teamActions;
    uint256 public hostileSwaps;
    uint256 public hostileFilled;

    constructor(
        ArbitrageHook arbitrage,
        PoolSwapTest swaps,
        HostileAsset asset,
        TestAsset dollars
    ) {
        hook = arbitrage;
        swapper = swaps;
        core = arbitrage.core();
        manager = arbitrage.poolManager();
        payFirst = new PayFirstRouter(manager);
        hostile = new HostileHomeRouter(manager);
        szr = TestAsset(arbitrage.token());
        weth = TestAsset(arbitrage.backingAsset());
        usd = dollars;
        coin = asset;
        id = arbitrage.openMarket(treasury);
    }

    function create(PoolKey calldata pool) external {
        hook.createPool(id, pool, uint160(1 << 96));
        theirs.push(pool);
    }

    function addOwn(PoolKey calldata pool) external {
        own.push(pool);
    }

    function _one(bytes32 only) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = only;
    }

    /// Two WETH pools and one USD pool for the hostile token, compared with each other
    /// across the public WETH/USD pool.
    function start(PoolKey calldata publicPool) external {
        shared = publicPool;
        hook.addVenue(id, publicPool);
        bytes32[] memory pair = new bytes32[](2);
        pair[0] = PoolId.unwrap(theirs[0].toId());
        pair[1] = PoolId.unwrap(theirs[1].toId());
        bytes32 common = PoolId.unwrap(shared.toId());
        hook.setLeaders(id, address(weth), address(coin), pair);
        hook.setLeaders(id, address(weth), address(usd), _one(common));
        hook.setLeaders(id, address(usd), address(coin), _one(PoolId.unwrap(theirs[2].toId())));
        hook.setLeaders(id, address(usd), address(weth), _one(common));
        hook.setConnector(id, theirs[2], true);
        hook.setConnector(id, theirs[0], true);
        uint32 gas = uint32(hook.minimumGasLimit(id));
        hook.setLimits(id, address(weth), gas, 1e15, 1.0001e18);
        hook.setLimits(id, address(usd), gas, 1e15, 1.0001e18);
    }

    function _other(PoolKey memory pool, address asset) internal pure returns (address) {
        bool first = Currency.unwrap(pool.currency0) == asset;
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

    function _fund(address input, uint256 amount) internal {
        TestAsset(input).mint(address(this), amount);
        TestAsset(input).approve(address(swapper), type(uint256).max);
        TestAsset(input).approve(address(payFirst), type(uint256).max);
        TestAsset(input).approve(address(hostile), type(uint256).max);
    }

    /// What one market must never change in the other: SZR's inventory and pool prices on
    /// one side, the team's pool prices and what it has been paid on the other.
    function _szrSide() internal view returns (bytes32) {
        (uint160 first,,,) = manager.getSlot0(own[0].toId());
        (uint160 second,,,) = manager.getSlot0(own[1].toId());
        return keccak256(abi.encode(core.unreleasedSupply(), first, second));
    }

    function _teamSide() internal view returns (bytes32) {
        (uint160 first,,,) = manager.getSlot0(theirs[0].toId());
        (uint160 second,,,) = manager.getSlot0(theirs[1].toId());
        (uint160 third,,,) = manager.getSlot0(theirs[2].toId());
        return keccak256(
            abi.encode(first, second, third, weth.balanceOf(treasury), usd.balanceOf(treasury))
        );
    }

    function szrSwap(bool sell, uint256 raw) external {
        PoolKey memory pool = own[1];
        address input = sell ? address(szr) : _other(pool, address(szr));
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (sell) {
            if (szr.balanceOf(address(this)) < amount) return;
            szr.approve(address(swapper), type(uint256).max);
        }
        if (!sell) _fund(input, amount);
        bytes32 before = _teamSide();
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(pool, _params(pool, input, amount), settings, "");
        if (_teamSide() != before) leaked = true;
    }

    /// Moves the public pool, which both markets trade through and neither one searches.
    function publicSwap(bool sell, uint256 raw) external {
        address input = sell ? address(weth) : address(usd);
        uint256 amount = bound(raw, 1e15, 500_000e18);
        _fund(input, amount);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(shared, _params(shared, input, amount), settings, "");
    }

    function teamSwap(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = theirs[seed % theirs.length];
        address input = sell ? address(coin) : _other(pool, address(coin));
        uint256 amount = bound(raw, 1e15, 25_000e18);
        _fund(input, amount);
        bytes32 before = _szrSide();
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(pool, _params(pool, input, amount), settings, "");
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    function teamPaidFirst(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = theirs[seed % theirs.length];
        address input = sell ? address(coin) : _other(pool, address(coin));
        uint256 amount = bound(raw, 1e15, 25_000e18);
        _fund(input, amount);
        bytes32 before = _szrSide();
        payFirst.trade(pool, input, amount);
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    function teamArb(uint256 seed) external {
        bytes32 poolId = PoolId.unwrap(theirs[seed % theirs.length].toId());
        // `arb` refuses a pool that is not tracked.
        if (!hook.tracked(id, poolId)) return;
        bytes32 before = _szrSide();
        hook.arb(poolId);
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    /// The hostile token misbehaves while it is marked as synced. The swap may fail; it
    /// may not reach SZR's market or leave anything in the hook.
    function teamHostile(uint256 seed, uint256 raw, uint256 mode) external {
        PoolKey memory pool = theirs[seed % theirs.length];
        uint256 amount = bound(raw, 1e15, 25_000e18);
        _fund(address(coin), amount);
        bytes32 before = _szrSide();
        try hostile.trade{ gas: 12_000_000 }(pool, coin, amount, bound(mode, 1, 3)) {
            hostileFilled++;
        } catch { }
        coin.arm(0);
        if (_szrSide() != before) leaked = true;
        hostileSwaps++;
        teamActions++;
    }

    /// The owner reorders the WETH leaders, or switches the market off and on.
    function teamTune(uint256 seed) external {
        bytes32[] memory list = hook.leadersOf(id, address(weth), address(coin));
        if (seed % 2 == 0) {
            (list[0], list[1]) = (list[1], list[0]);
            hook.setLeaders(id, address(weth), address(coin), list);
            return;
        }
        ArbitrageHook.Market memory settings = hook.market(id);
        uint32 gas = settings.gasLimit == 0 ? uint32(hook.minimumGasLimit(id)) : 0;
        hook.setLimits(id, address(weth), gas, 1e15, settings.minimumEdge);
    }

    /// The owner takes the market's fourth pool, which leads nothing, out and puts it back.
    function teamToggle() external {
        bytes32 spare = PoolId.unwrap(theirs[3].toId());
        if (hook.tracked(id, spare)) return hook.untrack(id, spare);
        hook.retrack(spare);
    }

    function elapse(uint256 raw) external {
        skip(bound(raw, 1, 10 minutes));
    }
}

/// @dev SZR's market and an open market with a hostile token, side by side.
contract ArbitrageMarketsInvariantTest is ArbitrageWorld {
    MarketsHandler internal handler;
    HostileAsset internal coin;
    address internal vault = address(0x7EA5);
    address internal desk = address(0x7EA6);

    function setUp() public override {
        super.setUp();
        coin = new HostileAsset();
        _approve(coin);
        address[] memory assets = new address[](2);
        address[] memory recipients = new address[](2);
        assets[0] = address(backing);
        assets[1] = address(usd);
        recipients[0] = vault;
        recipients[1] = desk;
        hook.setProfitTokens(assets, recipients);
        handler = new MarketsHandler(hook, swapper, coin, usd);
        handler.addOwn(mainPool);
        handler.addOwn(usdPool);
        _create(address(backing), 3_000);
        _create(address(backing), 500);
        _create(address(usd), 3_000);
        // A fourth pool that leads nothing, for the owner to untrack and track again.
        _create(address(backing), 10_000);
        // The world's WETH/USD pool, which runs no hook and connects SZR's own pools.
        bool wethFirst = address(backing) < address(usd);
        handler.start(
            PoolKey(
                Currency.wrap(wethFirst ? address(backing) : address(usd)),
                Currency.wrap(wethFirst ? address(usd) : address(backing)),
                3_000,
                60,
                IHooks(address(0))
            )
        );
        szr.transfer(address(handler), 2_000_000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[10] = handler.teamToggle.selector;
        selectors[0] = handler.szrSwap.selector;
        selectors[1] = handler.teamSwap.selector;
        selectors[2] = handler.teamSwap.selector;
        selectors[3] = handler.teamPaidFirst.selector;
        selectors[4] = handler.teamHostile.selector;
        selectors[5] = handler.teamTune.selector;
        selectors[6] = handler.elapse.selector;
        selectors[7] = handler.publicSwap.selector;
        selectors[8] = handler.teamArb.selector;
        selectors[9] = handler.teamSwap.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _create(address partner, uint24 fee) internal {
        bool coinFirst = address(coin) < partner;
        PoolKey memory pool = PoolKey(
            Currency.wrap(coinFirst ? address(coin) : partner),
            Currency.wrap(coinFirst ? partner : address(coin)),
            fee,
            60,
            IHooks(address(hook))
        );
        handler.create(pool);
        _provide(pool, 400_000e18);
    }

    /// The protocol's share of what a market was paid in one token is 30%, rounded up at
    /// each payout. A swap can pay out twice: before it and after it.
    function _assertSplit(TestAsset asset, address recipient) internal view {
        uint256 share = asset.balanceOf(recipient);
        uint256 total = share + asset.balanceOf(handler.treasury());
        assertGe(share * 100, total * 30, "protocol share below 30%");
        assertLe(share * 100 - total * 30, 200 * handler.teamActions(), "above 30%");
    }

    /// Neither market ever reaches into the other, the hook keeps nothing, the hostile
    /// token is never paid out, and the split holds in each token profit is counted in.
    function invariantMarketsStayApartAndTheSplitHolds() public view {
        assertFalse(handler.leaked(), "one market changed the other");
        assertEq(coin.balanceOf(address(hook)), 0, "hook coin");
        assertEq(coin.balanceOf(handler.treasury()), 0, "paid in the hostile token");
        _assertHookEmpty();
        _assertSplit(backing, vault);
        _assertSplit(usd, desk);
        _assertGroups(address(backing));
        _assertGroups(address(usd));
        uint256 allowance = hook.market(handler.id()).gasLimit;
        if (allowance != 0) {
            assertGe(allowance, hook.minimumGasLimit(handler.id()), "allowance");
        }
    }

    /// Every group a market has for a token has leaders, and every leader is a pool the
    /// market tracks.
    function _assertGroups(address base) internal view {
        uint256 market = handler.id();
        address[] memory partners = hook.groupsOf(market, base);
        assertLe(partners.length, hook.MAX_GROUPS());
        for (uint256 index; index < partners.length; index++) {
            bytes32[] memory list = hook.leadersOf(market, base, partners[index]);
            assertGt(list.length, 0, "a group with no leaders");
            assertLe(list.length, hook.MAX_LEADERS());
            for (uint256 place; place < list.length; place++) {
                assertTrue(hook.tracked(market, list[place]), "a leader that is not tracked");
            }
        }
    }

    /// With a gap open, the search reads the marked token's balance before its first
    /// cycle. Each kind of misbehaviour undoes that one search and nothing else.
    function testHostileBalanceOnlyUndoesItsOwnSearch() public {
        for (uint256 mode = 1; mode < 4; mode++) {
            // Switched off, a sale leaves a gap; switched back on, the next swap meets it.
            handler.teamTune(1);
            handler.teamSwap(0, true, 25_000e18);
            handler.teamTune(1);
            vm.recordLogs();
            handler.teamHostile(0, 1_000e18, mode);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool undone;
            for (uint256 index; index < logs.length; index++) {
                if (logs[index].topics[0] == ArbitrageHook.SearchUndone.selector) {
                    undone = true;
                }
            }
            // A balance that burns all the gas it is given fails its own swap instead.
            if (mode == 3) undone = handler.hostileFilled() == 2;
            assertTrue(undone, "the misbehaving balance was reached");
            if (mode < 3) assertEq(handler.hostileFilled(), mode, "and the swap still filled");
            invariantMarketsStayApartAndTheSplitHolds();
        }
    }

    function afterInvariant() public view {
        console2.log("open market paid, WETH", backing.balanceOf(handler.treasury()) / 1e18);
        console2.log("  protocol share, WETH", backing.balanceOf(vault) / 1e18);
        console2.log("open market paid, USD", usd.balanceOf(handler.treasury()) / 1e18);
        console2.log("  protocol share, USD", usd.balanceOf(desk) / 1e18);
        console2.log("hostile swaps", handler.hostileSwaps());
        console2.log("  of which filled", handler.hostileFilled());
    }
}
