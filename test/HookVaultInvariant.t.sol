// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { VaultWorld, VaultHarness } from "./utils/VaultWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Holders deposit, withdraw and go in and out; others swap through the market's pools,
/// which makes the hook pay profit to the vault; anyone harvests. Each action checks what it
/// must, and records a break instead of reverting so the invariants report it.
contract VaultHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    VaultHarness internal vault;
    PoolSwapTest internal swapper;
    TestAsset internal asset0;
    TestAsset internal asset1;
    PoolKey internal firstPool;
    PoolKey internal secondPool;
    address[3] internal actors = [address(0xA1), address(0xA2), address(0xA3)];
    uint256 internal seedSupply;

    bool public roundTripProfited;
    bool public unitsPerShareFell;
    bool public unbookedMoved;
    bool public idleMoved;
    bool public curatorTookRewards;
    bool public transferMovedRewards;
    bool public positionsMoved;
    uint256 public rebalances;
    uint256 public idleSwaps;
    bytes4 public lastIdleRefusal;
    uint256 public transfers;
    uint256 public positionEdits;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public swaps;
    uint256 public profits;

    constructor(
        VaultHarness vault_,
        PoolSwapTest swapper_,
        TestAsset one,
        TestAsset two,
        PoolKey memory poolOne,
        PoolKey memory poolTwo
    ) {
        vault = vault_;
        swapper = swapper_;
        asset0 = one;
        asset1 = two;
        firstPool = poolOne;
        secondPool = poolTwo;
        seedSupply = vault_.totalSupply();
        for (uint256 index; index < actors.length; index++) {
            _arm(actors[index]);
        }
        _arm(address(this));
    }

    function _arm(address who) internal {
        vm.startPrank(who);
        asset0.approve(address(vault), type(uint256).max);
        asset1.approve(address(vault), type(uint256).max);
        asset0.approve(address(swapper), type(uint256).max);
        asset1.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function actor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function _fund(address who) internal {
        asset0.mint(who, 1e30);
        asset1.mint(who, 1e30);
    }

    /// Reads what must not move when an action only touches principal and fees.
    function _unbooked() internal view returns (uint256, uint256) {
        return (_surplus(asset0), _surplus(asset1));
    }

    /// What the vault holds beyond idle principal, whether booked as a reward or not.
    function _surplus(TestAsset asset) internal view returns (uint256) {
        (uint256 idle0, uint256 idle1) = vault.principal();
        uint256 idle = asset == asset0 ? idle0 : idle1;
        return asset.balanceOf(address(vault)) - idle;
    }

    struct Snap {
        uint256 supply;
        uint256 idle0;
        uint256 idle1;
        uint256 unbooked0;
        uint256 unbooked1;
        uint256 fees0;
        uint256 fees1;
        uint256[] units;
    }

    /// What a harvest would collect now, which is what any change to the positions also
    /// collects: a position's fees are paid out in full whatever the size of the change.
    function _snap() internal returns (Snap memory snap) {
        snap.supply = vault.totalSupply();
        (snap.idle0, snap.idle1) = vault.principal();
        (snap.unbooked0, snap.unbooked1) = _unbooked();
        snap.units = new uint256[](vault.positionCount());
        for (uint256 index; index < snap.units.length; index++) {
            snap.units[index] = vault.unitsOf(index);
        }
        uint256 saved = vm.snapshotState();
        vault.harvest();
        (uint256 after0, uint256 after1) = _unbooked();
        vm.revertToStateAndDelete(saved);
        snap.fees0 = after0 - snap.unbooked0;
        snap.fees1 = after1 - snap.unbooked1;
    }

    /// After a deposit or a withdrawal: units and idle principal per share never fall, so
    /// rounding went against the actor; idle is the exact fraction; and unbooked rose by
    /// exactly the fees collected, so none was paid out or turned into principal.
    function _verify(Snap memory snap, uint256 shares, bool adds, uint256 paid0, uint256 paid1)
        internal
    {
        uint256 supply = vault.totalSupply();
        for (uint256 index; index < snap.units.length; index++) {
            if (snap.units[index] * supply > vault.unitsOf(index) * snap.supply) {
                unitsPerShareFell = true;
            }
        }
        (uint256 now0, uint256 now1) = vault.principal();
        if (snap.idle0 * supply > now0 * snap.supply) unitsPerShareFell = true;
        if (snap.idle1 * supply > now1 * snap.supply) unitsPerShareFell = true;
        _checkIdle(snap, now0, now1, shares, adds);
        (uint256 after0, uint256 after1) = _unbooked();
        if (after0 + paid0 != snap.unbooked0 + snap.fees0) unbookedMoved = true;
        if (after1 + paid1 != snap.unbooked1 + snap.fees1) unbookedMoved = true;
    }

    function deposit(uint256 who, uint256 amount) external {
        if (vault.depositsPaused()) return;
        address holder = actor(who);
        _fund(holder);
        uint256 shares = bound(amount, 1, seedSupply);
        Snap memory snap = _snap();
        vm.prank(holder);
        vault.deposit(shares, type(uint256).max, type(uint256).max, block.timestamp);
        _verify(snap, shares, true, 0, 0);
        deposits++;
    }

    function withdraw(uint256 who, uint256 amount) external {
        address holder = actor(who);
        uint256 held = vault.balanceOf(holder);
        if (held == 0) return;
        uint256 shares = bound(amount, 1, held);
        _leave(holder, shares);
        withdrawals++;
    }

    function _leave(address holder, uint256 shares) internal {
        Snap memory snap = _snap();
        uint256 held0 = asset0.balanceOf(holder);
        uint256 held1 = asset1.balanceOf(holder);
        vm.prank(holder);
        (uint256 out0, uint256 out1) = vault.withdraw(shares, 0, 0, block.timestamp);
        // Whatever the holder got beyond what the withdrawal reported is rewards paid.
        uint256 paid0 = asset0.balanceOf(holder) - held0 - out0;
        uint256 paid1 = asset1.balanceOf(holder) - held1 - out1;
        _verify(snap, shares, false, paid0, paid1);
    }

    /// Nobody leaves with more than they paid for the same shares, unless the price moved
    /// in between, which here it cannot.
    function roundTrip(uint256 who, uint256 amount) external {
        if (vault.depositsPaused()) return;
        address holder = actor(who);
        _fund(holder);
        uint256 shares = bound(amount, 1, seedSupply);
        vm.startPrank(holder);
        (uint256 paid0, uint256 paid1) =
            vault.deposit(shares, type(uint256).max, type(uint256).max, block.timestamp);
        (uint256 out0, uint256 out1) = vault.withdraw(shares, 0, 0, block.timestamp);
        vm.stopPrank();
        if (out0 > paid0) roundTripProfited = true;
        if (out1 > paid1) roundTripProfited = true;
    }

    /// Time passes, so rewards stream and withdrawals pay them.
    function warp(uint256 time) external {
        vm.warp(block.timestamp + bound(time, 1, 5 days));
    }

    function claim(uint256 who) external {
        address holder = actor(who);
        address[] memory tokens = new address[](2);
        tokens[0] = address(asset0);
        tokens[1] = address(asset1);
        uint256 before0 = asset0.balanceOf(holder);
        uint256 before1 = asset1.balanceOf(holder);
        (uint256 held0, uint256 held1) = _unbooked();
        vm.prank(holder);
        vault.claim(tokens);
        (uint256 after0, uint256 after1) = _unbooked();
        // A claim collects no fees, so the vault holds exactly what it paid less.
        if (after0 + asset0.balanceOf(holder) - before0 != held0) unbookedMoved = true;
        if (after1 + asset1.balanceOf(holder) - before1 != held1) unbookedMoved = true;
    }

    function addIdle(uint256 who, uint256 amount0, uint256 amount1) external {
        address holder = actor(who);
        _fund(holder);
        vm.prank(holder);
        vault.addIdle(bound(amount0, 0, 1e21), bound(amount1, 0, 1e21));
    }

    function pause(bool paused) external {
        vm.prank(vault.curator());
        vault.setDepositsPaused(paused);
    }

    function swap(uint256 which, bool zeroForOne, uint256 amount) external {
        _fund(address(this));
        PoolKey memory pool = which % 2 == 0 ? firstPool : secondPool;
        (uint256 before0, uint256 before1) = _unbooked();
        PoolSwapTest.TestSettings memory settings;
        try swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(bound(amount, 1e18, 100_000e18)),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        ) {
            swaps++;
        } catch { }
        // What the hook pays in and the pools pay out as fees only ever adds.
        (uint256 after0, uint256 after1) = _unbooked();
        if (after0 > before0) profits++;
        if (after1 > before1) profits++;
    }

    /// A deposit's idle part is the fraction rounded up, a withdrawal's rounded down, and
    /// nothing else that reaches the vault changes it.
    function _checkIdle(Snap memory snap, uint256 now0, uint256 now1, uint256 shares, bool adds)
        internal
    {
        uint256 want0;
        uint256 want1;
        if (adds) {
            want0 = snap.idle0 + FixedPointMathLib.fullMulDivUp(snap.idle0, shares, snap.supply);
            want1 = snap.idle1 + FixedPointMathLib.fullMulDivUp(snap.idle1, shares, snap.supply);
        } else {
            want0 = snap.idle0 - FixedPointMathLib.fullMulDiv(snap.idle0, shares, snap.supply);
            want1 = snap.idle1 - FixedPointMathLib.fullMulDiv(snap.idle1, shares, snap.supply);
        }
        if (now0 != want0) idleMoved = true;
        if (now1 != want1) idleMoved = true;
    }

    // The curator's moves. Each tries and records what it did, since a refused move is
    // not a break. A move is taken a block apart from the last, as the vault requires.

    function _price(PoolKey memory pool) internal view returns (uint160 price) {
        (price,,,) = vault.poolManager().getSlot0(pool.toId());
    }

    function rebalance(uint256 from, uint256 to, uint256 amount, bool everything) external {
        uint256 count = vault.positionCount();
        if (count < 2) return;
        from = from % count;
        to = to % count;
        if (from == to) return;
        uint256 units = vault.unitsOf(from);
        if (units == 0) return;
        uint256 out = everything ? units : bound(amount, 1, units / 4 + 1);
        if (out > uint256(uint128(type(int128).max))) return;
        ArbitrageVault.Change[] memory list = new ArbitrageVault.Change[](2);
        list[0] = ArbitrageVault.Change(to, int128(int256(out * 9 / 10)));
        list[1] = ArbitrageVault.Change(from, -int128(int256(out)));
        uint160[] memory prices = new uint160[](2);
        prices[0] = _price(firstPool);
        prices[1] = _price(firstPool);
        (uint256 before0, uint256 before1) = _unbooked();
        vm.roll(block.number + 1);
        vm.prank(vault.curator());
        try vault.rebalance(list, prices, block.timestamp) {
            rebalances++;
            positionsMoved = true;
        } catch {
            return;
        }
        _noRewardsTaken(before0, before1);
    }

    function swapIdle(bool zeroForOne, uint256 amount) external {
        (uint256 idle0, uint256 idle1) = vault.principal();
        uint256 idle = zeroForOne ? idle0 : idle1;
        if (idle == 0) return;
        uint256 in_ = bound(amount, 1, idle > type(uint128).max ? type(uint128).max : idle);
        (uint256 before0, uint256 before1) = _unbooked();
        uint160 price = _price(firstPool);
        vm.roll(block.number + 1);
        vm.prank(vault.curator());
        try vault.swapIdle(zeroForOne, uint128(in_), 0, price, block.timestamp) {
            idleSwaps++;
        } catch {
            return;
        }
        _noRewardsTaken(before0, before1);
    }

    /// A curator move may add to what the vault holds beyond idle principal, when the hook
    /// pays profit in the middle of it, but never take from it.
    function _noRewardsTaken(uint256 before0, uint256 before1) internal {
        (uint256 after0, uint256 after1) = _unbooked();
        if (after0 < before0) curatorTookRewards = true;
        if (after1 < before1) curatorTookRewards = true;
    }

    function addPosition(uint256 low, uint256 high) external {
        if (vault.positionCount() >= vault.MAX_POSITIONS()) return;
        int24 lower = -int24(int256(bound(low, 1, 50) * 60));
        int24 upper = int24(int256(bound(high, 1, 50) * 60));
        vm.prank(vault.curator());
        try vault.addPosition(lower, upper) {
            positionEdits++;
            positionsMoved = true;
        } catch { }
    }

    function dropPosition(uint256 which) external {
        uint256 count = vault.positionCount();
        for (uint256 step; step < count; step++) {
            uint256 index = (which % count + step) % count;
            if (vault.unitsOf(index) != 0) continue;
            vm.prank(vault.curator());
            vault.dropPosition(index);
            positionEdits++;
            positionsMoved = true;
            return;
        }
    }

    /// Shares move between holders, and neither's earned rewards change in the move.
    function transferShares(uint256 from, uint256 to, uint256 amount) external {
        address sender = actor(from);
        address receiver = actor(to);
        uint256 held = vault.balanceOf(sender);
        if (held == 0) return;
        uint256 moved = bound(amount, 1, held);
        uint256 before0 =
            vault.earned(sender, address(asset0)) + vault.earned(receiver, address(asset0));
        uint256 before1 =
            vault.earned(sender, address(asset1)) + vault.earned(receiver, address(asset1));
        vm.prank(sender);
        vault.transfer(receiver, moved);
        uint256 after0 =
            vault.earned(sender, address(asset0)) + vault.earned(receiver, address(asset0));
        uint256 after1 =
            vault.earned(sender, address(asset1)) + vault.earned(receiver, address(asset1));
        if (before0 != after0) transferMovedRewards = true;
        if (before1 != after1) transferMovedRewards = true;
        transfers++;
    }

    function harvest() external {
        Snap memory snap = _snap();
        vault.harvest();
        (uint256 after0, uint256 after1) = _unbooked();
        if (after0 != snap.unbooked0 + snap.fees0) unbookedMoved = true;
        if (after1 != snap.unbooked1 + snap.fees1) unbookedMoved = true;
    }
}

