// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { OpenArbitrageMarket } from "../script/OpenArbitrageMarket.s.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Anyone can open a market inside the hook. It is searched on its own, and its profit
/// is counted in a token from the protocol's list: 30% to the protocol, the rest to the
/// market, in that token.
abstract contract MarketsWorld is ArbitrageWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal team = address(0x7EA3);
    address internal treasury = address(0x7EA4);
    /// Where the protocol's share of profit counted in USD is sent.
    address internal desk = address(0x7EA5);
    TestAsset internal coin;
    uint256 internal id;
    PoolKey internal first;
    PoolKey internal second;
    /// The world's hookless WETH/USD pool, which SZR's market uses as a connecting pool.
    PoolKey internal publicPool;

    function setUp() public virtual override {
        super.setUp();
        coin = _newAsset();
        _approve(coin);
        hook.setProfitToken(address(usd), desk);
        publicPool = _pair(address(backing), address(usd), 3_000, address(0));
        vm.startPrank(team);
        id = hook.openMarket(treasury);
        address[] memory chosen = new address[](2);
        chosen[0] = address(backing);
        chosen[1] = address(usd);
        hook.setTokens(id, chosen);
        // A market with two tokens needs a minimum for each before it is switched on.
        hook.setMinimumProfit(id, address(usd), 1e15);
        hook.setMinimumProfit(id, address(0), 1e15);
        vm.stopPrank();
        first = _create(address(backing), address(coin), 3_000);
        second = _create(address(backing), address(coin), 500);
        _lead(address(backing), address(coin), _list(_id(first), _id(second)));
        _limits(address(backing), 1e15);
    }

    function _pair(address one, address other, uint24 fee, address hooks)
        internal
        pure
        returns (PoolKey memory)
    {
        bool oneFirst = one < other;
        return PoolKey(
            Currency.wrap(oneFirst ? one : other),
            Currency.wrap(oneFirst ? other : one),
            fee,
            60,
            IHooks(hooks)
        );
    }

    function _create(address one, address other, uint24 fee)
        internal
        returns (PoolKey memory pool)
    {
        pool = _pair(one, other, fee, address(hook));
        vm.prank(team);
        hook.createPool(id, pool, uint160(1 << 96));
        _provide(pool, 1_000_000e18);
    }

    function _list(bytes32 only) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = only;
    }

    function _list(bytes32 one, bytes32 two) internal pure returns (bytes32[] memory list) {
        list = new bytes32[](2);
        list[0] = one;
        list[1] = two;
    }

    /// Sets a group's leaders with the market switched off, then switches it back on.
    function _lead(address base, address partner, bytes32[] memory list) internal {
        ArbitrageLogic.Market memory settings = hook.market(id);
        uint128 profit = hook.minimumProfit(id, base);
        vm.startPrank(team);
        hook.setLimits(id, base, 0, profit, settings.minimumEdge);
        hook.setLeaders(id, base, partner, list);
        if (settings.gasLimit != 0) {
            hook.setLimits(
                id, base, uint32(hook.minimumGasLimit(id)), profit, settings.minimumEdge
            );
        }
        vm.stopPrank();
    }

    function _limits(address base, uint128 profit) internal {
        uint32 gas = uint32(hook.minimumGasLimit(id));
        vm.prank(team);
        hook.setLimits(id, base, gas, profit, 1.0001e18);
    }

    function _cycles() internal returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) count++;
        }
    }

    /// The protocol's share is 30% of what was paid, rounded up at each payout. A swap can
    /// pay out twice: in the search before it and in the search after.
    function _assertThirty(uint256 share, uint256 total) internal pure {
        assertGe(share * 100, total * 30, "protocol took less than 30%");
        assertLt(share * 100 - total * 30, 200, "protocol took more than 30%");
    }

    /// The protocol's share of WETH is sent to Core, where it waits to be counted as backing.
    function _assertNothingHeld() internal {
        if (backing.balanceOf(address(core)) != core.reserveCash()) core.absorbBacking();
        assertEq(coin.balanceOf(address(hook)), 0, "hook coin");
        _assertHookEmpty();
    }
}

