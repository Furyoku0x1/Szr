// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { SzrTreasury } from "../../src/SzrTreasury.sol";
import { IndexPool } from "../../src/index/IndexPool.sol";
import { IndexPoolFactory } from "../../src/index/IndexPoolFactory.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The treasury against the live Core, Liquidity, pool manager and Metric WETH/USDG pool
/// of Robinhood Chain. An index pool of live stock tokens is created with the treasury as its
/// protocol, so its cut travels the whole way: index pool, Metric, Core. Runs only with a
/// `FORK_RPC_URL`, at the latest block, and spends nothing real:
///     FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///         forge test --match-path test/fork/SzrTreasuryFork.t.sol -vv
contract SzrTreasuryForkTest is Test {
    using StateLibrary for *;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant FAR = type(uint256).max;
    Liquidity internal constant LIQUIDITY =
        Liquidity(0x8c1261C469E83E93aa19Af8f07FD939078Dd1344);
    address internal constant METRIC = 0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386;
    address internal constant METRIC_FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    bool internal live;
    SzrCore internal core;
    SzrTreasury internal treasury;
    address internal manager;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        core = SzrCore(LIQUIDITY.core());
        manager = LIQUIDITY.manager();
        treasury =
            new SzrTreasury(core, LIQUIDITY.poolManager(), IMetricFactory(METRIC_FACTORY));
    }

    function _hops(SzrTreasury.Hop memory one)
        internal
        pure
        returns (SzrTreasury.Hop[] memory r)
    {
        r = new SzrTreasury.Hop[](1);
        r[0] = one;
    }

    function _hop(SzrTreasury.Venue venue, address pool, address out)
        internal
        pure
        returns (SzrTreasury.Hop memory)
    {
        PoolKey memory none;
        return SzrTreasury.Hop(venue, none, pool, out);
    }

    /// An index pool of NVDA and USDG whose protocol is the treasury, busy enough to owe a cut.
    function _indexPool() internal returns (IndexPool pool) {
        IndexPoolFactory factory = treasury.indexFactory();
        address[] memory list = new address[](2);
        list[0] = USDG;
        list[1] = NVDA;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        pool = IndexPool(factory.create("Index", "IDX", list, weights, 3e15, address(0), 0));
        deal(USDG, address(this), 1_000_000e6);
        deal(NVDA, address(this), 10_000e18);
        IERC20(USDG).approve(address(pool), FAR);
        IERC20(NVDA).approve(address(pool), FAR);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300_000e6;
        amounts[1] = 1_000e18;
        pool.start(amounts, 1e24, FAR);
        for (uint256 index; index < 3; index++) {
            pool.swap(USDG, NVDA, 5_000e6, true, 0, address(this), FAR);
            pool.swap(NVDA, USDG, 10e18, true, 0, address(this), FAR);
        }
    }

    function testTheIndexPoolsCutBecomesBackingOnTheLiveChain() public {
        if (!live) return vm.skip(true);
        if (core.activeSupply() == 0) return vm.skip(true);
        IndexPool pool = _indexPool();
        assertEq(pool.protocol(), address(treasury));
        uint256 cutUsdg = pool.payProtocol(USDG);
        uint256 cutNvda = pool.payProtocol(NVDA);
        assertGt(cutUsdg, 0);
        assertGt(cutNvda, 0);
        uint256 cash = core.reserveCash();
        address team = core.economics().beneficiary();
        uint256 teamBefore = IERC20(WETH).balanceOf(team);
        vm.startPrank(manager);
        // USDG to WETH on the live Metric pool.
        (uint256 backed, uint256 fee) = treasury.back(
            USDG, cutUsdg, _hops(_hop(SzrTreasury.Venue.METRIC, METRIC, WETH)), 1, FAR
        );
        // NVDA to USDG in the index pool, then USDG to WETH on Metric.
        SzrTreasury.Hop[] memory route = new SzrTreasury.Hop[](2);
        route[0] = _hop(SzrTreasury.Venue.INDEX, address(pool), USDG);
        route[1] = _hop(SzrTreasury.Venue.METRIC, METRIC, WETH);
        (uint256 more, uint256 moreFee) = treasury.back(NVDA, cutNvda, route, 1, FAR);
        vm.stopPrank();
        console2.log("backed, team fee (wei of WETH)", backed + more, fee + moreFee);
        assertGt(backed + more, 0);
        assertEq(core.reserveCash(), cash + backed + more, "backing raised");
        assertEq(IERC20(WETH).balanceOf(team), teamBefore + fee + moreFee, "team paid");
        assertEq(IERC20(WETH).balanceOf(address(treasury)), 0);
        assertEq(IERC20(USDG).balanceOf(address(treasury)), 0);
        assertEq(IERC20(NVDA).allowance(address(treasury), address(pool)), 0);
        assertEq(address(treasury).balance, 0);
    }

    /// Needs the SZR pool to exist at the fork block.
    function testRetireThroughTheLiveSzrPool() public {
        if (!live) return vm.skip(true);
        if (core.activeSupply() == 0) return vm.skip(true);
        PoolKey memory key;
        try LIQUIDITY.key(0) returns (PoolKey memory found) {
            key = found;
        } catch {
            return vm.skip(true);
        }
        (uint160 price,,,) = LIQUIDITY.poolManager().getSlot0(key.toId());
        if (price == 0) return vm.skip(true);
        address szr = address(core.token());
        address partner = Currency.unwrap(key.currency0) == szr
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);
        if (partner != WETH) return vm.skip(true);
        deal(WETH, address(treasury), 1e18);
        uint256 inventory = core.unreleasedSupply();
        SzrTreasury.Hop[] memory route = new SzrTreasury.Hop[](1);
        route[0] = SzrTreasury.Hop(SzrTreasury.Venue.V4, key, address(0), szr);
        vm.prank(manager);
        uint256 retired = treasury.retire(WETH, 1e18, route, 1, FAR);
        console2.log("SZR retired for 1 WETH", retired);
        assertGe(core.unreleasedSupply(), inventory + retired, "returned to the sale");
        assertEq(IERC20(szr).balanceOf(address(treasury)), 0);
    }
}
