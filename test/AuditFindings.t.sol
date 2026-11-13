// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { DeploySzr } from "../script/DeploySzr.s.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { InitialLiquidityTest } from "./InitialLiquidity.t.sol";

/// @dev Audit findings. `testFix_*` are regressions for fixed issues; `testPoC_*` pass while
/// the issue is still open or was accepted (see the README launch checklist).
/// ponytail: inherits InitialLiquidityTest for its deploy-script setUp, so its tests rerun here.
contract AuditFindingsTest is InitialLiquidityTest {
    /// H-1 (fixed part): the manager cannot withdraw or move the permanent genesis POL.
    function testFix_ManagerCannotWithdrawGenesisPol() public {
        _fundInitial();
        address operator = locker.manager();
        uint256 id = locker.INITIAL_POSITION();
        uint256 units = locker.liquidityHeld(id);
        Liquidity.Move memory move =
            Liquidity.Move(id, 0, units, 1, 0, 0, Liquidity.Bounds(0, 0, block.timestamp));

        vm.startPrank(operator);
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.withdrawPrincipal(id, units, 0, 0, block.timestamp);
        vm.expectRevert(Liquidity.InvalidPool.selector);
        locker.moveLiquidity(move);
        vm.stopPrank();

        assertEq(locker.liquidityHeld(id), units);
        locker.collect(id); // fees still collectable
    }

    /// M-2 (fixed): backing cannot be donated while no one holds a claim on it.
    function testFix_DonationAtZeroSupplyReverts() public {
        address donor = address(0xD0);
        backing.mint(donor, 100e18);
        vm.startPrank(donor);
        backing.approve(address(core), 100e18);
        vm.expectRevert(SzrCore.NoActiveSupply.selector);
        core.donateBacking(100e18);
        vm.stopPrank();

        _migrateContributor();
        vm.prank(donor);
        core.donateBacking(100e18);
        assertGe(core.reserveCash(), 100e18);
    }

    /// H-2 (open): a low-recovery migration lowers NAV for existing holders, and an arbitrageur
    /// who migrates cheap legacy SZR and redeems immediately leaves with more WETH than it brought.
    function testPoC_MigrationLowersFloorAndArbitrageExtractsFromHolders() public {
        vm.prank(alice);
        migrator.migrate(1_000_000e18, 0, block.timestamp);
        uint256 navBefore = core.NAV();

        oldHook.setPrice(3e11); // legacy recovery 10x lower (band drained / legacy price fell)
        address arb = address(0xA4B);
        oldToken.mint(arb, 1_000_000e18);
        vm.startPrank(arb);
        oldToken.approve(address(migrator), type(uint256).max);
        uint256 brought = migrator.migrate(1_000_000e18, 0, block.timestamp);
        core.token().approve(address(core), type(uint256).max);
        uint256 taken = core.redeem(1_000_000e18, 0);
        vm.stopPrank();

        assertLt(core.NAV(), navBefore * 60 / 100); // alice's floor fell >40%
        assertGt(taken, brought * 5); // arb extracted alice's backing
    }

    /// M-1 (fixed for the manager): before genesis is funded the pool is empty, so anyone can
    /// move its price into the genesis range for free and fundInitialLiquidity then reverts.
    /// Moving it back was also free but could be undone again before the funding landed.
    /// The manager can now restore the price and fund in one transaction, holding nothing.
    function testFix_ManagerRestoresAMovedGenesisPriceAndFundsInOneBatch() public {
        _migrateContributor();
        uint256 id = locker.INITIAL_POSITION();
        PoolKey memory key = locker.key(id);
        Liquidity.Position memory g = locker.position(id);
        bool szrFirst = Currency.unwrap(key.currency0) == address(core.token());
        uint160 target =
            TickMath.getSqrtPriceAtTick(szrFirst ? g.tickLower + 600 : g.tickUpper - 600);

        PoolSwapTest router = new PoolSwapTest(manager);
        address griefer = address(0x6121);
        backing.mint(griefer, 1e18);
        vm.startPrank(griefer);
        backing.approve(address(router), type(uint256).max);
        PoolSwapTest.TestSettings memory settings;
        router.swap(key, IPoolManager.SwapParams(!szrFirst, -1e18, target), settings, "");
        vm.stopPrank();
        assertEq(backing.balanceOf(griefer), 1e18); // cost nothing

        vm.prank(contributor);
        vm.expectRevert(Liquidity.AboveMaximum.selector);
        locker.fundInitialLiquidity(1, block.timestamp);

        // The manager holds no SZR or WETH in Liquidity. A swap through the empty pool spends
        // nothing, so it can move the price back and fund genesis in the same transaction.
        uint160 restore =
            TickMath.getSqrtPriceAtTick(szrFirst ? g.tickLower - 600 : g.tickUpper + 600);
        assertEq(locker.heldPrincipal(address(core.token())), 0);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            locker.swapPrincipal, (key, szrFirst, 1, 0, restore, block.timestamp)
        );
        calls[1] = abi.encodeCall(locker.fundInitialLiquidity, (1, block.timestamp));
        vm.prank(alice); // only the manager can make that swap
        vm.expectRevert(Liquidity.NotManager.selector);
        locker.multicall(calls);
        vm.prank(core.initializer()); // the manager in this fixture
        locker.multicall(calls);
        assertTrue(locker.initialLiquidityFunded());
        assertEq(locker.heldPrincipal(address(core.token())), 0);
        assertEq(locker.heldPrincipal(address(backing)), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Second audit pass (pre-deployment). All `testPoC_*` below pass while the issue is open.
    // ---------------------------------------------------------------------------------------

    function _buyer(uint256 funds) internal returns (address buyer) {
        buyer = address(0xB0B);
        backing.mint(buyer, funds);
        vm.prank(buyer);
        backing.approve(address(core), type(uint256).max);
    }

    /// N-1 (fixed by design): the auction stays closed while migration can still lower NAV,
    /// so no sale can store a floor that a later below-NAV migration strands above the market.
    function testFix_AuctionStaysClosedWhileMigrationCanLowerNav() public {
        vm.prank(alice);
        migrator.migrate(1_000_000e18, 0, block.timestamp);
        vm.warp(block.timestamp + 3 days);
        address buyer = _buyer(100e18);
        vm.prank(buyer);
        vm.expectRevert(SzrCore.AuctionNotOpen.selector);
        core.buy(1_000e18, type(uint256).max, block.timestamp);

        oldHook.setPrice(3e11);
        address late = address(0xA4B);
        oldToken.mint(late, 50_000_000e18);
        vm.startPrank(late);
        oldToken.approve(address(migrator), type(uint256).max);
        migrator.migrate(50_000_000e18, 0, block.timestamp);
        vm.stopPrank();

        _fundInitial(); // migration cannot close until the genesis position is funded
        vm.prank(core.initializer());
        core.closeMigration();
        vm.warp(block.timestamp + 30 days); // curve fully decayed
        uint256 floor = (core.backingRequired(1e18) * 3 + 1) / 2;
        assertEq(core.price(), floor); // decays to 1.5x the diluted NAV, not the old one
        vm.prank(buyer);
        core.buy(1_000e18, type(uint256).max, block.timestamp);
        assertEq(core.auctionState().floorWad, floor);
    }

    /// N-2 (accepted; FIFO sequencer, deploy from an unpublished address): `addPool` requires
    /// the pool price to equal the configured price exactly.
    /// If the main 1% pool is initialised at another price first, `addPool` reverts. Before
    /// the script runs this fails the local simulation (nothing is broadcast); between the
    /// script's separate transactions it leaves Core deployed but unlaunched. Redeploy fixes it.
    function testPoC_PoolPreInitialisationBreaksScriptedDeployment() public {
        DeploySzr.Config memory config;
        config.chainId = block.chainid;
        config.asset = address(backing);
        config.poolManager = address(manager);
        config.teamBeneficiary = address(this);
        config.legacyToken = address(oldToken);
        config.marketPrice = 4e12;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = TOTAL;
        config.initialLiquidityTokens = INITIAL;
        config.auction = SzrCore.AuctionConfig(8e12, 1, 20_000e18);
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));

        uint256 snapshot = vm.snapshotState();
        (SzrCore next,,) = deployment.run(config);
        address szr = address(next.token());
        vm.revertToState(snapshot);

        bool first = szr < address(backing);
        PoolKey memory key = PoolKey(
            Currency.wrap(first ? szr : address(backing)),
            Currency.wrap(first ? address(backing) : szr),
            10_000,
            200,
            IHooks(address(0))
        );
        vm.prank(address(0x6121));
        manager.initialize(key, uint160(1 << 96));

        vm.expectRevert(Liquidity.InvalidPrice.selector);
        deployment.run(config);
    }

    /// N-3 (guarded at deploy; the script refuses a genesis price below the highest NAV
    /// migration could reach): the genesis range is fixed before launch but NAV is set later.
    /// The unbacked genesis tokens keep NAV below what migrators recover, so this now needs
    /// the legacy price to rise well above the genesis price after deployment and most
    /// holders to migrate. Then genesis SZR is sold below NAV and redeemed against reserves.
    /// Holders' NAV is unchanged; the POL bears the loss.
    function testPoC_GenesisPricedBelowNavIsArbitragedAgainstReserves() public {
        oldHook.setPrice(8e12); // net recovery 7.92e-6 WETH/SZR vs 4e-6 genesis price
        _fundInitial();
        vm.prank(alice);
        migrator.migrate(300_000_000e18, 0, block.timestamp);
        assertGt(core.NAV(), 7e12); // 7.92e-6 diluted by the 25M genesis tokens
        uint256 navBefore = core.NAV();
        uint256 id = locker.INITIAL_POSITION();
        PoolKey memory key = locker.key(id);
        bool szrFirst = Currency.unwrap(key.currency0) == address(core.token());

        PoolSwapTest router = new PoolSwapTest(manager);
        address arb = address(0xA4B);
        backing.mint(arb, 40e18);
        vm.startPrank(arb);
        backing.approve(address(router), type(uint256).max);
        PoolSwapTest.TestSettings memory settings;
        router.swap(
            key,
            IPoolManager.SwapParams(
                !szrFirst,
                -40e18,
                szrFirst ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            settings,
            ""
        );
        uint256 bought = core.token().balanceOf(arb);
        core.token().approve(address(core), bought);
        uint256 taken = core.redeem(bought, 0);
        vm.stopPrank();

        assertGt(bought, INITIAL / 4); // a quarter of the permanent POL is gone
        assertGt(taken, 40e18 * 125 / 100); // >30% risk-free, paid from reserve cash
        assertGe(core.NAV(), navBefore); // holders unaffected: the genesis position paid
    }

    /// M-1 extension (accepted, liveness not loss): once anyone has liquidity inside the genesis
    /// range, restoring the price needs a third party to sell real SZR into those bids (at
    /// above-genesis prices). Core's genesis allocation cannot be used for it.
    function testPoC_GenesisBlockedByInRangeLiquidityNeedsRealSzrToRestore() public {
        _migrateContributor();
        uint256 id = locker.INITIAL_POSITION();
        PoolKey memory key = locker.key(id);
        Liquidity.Position memory g = locker.position(id);
        bool szrFirst = Currency.unwrap(key.currency0) == address(core.token());
        int24 lower = szrFirst ? g.tickLower : g.tickUpper - 1_200;

        // Griefer: a migrated holder who quotes SZR just inside the range, then buys into it.
        PoolSwapTest router = new PoolSwapTest(manager);
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        backing.mint(alice, 100e18);
        vm.startPrank(alice);
        migrator.migrate(5_000_000e18, 0, block.timestamp);
        core.token().approve(address(provider), type(uint256).max);
        backing.approve(address(router), type(uint256).max);
        provider.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(lower, lower + 1_200, 3e22, 0), ""
        );
        PoolSwapTest.TestSettings memory settings;
        router.swap(
            key,
            IPoolManager.SwapParams(
                !szrFirst, -50e18, TickMath.getSqrtPriceAtTick(lower + 600)
            ),
            settings,
            ""
        );
        vm.stopPrank();

        vm.prank(contributor);
        vm.expectRevert(Liquidity.AboveMaximum.selector);
        locker.fundInitialLiquidity(1, block.timestamp);

        // A zero-capital restore no longer works: the swap needs SZR the caller does not have.
        uint160 restore =
            TickMath.getSqrtPriceAtTick(szrFirst ? g.tickLower - 600 : g.tickUpper + 600);
        vm.expectRevert();
        router.swap(key, IPoolManager.SwapParams(szrFirst, -1e24, restore), settings, "");

        // A third holder must sell their own SZR down through the griefer's bids.
        address restorer = address(0x4E5);
        oldToken.mint(restorer, 2_000_000e18);
        vm.startPrank(restorer);
        oldToken.approve(address(migrator), type(uint256).max);
        migrator.migrate(2_000_000e18, 0, block.timestamp);
        core.token().approve(address(router), type(uint256).max);
        router.swap(
            key, IPoolManager.SwapParams(szrFirst, -2_000_000e18, restore), settings, ""
        );
        vm.stopPrank();
        assertLt(core.token().balanceOf(restorer), 2_000_000e18 - 100_000e18);

        vm.prank(contributor);
        assertGt(locker.fundInitialLiquidity(1, block.timestamp), 0);
    }

    /// Assurance (not a finding): redeem and donateSzr pass through the auction checkpoint
    /// before and after it opens. Scope: one migration, one real buy, up to 100 idle years.
    function testFuzz_ExitsSurviveAnyAuctionHistory(uint32 wait, uint96 rawBuy, uint32 idle)
        public
    {
        vm.prank(alice);
        migrator.migrate(1_000_000e18, 0, block.timestamp);
        vm.startPrank(alice);
        core.token().approve(address(core), type(uint256).max);
        core.redeem(1_000e18, 0);
        core.donateSzr(1e18);
        vm.stopPrank();
        _fundInitial(); // migration cannot close until the genesis position is funded
        vm.prank(core.initializer());
        core.closeMigration();
        vm.warp(core.auctionsOpenAt() + bound(wait, 1 hours, 3 * 365 days));
        uint256 amount = bound(rawBuy, 1e18, core.availableRelease() / 2);
        address buyer = _buyer(type(uint128).max);
        vm.prank(buyer);
        core.buy(amount, type(uint256).max, block.timestamp);
        vm.warp(block.timestamp + bound(idle, 0, 100 * 365 days));
        core.price();
        vm.startPrank(alice);
        core.redeem(1_000e18, 0);
        core.donateSzr(1e18);
        core.redeem(1_000e18, 0);
        vm.stopPrank();
    }
}