contract ArbitrageMarketsTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// A sale opens a gap between the market's two pools. The hook closes it with a cycle
    /// that starts and ends in WETH, and splits what is left exactly: 30% to the protocol,
    /// the rest to the team.
    function testProfitIsPaidInWethAndSplit() public {
        uint256 protocol = backing.balanceOf(address(core));
        uint256 inventory = core.unreleasedSupply();
        _trade(first, address(coin), 50_000e18);
        uint256 kept = backing.balanceOf(treasury);
        uint256 share = backing.balanceOf(address(core)) - protocol;
        assertGt(kept, 0, "team paid in WETH");
        _assertThirty(share, kept + share);
        uint256 cash = core.reserveCash();
        assertEq(core.absorbBacking(), share, "and Core can count it as backing");
        assertEq(core.reserveCash(), cash + share);
        assertEq(coin.balanceOf(treasury), 0, "nothing paid in the team's token");
        assertEq(core.unreleasedSupply(), inventory, "no SZR retired by another market");
        _assertNothingHeld();
    }

    /// A market's search touches nothing in SZR's market, and the reverse.
    function testMarketsAreSearchedApart() public {
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(usdPool, address(szr), 50_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 10e18, 1.0001e18);
        // An open gap in SZR's market is left exactly as it is by the other market's swap.
        uint256 gap = _price(usdPool);
        uint256 inventory = core.unreleasedSupply();
        _trade(first, address(coin), 50_000e18);
        assertEq(_price(usdPool), gap, "SZR pool untouched");
        assertEq(core.unreleasedSupply(), inventory, "nothing retired");
        // And SZR's own search pays the team nothing and leaves its pools alone.
        uint256 kept = backing.balanceOf(treasury);
        (uint160 before,,,) = manager.getSlot0(second.toId());
        _trade(usdPool, address(szr), 1_000e18);
        assertGt(core.unreleasedSupply(), inventory, "SZR gap closed by its own market");
        (uint160 afterwards,,,) = manager.getSlot0(second.toId());
        assertEq(afterwards, before, "team pool untouched");
        assertEq(backing.balanceOf(treasury), kept, "team not paid");
        _assertNothingHeld();
    }

    /// Nobody but its owner can configure a market, Liquidity's manager included.
    function testOnlyTheOwnerConfiguresAMarket() public {
        PoolKey memory extra = _pair(address(backing), address(usd), 500, address(hook));
        bytes32[] memory list = _list(_id(second));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.createPool(id, extra, uint160(1 << 96));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.addVenue(id, publicPool);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setLeaders(id, address(backing), address(coin), list);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setLimits(id, address(backing), 0, 0, 1.0001e18);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setConnector(id, publicPool, true);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setRecipient(id, address(this));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.nominateOwner(id, address(this));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.untrack(id, _id(second));
        // Nor can the team touch SZR's market or the list of profit tokens.
        vm.startPrank(team);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setLeaders(1, address(szr), address(usd), list);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.untrack(1, _id(usdPool));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setProfitToken(address(usd), desk);
        // A pool of one market cannot lead in another.
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(id, address(szr), address(usd), _list(_id(usdPool)));
        vm.stopPrank();
    }

    /// A pool on the hook joins a market only by being created through the hook, and never
    /// holds SZR.
    function testHookedPoolsJoinOnlyByBeingCreatedThroughTheHook() public {
        vm.startPrank(team);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.createPool(id, publicPool, uint160(1 << 96));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.createPool(
            id, _pair(address(szr), address(backing), 500, address(hook)), uint160(1 << 96)
        );
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.addVenue(id, usdPool);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.addVenue(id, mainPool);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.createPool(1, _pair(address(coin), address(usd), 500, address(hook)), 1 << 96);
        vm.stopPrank();
        // A pool somebody else already created on the hook cannot be claimed.
        PoolKey memory taken = _pair(address(coin), address(usd), 3_000, address(hook));
        manager.initialize(taken, uint160(1 << 96));
        vm.prank(team);
        vm.expectRevert();
        hook.createPool(id, taken, uint160(1 << 96));
        assertEq(hook.partnerOf(_id(taken)), address(0), "not tracked");
        assertFalse(hook.tracked(id, _id(taken)));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.openMarket(address(0));
    }

    /// Connecting pools of an open market may run no hook but this one, and then only as a
    /// pool of the same market. They may not hold SZR.
    function testConnectingPoolRules() public {
        PoolKey memory own = _create(address(coin), address(usd), 3_000);
        vm.prank(address(0xBEEF));
        uint256 rival = hook.openMarket(address(0xBEEF));
        vm.startPrank(address(0xBEEF));
        // Another market's pool on this hook would be traded without that market's search.
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setConnector(rival, own, true);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setConnector(rival, usdPool, true);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setConnector(rival, mainPool, true);
        PoolKey memory foreign = _pair(address(coin), address(usd), 3_000, address(0xF00D));
        vm.expectRevert(ArbitrageLogic.NotTrusted.selector);
        hook.setConnector(rival, foreign, true);
        // A hookless pool is fine for anyone.
        hook.setConnector(rival, publicPool, true);
        vm.stopPrank();
        vm.prank(team);
        hook.setConnector(id, own, true);
        assertEq(
            hook.connector(id, Currency.unwrap(own.currency0), Currency.unwrap(own.currency1)),
            _id(own)
        );
    }

    /// The owner sets their pools' fees and prices, and the split does not depend on
    /// either: the profit is what is left over once every other token has netted to nothing.
    function testSplitDoesNotDependOnTheOwnersPools() public {
        // A pool with a 10% fee, priced far from the others, leads.
        PoolKey memory toll = _pair(address(backing), address(coin), 100_000, address(hook));
        vm.prank(team);
        hook.createPool(id, toll, uint160(1 << 96) / 3);
        // The owner is its only liquidity provider, and its price is the owner's choice.
        _provide(toll, 200_000e18);
        bytes32[] memory list = new bytes32[](3);
        list[0] = _id(toll);
        list[1] = _id(first);
        list[2] = _id(second);
        _lead(address(backing), address(coin), list);
        uint256 protocol = backing.balanceOf(address(core));
        _trade(first, address(coin), 50_000e18);
        uint256 kept = backing.balanceOf(treasury);
        uint256 share = backing.balanceOf(address(core)) - protocol;
        assertGt(kept, 0, "team paid");
        _assertThirty(share, kept + share);
        _assertNothingHeld();
    }

    /// A pool taken out of a market can be put back by its owner, and by nobody else.
    function testUntrackedPoolCanBeTrackedAgain() public {
        PoolKey memory extra = _create(address(backing), address(usd), 500);
        vm.prank(team);
        hook.untrack(id, _id(extra));
        assertEq(hook.partnerOf(_id(extra)), address(0));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.retrack(_id(extra));
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        hook.retrack(_id(usdPool));
        vm.expectRevert(ArbitrageLogic.UnknownPool.selector);
        hook.retrack(_id(publicPool));
        vm.prank(team);
        hook.retrack(_id(extra));
        assertEq(hook.partnerOf(_id(extra)), address(usd));
        assertEq(hook.market(id).poolCount, 3);
        // A leader cannot be untracked, whichever of its tokens it leads for.
        vm.startPrank(team);
        vm.expectRevert(ArbitrageLogic.StillLeader.selector);
        hook.untrack(id, _id(first));
        vm.stopPrank();
    }

    /// A market passes to a new owner in two steps, and SZR's market never does.
    function testOwnershipPassesByNominationAndAcceptance() public {
        address heir = address(0xE1);
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.acceptOwnership(id);
        vm.prank(heir);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, heir);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setRecipient(id, team);
        vm.prank(heir);
        hook.setRecipient(id, heir);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.nominateOwner(1, heir);
        // Nobody can accept a market that named nobody.
        vm.prank(address(0));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.acceptOwnership(1);
    }
}

