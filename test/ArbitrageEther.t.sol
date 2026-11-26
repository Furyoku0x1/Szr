// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { DrainRouter } from "./utils/ArbitrageDrain.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { V4Read } from "../src/arbitrage/lib/V4Read.sol";

/// @dev Pools on the other ether token are venues too: a TEAM/ETH pool and a TEAM/WETH pool
/// are compared with each other when a market chooses both ETH and WETH. TEAM's address is
/// below WETH's, so WETH/TEAM has TEAM first and ETH/TEAM has ETH first: the two pools'
/// prices run in opposite directions in storage, which a mix-up of the pair would show.
abstract contract EtherWorld is WrapWorld {
    TestAsset internal team0;

    struct Seen {
        uint256 bought;
        uint256 sold;
        uint256 wraps;
        uint256 unwraps;
        uint256 payouts;
        uint256 failed;
        uint256 undone;
    }

    function setUp() public virtual override {
        super.setUp();
        team0 = new TestAsset();
        while (address(team0) > address(backing)) team0 = new TestAsset();
        _approve(team0);
    }

    // ----- helpers -----

    /// The market counts in ETH and WETH, and the world's own WETH/coin group is emptied so
    /// that only the pools a test makes are venues.
    function _etherMarket(bool withWeth) internal {
        address[] memory tokens = new address[](withWeth ? 2 : 1);
        tokens[0] = address(0);
        if (withWeth) tokens[1] = address(backing);
        vm.prank(team);
        hook.setTokens(id, tokens);
        _lead(address(backing), address(coin), new bytes32[](0));
    }

    /// Focus TEAM/`one`, venue TEAM/`other`, each the only leader of its group; the focus
    /// pool is on the hook and the venue is not.
    function _pairUp(address one, address other)
        internal
        returns (PoolKey memory hooked, PoolKey memory venue)
    {
        _etherMarket(true);
        hooked = _make(one, address(team0), 3_000, address(hook));
        venue = _make(other, address(team0), 500, address(0));
        _venue(venue);
        _lead(one, address(team0), _list(_id(hooked)));
        _lead(other, address(team0), _list(_id(venue)));
        _limits(one, 1e15);
        _limits(other, 1e15);
    }

    function _scan() internal returns (Seen memory seen) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.CycleFailed.selector) seen.failed++;
            if (topic == ArbitrageLogic.ProfitPaid.selector) {
                if (logs[index].topics[2] == bytes32(0)) seen.payouts++;
            }
            if (topic == ArbitrageLogic.SearchUndone.selector) seen.undone++;
            if (topic == ArbitrageLogic.Arbitraged.selector) {
                (bool buying,) = abi.decode(logs[index].data, (bool, uint256));
                if (buying) seen.bought++;
                else seen.sold++;
            }
            if (logs[index].emitter != address(backing)) continue;
            if (topic != TRANSFER) continue;
            if (logs[index].topics[1] == bytes32(0)) seen.wraps++;
            if (logs[index].topics[2] == bytes32(0)) seen.unwraps++;
        }
        // Paying out ETH profit wraps it too; that is no cycle's conversion.
        seen.wraps -= seen.payouts;
    }

    /// A swap in the venue opens a gap; the next swap in the hooked pool closes it.
    function _close(PoolKey memory hooked, PoolKey memory venue, address venueInput)
        internal
        returns (Seen memory seen)
    {
        _in(venue, venueInput, 50_000e18);
        vm.recordLogs();
        _in(hooked, address(team0), 1e18);
        seen = _scan();
    }

    function _assertCleanCycle(Seen memory seen) internal pure {
        assertEq(seen.failed, 0, "no cycle failed");
        assertEq(seen.undone, 0, "no search undone");
    }
}

