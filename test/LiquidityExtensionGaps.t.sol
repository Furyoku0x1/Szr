// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { StdStorage, stdStorage } from "forge-std/StdStorage.sol";
import { MetricExtensionWorld } from "./MetricLiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A route hook that works against the extension. In `beforeSwap` it can call the
/// extension back on every entry point, and it can return a delta that moves the swap's
/// amounts. A delta it returns is settled by it first, as a real hook would.
contract HostileRouteHook {
    IPoolManager internal immutable manager;
    int128 internal specified;
    int128 internal unspecified;
    bool internal reenter;
    uint256 public attempts;
    uint256 public successes;
    bytes4[4] public reasons;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function configure(int128 specified_, int128 unspecified_, bool reenter_) external {
        specified = specified_;
        unspecified = unspecified_;
        reenter = reenter_;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        if (reenter) _callBack(sender, key);
        _settle(params.zeroForOne ? key.currency0 : key.currency1, specified);
        _settle(params.zeroForOne ? key.currency1 : key.currency0, unspecified);
        return (this.beforeSwap.selector, toBeforeSwapDelta(specified, unspecified), 0);
    }

    /// A positive delta is owed to the hook, so it takes first; a negative one it pays first.
    function _settle(Currency currency, int128 amount) internal {
        if (amount > 0) manager.take(currency, address(this), uint128(amount));
        if (amount < 0) {
            manager.sync(currency);
            TestAsset(Currency.unwrap(currency)).transfer(address(manager), uint128(-amount));
            manager.settle();
        }
    }

    function _callBack(address target, PoolKey calldata key) internal {
        bytes[] memory batch = new bytes[](1);
        batch[0] = abi.encodeCall(LiquidityExtension.wrap, (1));
        bytes[4] memory calls = [
            abi.encodeCall(LiquidityExtension.swap, (key, true, 1e18, 0, 1 << 70, 1 << 40)),
            abi.encodeCall(LiquidityExtension.marketCall, (hex"12345678")),
            abi.encodeWithSignature("multicall(bytes[])", batch),
            abi.encodeCall(LiquidityExtension.unlockCallback, (hex""))
        ];
        for (uint256 index; index < calls.length; index++) {
            (bool ok, bytes memory data) = target.call(calls[index]);
            attempts++;
            if (ok) successes++;
            if (data.length >= 4) reasons[index] = bytes4(data);
        }
    }
}