contract HookVaultInvariantTest is VaultWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    VaultHandler internal handler;
    uint256 internal seedSupply;
    uint256[] internal seedUnits;

    function setUp() public override {
        super.setUp();
        _seed(3);
        seedSupply = vault.totalSupply();
        for (uint256 index; index < 3; index++) {
            seedUnits.push(vault.unitsOf(index));
        }
        vm.prank(team);
        hook.setRecipient(id, address(vault));
        handler = VaultHandler(
            deployCode(
                "HookVaultInvariant.t.sol:VaultHandler",
                abi.encode(
                    vault,
                    swapper,
                    token0 == address(backing) ? backing : coin,
                    token0 == address(backing) ? coin : backing,
                    first,
                    second
                )
            )
        );
        targetContract(address(handler));
    }

    /// The vault's own record of a position is the pool manager's, so what the shares
    /// redeem is exactly what the pools hold.
    function invariantUnitsMatchThePools() public view {
        for (uint256 index; index < vault.positionCount(); index++) {
            ArbitrageVault.Position memory entry = vault.positionAt(index);
            (uint128 held,,) = manager.getPositionInfo(
                first.toId(),
                address(vault),
                entry.tickLower,
                entry.tickUpper,
                bytes32(entry.salt)
            );
            assertEq(held, vault.unitsOf(index), "position");
        }
    }

    function invariantIdleIsCoveredByBalance() public view {
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertLe(idle0, _balance(token0), "token0");
        assertLe(idle1, _balance(token1), "token1");
    }

    /// Every share is held by someone known, the locked minimum stays, and the units a
    /// share stands for never fall below what the seed gave it: rounding always went
    /// against whoever acted. Cross-multiplied so there is no division to round.
    function invariantUnitsPerShareNeverFall() public view {
        uint256 supply = vault.totalSupply();
        uint256 counted = vault.balanceOf(curator) + vault.balanceOf(vault.DEAD());
        for (uint256 index; index < 3; index++) {
            counted += vault.balanceOf(handler.actor(index));
        }
        assertEq(counted, supply, "every share has a known holder");
        assertGe(supply, vault.MINIMUM_SHARES(), "the minimum is never withdrawn");
        // Once the curator has moved liquidity between positions a position's units per
        // share rightly change, so the seed's is compared only before that.
        if (handler.positionsMoved()) return;
        for (uint256 index; index < seedUnits.length; index++) {
            assertGe(
                vault.unitsOf(index) * seedSupply, seedUnits[index] * supply, "units/share"
            );
        }
    }

    /// What holders could claim, plus the curator's fee, never exceeds what the vault holds
    /// beyond idle principal, for either token: the stream is always fully backed.
    function invariantRewardsAreBacked() public view {
        address[2] memory tokens = [token0, token1];
        for (uint256 slot; slot < 2; slot++) {
            address token = tokens[slot];
            uint256 total = vault.feeOwed(token);
            total += vault.earned(curator, token) + vault.earned(vault.DEAD(), token);
            for (uint256 index; index < 3; index++) {
                total += vault.earned(handler.actor(index), token);
            }
            assertLe(total, vault.owed(token), "claimable exceeds what is reserved");
            (uint256 idle0, uint256 idle1) = vault.principal();
            uint256 idle = slot == 0 ? idle0 : idle1;
            assertLe(vault.owed(token), _balance(token) - idle, "reserved exceeds the surplus");
        }
    }

    function invariantNoActionBreaksTheAccounting() public view {
        assertFalse(handler.roundTripProfited(), "a round trip made money");
        assertFalse(handler.unitsPerShareFell(), "rounding went against holders");
        assertFalse(handler.unbookedMoved(), "unbooked changed other than by fees");
        assertFalse(handler.idleMoved(), "idle principal moved other than pro-rata");
        assertFalse(handler.curatorTookRewards(), "a curator move took rewards");
        assertFalse(handler.transferMovedRewards(), "a transfer moved earned rewards");
    }

    /// Shows what a run exercised, with -vv.
    function invariantCallSummary() public view {
        console2.log("deposits", handler.deposits());
        console2.log("withdrawals", handler.withdrawals());
        console2.log("swaps", handler.swaps());
        console2.log("rewards arrived", handler.profits());
        console2.log("rebalances", handler.rebalances());
        console2.log("idle swaps", handler.idleSwaps());
        console2.logBytes4(handler.lastIdleRefusal());
        console2.log("position edits", handler.positionEdits());
        console2.log("transfers", handler.transfers());
    }

    function _balance(address asset) internal view returns (uint256) {
        return asset == address(backing)
            ? backing.balanceOf(address(vault))
            : coin.balanceOf(address(vault));
    }
}