contract ArbitrageEtherTest is EtherWorld {
    // ----- a pool on the other ether token is a venue -----

    /// TEAM/ETH on the hook against TEAM/WETH: profit is counted in ETH and paid as WETH,
    /// 30% (rounded up) to ETH's protocol recipient.
    function _ethAgainstWeth(address venueInput, bool buy) internal {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(0), address(backing));
        uint256 desk = backing.balanceOf(ethDesk);
        Seen memory seen = _close(hooked, venue, venueInput);
        _assertCleanCycle(seen);
        if (buy) {
            assertGt(seen.bought, 0, "bought ETH in the hooked pool");
            assertEq(seen.sold, 0, "one direction");
            assertGt(seen.wraps, 0, "ETH became the WETH the venue wants");
            assertEq(seen.unwraps, 0, "no unwrap");
        } else {
            assertGt(seen.sold, 0, "sold ETH in the hooked pool");
            assertEq(seen.bought, 0, "one direction");
            assertGt(seen.unwraps, 0, "the WETH the venue paid became ETH");
            assertEq(seen.wraps, 0, "no wrap");
        }
        uint256 share = backing.balanceOf(ethDesk) - desk;
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "the market was paid in WETH");
        _assertThirty(share, share + kept);
        _assertClean();
    }

    function testEthPoolClosesGapAgainstWethPoolBuying() public {
        _ethAgainstWeth(address(team0), true);
    }

    function testEthPoolClosesGapAgainstWethPoolSelling() public {
        _ethAgainstWeth(address(backing), false);
    }

    /// The mirror: the hooked pool holds WETH, the venue ETH. Profit is WETH, and the
    /// protocol's share goes to WETH's recipient (Core) by `take`.
    function _wethAgainstEth(address venueInput, bool buy) internal {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(backing), address(0));
        uint256 vault = backing.balanceOf(address(core));
        Seen memory seen = _close(hooked, venue, venueInput);
        _assertCleanCycle(seen);
        if (buy) {
            assertGt(seen.bought, 0, "bought WETH in the hooked pool");
            assertEq(seen.sold, 0, "one direction");
            assertGt(seen.unwraps, 0, "WETH became the ETH the venue wants");
            assertEq(seen.wraps, 0, "no wrap");
        } else {
            assertGt(seen.sold, 0, "sold WETH in the hooked pool");
            assertEq(seen.bought, 0, "one direction");
            assertGt(seen.wraps, 0, "the ETH the venue paid became WETH");
            assertEq(seen.unwraps, 0, "no unwrap");
        }
        uint256 share = backing.balanceOf(address(core)) - vault;
        uint256 kept = backing.balanceOf(treasury);
        assertGt(kept, 0, "the market was paid in WETH");
        _assertThirty(share, share + kept);
        _assertClean();
    }

    function testWethPoolClosesGapAgainstEthPoolBuying() public {
        _wethAgainstEth(address(team0), true);
    }

    function testWethPoolClosesGapAgainstEthPoolSelling() public {
        _wethAgainstEth(address(0), false);
    }

    /// The venue is the head of another group under the twin: X/WETH, reached from TEAM/ETH
    /// through the connecting pool X/TEAM.
    function _otherGroup(address venueInput) internal {
        _etherMarket(true);
        PoolKey memory hooked = _make(address(0), address(team0), 3_000, address(hook));
        PoolKey memory head = _make(address(backing), address(usd), 500, address(0));
        PoolKey memory cross = _make(address(usd), address(team0), 500, address(0));
        _venue(head);
        vm.prank(team);
        hook.setConnector(id, cross, true);
        _lead(address(0), address(team0), _list(_id(hooked)));
        _lead(address(backing), address(usd), _list(_id(head)));
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
        Seen memory seen = _close(hooked, head, venueInput);
        _assertCleanCycle(seen);
        assertGt(seen.bought + seen.sold, 0, "gap closed through the pool and the twin");
        assertGt(seen.wraps + seen.unwraps, 0, "converted");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    function testVenueInAnotherGroupUnderTheTwinSelling() public {
        _otherGroup(address(backing));
    }

    function testVenueInAnotherGroupUnderTheTwinBuying() public {
        _otherGroup(address(usd));
    }

    // ----- sweep -----

    /// Two hookless pools on different ether tokens: `sweep` centres on the head of each
    /// group of the token it is given, and the twin's pool is a venue.
    function _sweepGap(address base) internal {
        _etherMarket(true);
        PoolKey memory eth = _make(address(0), address(team0), 3_000, address(0));
        PoolKey memory weth = _make(address(backing), address(team0), 500, address(0));
        _venue(eth);
        _venue(weth);
        _lead(address(0), address(team0), _list(_id(eth)));
        _lead(address(backing), address(team0), _list(_id(weth)));
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
        _in(weth, address(team0), 50_000e18);
        vm.recordLogs();
        uint256 profit = hook.sweep(id, base);
        Seen memory seen = _scan();
        assertGt(profit, 0, "the gap between ETH and WETH pools was closed");
        _assertCleanCycle(seen);
        assertGt(seen.wraps + seen.unwraps, 0, "converted");
        _assertClean();
    }

    function testSweepOfEthClosesGapBetweenEthAndWethPools() public {
        _sweepGap(address(0));
    }

    function testSweepOfWethClosesGapBetweenEthAndWethPools() public {
        _sweepGap(address(backing));
    }

    // ----- remembered venues and re-centring -----

    /// A swap that itself opens the gap: the search before it finds nothing and remembers
    /// its venues, the twin's pool among them; the search after it closes the gap with them.
    function _afterSwap(address input) internal {
        (PoolKey memory hooked,) = _pairUp(address(0), address(backing));
        vm.recordLogs();
        _in(hooked, input, 50_000e18);
        Seen memory seen = _scan();
        _assertCleanCycle(seen);
        assertGt(seen.bought + seen.sold, 0, "the search after the swap closed the gap");
        assertGt(seen.wraps + seen.unwraps, 0, "against the twin's pool");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }

    function testSearchAfterSwapUsesRememberedTwinVenueTeamIn() public {
        _afterSwap(address(team0));
    }

    function testSearchAfterSwapUsesRememberedTwinVenueEthIn() public {
        _afterSwap(address(0));
    }

    /// The search does not look next from the pool it just traded when that pool holds the
    /// twin. Looked at from there with this search's token, its price would run the wrong
    /// way and invent a gap whose cycle fails.
    function testSearchDoesNotRecentreOnATwinVenue() public {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(0), address(backing));
        _in(venue, address(team0), 50_000e18);
        vm.recordLogs();
        _in(hooked, address(team0), 1e18);
        Seen memory seen = _scan();
        assertGt(seen.bought, 0, "the gap was closed");
        _assertCleanCycle(seen);
        _assertClean();
    }

    // ----- the allowance -----

    /// Leaders named under the twin raise the allowance a market needs, even when only the
    /// other token is chosen: a search counting in ETH reads the WETH groups anyway.
    function testMinimumGasLimitCountsTheTwinsGroups() public {
        _etherMarket(true);
        uint256 empty = hook.minimumGasLimit(id);
        PoolKey memory one = _make(address(backing), address(team0), 500, address(0));
        PoolKey memory two = _make(address(backing), address(team0), 100, address(0));
        PoolKey memory three = _make(address(backing), address(team0), 10_000, address(0));
        _venue(one);
        _venue(two);
        _venue(three);
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(one);
        list[1] = _id(two);
        list[2] = _id(three);
        _lead(address(backing), address(team0), list);
        uint256 withTwin = hook.minimumGasLimit(id);
        assertGt(withTwin, empty, "leaders under WETH raise it");
        // WETH no longer chosen: its groups are still read by searches counting in ETH.
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(team);
        hook.setTokens(id, tokens);
        assertEq(hook.minimumGasLimit(id), withTwin, "and still count");
    }

    /// ETH has the larger group, so one leader under WETH adds nothing on WETH's own side:
    /// only the two sides summed need more than the allowance, which is exactly enough.
    function testLeadersUnderTheTwinNeedTheAllowance() public {
        _etherMarket(true);
        bytes32[] memory big = new bytes32[](3);
        for (uint256 index; index < 3; index++) {
            PoolKey memory pool =
                _make(address(0), address(team0), uint24(500 + index * 100), address(0));
            _venue(pool);
            big[index] = _id(pool);
        }
        _lead(address(0), address(team0), big);
        _limits(address(0), 1e15);
        assertEq(hook.market(id).gasLimit, hook.minimumGasLimit(id), "exact");
        PoolKey memory venue = _make(address(backing), address(team0), 2_000, address(0));
        _venue(venue);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLeaders(id, address(backing), address(team0), _list(_id(venue)));
        // With the allowance raised to what it now needs, the same call works.
        vm.startPrank(team);
        hook.setLimits(id, address(0), 0, 1e15, 1.0001e18);
        hook.setLeaders(id, address(backing), address(team0), _list(_id(venue)));
        vm.stopPrank();
        _limits(address(0), 1e15);
        assertEq(hook.market(id).gasLimit, hook.minimumGasLimit(id), "and it is workable");
    }

    // ----- unchanged behaviour -----

    /// A market that chose only ETH reads no pool of the twin's, and nothing converts.
    function testMarketChoosingOnlyEthBehavesAsBefore() public {
        _etherMarket(false);
        PoolKey memory hooked = _make(address(0), address(team0), 3_000, address(hook));
        PoolKey memory venue = _make(address(0), address(team0), 500, address(0));
        _venue(venue);
        _lead(address(0), address(team0), _list(_id(hooked), _id(venue)));
        _limits(address(0), 1e15);
        Seen memory seen = _close(hooked, venue, address(team0));
        _assertCleanCycle(seen);
        assertGt(seen.bought + seen.sold, 0, "gap closed");
        assertEq(seen.wraps + seen.unwraps, 0, "nothing converted");
        assertGt(backing.balanceOf(ethDesk), 0, "protocol paid in WETH");
        _assertClean();
    }

    /// A market counting in USD is allowed what it was (exactly). What a swap costs is
    /// logged: the ether check adds a few hundred gas per search and cycle.
    function testUsdMarketAllowanceIsUnchanged() public {
        PoolKey memory hooked = _make(address(usd), address(coin), 3_000, address(hook));
        PoolKey memory venue = _make(address(usd), address(coin), 500, address(0));
        _venue(venue);
        _lead(address(usd), address(coin), _list(_id(hooked), _id(venue)));
        _limits(address(usd), 1e15);
        assertEq(hook.minimumGasLimit(id), 6_660_000, "allowance");
        assertEq(
            hook.gasForSwap(id),
            7_080_242,
            "gas for a swap, with the base and the one centre it lists"
        );
        emit log_named_uint("usd market gasForSwap", hook.gasForSwap(id));
        _in(hooked, address(usd), 1e18);
        _in(hooked, address(usd), 1e15);
        uint256 spent = gasleft();
        _in(hooked, address(usd), 1e15);
        spent -= gasleft();
        emit log_named_uint("usd market no-gap swap gas", spent);
        _in(venue, address(coin), 50_000e18);
        spent = gasleft();
        _in(hooked, address(usd), 1e18);
        spent -= gasleft();
        emit log_named_uint("usd market gap-closing swap gas", spent);
    }

    // ----- gas -----

    function _swapGas(PoolKey memory pool) internal returns (uint256 used) {
        used = gasleft();
        _in(pool, address(team0), 1e15);
        used -= gasleft();
    }

    /// A swap with no gap beside one that closes a gap against a twin venue, each way.
    function testGasOfACycleAgainstATwinVenue() public {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(0), address(backing));
        _in(hooked, address(team0), 1e15);
        uint256 quiet = _swapGas(hooked);
        _in(venue, address(team0), 50_000e18);
        uint256 buying = _swapGas(hooked);
        _in(venue, address(backing), 100_000e18);
        uint256 selling = _swapGas(hooked);
        emit log_named_uint("ETH+WETH market, swap with no gap, gas", quiet);
        emit log_named_uint("swap closing a gap, buying ETH (wrap), gas", buying);
        emit log_named_uint("swap closing a gap, selling ETH (unwrap), gas", selling);
        uint256 attempt = hook.PLAN_GAS() / 2;
        assertLt(buying - quiet, attempt, "buy cycle fits one try");
        assertLt(selling - quiet, attempt, "sell cycle fits one try");
    }
}

