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

/// @dev Trades in SZR's market and in an open market whose token is hostile, and
/// plays that market's owner. Each action records whether it reached across markets.
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
    HostileAsset public coin;
    uint256 public id;
    address public treasury = address(0x7EA4);
    PoolKey[] internal own;
    PoolKey[] internal theirs;

    bool public leaked;
    uint256 public teamActions;
    uint256 public hostileSwaps;
    uint256 public hostileFilled;

    constructor(ArbitrageHook arbitrage, PoolSwapTest swaps, HostileAsset asset) {
        hook = arbitrage;
        swapper = swaps;
        core = arbitrage.core();
        manager = arbitrage.poolManager();
        payFirst = new PayFirstRouter(manager);
        hostile = new HostileHomeRouter(manager);
        szr = TestAsset(arbitrage.token());
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

    function start(PoolKey calldata route) external {
        bytes32[] memory list = new bytes32[](2);
        list[0] = PoolId.unwrap(theirs[0].toId());
        list[1] = PoolId.unwrap(theirs[1].toId());
        hook.setLeaders(id, address(coin), list);
        list = new bytes32[](1);
        list[0] = PoolId.unwrap(theirs[2].toId());
        hook.setLeaders(id, _other(theirs[2], hook.backingAsset()), list);
        hook.setConnector(id, route, true);
        hook.setLimits(id, uint32(hook.minimumGasLimit(id)), 1e15, 1.0001e18);
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
            abi.encode(first, second, third, TestAsset(hook.backingAsset()).balanceOf(treasury))
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

    function teamSwap(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = theirs[seed % theirs.length];
        address input = sell ? _other(pool, hook.backingAsset()) : hook.backingAsset();
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
        address input = sell ? _other(pool, hook.backingAsset()) : hook.backingAsset();
        uint256 amount = bound(raw, 1e15, 25_000e18);
        _fund(input, amount);
        bytes32 before = _szrSide();
        payFirst.trade(pool, input, amount);
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    /// The hostile token misbehaves while it is marked as synced. The swap may fail; it
    /// may not reach SZR's market or leave anything in the hook.
    function teamHostile(uint256 seed, uint256 raw, uint256 mode) external {
        // The first two pools are the ones that trade the hostile token.
        PoolKey memory pool = theirs[seed % 2];
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

    /// The owner reorders the leaders, or switches the market off and on.
    function teamTune(uint256 seed) external {
        bytes32[] memory list = hook.leadersOf(id, address(coin));
        if (seed % 2 == 0) {
            (list[0], list[1]) = (list[1], list[0]);
            hook.setLeaders(id, address(coin), list);
            return;
        }
        ArbitrageHook.Market memory settings = hook.market(id);
        uint32 gas = settings.gasLimit == 0 ? uint32(hook.minimumGasLimit(id)) : 0;
        hook.setLimits(id, gas, settings.minimumProfit, settings.minimumEdge);
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

    function setUp() public override {
        super.setUp();
        coin = new HostileAsset();
        _approve(coin);
        hook.setProtocolRecipient(vault);
        handler = new MarketsHandler(hook, swapper, coin);
        handler.addOwn(mainPool);
        handler.addOwn(usdPool);
        _create(address(coin), 3_000);
        _create(address(coin), 500);
        _create(address(usd), 3_000);
        // A hookless pool connecting the market's two tokens.
        bool coinFirst = address(coin) < address(usd);
        PoolKey memory route = PoolKey(
            Currency.wrap(coinFirst ? address(coin) : address(usd)),
            Currency.wrap(coinFirst ? address(usd) : address(coin)),
            3_000,
            60,
            IHooks(address(0))
        );
        manager.initialize(route, uint160(1 << 96));
        _provide(route, 2_000_000e18);
        handler.start(route);
        szr.transfer(address(handler), 2_000_000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.szrSwap.selector;
        selectors[1] = handler.teamSwap.selector;
        selectors[2] = handler.teamSwap.selector;
        selectors[3] = handler.teamPaidFirst.selector;
        selectors[4] = handler.teamHostile.selector;
        selectors[5] = handler.teamTune.selector;
        selectors[6] = handler.elapse.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _create(address partner, uint24 fee) internal {
        bool wethFirst = address(backing) < partner;
        PoolKey memory pool = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : partner),
            Currency.wrap(wethFirst ? partner : address(backing)),
            fee,
            60,
            IHooks(address(hook))
        );
        handler.create(pool);
        _provide(pool, 400_000e18);
    }

    /// Neither market ever reaches into the other, the hook keeps nothing, and the
    /// protocol's share of what the open market earned is 30%, to within rounding.
    function invariantMarketsStayApartAndTheSplitHolds() public view {
        assertFalse(handler.leaked(), "one market changed the other");
        assertEq(coin.balanceOf(address(hook)), 0, "hook coin");
        _assertHookEmpty();
        uint256 share = backing.balanceOf(vault);
        uint256 total = share + backing.balanceOf(handler.treasury());
        assertLe(share * 100, total * 30, "protocol share above 30%");
        // Each payout rounds the share down by less than one unit, and a swap can pay out
        // twice: once in the search before it and once in the search after.
        assertLe(total * 30 - share * 100, 200 * handler.teamActions(), "below 30%");
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
        console2.log("protocol share, WETH", backing.balanceOf(vault) / 1e18);
        console2.log("hostile swaps", handler.hostileSwaps());
        console2.log("  of which filled", handler.hostileFilled());
    }
}
