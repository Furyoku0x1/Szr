// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { SzrMigration } from "../src/SzrMigration.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { LegacyMigrationHook } from "./utils/LegacyMigrationHook.sol";
import { LaunchWorld } from "./utils/LaunchWorld.sol";

/// @dev Random users and the team act on the system from the moment the deploy script ends.
contract LaunchHandler is Test {
    SzrCore internal core;
    Liquidity internal locker;
    SzrMigration internal migrator;
    PoolSwapTest internal router;
    LegacyMigrationHook internal oldHook;
    TestAsset internal backing;
    TestAsset internal szr;
    TestAsset internal old;
    address internal team;
    address[3] internal actors;
    bool public navFellAfterClose;
    bool public redeemUnfunded;
    bool public soldBelowMinimum;
    uint256 public migrations;
    uint256 public sales;
    uint256 public draws;
    uint256 public settlements;
    uint256 public poolTrades;

    constructor(
        SzrCore core_,
        Liquidity locker_,
        PoolSwapTest router_,
        LegacyMigrationHook hook_,
        address team_,
        address[3] memory actors_
    ) {
        core = core_;
        locker = locker_;
        router = router_;
        oldHook = hook_;
        team = team_;
        actors = actors_;
        migrator = SzrMigration(core.migration());
        backing = TestAsset(core.backingAsset());
        szr = TestAsset(address(core.token()));
        old = TestAsset(address(hook_.token()));
    }

    /// Once migration has closed, no action may lower backing per active token.
    modifier tracked() {
        bool closed = core.migrationRemaining() == 0;
        uint256 backingBefore = core.backingAmount();
        uint256 supplyBefore = core.activeSupply();
        _;
        if (!closed) return;
        if (core.backingAmount() * supplyBefore < backingBefore * core.activeSupply()) {
            navFellAfterClose = true;
        }
    }

    function migrate(uint256 actor, uint256 raw) external tracked {
        address owner = actors[actor % 3];
        uint256 room = core.migrationRemaining();
        uint256 held = old.balanceOf(owner);
        if (room <= 1e18) return;
        if (held < 1e18) return;
        uint256 most = held < room - 1 ? held : room - 1;
        if (most > 30_000_000e18) most = 30_000_000e18;
        vm.prank(owner);
        migrator.migrate(bound(raw, 1e18, most), 0, block.timestamp);
        migrations++;
    }

    /// The old price is flat in practice; moving it stresses NAV during migration.
    function repriceLegacy(uint256 raw) external {
        oldHook.setPrice(bound(raw, 1e11, 3e12));
    }

    function redeem(uint256 actor, uint256 raw) external tracked {
        address owner = actors[actor % 3];
        uint256 held = szr.balanceOf(owner);
        if (held == 0) return;
        uint256 amount = bound(raw, 1, held);
        uint256 payout =
            FixedPointMathLib.fullMulDiv(amount, core.backingAmount(), core.activeSupply());
        if (payout > core.reserveCash()) {
            redeemUnfunded = true;
            return;
        }
        vm.prank(owner);
        core.redeem(amount, payout);
    }

    function donateWeth(uint256 actor, uint256 raw) external tracked {
        if (core.activeSupply() == 0) return; // refused by design: nobody to receive it
        vm.prank(actors[actor % 3]);
        core.donateBacking(bound(raw, 1, 1e18));
    }

    /// WETH sent to Core by plain transfer and folded in by a bystander.
    function absorbStray(uint256 raw) external tracked {
        if (core.activeSupply() == 0) return; // refused by design: nobody to receive it
        backing.mint(address(core), bound(raw, 1, 1e18));
        core.absorbBacking();
    }

    function donateSzr(uint256 actor, uint256 raw) external tracked {
        address owner = actors[actor % 3];
        uint256 held = szr.balanceOf(owner);
        if (held < 2) return;
        vm.prank(owner);
        core.donateSzr(bound(raw, 1, held / 2));
    }

    function poolTrade(uint256 actor, bool wethIn, uint256 raw) external tracked {
        address owner = actors[actor % 3];
        uint256 amount;
        if (wethIn) {
            amount = bound(raw, 1e12, 20e18);
        } else {
            uint256 held = szr.balanceOf(owner);
            if (held < 1e12) return;
            amount = bound(raw, 1e12, held);
        }
        PoolKey memory pool = locker.key(0);
        bool zeroForOne = (Currency.unwrap(pool.currency0) == address(backing)) == wethIn;
        PoolSwapTest.TestSettings memory settings;
        // An outside trade can fail on its own terms, such as the price already at its limit.
        vm.prank(owner);
        try router.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        ) {
            poolTrades++;
        } catch { }
    }

    function collect(bool genesis) external tracked {
        locker.collect(genesis ? locker.INITIAL_POSITION() : 0);
    }

    /// Anyone can fund genesis. It fails while an outside trade has pushed the empty pool's
    /// price into the genesis range, which is the documented, recoverable state.
    function fund() external tracked {
        if (core.initialLiquidityReleased()) return;
        try locker.fundInitialLiquidity(1, block.timestamp) { } catch { }
    }

    function close() external tracked {
        if (core.migrationRemaining() == 0) return;
        if (!core.initialLiquidityReleased()) return;
        vm.prank(team);
        core.closeMigration();
    }

    function extend(uint256 raw) external tracked {
        if (core.migrationRemaining() == 0) return;
        if (!core.initialLiquidityReleased()) return;
        uint256 inventory = core.publicInventory();
        if (inventory == 0) return;
        if (inventory > 40_000_000e18) inventory = 40_000_000e18;
        vm.prank(team);
        core.extendMigration(bound(raw, 1, inventory));
    }

    function buy(uint256 actor, uint256 raw) external tracked {
        if (core.auctionsOpenAt() == 0) return;
        uint256 available = core.availableRelease();
        if (available == 0) return;
        if (available > 300_000e18) available = 300_000e18;
        uint256 quantity = bound(raw, 1, available);
        address owner = actors[actor % 3];
        (uint256 payment,,) = core.quote(quantity);
        if (payment * 2 < core.backingRequired(quantity) * 3) soldBelowMinimum = true;
        if (backing.balanceOf(owner) < payment) return;
        vm.prank(owner);
        core.buy(quantity, payment, block.timestamp);
        sales++;
    }

    function borrow(uint256 actor, uint256 rawCollateral, uint256 rawPrincipal)
        external
        tracked
    {
        if (core.migrationRemaining() != 0) return;
        address owner = actors[actor % 3];
        (uint256 locked, uint256 debt, uint256 expiry) = core.loans(owner);
        if (debt != 0) {
            if (block.timestamp >= expiry) return;
        }
        uint256 added = bound(rawCollateral, 0, szr.balanceOf(owner));
        uint256 capacity = FixedPointMathLib.fullMulDiv(
            locked + added, core.backingAmount(), core.activeSupply()
        );
        if (capacity <= debt + 1) return;
        uint256 room = capacity - debt;
        if (room > core.reserveCash()) room = core.reserveCash();
        if (room < 2) return;
        vm.prank(owner);
        core.borrow(added, bound(rawPrincipal, 2, room));
        draws++;
    }

    function repay(uint256 actor, uint256 raw, bool reclaim) external tracked {
        address owner = actors[actor % 3];
        (, uint256 principal,) = core.loans(owner);
        if (principal == 0) return;
        uint256 amount = bound(raw, 1, principal);
        vm.prank(owner);
        if (reclaim) core.repayAndReclaim(amount);
        else core.repay(amount);
    }

    function settle(uint256 actor) external tracked {
        address owner = actors[actor % 3];
        (, uint256 principal, uint256 expiry) = core.loans(owner);
        if (principal == 0) return;
        if (block.timestamp < expiry) return;
        core.settleExpired(owner);
        settlements++;
    }

    /// The team turns sale funding into liquidity. Its own limits may refuse a step.
    function teamDeploy(uint256 raw) external tracked {
        uint256 held = locker.heldPrincipal(address(backing));
        if (held < 1e12) return;
        PoolKey memory pool = locker.key(0);
        bool wethIn = Currency.unwrap(pool.currency0) == address(backing);
        vm.startPrank(team);
        try locker.swapPrincipal(
            pool,
            wethIn,
            bound(raw, 1e12, held),
            0,
            wethIn ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        ) { }
            catch { }
        try locker.deployPrincipal(
            0, 1e15, Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        ) { }
            catch { }
        vm.stopPrank();
    }

    function teamWithdraw(uint256 raw) external tracked {
        uint256 units = locker.liquidityHeld(0);
        if (units == 0) return;
        vm.prank(team);
        locker.withdrawPrincipal(0, bound(raw, 1, units), 0, 0, block.timestamp);
    }

    function elapse(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 1, 40 days));
    }
}