/// @dev A twin-venue cycle takes the twin out of the pool manager and puts the other form
/// back; whoever controls the unlock can borrow that balance, and the swap then fails.
contract ArbitrageEtherDrainTest is EtherWorld {
    uint256 internal constant NONE = type(uint256).max;

    DrainRouter internal drain;

    function setUp() public override {
        super.setUp();
        drain = new DrainRouter(manager);
        vm.deal(address(drain), 1_000e18);
        team0.approve(address(drain), type(uint256).max);
        backing.approve(address(drain), type(uint256).max);
    }

    function _try(PoolKey memory pool, address drained, uint256 leave)
        internal
        returns (bool ok, bytes memory data)
    {
        (ok, data) = address(drain)
            .call(abi.encodeCall(drain.trade, (pool, address(team0), 1e18, drained, leave)));
    }

    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 word;
            assembly ("memory-safe") {
                word := mload(add(add(data, 32), index))
            }
            if (word == wanted) return true;
        }
        return false;
    }

    /// Before the swap the gap is already open, so the search meets the shortage and the
    /// swap fails; the control borrows nothing and the swap fills.
    function _drained(address venueInput, address drained) internal {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(0), address(backing));
        _in(venue, venueInput, 50_000e18);
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = _try(hooked, drained, 0);
        assertFalse(ok, "the swap fails");
        assertTrue(_has(data, V4Read.Drained.selector), "with Drained");
        vm.revertToState(snapshot);
        (ok,) = _try(hooked, drained, NONE);
        assertTrue(ok, "the control fills");
        assertGt(backing.balanceOf(treasury), 0, "and closes the gap");
    }

    /// Buying ETH: the venue is paid WETH, which the hook gets by taking ETH.
    function testBuyCycleAgainstTwinVenueFailsWhenEthIsBorrowed() public {
        _drained(address(team0), address(0));
    }

    /// Selling ETH: the venue pays WETH, which the hook takes out to unwrap.
    function testSellCycleAgainstTwinVenueFailsWhenWethIsBorrowed() public {
        _drained(address(backing), address(backing));
    }

    /// Selling ETH while all of the pool manager's ETH is borrowed: the cycle never takes
    /// ETH for the venue. It unwraps the WETH the venue paid and settles that ETH, so the
    /// profit has ETH to be taken from and the gap closes. The drain is absorbed, not a gap
    /// skipped.
    function testSellCycleAgainstTwinVenueClosesTheGapWhenEthIsBorrowed() public {
        (PoolKey memory hooked, PoolKey memory venue) = _pairUp(address(0), address(backing));
        _in(venue, address(backing), 50_000e18);
        uint256 desk = backing.balanceOf(ethDesk);
        vm.recordLogs();
        (bool ok,) = _try(hooked, address(0), 0);
        assertTrue(ok, "the swap fills");
        Seen memory seen = _scan();
        assertEq(seen.sold, 1, "one cycle, selling ETH");
        assertEq(seen.bought, 0, "and no other");
        assertGt(seen.unwraps, 0, "by unwrapping the WETH the venue paid");
        _assertCleanCycle(seen);
        assertGt(backing.balanceOf(ethDesk), desk, "protocol paid");
        assertGt(backing.balanceOf(treasury), 0, "market paid");
        vm.recordLogs();
        _in(hooked, address(team0), 1e15);
        seen = _scan();
        assertEq(seen.bought + seen.sold, 0, "the next swap finds no cycle");
        _assertClean();
    }
}