/// @dev What the shared base of both extensions does at its edges: batches, a hostile
/// route hook, native ETH through an arbitrage-hook pool, and Core with no holders.
contract LiquidityExtensionGapsTest is MetricExtensionWorld {
    using stdStorage for StdStorage;

    address internal ethDesk = address(0x7EA6);

    // ---------------------------------------------------------------------------------
    // T-5: multicall
    // ---------------------------------------------------------------------------------

    function testMulticallBatchesForTheManagerOnBothExtensions() public {
        _batchApplies(LiquidityExtension(payable(address(ext))));
        _batchApplies(LiquidityExtension(payable(address(mext))));
    }

    function testMulticallRefusesStrangersAndRollsBackOnAnyFailure() public {
        _batchFails(LiquidityExtension(payable(address(ext))));
        _batchFails(LiquidityExtension(payable(address(mext))));
    }

    function testMulticallRefusesEtherSentWithTheBatch() public {
        _etherRefused(LiquidityExtension(payable(address(ext))));
        _etherRefused(LiquidityExtension(payable(address(mext))));
    }

    function _batchApplies(LiquidityExtension x) internal {
        vm.deal(address(x), 2e18);
        uint256 cash = core.reserveCash();
        uint256 held = backing.balanceOf(address(x));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(x.wrap, (2e18));
        calls[1] = abi.encodeCall(x.toCore, (address(backing), 1.5e18));
        x.multicall(calls);
        assertEq(address(x).balance, 0, "wrap applied");
        assertEq(backing.balanceOf(address(x)), held + 0.5e18, "wrapped, then some given");
        assertEq(core.reserveCash(), cash + 1.5e18, "toCore applied");
    }

    function _batchFails(LiquidityExtension x) internal {
        vm.deal(address(x), 2e18);
        uint256 held = backing.balanceOf(address(x));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(x.wrap, (1e18));
        calls[1] = abi.encodeCall(x.toCore, (address(backing), 1e18));
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        x.multicall(calls);
        // The second call fails with its own error and takes the wrap before it back.
        calls[1] = abi.encodeCall(x.toCore, (address(coin), 1));
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        x.multicall(calls);
        assertEq(address(x).balance, 2e18, "the wrap was rolled back");
        assertEq(backing.balanceOf(address(x)), held, "no WETH made");
        // A refused market call inside a batch fails the batch.
        calls[1] = abi.encodeCall(x.marketCall, (abi.encodeCall(hook.openMarket, (alice))));
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        x.multicall(calls);
        assertEq(address(x).balance, 2e18, "nothing applied");
    }

    /// Solady's `multicall` is payable but reverts when it is given ether, so a batch cannot
    /// double-spend one `msg.value`. A stranger's empty batch with ETH reverts, the ether
    /// stays with the sender, and nothing else moves.
    function _etherRefused(LiquidityExtension x) internal {
        vm.deal(alice, 5e18);
        uint256 held = backing.balanceOf(address(x));
        uint256 cash = core.reserveCash();
        uint256 wethEther = address(backing).balance;
        uint256 managerEther = address(this).balance;
        uint256 before = address(x).balance;
        // The same empty batch without ether passes, so the value is what is refused.
        vm.prank(alice);
        (bool ok,) = address(x).call(abi.encodeCall(x.multicall, (new bytes[](0))));
        assertTrue(ok, "control: an empty batch with no ether");
        vm.prank(alice);
        (ok,) = address(x).call{ value: 1e18 }(abi.encodeCall(x.multicall, (new bytes[](0))));
        assertFalse(ok, "ether with a batch is refused");
        assertEq(address(x).balance, before, "the extension kept nothing");
        assertEq(alice.balance, 5e18, "the stranger still has it");
        assertEq(backing.balanceOf(address(x)), held, "nothing wrapped");
        assertEq(core.reserveCash(), cash, "Core untouched");
        assertEq(address(backing).balance, wethEther, "WETH untouched");
        assertEq(address(this).balance, managerEther, "nobody was paid");
        // The manager's batch is refused the same way.
        (ok,) = address(x).call{ value: 1e18 }(abi.encodeCall(x.multicall, (new bytes[](0))));
        assertFalse(ok, "and for the manager");
        assertEq(address(x).balance, before, "still nothing kept");
    }

    // ---------------------------------------------------------------------------------
    // T-6: a hostile route hook
    // ---------------------------------------------------------------------------------

    function _hostile() internal returns (HostileRouteHook evil, PoolKey memory key) {
        address at = address(uint160(0xE711 << 144 | 1 << 7 | 1 << 3));
        deployCodeTo(
            "LiquidityExtensionGaps.t.sol:HostileRouteHook", abi.encode(address(manager)), at
        );
        evil = HostileRouteHook(at);
        key = _pair(address(backing), address(coin), 3_000, at);
        manager.initialize(key, uint160(1 << 96));
        _provide(key, HELD);
        ext.registerRoute(key);
        backing.mint(at, 100e18);
        coin.mint(at, 100e18);
    }

    function _swapIn(PoolKey memory key, uint256 amount, uint256 minimum)
        internal
        returns (uint256 spent, uint256 got)
    {
        bool zeroForOne = Currency.unwrap(key.currency0) == address(backing);
        (spent, got) = ext.swap(
            key, zeroForOne, amount, minimum, zeroForOne ? FLOOR : CEILING, block.timestamp
        );
    }

    function testHookCallingTheExtensionBackFailsEverywhere() public {
        (HostileRouteHook evil, PoolKey memory key) = _hostile();
        evil.configure(0, 0, true);
        uint256 backingBefore = backing.balanceOf(address(ext));
        uint256 coinBefore = coin.balanceOf(address(ext));
        (uint256 spent, uint256 got) = _swapIn(key, 1_000e18, 1);
        assertEq(evil.attempts(), 4, "the hook tried every entry point");
        assertEq(evil.successes(), 0, "and none worked");
        bytes4 busy = ReentrancyGuard.Reentrancy.selector;
        assertEq(evil.reasons(0), busy, "swap is busy");
        assertEq(evil.reasons(1), busy, "marketCall is busy");
        assertEq(evil.reasons(2), busy, "multicall is busy");
        assertEq(evil.reasons(3), LiquidityExtension.NotPoolManager.selector, "not the manager");
        assertEq(backing.balanceOf(address(ext)), backingBefore - spent, "only its amounts");
        assertEq(coin.balanceOf(address(ext)), coinBefore + got, "only its amounts");
    }

    function testHookCuttingTheOutputRevertsBelowMinimum() public {
        (HostileRouteHook evil, PoolKey memory key) = _hostile();
        uint256 snapshot = vm.snapshotState();
        (, uint256 honest) = _swapIn(key, 1_000e18, 1);
        vm.revertToState(snapshot);
        evil.configure(0, 50e18, false);
        uint256 backingBefore = backing.balanceOf(address(ext));
        uint256 coinBefore = coin.balanceOf(address(ext));
        vm.expectRevert(LiquidityExtension.BelowMinimum.selector);
        _swapIn(key, 1_000e18, honest - 50e18 + 1);
        assertEq(backing.balanceOf(address(ext)), backingBefore, "nothing left");
        assertEq(coin.balanceOf(address(ext)), coinBefore, "nothing arrived");
        // Allowed to fill for less, the swap pays and receives only its own amounts.
        (uint256 spent, uint256 got) = _swapIn(key, 1_000e18, honest - 50e18);
        assertEq(got, honest - 50e18, "the hook's cut came off the output");
        assertEq(spent, 1_000e18, "the input is what was asked");
        assertEq(backing.balanceOf(address(ext)), backingBefore - spent);
        assertEq(coin.balanceOf(address(ext)), coinBefore + got);
    }

    /// A hook whose output-side delta is larger than the whole fill leaves the extension
    /// owed nothing and owing output: the swap reverts and nothing moves.
    function testHookTakingMoreThanTheFillRevertsInvalidDelta() public {
        (HostileRouteHook evil, PoolKey memory key) = _hostile();
        uint256 snapshot = vm.snapshotState();
        (, uint256 honest) = _swapIn(key, 1_000e18, 1);
        vm.revertToState(snapshot);
        evil.configure(0, int128(int256(honest + 1e18)), false);
        uint256 backingBefore = backing.balanceOf(address(ext));
        uint256 coinBefore = coin.balanceOf(address(ext));
        vm.expectRevert(LiquidityExtension.InvalidDelta.selector);
        _swapIn(key, 1_000e18, 1);
        assertEq(backing.balanceOf(address(ext)), backingBefore, "nothing left");
        assertEq(coin.balanceOf(address(ext)), coinBefore, "nothing arrived");
    }

    /// A hook that returns a delta on the input side cannot make the extension pay more
    /// than it offered: the pool manager nets the hook's delta out of the caller's. The
    /// extension's `AboveMaximum` check is a second guard behind that.
    function testHookCannotMakeTheExtensionPayMoreThanItOffered() public {
        (HostileRouteHook evil, PoolKey memory key) = _hostile();
        uint256 snapshot = vm.snapshotState();
        (, uint256 honest) = _swapIn(key, 1_000e18, 1);
        vm.revertToState(snapshot);
        int128[2] memory deltas = [int128(-40e18), int128(40e18)];
        for (uint256 index; index < 2; index++) {
            snapshot = vm.snapshotState();
            evil.configure(deltas[index], 0, false);
            uint256 backingBefore = backing.balanceOf(address(ext));
            (uint256 spent, uint256 got) = _swapIn(key, 1_000e18, 1);
            assertEq(spent, 1_000e18, "exactly what was offered");
            assertEq(backing.balanceOf(address(ext)), backingBefore - spent, "paid its own");
            // A hook that pays input in swaps more, and one that takes input swaps less.
            if (index == 0) assertGt(got, honest, "more came out");
            else assertLt(got, honest, "less came out");
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------
    // T-7: native ETH through an arbitrage-hook pool
    // ---------------------------------------------------------------------------------

    /// ETH/coin on the hook, with WETH/coin as the venue it is compared against. Profit is
    /// counted in ETH.
    function _etherPool() internal returns (PoolKey memory hooked, PoolKey memory venue) {
        hook.setProfitToken(address(0), ethDesk);
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(backing);
        vm.prank(team);
        hook.setTokens(id, tokens);
        _lead(address(backing), address(coin), new bytes32[](0));
        hooked = _pair(address(0), address(coin), 3_000, address(hook));
        vm.prank(team);
        hook.createPool(id, hooked, uint160(1 << 96));
        provider.modifyLiquidity{ value: 2_000_000e18 }(
            hooked, IPoolManager.ModifyLiquidityParams(-887_220, 887_220, int256(HELD), 0), ""
        );
        venue = _pair(address(backing), address(coin), 500, address(0));
        manager.initialize(venue, uint160(1 << 96));
        _provide(venue, HELD);
        vm.prank(team);
        hook.addVenue(id, venue);
        _lead(address(0), address(coin), _list(_id(hooked)));
        _lead(address(backing), address(coin), _list(_id(venue)));
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
    }

    /// An exact-input swap by the extension, whose balances must move by exactly what the
    /// `Swapped` event reports.
    function _etherSwap(PoolKey memory key, bool zeroForOne, uint256 amount) internal {
        uint256 ethBefore = address(ext).balance;
        uint256 coinBefore = coin.balanceOf(address(ext));
        vm.recordLogs();
        (uint256 spent, uint256 got) = ext.swap(
            key, zeroForOne, amount, 1, zeroForOne ? FLOOR : CEILING, block.timestamp
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory seen;
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == LiquidityExtension.Swapped.selector) {
                seen = logs[index].data;
            }
        }
        assertEq(seen, abi.encode(zeroForOne, spent, got), "Swapped matches");
        assertEq(spent, amount, "all of it was filled");
        assertGt(got, 0, "something came back");
        if (zeroForOne) {
            assertEq(address(ext).balance, ethBefore - spent, "ETH paid by settle");
            assertEq(coin.balanceOf(address(ext)), coinBefore + got, "coin received");
        } else {
            assertEq(address(ext).balance, ethBefore + got, "ETH taken through receive");
            assertEq(coin.balanceOf(address(ext)), coinBefore - spent, "coin paid");
        }
    }

    function testEtherSwapsThroughAnArbitrageHookPoolMoveExactlyTheSwappedAmounts() public {
        (PoolKey memory hooked,) = _etherPool();
        vm.deal(address(ext), 10_000e18);
        ext.registerRoute(hooked);
        _etherSwap(hooked, true, 1_000e18);
        _etherSwap(hooked, false, 500e18);
    }

    /// With a gap open, the extension's ETH swap carries the hook's own gas rule.
    function testEtherSwapWithTooLittleGasRevertsInsufficientGas() public {
        (PoolKey memory hooked, PoolKey memory venue) = _etherPool();
        vm.deal(address(ext), 10_000e18);
        ext.registerRoute(hooked);
        _trade(venue, address(coin), 50_000e18);
        bytes memory call =
            abi.encodeCall(ext.swap, (hooked, true, 1e18, 0, FLOOR, block.timestamp));
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = address(ext).call{ gas: 300_000 }(call);
        assertFalse(ok, "short gas reverts");
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "the hook's error");
        vm.revertToState(snapshot);
        vm.recordLogs();
        (ok,) = address(ext).call{ gas: 9_000_000 }(call);
        assertTrue(ok, "enough gas fills it");
        assertGt(_cycles(), 0, "and the search ran");
    }

    // ---------------------------------------------------------------------------------
    // T-8: toCore with no active supply
    // ---------------------------------------------------------------------------------

    function _noHolders() internal {
        uint256 slot = stdstore.target(address(core)).sig("unreleasedSupply()").find();
        vm.store(address(core), bytes32(slot), bytes32(szr.totalSupply()));
        assertEq(core.activeSupply(), 0, "nobody holds SZR");
    }

    function _toCoreRefused(LiquidityExtension x) internal {
        // SZR is left out: an extension that holds any SZR makes the active supply positive,
        // so `InsufficientInventory` cannot be reached with no holders.
        uint256 backingHeld = backing.balanceOf(address(x));
        vm.expectRevert(SzrCore.NoActiveSupply.selector);
        x.toCore(address(backing), 1e18);
        assertEq(backing.balanceOf(address(x)), backingHeld, "WETH kept");
        assertEq(backing.allowance(address(x), address(core)), 0, "no WETH allowance");
    }

    function testToCoreWethWithNoActiveSupplyIsRefusedAndLeavesNothingBehind() public {
        backing.mint(address(mext), 5e18);
        _noHolders();
        _toCoreRefused(LiquidityExtension(payable(address(ext))));
        _toCoreRefused(LiquidityExtension(payable(address(mext))));
    }
}