/// @notice The existing random-action suite starts after migration with no genesis position.
/// This one starts where the deploy script ends: 25M unbacked genesis tokens in the pool,
/// zero reserves, migration open, and runs through closing, sales and loans.
contract LaunchInvariantTest is LaunchWorld {
    LaunchHandler internal handler;

    function setUp() public virtual {
        _start(true);
    }

    function _start(bool fundGenesis) internal {
        _world(address(0x1000), fundGenesis); // WETH below SZR, as on Robinhood Chain
        address[3] memory users = [alice, bob, carol];
        handler = new LaunchHandler(core, locker, router, oldHook, team, users);
        targetContract(address(handler));
    }

    function invariantBooksBalanceFromLaunch() public view {
        _books();
        address[3] memory users = [alice, bob, carol];
        uint256 debt;
        uint256 collateral;
        uint256 reclaimable;
        for (uint256 index; index < 3; index++) {
            (uint256 locked, uint256 owed,) = core.loans(users[index]);
            debt += owed;
            collateral += locked;
            reclaimable += core.reclaimableCollateral(users[index]);
            assertLe(owed * core.activeSupply(), locked * core.backingAmount());
        }
        assertEq(core.loanPrincipal(), debt);
        assertEq(core.pledgedSupply(), collateral);
        assertEq(core.totalReclaimable(), reclaimable);
        assertFalse(handler.navFellAfterClose());
        assertFalse(handler.redeemUnfunded());
        assertFalse(handler.soldBelowMinimum());
        if (core.migrationRemaining() != 0) {
            assertEq(core.loanPrincipal(), 0);
            assertEq(core.auctionsOpenAt(), 0);
            assertEq(core.totalReleased(), 0);
        }
    }

    /// After any sequence, everyone can leave: wallets first with loans outstanding, then
    /// live loans repay and expired ones settle.
    function afterInvariant() public {
        address[3] memory users = [alice, bob, carol];
        for (uint256 index; index < 3; index++) {
            _exit(users[index]);
        }
        for (uint256 index; index < 3; index++) {
            (, uint256 owed, uint256 expiry) = core.loans(users[index]);
            if (owed == 0) continue;
            if (block.timestamp < expiry) {
                vm.prank(users[index]);
                core.repayAndReclaim(owed);
            } else {
                core.settleExpired(users[index]);
            }
            _exit(users[index]);
        }
        assertEq(core.loanPrincipal(), 0);
        assertEq(core.pledgedSupply(), 0);
        _books();
    }

    function _exit(address owner) internal {
        vm.startPrank(owner);
        uint256 reclaimable = core.reclaimableCollateral(owner);
        if (reclaimable != 0) core.reclaimCollateral(reclaimable);
        uint256 held = szr.balanceOf(owner);
        if (held != 0) {
            uint256 expected =
                FixedPointMathLib.fullMulDiv(held, core.backingAmount(), core.activeSupply());
            assertEq(core.redeem(held, 0), expected);
        }
        vm.stopPrank();
    }
}

/// @notice The same run starting before genesis is funded (the script's funding switched off
/// or its funding transaction failed), so funding lands at a random point among migrations,
/// redemptions and pool trades.
contract LaunchUnfundedInvariantTest is LaunchInvariantTest {
    function setUp() public override {
        _start(false);
    }
}