/// @dev A buy cycle against a twin venue converts exactly what the venue was paid, out of
/// the ETH the hooked pool just paid out. A first try sized too large can need more than that,
/// and it must fail as a cycle, not as a shortage at the pool manager.
contract ArbitrageEtherGuardTest is EtherWorld {
    function _liquidity(
        PoolKey memory pool,
        int24 lower,
        int24 upper,
        uint256 units,
        uint256 eth
    ) internal {
        provider.modifyLiquidity{ value: eth }(
            pool, IPoolManager.ModifyLiquidityParams(lower, upper, int256(units), 0), ""
        );
    }

    /// The hooked TEAM/ETH pool holds ETH only between two prices, so the pool manager holds
    /// about 29.55 ETH. The TEAM/WETH venue is cheap in TEAM by about 18%, with a deep band
    /// of one tick spacing at its current price and little liquidity beyond it: the size
    /// estimate reads the deep band, but a cycle that large leaves it.
    function _thin() internal returns (PoolKey memory hooked) {
        _etherMarket(true);
        hooked = _pair(address(0), address(team0), 3_000, address(hook));
        vm.prank(team);
        hook.createPool(id, hooked, uint160(1 << 96));
        _liquidity(hooked, -600, 600, 1_000e18, 40e18);
        PoolKey memory venue = _pair(address(backing), address(team0), 500, address(0));
        manager.initialize(venue, TickMath.getSqrtPriceAtTick(-2_000));
        _liquidity(venue, TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 5e19, 0);
        _liquidity(venue, -2_040, -1_980, 1e22, 0);
        _venue(venue);
        _lead(address(0), address(team0), _list(_id(hooked)));
        _lead(address(backing), address(team0), _list(_id(venue)));
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
    }

    /// Without the check in `_outOfHome` the first try converts more ETH than the pool
    /// manager holds and the swap reverts `Drained`; with it that try fails as unprofitable
    /// and a smaller one closes the gap.
    function testOversizedFirstTryFailsAsACycleNotAsADrain() public {
        PoolKey memory hooked = _thin();
        assertLt(address(manager).balance, 30e18, "little ETH in the pool manager");
        vm.recordLogs();
        _in(hooked, address(team0), 1e15);
        Seen memory seen = _scan();
        assertGt(seen.bought, 0, "the gap was closed at a smaller size");
        _assertCleanCycle(seen);
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertClean();
    }
}
