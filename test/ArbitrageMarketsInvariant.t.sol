// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { console2 } from "forge-std/console2.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { PayFirstRouter } from "./utils/Routers.sol";
import { DrainRouter } from "./utils/ArbitrageDrain.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
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
    DrainRouter public drainer;
    TestAsset public szr;
    TestAsset public weth;
    TestAsset public usd;
    HostileAsset public coin;
    uint256 public id;
    address public treasury = address(0x7EA4);
    /// Where the protocol's share goes, per token, whenever it is approved.
    address internal vault = address(0x7EA5);
    address internal desk = address(0x7EA6);
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    PoolKey[] internal own;
    PoolKey[] internal theirs;
    PoolKey internal shared;
    WrappedPricer internal pricer;
    /// The market's native ETH pools: one on the hook and a hookless one to trade it against.
    PoolKey internal ethHooked;
    PoolKey internal ethOpen;
    /// The market's USD/ETH pool on the hook. Its USD/WETH counterpart is the public pool,
    /// so a gap between them is closed through the wrap link.
    PoolKey internal usdEth;

    bool public leaked;
    /// Set when the market was paid in a token it had not chosen or that was not approved.
    bool public paidWrongly;
    /// Searches undone by a misbehaving balance. Counted here because auditing reads the
    /// recorded logs, which empties them for anyone else.
    uint256 public undoneSearches;
    /// Liquidity's manager, who approves tokens.
    address internal admin;
    uint256 public teamActions;
    uint256 public hostileSwaps;
    uint256 public hostileFilled;
    /// Payouts of profit counted in native ETH, which leave the hook as WETH.
    uint256 public ethPayouts;
    /// Times the hook turned WETH into ETH inside a cycle: a burn of WETH is nothing else.
    uint256 public unwraps;
    /// Times the hook turned ETH into WETH inside a cycle: a mint of WETH is nothing else.
    uint256 public wraps;
    /// Swaps through the draining router, how many were refused, and whether one that filled
    /// did anything other than what the same swap does with nothing drained.
    uint256 public drainSwaps;
    uint256 public drainRefused;
    uint256 public drainAfter;
    bool public drainSkipped;

    receive() external payable { }

    constructor(
        ArbitrageHook arbitrage,
        PoolSwapTest swaps,
        HostileAsset asset,
        TestAsset dollars
    ) {
        admin = msg.sender;
        hook = arbitrage;
        swapper = swaps;
        core = arbitrage.core();
        manager = arbitrage.poolManager();
        payFirst = new PayFirstRouter(manager);
        hostile = new HostileHomeRouter(manager);
        drainer = new DrainRouter(manager);
        szr = TestAsset(arbitrage.token());
        weth = TestAsset(arbitrage.backingAsset());
        usd = dollars;
        coin = asset;
        id = arbitrage.openMarket(treasury);
        address[] memory chosen = new address[](3);
        chosen[0] = address(weth);
        chosen[1] = address(usd);
        chosen[2] = address(0);
        arbitrage.setTokens(id, chosen);
    }

    /// The market's native ETH pools, led together by the hostile token's group of ETH.
    function createEth(PoolKey calldata hooked, PoolKey calldata open) external {
        hook.createPool(id, hooked, uint160(1 << 96));
        hook.addVenue(id, open);
        ethHooked = hooked;
        ethOpen = open;
        bytes32[] memory pair = new bytes32[](2);
        pair[0] = PoolId.unwrap(hooked.toId());
        pair[1] = PoolId.unwrap(open.toId());
        hook.setLeaders(id, address(0), address(coin), pair);
    }

    /// The market's USD/ETH pool, the only pool in the group of ETH under USD.
    function createUsdEth(PoolKey calldata pool) external {
        hook.createPool(id, pool, uint160(1 << 96));
        usdEth = pool;
        hook.setLeaders(id, address(usd), address(0), _one(PoolId.unwrap(pool.toId())));
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
    function start(PoolKey calldata publicPool, PoolKey calldata wrapped, WrappedPricer quoter)
        external
    {
        shared = publicPool;
        pricer = quoter;
        hook.addVenue(id, publicPool);
        // A pool of the hostile token on a wrapping hook leads beside the market's own.
        hook.addVenue(id, wrapped);
        bytes32[] memory pair = new bytes32[](3);
        pair[0] = PoolId.unwrap(theirs[0].toId());
        pair[1] = PoolId.unwrap(theirs[1].toId());
        pair[2] = PoolId.unwrap(wrapped.toId());
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
        hook.setLimits(id, address(0), gas, 1e15, 1.0001e18);
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
        TestAsset(input).approve(address(drainer), type(uint256).max);
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

    function _watch() internal {
        vm.recordLogs();
    }

    /// Nothing changes the market's tokens during a swap, so the lists read now are the
    /// ones the payout saw.
    function _audit() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageHook.SearchUndone.selector) undoneSearches++;
            if (logs[index].emitter == address(weth)) {
                if (logs[index].topics[0] == TRANSFER) {
                    if (logs[index].topics[2] == bytes32(0)) unwraps++;
                    if (logs[index].topics[1] == bytes32(0)) wraps++;
                }
            }
            if (logs[index].topics[0] != ArbitrageHook.ProfitPaid.selector) continue;
            if (uint256(logs[index].topics[1]) != id) continue;
            address asset = address(uint160(uint256(logs[index].topics[2])));
            if (asset == address(0)) ethPayouts++;
            if (hook.shareRecipient(asset) == address(0)) paidWrongly = true;
            if (!_chosen(asset)) paidWrongly = true;
        }
    }

    function _chosen(address asset) internal view returns (bool) {
        address[] memory list = hook.tokensOf(id);
        for (uint256 index; index < list.length; index++) {
            if (list[index] == asset) return true;
        }
        return false;
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
        _watch();
        swapper.swap(pool, _params(pool, input, amount), settings, "");
        _audit();
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    /// Trades in the market's native ETH pools, with ETH in or the hostile token in.
    function ethSwap(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = seed % 2 == 0 ? ethHooked : ethOpen;
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (sell) _fund(address(coin), amount);
        else vm.deal(address(this), address(this).balance + amount);
        bytes32 before = _szrSide();
        PoolSwapTest.TestSettings memory settings;
        _watch();
        swapper.swap{ value: sell ? 0 : amount }(
            pool, _params(pool, sell ? address(coin) : address(0), amount), settings, ""
        );
        _audit();
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    /// Trades in the market's USD/ETH pool with ETH in or USD in. The public USD/WETH pool
    /// moves on its own, so the two drift apart and the hook closes the gap through the
    /// wrap link, in whichever direction it opens.
    function usdEthSwap(bool sell, uint256 raw) external {
        uint256 amount = bound(raw, 1e15, 25_000e18);
        address input = sell ? address(usd) : address(0);
        if (sell) _fund(input, amount);
        else vm.deal(address(this), address(this).balance + amount);
        bytes32 before = _szrSide();
        PoolSwapTest.TestSettings memory settings;
        _watch();
        swapper.swap{ value: sell ? 0 : amount }(
            usdEth, _params(usdEth, input, amount), settings, ""
        );
        _audit();
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    function teamPaidFirst(uint256 seed, bool sell, uint256 raw) external {
        PoolKey memory pool = theirs[seed % theirs.length];
        address input = sell ? address(coin) : _other(pool, address(coin));
        uint256 amount = bound(raw, 1e15, 25_000e18);
        _fund(input, amount);
        bytes32 before = _szrSide();
        _watch();
        payFirst.trade(pool, input, amount);
        _audit();
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    function teamArb(uint256 seed) external {
        bytes32 poolId = PoolId.unwrap(theirs[seed % theirs.length].toId());
        // `arb` refuses a pool that is not tracked.
        if (!hook.tracked(id, poolId)) return;
        // `arb` also refuses a pool whose token the market has dropped.
        if (hook.partnerOf(poolId) == address(0)) return;
        bytes32 before = _szrSide();
        _watch();
        hook.arb(poolId);
        _audit();
        if (_szrSide() != before) leaked = true;
        teamActions++;
    }

    /// Anyone sweeps the market for one of its profit tokens. Like `arb`, it must not
    /// reach SZR's market.
    function teamSweep(uint256 seed) external {
        address base = seed % 3 == 0 ? address(weth) : address(usd);
        if (seed % 3 == 2) base = address(0);
        bytes32 before = _szrSide();
        _watch();
        hook.sweep(id, base);
        _audit();
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
        _watch();
        try hostile.trade{ gas: 12_000_000 }(pool, coin, amount, bound(mode, 1, 3)) {
            hostileFilled++;
        } catch { }
        coin.arm(0);
        _audit();
        if (_szrSide() != before) leaked = true;
        hostileSwaps++;
        teamActions++;
    }

    /// Borrows the pool manager's whole balance of a token for the length of a swap in one
    /// of the market's pools, the USD/ETH pool with its wrap link included. The swap must be
    /// refused (a gap was open before it), or fill; and if no search was undone by the
    /// shortage, do exactly what the same swap does with nothing borrowed, which is closing
    /// every gap it meets. A search after the swap undone by the shortage may leave a gap
    /// that the control closes, so that comparison is skipped for it.
    function teamDrain(uint256 seed, bool sell, uint256 raw) external {
        bool link = seed % (theirs.length + 1) == theirs.length;
        PoolKey memory pool = link ? usdEth : theirs[seed % theirs.length];
        address input;
        if (link) input = sell ? address(usd) : address(0);
        else input = sell ? address(coin) : _other(pool, address(coin));
        uint256 amount = bound(raw, 1e15, 25_000e18);
        if (input == address(0)) vm.deal(address(drainer), address(drainer).balance + amount);
        else _fund(input, amount);
        uint256 pick = (seed / 8) % 4;
        address drained = pick == 0 ? address(weth) : pick == 1 ? address(usd) : address(0);
        if (pick == 3) drained = address(coin);
        // The wrapped pool's own hook takes its input from the pool manager, which no check
        // of this contract can stand in for, so it is left out of both runs. Draining the
        // token a wrapped pool's hook takes is not covered: see the backlog.
        uint256 hidden = pricer.mode();
        pricer.arm(1);
        uint256 snapshot = vm.snapshotState();
        _watch();
        bool filled = _drainSwap(pool, input, amount, drained, 0);
        bool undone = _undoneByDrain();
        bytes32 team = _teamSide();
        bytes32 szrSide = _szrSide();
        if (filled) vm.revertToState(snapshot);
        _watch();
        _drainSwap(pool, input, amount, drained, type(uint256).max);
        _audit();
        pricer.arm(hidden);
        if (filled) {
            if (undone) {
                drainAfter++;
            } else {
                if (team != _teamSide()) drainSkipped = true;
                if (szrSide != _szrSide()) drainSkipped = true;
            }
        } else {
            drainRefused++;
        }
        drainSwaps++;
        teamActions++;
    }

    /// Whether a search was undone by the shortage since `_watch`.
    function _undoneByDrain() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageHook.SearchUndone.selector) continue;
            if (abi.decode(logs[index].data, (bytes4)) == ArbitrageHook.Drained.selector) {
                return true;
            }
        }
        return false;
    }

    function _drainSwap(
        PoolKey memory pool,
        address input,
        uint256 amount,
        address drained,
        uint256 leave
    ) internal returns (bool filled) {
        try drainer.trade{ gas: 30_000_000 }(pool, input, amount, drained, leave) {
            return true;
        } catch {
            return false;
        }
    }

    /// The owner reorders the WETH leaders, or switches the market off and on.
    function teamTune(uint256 seed) external {
        bytes32[] memory list = hook.leadersOf(id, address(weth), address(coin));
        if (seed % 2 == 0) {
            (list[0], list[1]) = (list[1], list[0]);
            // Refused while WETH is not both approved and chosen.
            try hook.setLeaders(id, address(weth), address(coin), list) { } catch { }
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

    /// The owner reorders or drops the tokens the market counts profit in. A choice that
    /// needs more gas than the allowance is refused, which is what the hook promises.
    function teamTokens(uint256 seed) external {
        address[] memory list;
        uint256 pick = seed % 5;
        if (pick == 4) {
            list = new address[](0);
        } else if (pick > 1) {
            list = new address[](1);
            list[0] = pick == 2 ? address(weth) : address(usd);
        } else {
            list = new address[](2);
            list[0] = pick == 0 ? address(weth) : address(usd);
            list[1] = pick == 0 ? address(usd) : address(weth);
        }
        address[] memory withEth = new address[](list.length + 1);
        for (uint256 index; index < list.length; index++) {
            withEth[index] = list[index];
        }
        try hook.setTokens(id, withEth) { } catch { }
    }

    /// Liquidity's manager takes a token off, or approves it again with its old recipient.
    function approval(uint256 seed) external {
        uint256 pick = seed % 3;
        address asset = pick == 0 ? address(weth) : pick == 1 ? address(usd) : address(0);
        address recipient = hook.shareRecipient(asset);
        if (recipient != address(0)) {
            vm.prank(admin);
            hook.setProfitToken(asset, address(0));
            return;
        }
        vm.prank(admin);
        hook.setProfitToken(asset, asset == address(usd) ? desk : vault);
    }

    /// The wrapped pool's pricer starts or stops giving bad answers.
    function pricerMode(uint256 seed) external {
        pricer.arm(seed % 6);
    }

    function elapse(uint256 raw) external {
        skip(bound(raw, 1, 10 minutes));
    }
}

/// @dev SZR's market and an open market with a hostile token, side by side.
contract ArbitrageMarketsInvariantTest is ArbitrageWorld {
    MarketsHandler internal handler;
    HostileAsset internal coin;
    WrappedPricer internal pricer;
    address internal vault = address(0x7EA5);
    address internal desk = address(0x7EA6);

    function setUp() public override {
        super.setUp();
        coin = new HostileAsset();
        _approve(coin);
        hook.setProfitToken(address(backing), vault);
        hook.setProfitToken(address(usd), desk);
        // Paid out as WETH, to the same place as WETH profit, so the split can be checked.
        hook.setProfitToken(address(0), vault);
        vm.deal(address(this), 2_000_000e18);
        // The world's WETH has neither `deposit()` nor `withdraw()`; the real one has both,
        // and sends the ETH it unwraps from its own balance.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        vm.deal(address(backing), 2_000_000e18);
        // Deployed by name: embedding the handler's code would put this contract over the
        // size limit.
        handler = MarketsHandler(
            payable(deployCode(
                    "ArbitrageMarketsInvariant.t.sol:MarketsHandler",
                    abi.encode(hook, swapper, coin, usd)
                ))
        );
        handler.addOwn(mainPool);
        handler.addOwn(usdPool);
        _create(address(backing), 3_000);
        _create(address(backing), 500);
        _create(address(usd), 3_000);
        _createEth();
        _createUsdEth();
        // A fourth pool that leads nothing, for the owner to untrack and track again.
        _create(address(backing), 10_000);
        // The world's WETH/USD pool, which runs no hook and connects SZR's own pools.
        bool wethFirst = address(backing) < address(usd);
        PoolKey memory publicPool = PoolKey(
            Currency.wrap(wethFirst ? address(backing) : address(usd)),
            Currency.wrap(wethFirst ? address(usd) : address(backing)),
            3_000,
            60,
            IHooks(address(0))
        );
        handler.start(publicPool, _wrapped(), pricer);
        szr.transfer(address(handler), 2_000_000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](20);
        selectors[19] = handler.teamDrain.selector;
        selectors[17] = handler.usdEthSwap.selector;
        selectors[18] = handler.usdEthSwap.selector;
        selectors[15] = handler.ethSwap.selector;
        selectors[16] = handler.ethSwap.selector;
        selectors[14] = handler.teamSweep.selector;
        selectors[12] = handler.teamTokens.selector;
        selectors[13] = handler.approval.selector;
        selectors[11] = handler.pricerMode.selector;
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

    receive() external payable { }

    /// A hooked and a hookless pool of the hostile token against native ETH.
    function _createEth() internal {
        PoolKey memory hooked = _ethPool(address(hook));
        PoolKey memory open = _ethPool(address(0));
        open.fee = 500;
        manager.initialize(open, uint160(1 << 96));
        handler.createEth(hooked, open);
        _provideEth(hooked);
        _provideEth(open);
    }

    /// A hooked pool of USD against native ETH, beside the public USD/WETH pool.
    function _createUsdEth() internal {
        PoolKey memory pool = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(address(usd)),
            3_000,
            60,
            IHooks(address(hook))
        );
        handler.createUsdEth(pool);
        _provideEth(pool);
    }

    function _ethPool(address hooks) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(coin)), 3_000, 60, IHooks(hooks)
        );
    }

    function _provideEth(PoolKey memory pool) internal {
        provider.modifyLiquidity{ value: 500_000e18 }(
            pool,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 400_000e18, 0
            ),
            ""
        );
    }

    /// A pool of the hostile token against WETH on a wrapping hook, with its pricer.
    function _wrapped() internal returns (PoolKey memory pool) {
        WrappedPool wrapper =
            WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
        bool coinFirst = address(coin) < address(backing);
        pool = PoolKey(
            Currency.wrap(coinFirst ? address(coin) : address(backing)),
            Currency.wrap(coinFirst ? address(backing) : address(coin)),
            3_000,
            60,
            IHooks(address(wrapper))
        );
        manager.initialize(pool, uint160(1 << 96));
        coin.mint(address(wrapper), 400_000e18);
        backing.mint(address(wrapper), 400_000e18);
        wrapper.seed(pool, 400_000e18, 400_000e18);
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
        assertFalse(handler.paidWrongly(), "paid in a token not approved and chosen");
        assertFalse(handler.drainSkipped(), "a borrowed balance changed what a swap did");
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
            uint256 earlier = handler.undoneSearches();
            handler.teamHostile(0, 1_000e18, mode);
            bool undone = handler.undoneSearches() > earlier;
            // A balance that burns all the gas it is given fails its own swap instead.
            if (mode == 3) undone = handler.hostileFilled() == 2;
            assertTrue(undone, "the misbehaving balance was reached");
            if (mode < 3) assertEq(handler.hostileFilled(), mode, "and the swap still filled");
            invariantMarketsStayApartAndTheSplitHolds();
        }
    }

    /// A fixed run of handler calls pays ETH profit out, so the invariant runs are known to
    /// reach that path; and taking ETH off and approving it again keeps it working.
    function testEthPayoutsHappen() public {
        handler.ethSwap(1, true, 25_000e18);
        handler.ethSwap(0, true, 1_000e18);
        assertGt(handler.ethPayouts(), 0, "ETH profit paid");
        uint256 paid = handler.ethPayouts();
        handler.approval(2);
        handler.ethSwap(1, true, 25_000e18);
        handler.ethSwap(0, true, 1_000e18);
        assertEq(handler.ethPayouts(), paid, "nothing paid while ETH is off");
        handler.approval(2);
        handler.ethSwap(1, true, 25_000e18);
        handler.ethSwap(0, true, 1_000e18);
        assertGt(handler.ethPayouts(), paid, "paid again once approved");
        assertFalse(handler.paidWrongly(), "paid wrongly");
        invariantMarketsStayApartAndTheSplitHolds();
    }

    /// A fixed run reaches a cycle that unwraps, so the invariant runs are known to as well:
    /// the public pool moves WETH's price in USD, and a swap in the USD/ETH pool finds it.
    function testWrapLinkConvertsInTheLongRun() public {
        handler.publicSwap(true, 400_000e18);
        handler.usdEthSwap(true, 1_000e18);
        handler.publicSwap(false, 400_000e18);
        handler.usdEthSwap(false, 1_000e18);
        assertGt(handler.unwraps(), 0, "WETH unwrapped inside a cycle");
        assertGt(handler.wraps(), 0, "ETH wrapped inside a cycle");
        assertFalse(handler.leaked(), "leaked");
        invariantMarketsStayApartAndTheSplitHolds();
    }

    /// The market's native ETH pools and its WETH pools pair the same token, so each is a
    /// venue of the other. A fixed run reaches cycles that cross between them (a conversion
    /// in each direction), as the invariant runs do, with swaps in both pools.
    function testEtherTwinsCycleInTheLongRun() public {
        handler.ethSwap(1, true, 25_000e18);
        handler.teamSwap(0, true, 25_000e18);
        handler.ethSwap(0, true, 25_000e18);
        handler.teamSwap(1, false, 25_000e18);
        handler.ethSwap(0, false, 25_000e18);
        handler.teamSwap(0, false, 25_000e18);
        assertGt(handler.unwraps(), 0, "WETH unwrapped inside a cycle");
        assertGt(handler.wraps(), handler.ethPayouts(), "ETH wrapped inside a cycle");
        assertFalse(handler.leaked(), "leaked");
        invariantMarketsStayApartAndTheSplitHolds();
    }

    function afterInvariant() public view {
        console2.log("open market paid, WETH", backing.balanceOf(handler.treasury()) / 1e18);
        console2.log("  protocol share, WETH", backing.balanceOf(vault) / 1e18);
        console2.log("open market paid, USD", usd.balanceOf(handler.treasury()) / 1e18);
        console2.log("  protocol share, USD", usd.balanceOf(desk) / 1e18);
        console2.log("ETH profit payouts", handler.ethPayouts());
        console2.log("unwraps inside cycles", handler.unwraps());
        console2.log("wraps inside cycles", handler.wraps());
        console2.log("drained swaps", handler.drainSwaps());
        console2.log("  of which refused", handler.drainRefused());
        console2.log("  of which filled with a search undone", handler.drainAfter());
        console2.log("hostile swaps", handler.hostileSwaps());
        console2.log("  of which filled", handler.hostileFilled());
    }
}
