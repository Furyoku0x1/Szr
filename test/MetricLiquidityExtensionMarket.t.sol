// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MetricExtensionWorld, SwapPool } from "./MetricLiquidityExtension.t.sol";
import { FlatPricer } from "./utils/WrappedPool.sol";
import { MetricPoolImmutables } from "../src/interfaces/metric/IMetricPool.sol";
import { MetricVenueHook } from "../src/hooks/MetricVenueHook.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Vm } from "forge-std/Vm.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A swap pool that passes `MetricVenueHook.bind`: it names its factory and reports a
/// flat price. It refuses exact-output swaps, which `SwapPool` would read as a huge size.
contract VenuePool is SwapPool {
    address internal immutable factory;

    constructor(
        address token0_,
        address token1_,
        uint256 minimum_,
        uint256[4] memory orders_,
        address factory_
    ) SwapPool(token0_, token1_, minimum_, orders_) {
        factory = factory_;
    }

    function getImmutables() public view override returns (MetricPoolImmutables memory imm) {
        imm = super.getImmutables();
        imm.factory = factory;
    }

    function getSellAndBuyPrices() external pure returns (uint128, uint128) {
        return (uint128(1 << 64), uint128(1 << 64));
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128 limit,
        bytes calldata one,
        bytes calldata two
    ) public override returns (int128, int128) {
        require(amountSpecified > 0, "exact output refused");
        return super.swap(recipient, zeroForOne, amountSpecified, limit, one, two);
    }
}