contract ArbitrageProfitTokensTest is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey internal dollars;

    function setUp() public override {
        super.setUp();
        dollars = _create(address(usd), address(coin), 3_000);
    }

    /// A token is approved with the recipient of the protocol's share, and taking it off
    /// clears that.
    function testProfitTokenApproval() public {
        assertEq(hook.shareRecipient(address(backing)), address(core));
        assertEq(hook.shareRecipient(address(usd)), desk);
        hook.setProfitToken(address(usd), address(0));
        assertEq(hook.shareRecipient(address(usd)), address(0));
    }

    /// A pool with no WETH counts its profit in whichever of its tokens is on the list,
    /// and pays it out in that token: the protocol's share to that token's own recipient.
    function testPoolWithoutWethIsPaidInItsListedToken() public {
        PoolKey memory cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        _limits(address(usd), 1e15);
        uint256 weth = backing.balanceOf(treasury);
        _trade(dollars, address(coin), 50_000e18);
        uint256 kept = usd.balanceOf(treasury);
        uint256 share = usd.balanceOf(desk);
        assertGt(kept, 0, "team paid in USD");
        _assertThirty(share, kept + share);
        assertEq(backing.balanceOf(treasury), weth, "nothing paid in WETH");
        assertEq(coin.balanceOf(treasury), 0, "nothing paid in the team's token");
        _assertNothingHeld();
    }

    /// The team's WETH pool and USD pool are compared through a public pool that runs no
    /// hook, with the team's other pool as the connecting pool. A swap in either one is
    /// searched, and each counts its profit in its own listed token.
    function testWethPoolAndUsdPoolAreArbitragedAgainstEachOther() public {
        vm.startPrank(team);
        hook.addVenue(id, publicPool);
        hook.setConnector(id, dollars, true);
        hook.setConnector(id, first, true);
        vm.stopPrank();
        // Counted in WETH: the WETH pool against the public pool, across the USD pool.
        _lead(address(backing), address(coin), _list(_id(first)));
        _lead(address(backing), address(usd), _list(_id(publicPool)));
        // Counted in USD: the USD pool against the public pool, across the WETH pool.
        _lead(address(usd), address(coin), _list(_id(dollars)));
        _lead(address(usd), address(backing), _list(_id(publicPool)));
        _limits(address(usd), 1e15);
        _trade(first, address(coin), 50_000e18);
        uint256 weth = backing.balanceOf(treasury);
        assertGt(weth, 0, "swap in the WETH pool paid in WETH");
        assertEq(usd.balanceOf(treasury), 0, "and not in USD");
        // The first cycle left the two pools aligned, so open the gap from the other side.
        _trade(dollars, address(coin), 80_000e18);
        assertGt(usd.balanceOf(treasury), 0, "swap in the USD pool paid in USD");
        assertGt(usd.balanceOf(desk), 0, "with the protocol's share in USD");
        assertEq(backing.balanceOf(treasury), weth, "and nothing more in WETH");
        assertEq(coin.balanceOf(treasury), 0, "never in the team's token");
        _assertNothingHeld();
    }

    /// The same public pool can be a venue in any number of markets, each on its own.
    function testPublicPoolCanServeSeveralMarkets() public {
        address rivalOwner = address(0xBEEF);
        vm.startPrank(rivalOwner);
        uint256 rival = hook.openMarket(rivalOwner);
        hook.addVenue(rival, publicPool);
        vm.expectRevert(ArbitrageLogic.AlreadyTracked.selector);
        hook.addVenue(rival, publicPool);
        hook.setLeaders(rival, address(backing), address(usd), _list(_id(publicPool)));
        vm.stopPrank();
        vm.startPrank(team);
        hook.addVenue(id, publicPool);
        assertTrue(hook.tracked(id, _id(publicPool)));
        hook.untrack(id, _id(publicPool));
        vm.stopPrank();
        assertFalse(hook.tracked(id, _id(publicPool)));
        assertTrue(hook.tracked(rival, _id(publicPool)), "the other market keeps it");
        assertEq(hook.leadersOf(rival, address(backing), address(usd)).length, 1);
        // A pool on the hook can only be a venue in the market that created it.
        vm.prank(rivalOwner);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(rival, address(backing), address(coin), _list(_id(first)));
    }

    /// A pool with neither token on the list is never searched: there is nothing its
    /// profit could be counted in. Once one is listed and the pool is tracked again, it is.
    function testPoolWithNoListedTokenIsNotSearched() public {
        TestAsset other = new TestAsset();
        _approve(other);
        PoolKey memory odd = _create(address(other), address(coin), 3_000);
        PoolKey memory twin = _create(address(other), address(coin), 500);
        vm.recordLogs();
        _trade(odd, address(coin), 50_000e18);
        assertEq(_cycles(), 0, "no cycle");
        assertEq(other.balanceOf(treasury), 0, "nothing paid");
        hook.setProfitToken(address(other), desk);
        address[] memory chosen = new address[](2);
        chosen[0] = address(backing);
        chosen[1] = address(other);
        vm.startPrank(team);
        hook.setMinimumProfit(id, address(other), 1e15);
        hook.setTokens(id, chosen);
        hook.untrack(id, _id(odd));
        hook.retrack(_id(odd));
        hook.untrack(id, _id(twin));
        hook.retrack(_id(twin));
        vm.stopPrank();
        _lead(address(other), address(coin), _list(_id(odd), _id(twin)));
        _limits(address(other), 1e15);
        _trade(odd, address(coin), 1_000e18);
        assertGt(other.balanceOf(treasury), 0, "paid once its token is listed");
        _assertNothingHeld();
    }

    /// Taking a token off the list stops its pools being arbitraged at once, without
    /// touching the swap.
    function testDelistedTokenIsNoLongerPaidOut() public {
        PoolKey memory cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        _limits(address(usd), 1e15);
        hook.setProfitToken(address(usd), address(0));
        vm.recordLogs();
        _trade(dollars, address(coin), 50_000e18);
        assertEq(_cycles(), 0, "no cycle");
        assertEq(usd.balanceOf(treasury), 0, "nothing paid");
        assertEq(usd.balanceOf(desk), 0, "nothing paid");
        _assertNothingHeld();
    }

    /// With its token off the list a pool is not arbitraged, so a swap is not failed for
    /// bringing too little gas to arbitrage it, even with a gap wide open.
    function testDelistedPoolDoesNotFailASwapShortOfGas() public {
        PoolKey memory cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        _limits(address(usd), 1e15);
        hook.setProfitToken(address(usd), address(0));
        _trade(dollars, address(coin), 50_000e18);
        bool zeroForOne = Currency.unwrap(dollars.currency0) == address(coin);
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(1e15),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.cool(address(manager));
        vm.cool(address(hook));
        (bool filled,) = address(swapper).call{ gas: 700_000 }(
            abi.encodeCall(swapper.swap, (dollars, params, settings, ""))
        );
        assertTrue(filled, "swap went through on little gas");
    }

    /// Rules on what can be named, each refused on its own account.
    function testNamingRules() public {
        vm.startPrank(team);
        // Leaders can only be named for a token profit may be counted in.
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setLeaders(id, address(coin), address(usd), _list(_id(dollars)));
        // Nothing may be paid to the hook itself.
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setRecipient(id, address(hook));
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.openMarket(address(hook));
        vm.stopPrank();
        // SZR's pools come from Liquidity, even for its manager.
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.createPool(1, _pair(address(coin), address(usd), 500, address(hook)), 1 << 96);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.addVenue(1, publicPool);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(szr), desk);
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(usd), address(hook));
    }

    /// Each token has its own smallest profit, in its own units.
    function testSmallestProfitIsSetPerToken() public {
        PoolKey memory cheap = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(dollars), _id(cheap)));
        // Far more than any cycle here can return in USD; WETH keeps its own.
        _limits(address(usd), 1_000_000e18);
        assertEq(hook.minimumProfit(id, address(backing)), 1e15);
        vm.recordLogs();
        _trade(dollars, address(coin), 50_000e18);
        assertEq(_cycles(), 0, "USD cycle below its minimum");
        _trade(first, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "WETH cycle still runs");
        _assertNothingHeld();
    }
}

