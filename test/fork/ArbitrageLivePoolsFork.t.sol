// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { DeployArbitrageHook } from "../../script/DeployArbitrageHook.s.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../../src/arbitrage/ArbitrageLogic.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { ILegacySzrHook, ILegacySzrToken } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";

/// @notice The arbitrage hook against real, hookless ETH/USDG pools on Robinhood Chain: an
/// outside market counting in ETH lists three of them as leaders and closes gaps against
/// them. Skipped unless FORK_RPC_URL is set.
/// @dev The market counts in ETH alone. The leaders hold ETH, and a market that counted in
/// WETH could only read them through the twin rule, which needs ETH chosen as well. The
/// WETH/USDG pool is checked in `setUp` and left out for the same reason: it could only be
/// a leader of a WETH group. ETH profit is paid out as WETH.
contract ArbitrageLivePoolsForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant LEGACY = 0xbeD7c1660a01dbEEe225bd893ac31727a91A5773;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant TEAM = address(0x7EA);
    address internal constant TRADER = address(0x7AADE);
    address internal constant OWNER = address(0x7EA3);
    address internal constant TREASURY = address(0x7EA4);
    address internal constant DESK = address(0x7EA6);

    uint24 internal constant HOOK_FEE = 500;

    IPoolManager internal manager;
    IERC20 internal weth;
    SzrCore internal core;
    Liquidity internal locker;
    ArbitrageApi internal arbitrage;
    PoolSwapTest internal router;
    PoolModifyLiquidityTest internal provider;
    PoolKey[4] internal live;
    PoolKey internal hooked;
    uint256 internal id;
    bool internal forked;

    struct Result {
        uint256 profit;
        uint256 share;
        uint256 expected;
        uint256 payouts;
        uint256 cycles;
        uint256 failures;
        uint256 undone;
        bytes32[] traded;
    }

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 pinned = vm.envOr("FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, pinned);
        forked = true;
        ILegacySzrHook legacy = ILegacySzrHook(ILegacySzrToken(LEGACY).hook());
        weth = IERC20(legacy.weth());
        manager = IPoolManager(address(legacy.poolManager()));
        _launch();
        _checkLivePools();
        deal(TRADER, 1_000_000 ether);
        deal(USDG, TRADER, 1e15);
        vm.startPrank(TRADER);
        IERC20(USDG).approve(address(router), type(uint256).max);
        IERC20(USDG).approve(address(provider), type(uint256).max);
        vm.stopPrank();
    }

    function _launch() internal {
        DeploySzr.Config memory config;
        config.chainId = block.chainid;
        config.asset = address(weth);
        config.poolManager = address(manager);
        config.teamBeneficiary = address(0xBEEF);
        config.manager = TEAM;
        config.legacyToken = LEGACY;
        config.marketPrice = 507e9;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = 350_000_000e18;
        config.initialLiquidityTokens = 25_000_000e18;
        config.auction = SzrCore.AuctionConfig(1014e9, 1, 200_000e18);
        config.fundInitialLiquidity = true;
        (core,, locker) = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr")).run(config);
        arbitrage = DeployArbitrageHook(
                deployCode("DeployArbitrageHook.s.sol:DeployArbitrageHook")
            )
            .run(block.chainid, locker);
        router = new PoolSwapTest(manager);
        provider = new PoolModifyLiquidityTest(manager);
        vm.prank(TEAM);
        locker.acceptManager();
    }

    function _checkLivePools() internal {
        bytes32[4] memory ids = [
            bytes32(0x387bf619da4d3fb62bb276482693dba1b9b3520f573cabdfe033384a24125982),
            bytes32(0x24107d152f14a76d292123265ae3f3c71f863fc2f4ef7ba49d64e78d28ea379e),
            bytes32(0x54f7883914619af9105355bf83ed678bcf9f63560218ac61c9963b9503d0ba32),
            bytes32(0x84bd4e2d8be11aeb0afc1195b38f587b61e90068548f1063fdbe448fb8cad0b6)
        ];
        live[0] = _hookless(address(0), 500, 10);
        live[1] = _hookless(address(0), 100, 1);
        live[2] = _hookless(address(0), 460, 9);
        live[3] = _hookless(address(weth), 200, 4);
        for (uint256 index; index < 4; index++) {
            assertEq(PoolId.unwrap(live[index].toId()), ids[index], "pool id");
            assertGt(manager.getLiquidity(live[index].toId()), 0, "pool has liquidity");
        }
    }

    function _hookless(address first, uint24 fee, int24 spacing)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey(
            Currency.wrap(first), Currency.wrap(USDG), fee, spacing, IHooks(address(0))
        );
    }

    // ----- the world -----

    /// An outside market counting in ETH, with one pool of its own priced where pool A is
    /// and `listed` (indexes into the live pools, deepest first) as the leaders.
    function _open(uint256[] memory listed) internal {
        vm.prank(TEAM);
        arbitrage.setProfitToken(address(0), DESK);
        (uint160 price,,,) = manager.getSlot0(live[0].toId());
        hooked = PoolKey(
            Currency.wrap(address(0)),
            Currency.wrap(USDG),
            HOOK_FEE,
            10,
            IHooks(address(arbitrage))
        );
        address[] memory chosen = new address[](1);
        vm.startPrank(OWNER);
        id = arbitrage.openMarket(TREASURY);
        arbitrage.setTokens(id, chosen);
        arbitrage.createPool(id, hooked, price);
        bytes32[] memory leaders = new bytes32[](listed.length);
        for (uint256 index; index < listed.length; index++) {
            arbitrage.addVenue(id, live[listed[index]]);
            leaders[index] = PoolId.unwrap(live[listed[index]].toId());
        }
        arbitrage.setLeaders(id, address(0), USDG, leaders);
        arbitrage.setLimits(
            id, address(0), uint32(arbitrage.minimumGasLimit(id)), 1e9, 1.0001e18
        );
        vm.stopPrank();
        _provideDepth(price);
    }

    /// About $100k of each token across the full range, so that a 1% move is a real trade.
    function _provideDepth(uint160 price) internal {
        uint256 depth = uint256(1e11) * (1 << 96) / price;
        vm.prank(TRADER);
        provider.modifyLiquidity{ value: 1_000 ether }(
            hooked,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(10), TickMath.maxUsableTick(10), int256(depth), 0
            ),
            ""
        );
    }

    /// Moves a hookless pool to `hooked`'s price raised by `gap` (WAD). Nothing searches
    /// there, so the gap stays open for the next swap in the hook's pool. The square root of
    /// the ratio is taken as half of it, which is exact enough for a gap of 1% or less.
    function _open_gap(PoolKey memory leader, uint256 gap) internal {
        (uint160 base,,,) = manager.getSlot0(hooked.toId());
        uint160 target = uint160(uint256(base) * (2e18 + gap) / 2e18);
        (uint160 now_,,,) = manager.getSlot0(leader.toId());
        bool zeroForOne = now_ > target;
        PoolSwapTest.TestSettings memory settings;
        vm.prank(TRADER);
        router.swap{ value: 100_000 ether }(
            leader, IPoolManager.SwapParams(zeroForOne, -int256(1e30), target), settings, ""
        );
    }

    function _swap(PoolKey memory pool, bool zeroForOne, uint256 amount, uint256 gas)
        internal
        returns (bool ok)
    {
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.prank(TRADER);
        (ok,) = address(router).call{ gas: gas, value: zeroForOne ? amount : 0 }(
            abi.encodeCall(router.swap, (pool, params, settings, ""))
        );
    }

    function _scan() internal view returns (Result memory out) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        out.traded = new bytes32[](logs.length);
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(arbitrage)) continue;
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.Arbitraged.selector) {
                out.traded[out.cycles++] = logs[index].topics[2];
            } else if (topic == ArbitrageLogic.ProfitPaid.selector) {
                (uint256 amount, uint256 share) =
                    abi.decode(logs[index].data, (uint256, uint256));
                out.profit += amount;
                out.share += share;
                out.expected += (amount * 30 + 99) / 100;
                out.payouts++;
            } else if (topic == ArbitrageLogic.CycleFailed.selector) {
                out.failures++;
            } else if (topic == ArbitrageLogic.SearchUndone.selector) {
                out.undone++;
            }
        }
    }

    function _name(bytes32 poolId) internal view returns (string memory) {
        if (poolId == PoolId.unwrap(live[0].toId())) return "A (0.05%)";
        if (poolId == PoolId.unwrap(live[1].toId())) return "B (0.01%)";
        if (poolId == PoolId.unwrap(live[2].toId())) return "C (0.046%)";
        return "other";
    }

    function _assertClean() internal view {
        assertEq(weth.balanceOf(address(arbitrage)), 0, "hook weth");
        assertEq(IERC20(USDG).balanceOf(address(arbitrage)), 0, "hook usdg");
        assertEq(address(arbitrage).balance, 0, "hook ether");
        assertEq(manager.balanceOf(address(arbitrage), 0), 0, "hook claims on ETH");
        assertEq(manager.balanceOf(address(arbitrage), uint160(USDG)), 0, "hook claims on USDG");
    }

    /// How far apart two pools' prices are, as a fraction of price in WAD.
    function _apart(PoolKey memory one, PoolKey memory other) internal view returns (uint256) {
        (uint160 first,,,) = manager.getSlot0(one.toId());
        (uint160 second,,,) = manager.getSlot0(other.toId());
        uint256 ratio = FullMath.mulDiv(first, 1e18, second);
        ratio = ratio * ratio / 1e18;
        return ratio > 1e18 ? ratio - 1e18 : 1e18 - ratio;
    }

    function _all() internal pure returns (uint256[] memory list) {
        list = new uint256[](3);
        list[1] = 1;
        list[2] = 2;
    }

    function _only(uint256 pool) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = pool;
    }

    /// Opens the gap in every leader, then makes one small swap in the hook's pool.
    function _run(uint256[] memory listed, uint256 gap) internal returns (Result memory out) {
        _open(listed);
        for (uint256 index; index < listed.length; index++) {
            _open_gap(live[listed[index]], gap);
        }
        vm.recordLogs();
        assertTrue(_swap(hooked, true, 1e16, 30_000_000), "swap");
        out = _scan();
    }

    // ----- tests -----

    function testClosesAGapAgainstLiveLeaders() public {
        if (!forked) return vm.skip(true);
        console2.log("block", block.number);
        _open(_all());
        for (uint256 index; index < 3; index++) {
            _open_gap(live[index], 0.01e18);
        }
        uint256 desk = weth.balanceOf(DESK);
        uint256 treasury = weth.balanceOf(TREASURY);
        vm.recordLogs();
        uint256 start = gasleft();
        assertTrue(_swap(hooked, true, 1e16, 30_000_000), "swap");
        uint256 used = start - gasleft();
        Result memory out = _scan();
        assertGt(out.profit, 0, "ProfitPaid with a profit");
        assertEq(out.failures + out.undone, 0, "nothing failed or undone");
        assertEq(out.share, out.expected, "protocol share, 30% rounded up");
        assertEq(weth.balanceOf(DESK) - desk, out.share, "protocol paid");
        assertEq(weth.balanceOf(TREASURY) - treasury, out.profit - out.share, "market paid");
        console2.log("payouts", out.payouts);
        console2.log("profit (wei of ETH)", out.profit);
        console2.log("gas of the swap", used);
        for (uint256 index; index < out.cycles; index++) {
            console2.log("cycle against", _name(out.traded[index]));
            PoolKey memory venue = _keyOf(out.traded[index]);
            uint256 allowed = (uint256(HOOK_FEE) + venue.fee) * 1e12 + 2e14;
            assertLe(_apart(hooked, venue), allowed, "within the combined fees");
        }
        assertGt(out.cycles, 0, "a cycle ran");
        _assertClean();
    }

    function _keyOf(bytes32 poolId) internal view returns (PoolKey memory) {
        for (uint256 index; index < 3; index++) {
            if (PoolId.unwrap(live[index].toId()) == poolId) return live[index];
        }
        revert("not a leader");
    }

    function testEachLeaderAlone() public {
        if (!forked) return vm.skip(true);
        uint256 snap = vm.snapshotState();
        for (uint256 pool; pool < 3; pool++) {
            Result memory out = _run(_only(pool), 0.01e18);
            console2.log("only leader", _name(PoolId.unwrap(live[pool].toId())));
            console2.log("profit (wei of ETH)", out.profit);
            assertGt(out.profit, 0, "profit");
            assertGt(out.cycles, 0, "a cycle ran");
            _assertClean();
            vm.revertToState(snap);
            snap = vm.snapshotState();
        }
    }

    /// The hook's pool charges 0.05%. Against B (0.01%) a gap of 0.09% clears both fees and
    /// the 0.01% edge (0.07%); against A (0.05%) it does not (0.11%).
    function testSmallGapNeedsTheLowFeePool() public {
        if (!forked) return vm.skip(true);
        uint256 snap = vm.snapshotState();
        uint256[] memory both = new uint256[](2);
        both[1] = 1;
        Result memory withB = _run(both, 0.0009e18);
        console2.log("profit with B a leader (wei of ETH)", withB.profit);
        assertGt(withB.profit, 0, "closed with B");
        assertGt(withB.cycles, 0, "traded");
        for (uint256 index; index < withB.cycles; index++) {
            assertEq(withB.traded[index], PoolId.unwrap(live[1].toId()), "against B");
        }
        vm.revertToState(snap);
        Result memory onlyA = _run(_only(0), 0.0009e18);
        assertEq(onlyA.cycles, 0, "nothing traded with only A");
        assertEq(onlyA.profit, 0, "no profit with only A");
    }

    function testGasForSwapIsEnough() public {
        if (!forked) return vm.skip(true);
        _open(_all());
        for (uint256 index; index < 3; index++) {
            _open_gap(live[index], 0.01e18);
        }
        uint256 minimum = arbitrage.minimumGasLimit(id);
        uint256 stated = arbitrage.gasForSwap(id);
        console2.log("minimumGasLimit", minimum);
        console2.log("gasForSwap", stated);
        vm.cool(address(manager));
        vm.cool(address(arbitrage));
        vm.cool(USDG);
        vm.cool(address(weth));
        vm.recordLogs();
        // The router and the pool manager use some of this before the hook is called.
        assertTrue(_swap(hooked, true, 1e16, stated + 150_000), "swap given the stated gas");
        Result memory out = _scan();
        assertEq(out.undone, 0, "search not undone");
        assertGt(out.cycles, 0, "gap closed");
    }
}
