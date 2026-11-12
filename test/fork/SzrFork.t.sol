// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { SzrMigration, ILegacySzrHook, ILegacySzrToken } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";

/// @notice Rehearsal against the live legacy SZR hook on Robinhood Chain. Skipped unless
/// FORK_RPC_URL is set; FORK_BLOCK pins the block (the holders below were read at 112788329).
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*"
contract SzrForkTest is Test {
    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    uint256 internal constant INITIAL = 25_000_000e18;
    // Real holders of the old token, impersonated on the fork to supply and migrate it.
    address[7] internal funders = [
        0xA365B69A5AfCe3BD08577a9420902354365E951e,
        0x1305869ceD9527EA23f30E116f6E8dC7AdC21122,
        0xF27E6D330D1f61A01e17C987B07dB416434C2c85,
        0x15579C473047Cb226159f64cD21b621B921F5637,
        0xA2f8BC096023142e5cC50EE6168DDc709cbd5b93,
        0x3eE67aD5Dd107e0d801c86A6A61401c74F515DC9,
        0x77445B7a3592DBdcc8b0B03D51547C24923e2fb2
    ];
    address internal constant HOLDER = 0xf6be30ef5504aFd02E93dBAbe6E082177db5f644;

    ILegacySzrHook internal hook;
    IERC20 internal weth;
    IERC20 internal old = IERC20(LEGACY);
    SzrCore internal core;
    Liquidity internal locker;
    SzrMigration internal migrator;
    address internal deployer;
    bool internal live;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        live = true;
        hook = ILegacySzrHook(ILegacySzrToken(LEGACY).hook());
        weth = IERC20(hook.weth());
    }

    function _config() internal view returns (DeploySzr.Config memory config) {
        config.chainId = block.chainid;
        config.asset = address(weth);
        config.poolManager = address(hook.poolManager());
        config.teamBeneficiary = address(0xBEEF);
        config.legacyToken = LEGACY;
        config.marketPrice = 4e12;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = 350_000_000e18;
        config.initialLiquidityTokens = INITIAL;
        config.auction = SzrCore.AuctionConfig(8e12, 1, 20_000e18);
    }

    /// Runs the real deploy script, with the deployer migrating 25M and funding genesis.
    function _deploy() internal {
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        uint256 snapshot = vm.snapshotState();
        (SzrCore trial,,) = deployment.run(_config());
        address broadcaster = trial.initializer();
        vm.revertToState(snapshot); // also resets this contract's storage
        deployer = broadcaster;
        uint256 needed = INITIAL;
        for (uint256 index; index < funders.length; index++) {
            uint256 held = old.balanceOf(funders[index]);
            uint256 amount = held < needed ? held : needed;
            vm.prank(funders[index]);
            old.transfer(deployer, amount);
            needed -= amount;
        }
        assertEq(needed, 0, "impersonated holders no longer hold 25M old SZR at this block");
        DeploySzr.Config memory config = _config();
        config.fundInitialLiquidity = true;
        config.initialLiquidityMinimumBacking = hook.quoteSellExactIn(INITIAL).netWethOut;
        (core,, locker) = deployment.run(config);
        migrator = SzrMigration(core.migration());
    }

    function testLegacyHookPaysOneFlatPriceUpToCirculatingSupply() public {
        if (!live) return vm.skip(true);
        uint256 one = hook.quoteSellExactIn(1e18).netWethOut;
        assertGt(one, 0);
        // The same price per token at every size: no slippage and no sell fee.
        assertApproxEqAbs(hook.quoteSellExactIn(1_000_000e18).netWethOut, one * 1_000_000, 1e6);
        assertApproxEqAbs(
            hook.quoteSellExactIn(100_000_000e18).netWethOut, one * 100_000_000, 1e8
        );
        // Only tokens outside the hook's own inventory can be sold, less one wei.
        uint256 circulating = old.totalSupply() - old.balanceOf(address(hook)) - 1;
        assertGt(hook.quoteSellExactIn(circulating).netWethOut, 0);
        vm.expectRevert();
        hook.quoteSellExactIn(circulating + 1);
        emit log_named_decimal_uint("WETH per old SZR", one, 18);
        emit log_named_decimal_uint("old SZR that can be sold", circulating, 18);
        emit log_named_decimal_uint(
            "WETH if all of it migrates", hook.quoteSellExactIn(circulating).netWethOut, 18
        );
        emit log_named_decimal_uint("WETH held by the hook", weth.balanceOf(address(hook)), 18);
    }

    function testFullLaunchAgainstTheLiveLegacyHook() public {
        if (!live) return vm.skip(true);
        uint256 quoted = hook.quoteSellExactIn(INITIAL).netWethOut;
        uint256 hookWeth = weth.balanceOf(address(hook));
        _deploy();

        // The deploy script migrated 25M through the real hook and funded the genesis position.
        assertTrue(locker.initialLiquidityFunded());
        assertEq(core.activeSupply(), INITIAL);
        assertEq(core.reserveCash(), quoted);
        assertEq(weth.balanceOf(address(core)), quoted);
        assertEq(hookWeth - weth.balanceOf(address(hook)), quoted);
        assertEq(core.auctionsOpenAt(), 0);
        uint256 nav = core.NAV();
        emit log_named_decimal_uint("NAV after the deployer's migration", nav, 18);

        // A second real holder migrates everything: same price, so NAV does not move.
        uint256 amount = old.balanceOf(HOLDER);
        assertGt(amount, 0);
        (uint256 expected,,) = migrator.quote(amount);
        vm.startPrank(HOLDER);
        old.approve(address(migrator), amount);
        assertEq(migrator.migrate(amount, expected, block.timestamp), expected);
        IERC20 szr = IERC20(address(core.token()));
        assertEq(szr.balanceOf(HOLDER), amount);
        assertApproxEqAbs(core.NAV(), nav, 1);

        // Redemption pays real WETH at NAV while migration is still open.
        szr.approve(address(core), amount);
        uint256 paid = core.redeem(amount / 2, 0);
        assertEq(weth.balanceOf(HOLDER), paid);
        assertApproxEqAbs(paid, amount / 2 * nav / 1e18, 1e6);
        vm.stopPrank();

        _buyFromPool(szr);
        _openAndBuyFromAuction(szr);
        assertEq(weth.balanceOf(address(core)), core.reserveCash());
    }

    /// The genesis pool trades on the real PoolManager before migration closes.
    function _buyFromPool(IERC20 szr) internal {
        PoolKey memory pool = locker.key(locker.INITIAL_POSITION());
        bool first = Currency.unwrap(pool.currency0) == address(weth);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(hook.poolManager())));
        PoolSwapTest.TestSettings memory settings;
        address buyer = address(0xB0B);
        deal(address(weth), buyer, 1e18);
        vm.startPrank(buyer);
        weth.approve(address(router), 1e18);
        router.swap(
            pool,
            IPoolManager.SwapParams(
                first,
                -int256(1e18),
                first ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        vm.stopPrank();
        assertGt(szr.balanceOf(buyer), 0);
        // The 1% swap fee is collected in WETH and split 67% reserves, 33% team.
        uint256 cash = core.reserveCash();
        locker.collect(locker.INITIAL_POSITION());
        uint256 team = core.economics().claimableFees();
        assertApproxEqRel(core.reserveCash() - cash + team, 0.01e18, 1e12);
        assertApproxEqRel(team, 0.0033e18, 1e12);
    }

    /// Closing migration opens the sale; a buyer pays at least 1.5x NAV in real WETH.
    function _openAndBuyFromAuction(IERC20 szr) internal {
        vm.prank(deployer);
        core.closeMigration();
        assertEq(core.auctionsOpenAt(), block.timestamp);
        vm.warp(block.timestamp + 3 days);
        (uint256 payment, uint256 reserves, uint256 funding) = core.quote(100_000e18);
        assertGe(payment * 2, core.backingRequired(100_000e18) * 3);
        address buyer = address(0xA11CE);
        deal(address(weth), buyer, payment);
        uint256 nav = core.NAV();
        uint256 cash = core.reserveCash();
        vm.startPrank(buyer);
        weth.approve(address(core), payment);
        core.buy(100_000e18, payment, block.timestamp);
        assertEq(szr.balanceOf(buyer), 100_000e18);
        assertEq(core.reserveCash(), cash + reserves);
        assertEq(locker.heldPrincipal(address(weth)), funding);
        assertGt(core.NAV(), nav);
        // Loans open once migration has closed.
        szr.approve(address(core), 50_000e18);
        core.borrow(50_000e18, core.backingRequired(25_000e18));
        vm.stopPrank();
    }
}