contract ArbitrageMarketScriptTest is MarketsWorld {
    function _switchedOff(uint256 opened) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] != ArbitrageLogic.LimitsSet.selector) continue;
            if (uint256(logs[index].topics[1]) != opened) continue;
            (uint32 gas,,) = abi.decode(logs[index].data, (uint32, uint128, uint64));
            if (gas == 0) return true;
        }
        return false;
    }

    /// The setup script opens a market, creates its pools, adds a public pool and names
    /// leaders in one run. Run again on the same market, it changes the leaders of a
    /// market that is switched on.
    function testScriptOpensAndConfiguresAMarket() public {
        address owner = address(0xA7);
        TestAsset other = new TestAsset();
        _approve(other);
        OpenArbitrageMarket.Config memory plan;
        plan.hook = hook;
        plan.owner = owner;
        plan.recipient = address(0xA8);
        plan.pools = new PoolKey[](2);
        plan.pools[0] = _pair(address(backing), address(other), 3_000, address(hook));
        plan.pools[1] = _pair(address(backing), address(other), 500, address(hook));
        plan.prices = new uint160[](2);
        plan.prices[0] = uint160(1 << 96);
        plan.prices[1] = uint160(1 << 96);
        plan.venues = new PoolKey[](1);
        plan.venues[0] = publicPool;
        plan.groups = new OpenArbitrageMarket.Group[](1);
        plan.groups[0] = OpenArbitrageMarket.Group(
            address(backing), address(other), _list(_id(plan.pools[0]), _id(plan.pools[1]))
        );
        plan.limits = new OpenArbitrageMarket.Limit[](1);
        plan.limits[0] = OpenArbitrageMarket.Limit(address(backing), 1e15);
        OpenArbitrageMarket setup = new OpenArbitrageMarket();
        uint256 opened = setup.run(plan);
        assertEq(hook.market(opened).owner, owner);
        assertEq(hook.market(opened).gasLimit, hook.minimumGasLimit(opened));
        assertTrue(hook.tracked(opened, _id(publicPool)));
        _provide(plan.pools[0], 1_000_000e18);
        _provide(plan.pools[1], 1_000_000e18);
        _trade(plan.pools[0], address(other), 50_000e18);
        assertGt(backing.balanceOf(address(0xA8)), 0, "the new market is paid");
        // A second run on the same market swaps the leaders round while it is on.
        OpenArbitrageMarket.Config memory change;
        change.hook = hook;
        change.owner = owner;
        change.market = opened;
        change.groups = new OpenArbitrageMarket.Group[](1);
        change.groups[0] = OpenArbitrageMarket.Group(
            address(backing), address(other), _list(_id(plan.pools[1]), _id(plan.pools[0]))
        );
        change.limits = plan.limits;
        vm.recordLogs();
        assertEq(setup.run(change), opened);
        assertFalse(_switchedOff(opened), "never switched off on the way");
        assertEq(
            hook.leadersOf(opened, address(backing), address(other))[0], _id(plan.pools[1])
        );
        assertEq(hook.market(opened).gasLimit, hook.minimumGasLimit(opened), "back on");
        // The whole first plan again changes nothing and reverts nowhere.
        plan.market = opened;
        setup.run(plan);
        assertEq(hook.market(opened).poolCount, 3);
    }

    /// Choosing again a token whose groups are still set needs a larger allowance than the
    /// market has: the script makes room first, so the market is not refused.
    function testScriptMakesRoomBeforeChoosingTokens() public {
        address owner = address(0xA7);
        TestAsset other = new TestAsset();
        _approve(other);
        OpenArbitrageMarket.Config memory plan;
        plan.hook = hook;
        plan.owner = owner;
        plan.recipient = address(0xA8);
        plan.tokens = new address[](2);
        plan.tokens[0] = address(backing);
        plan.tokens[1] = address(usd);
        plan.pools = new PoolKey[](3);
        plan.prices = new uint160[](3);
        bytes32[] memory leaders = new bytes32[](3);
        uint24[3] memory fees = [uint24(3_000), 500, 10_000];
        for (uint256 index; index < 3; index++) {
            plan.pools[index] = _pair(address(usd), address(other), fees[index], address(hook));
            plan.prices[index] = uint160(1 << 96);
            leaders[index] = _id(plan.pools[index]);
        }
        plan.groups = new OpenArbitrageMarket.Group[](1);
        plan.groups[0] = OpenArbitrageMarket.Group(address(usd), address(other), leaders);
        OpenArbitrageMarket setup = new OpenArbitrageMarket();
        plan.limits = new OpenArbitrageMarket.Limit[](2);
        plan.limits[0] = OpenArbitrageMarket.Limit(address(backing), 1e15);
        plan.limits[1] = OpenArbitrageMarket.Limit(address(usd), 1e15);
        uint256 opened = setup.run(plan);
        // The owner drops USD and trims the allowance to what WETH alone needs.
        address[] memory weth = new address[](1);
        weth[0] = address(backing);
        vm.startPrank(owner);
        hook.setTokens(opened, weth);
        hook.setLimits(
            opened, address(usd), uint32(hook.minimumGasLimit(opened)), 1e15, 1.0001e18
        );
        vm.stopPrank();
        // The same plan again chooses USD, whose three leaders need more than that.
        OpenArbitrageMarket.Config memory again;
        again.hook = hook;
        again.owner = owner;
        again.market = opened;
        again.tokens = plan.tokens;
        setup.run(again);
        assertEq(hook.tokensOf(opened).length, 2);
        assertEq(hook.tokensOf(opened)[1], address(usd));
    }
}