/// @dev The Metric extension's own arbitrage-hook market.
contract MetricLiquidityExtensionMarketTest is MetricExtensionWorld {
    /// The extension opens a market, creates two plain v4 pools in it on the Metric pool's own
    /// pair through `marketCall` (the Metric pool is not wired in as a venue here), and a swap
    /// by someone else pays the market's profit to the extension.
    function testOwnMarketPaysTheExtension() public {
        uint256 market = mext.openMarket();
        assertEq(hook.market(market).owner, address(mext));
        assertEq(hook.market(market).recipient, address(mext));
        id = market;
        team = address(mext);
        address[] memory chosen = new address[](1);
        chosen[0] = address(usd);
        mext.marketCall(abi.encodeCall(hook.setTokens, (market, chosen)));
        PoolKey memory one = _pair(address(t0), address(t1), 1_000, address(hook));
        PoolKey memory two = _pair(address(t0), address(t1), 200, address(hook));
        mext.marketCall(abi.encodeCall(hook.createPool, (market, one, uint160(1 << 96))));
        mext.marketCall(abi.encodeCall(hook.createPool, (market, two, uint160(1 << 96))));
        _provide(one, 1_000_000e18);
        _provide(two, 1_000_000e18);
        _lead(address(usd), address(coin), _list(_id(one), _id(two)));
        _limits(address(usd), 1e15);
        uint256 before = usd.balanceOf(address(mext));
        _trade(one, address(coin), 50_000e18);
        assertGt(usd.balanceOf(address(mext)), before, "profit paid to the extension");
        vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
        mext.marketCall(abi.encodeCall(hook.setRecipient, (market, alice)));
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.createPool(market, one, uint160(1 << 96));
    }

    /// What every extension shares also holds for this one: swaps through a registered v4
    /// route, giving WETH to Core, wrapping, and the refused market calls.
    function testSharedBaseBehaviour() public {
        PoolKey memory route = _openPool(address(backing), address(coin), 3_000);
        backing.mint(address(mext), HELD);
        mext.registerRoute(route);
        bool zeroForOne = Currency.unwrap(route.currency0) == address(backing);
        (, uint256 got) = mext.swap(
            route, zeroForOne, 1_000e18, 1, zeroForOne ? FLOOR : CEILING, block.timestamp
        );
        assertGt(got, 0, "swapped through the route");
        uint256 cash = core.reserveCash();
        mext.toCore(address(backing), 5e18);
        assertEq(core.reserveCash(), cash + 5e18, "backing given to Core");
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        mext.toCore(address(coin), 1);
        vm.deal(address(mext), 2e18);
        mext.wrap(2e18);
        mext.unwrap(2e18);
        assertEq(address(mext).balance, 2e18, "1:1 round trip");
        uint256 market = mext.openMarket();
        bytes[] memory refused = new bytes[](5);
        refused[0] = abi.encodeCall(hook.setRecipient, (market, alice));
        refused[1] = abi.encodeCall(hook.nominateOwner, (market, alice));
        refused[2] = abi.encodeCall(hook.openMarket, (alice));
        refused[3] = abi.encodeCall(hook.acceptOwnership, (market));
        refused[4] = "";
        for (uint256 index; index < refused.length; index++) {
            vm.expectRevert(LiquidityExtension.ForbiddenCall.selector);
            mext.marketCall(refused[index]);
        }
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.NotManager.selector);
        mext.toCore(address(backing), 1);
    }

    /// The extension's own Metric pool, bound to a real venue hook, is also a venue of the
    /// extension's own market. A stranger's sale into the market's one v4 pool opens a gap
    /// that only the venue leg can close, and the extension, as recipient, is paid. Its bins
    /// are still its own afterwards. The venue is listed as a leader too: with the v4 pool
    /// alone, the searches found no gap to close.
    function testOwnMetricPoolIsAVenueOfTheOwnMarket() public {
        VenuePool metric = _venuePool();
        (uint256 paid0, uint256 paid1) = mext.addLiquidity(
            address(metric), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp
        );
        PoolKey memory v4 = _openOwnMarket(_bindVenue(metric));
        uint256 usdBefore = usd.balanceOf(address(mext));
        uint256 coinBefore = coin.balanceOf(address(metric));
        uint256 usdPoolBefore = usd.balanceOf(address(metric));
        vm.recordLogs();
        _trade(v4, address(coin), 50_000e18);
        assertGt(_cycles(), 0, "a cycle ran");
        assertTrue(coin.balanceOf(address(metric)) != coinBefore, "Metric coin moved");
        assertTrue(usd.balanceOf(address(metric)) != usdPoolBefore, "Metric usd moved");
        assertGt(usd.balanceOf(address(mext)), usdBefore, "profit paid to the extension");
        (uint256 got0, uint256 got1) = mext.removeLiquidity(
            address(metric), 1, _bins(), _shares(1e18), 0, 0, block.timestamp
        );
        assertEq(got0, paid0, "token0 back");
        assertEq(got1, paid1, "token1 back");
    }

    /// The extension swaps through the venue hook's v4 pool as a route: it fills from the
    /// Metric pool and `Swapped` matches what moved, with no market tracking the venue.
    function testSwapThroughTheVenueHookFillsFromMetric() public {
        VenuePool metric = _venuePool();
        PoolKey memory key = _bindVenue(metric);
        mext.registerRoute(key);
        uint256 in0 = t0.balanceOf(address(mext));
        uint256 out1 = t1.balanceOf(address(mext));
        uint256 pool0 = t0.balanceOf(address(metric));
        uint256 pool1 = t1.balanceOf(address(metric));
        vm.recordLogs();
        (uint256 spent, uint256 got) = mext.swap(key, true, 100e18, 1, FLOOR, block.timestamp);
        assertEq(_swapped(), abi.encode(true, spent, got), "Swapped matches the return");
        assertEq(spent, 100e18, "all of it is spent");
        assertGt(got, 0, "filled");
        assertEq(t0.balanceOf(address(mext)), in0 - spent, "extension paid");
        assertEq(t1.balanceOf(address(mext)), out1 + got, "extension received");
        assertEq(t0.balanceOf(address(metric)), pool0 + spent, "Metric took the input");
        assertEq(t1.balanceOf(address(metric)), pool1 - got, "Metric paid the output");
    }

    /// With a gap open in a market that tracks the venue, the extension's swap through the
    /// venue hook starts the search, which closes the gap and pays the market's recipient.
    function testSwapThroughTheVenueHookClosesAGapAndPaysTheMarket() public {
        (PoolKey memory key,) = _gapThroughTheVenue();
        uint256 usdBefore = usd.balanceOf(address(mext));
        vm.recordLogs();
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usd);
        (uint256 spent, uint256 got) =
            mext.swap(key, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING, block.timestamp);
        assertGt(_cycles(), 0, "the search ran");
        uint256 own = zeroForOne ? usdBefore - spent : usdBefore + got;
        assertGt(usd.balanceOf(address(mext)), own, "the recipient was paid profit");
    }

    /// The extension's swap through the venue hook with too little gas for the search skips
    /// the search and still settles, and more gas never turns a settled swap into a failed
    /// one. Proven at 50,000-gas steps over the whole range, then at 2,000-gas steps around
    /// the first level where a cycle runs, where the search's own gas check sits. Each swap
    /// starts cold. The wrapper catches the search's failures, so no `InsufficientGas` can
    /// show here; what is pinned is that the swap settles.
    function testLowGasSwapThroughTheVenueHookSkipsTheSearch() public {
        (PoolKey memory key,) = _gapThroughTheVenue();
        bytes memory call =
            abi.encodeCall(mext.swap, (key, true, 1e18, 0, FLOOR, block.timestamp));
        bool settled;
        bool skippedOnly;
        uint256 firstSearch;
        for (uint256 gas = 300_000; gas <= 9_000_000; gas += 50_000) {
            (bool ok, uint256 skips, uint256 cycles) = _attempt(key, call, gas);
            if (settled) assertTrue(ok, "more gas failed a swap");
            if (ok) settled = true;
            if (ok) {
                if (skips != 0) {
                    if (cycles == 0) skippedOnly = true;
                }
            }
            if (cycles != 0) {
                if (firstSearch == 0) firstSearch = gas;
            }
        }
        assertTrue(skippedOnly, "never settled with the search skipped");
        assertGt(firstSearch, 0, "never searched");
        settled = false;
        for (uint256 gas = firstSearch - 50_000; gas <= firstSearch + 50_000; gas += 2_000) {
            (bool ok,,) = _attempt(key, call, gas);
            if (settled) assertTrue(ok, "more gas failed a swap, fine steps");
            if (ok) settled = true;
        }
        assertTrue(settled, "never settled in the fine range");
    }

    function _attempt(PoolKey memory key, bytes memory call, uint256 gas)
        internal
        returns (bool ok, uint256 skips, uint256 cycles)
    {
        uint256 snapshot = vm.snapshotState();
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(key.hooks));
        vm.cool(address(lastMetric));
        vm.cool(address(mext));
        vm.recordLogs();
        (ok,) = address(mext).call{ gas: gas }(call);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        skips = _count(logs, ArbitrageLogic.VenueSearchSkipped.selector);
        cycles = _count(logs, ArbitrageLogic.Arbitraged.selector);
        vm.revertToState(snapshot);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic) internal view returns (uint256 n) {
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].emitter != address(hook)) continue;
            if (logs[index].topics[0] == topic) n++;
        }
    }

    /// A venue hook pool wired to the extension's own market with a gap open in its one v4
    /// pool, and the venue pool registered as a route.
    function _gapThroughTheVenue() internal returns (PoolKey memory key, PoolKey memory v4) {
        key = _bindVenue(_venuePool());
        v4 = _openOwnMarket(key);
        uint256 market = hook.marketCount();
        MetricVenueHook(address(key.hooks))
            .setTrigger(key, market, address(usd), 12_000_000, true);
        mext.registerRoute(key);
        address usdToken = address(usd);
        mext.marketCall(abi.encodeCall(hook.setLimits, (market, usdToken, 0, 1e15, 1.0001e18)));
        _trade(v4, address(coin), 50_000e18);
        uint32 gas = uint32(hook.minimumGasLimit(market));
        mext.marketCall(
            abi.encodeCall(hook.setLimits, (market, usdToken, gas, 1e15, 1.0001e18))
        );
    }

    /// The data of the extension's `Swapped` log: direction, spent, received.
    function _swapped() internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == LiquidityExtension.Swapped.selector) {
                data = logs[index].data;
            }
        }
    }

    VenuePool internal lastMetric;

    function _venuePool() internal returns (VenuePool made) {
        made = VenuePool(
            deployCode(
                "MetricLiquidityExtensionMarket.t.sol:VenuePool",
                abi.encode(address(t0), address(t1), MIN, none, address(metricFactory))
            )
        );
        lastMetric = made;
        metricFactory.register(address(made));
        t0.mint(address(made), HELD);
        t1.mint(address(made), HELD);
        mext.addPool(address(made));
    }

    /// Wraps the pool in a venue hook with a flat pricer. This test is Liquidity's manager.
    function _bindVenue(VenuePool metric) internal returns (PoolKey memory key) {
        address at = address(uint160(0x4444 << 144 | 0x2888 | 1 << 6));
        deployCodeTo(
            "MetricVenueHook.sol:MetricVenueHook",
            abi.encode(address(this), address(metricFactory), address(manager), address(hook)),
            at
        );
        key = PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 0, 1, IHooks(at));
        MetricVenueHook(at).bind(key, address(metric));
        hook.setPricer(at, address(new FlatPricer()));
    }

    /// Opens the extension's market counting in USD with one v4 pool and the venue, all set
    /// through `marketCall`.
    function _openOwnMarket(PoolKey memory venueKey) internal returns (PoolKey memory v4) {
        uint256 market = mext.openMarket();
        address usdToken = address(usd);
        address[] memory chosen = new address[](1);
        chosen[0] = usdToken;
        v4 = _pair(address(t0), address(t1), 1_000, address(hook));
        mext.marketCall(abi.encodeCall(hook.setTokens, (market, chosen)));
        mext.marketCall(abi.encodeCall(hook.createPool, (market, v4, uint160(1 << 96))));
        _provide(v4, 1_000_000e18);
        mext.marketCall(abi.encodeCall(hook.setLimits, (market, usdToken, 0, 1e15, 1.0001e18)));
        mext.marketCall(abi.encodeCall(hook.addVenue, (market, venueKey)));
        bytes32[] memory leaders = _list(_id(v4), _id(venueKey));
        mext.marketCall(
            abi.encodeCall(hook.setLeaders, (market, usdToken, address(coin), leaders))
        );
        uint32 gas = uint32(hook.minimumGasLimit(market));
        mext.marketCall(
            abi.encodeCall(hook.setLimits, (market, usdToken, gas, 1e15, 1.0001e18))
        );
    }

    /// A swap through a hooked route by the extension carries the hook's gas rule: with an
    /// open gap and too little gas it reverts with the hook's error, never skips the gap.
    function testShortGasSwapThroughHookPoolReverts() public {
        mext.registerRoute(usdPool);
        PoolKey memory low = _addHooked(address(usd), 500);
        hook.setLimits(1, address(szr), 0, 0, 1.0001e18);
        _trade(low, address(szr), 150_000e18);
        hook.setLimits(1, address(szr), 8_000_000, 0, 1.0001e18);
        bool zeroForOne = Currency.unwrap(usdPool.currency0) == address(usd);
        bytes memory call = abi.encodeCall(
            mext.swap,
            (usdPool, zeroForOne, 1e18, 0, zeroForOne ? FLOOR : CEILING, block.timestamp)
        );
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = address(mext).call{ gas: 300_000 }(call);
        assertFalse(ok, "short gas reverts");
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "the hook's error");
        vm.revertToState(snapshot);
        (ok,) = address(mext).call{ gas: 9_000_000 }(call);
        assertTrue(ok, "enough gas fills it");
    }
}
