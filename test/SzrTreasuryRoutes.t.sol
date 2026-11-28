// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { TreasuryWorld, _treasury } from "./SzrTreasury.t.sol";
import { ArbitrageWorld } from "./utils/ArbitrageWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockMetricPool } from "./utils/metric/MockMetricPool.sol";
import { SzrTreasury } from "../src/SzrTreasury.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IIndexHook } from "../src/interfaces/IIndexHook.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IMetricPool, MetricImmutables } from "../src/interfaces/metric/IMetricPool.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { BeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A Metric pool that does one thing in its swap: calls `target` with `data` and
/// passes any revert up, so a test can have a venue reenter the treasury or poke its callback.
contract HostileMetric is IMetricPool {
    address public immutable token0;
    address public immutable token1;
    address internal target;
    bytes internal data;

    constructor(address one, address two) {
        token0 = one;
        token1 = two;
    }

    function aim(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
    }

    function getImmutables() external view returns (MetricImmutables memory) {
        return MetricImmutables(address(0), token0, token1, 1, 1);
    }

    function getSellAndBuyPrices() external pure returns (uint128, uint128) {
        return (0, 0);
    }

    function swap(address, bool, int128, uint128, bytes calldata, bytes calldata)
        external
        returns (int128, int128)
    {
        (bool ok, bytes memory result) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return (0, 0);
    }
}

/// @dev An index pool that lies, put in place of a real one with `vm.etch` so the factory
/// knows its address. Modes: 0 swaps one for one; 1 takes the input, pays nothing and says
/// so; 2 pulls one more than it was approved for; 3 calls `target` and passes its revert up;
/// 4 pulls one less than it was approved for; 5 takes the input and pays nothing but
/// reports a full output. The plan sits in a hashed slot because the code replaces a pool
/// that has storage of its own.
contract FakeIndex {
    struct Plan {
        uint8 mode;
        address target;
        bytes data;
    }

    function _plan() internal pure returns (Plan storage plan) {
        bytes32 slot = keccak256("szr.treasury.fake.index");
        assembly ("memory-safe") {
            plan.slot := slot
        }
    }

    function aim(uint8 mode_, address target_, bytes calldata data_) external {
        Plan storage plan = _plan();
        plan.mode = mode_;
        plan.target = target_;
        plan.data = data_;
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool,
        uint256,
        address recipient,
        uint256
    ) external returns (uint256, uint256) {
        Plan storage plan = _plan();
        uint8 mode = plan.mode;
        if (mode == 3) {
            (bool ok, bytes memory result) = plan.target.call(plan.data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
        }
        uint256 pulled = mode == 2 ? amount + 1 : mode == 4 ? amount - 1 : amount;
        TestAsset(tokenIn).transferFrom(msg.sender, address(this), pulled);
        if (mode == 1) return (amount, 0);
        if (mode != 5) TestAsset(tokenOut).transfer(recipient, amount);
        return (amount, amount);
    }
}

/// @dev A token that takes one unit more than it moves from the sender, which a pool could
/// do to drain more than it was approved for.
contract GreedyAsset is TestAsset {
    function _afterTokenTransfer(address from, address to, uint256) internal override {
        if (from == address(0)) return;
        if (to == address(0)) return;
        _burn(from, 1);
    }
}

/// @dev A token that, once switched on, delivers one unit less than it moves.
contract ShortAsset is TestAsset {
    bool public short;

    function setShort(bool on) external {
        short = on;
    }

    function _afterTokenTransfer(address from, address to, uint256) internal override {
        if (!short) return;
        if (from == address(0)) return;
        if (to == address(0)) return;
        _burn(to, 1);
    }
}

/// @dev Pays an index pool's protocol cut to the treasury in the middle of a swap, as any
/// code that runs during a hop could, since `payProtocol` is open to everyone.
contract PayoutHook is IIndexHook {
    IndexPool internal immutable owing;
    address internal immutable token;

    constructor(IndexPool owing_, address token_) {
        owing = owing_;
        token = token_;
    }

    function beforeSwap(address, address, address) external {
        owing.payProtocol(token);
    }

    function afterSwap(address, address, address, uint256, uint256) external { }
}

/// @dev The same for a v4 pool: a hook whose `beforeSwap` pays the cut.
contract PayoutV4Hook {
    IndexPool internal immutable owing;
    address internal immutable token;

    constructor(IndexPool owing_, address token_) {
        owing = owing_;
        token = token_;
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        owing.payProtocol(token);
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }
}

contract SzrTreasuryRoutesTest is TreasuryWorld {
    function _assertDone(uint256 backed, uint256 fee, uint256 inAmount) internal view {
        _assertBacked(backed, fee);
        assertGt(backed + fee, inAmount * 98 / 100, "close to the input");
        assertLe(backed + fee, inAmount, "no more than the input");
    }

    function test_backThroughV4() public {
        PoolKey memory pool = _v4Pool(address(backing), address(coin));
        (uint256 backed, uint256 fee) =
            _back(coin, 100e18, _route(_v4Hop(pool, address(backing))));
        _assertDone(backed, fee, 100e18);
    }

    function test_backThroughMetricInBothDirections() public {
        MockMetricPool pool = _metricPool(address(coin), address(backing));
        (uint256 backed, uint256 fee) =
            _back(coin, 100e18, _route(_metricHop(address(pool), address(backing))));
        assertEq(backed + fee, 100e18, "price one");
        _assertBacked(backed, fee);
        _mark();
        // Out and back again, so that both directions of the pool are used.
        backing.mint(address(treasury), 50e18);
        SzrTreasury.Hop[] memory route = _route(
            _metricHop(address(pool), address(coin)),
            _metricHop(address(pool), address(backing))
        );
        (backed, fee) = treasury.back(address(backing), 50e18, route, 50e18, FAR);
        _assertBacked(backed, fee);
        assertEq(backed + fee, 50e18);
    }

    function test_backThroughAnIndexPoolAndTheApprovalIsReset() public {
        IndexPool pool = _indexPool(address(usdg), address(backing));
        (uint256 backed, uint256 fee) =
            _back(usdg, 100e18, _route(_indexHop(address(pool), address(backing))));
        _assertDone(backed, fee, 100e18);
        assertEq(usdg.allowance(address(treasury), address(pool)), 0, "approval");
        assertEq(usdg.balanceOf(address(treasury)), 0);
    }

    function test_mixedMultihopFromAStockToken() public {
        IndexPool index = _indexPool(address(coin), address(usdg));
        MockMetricPool metric = _metricPool(address(usdg), address(backing));
        SzrTreasury.Hop[] memory route = _route(
            _indexHop(address(index), address(usdg)),
            _metricHop(address(metric), address(backing))
        );
        (uint256 backed, uint256 fee) = _back(coin, 100e18, route);
        _assertDone(backed, fee, 100e18);
        assertEq(coin.allowance(address(treasury), address(index)), 0, "approval");
    }

    function test_aRouteMayEndInNativeEthWhichIsWrapped() public {
        PoolKey memory pool = _v4Pool(address(0), address(coin));
        (uint256 backed, uint256 fee) = _back(coin, 100e18, _route(_v4Hop(pool, address(0))));
        _assertDone(backed, fee, 100e18);
    }

    function test_aRouteMayStartFromWethThroughNativeEth() public {
        PoolKey memory native = _v4Pool(address(0), address(coin));
        PoolKey memory erc20 = _v4Pool(address(backing), address(coin));
        SzrTreasury.Hop[] memory route =
            _route(_v4Hop(native, address(coin)), _v4Hop(erc20, address(backing)));
        (uint256 backed, uint256 fee) = _back(backing, 100e18, route);
        assertGt(backed + fee, 95e18, "two fees");
        assertLt(backed + fee, 100e18);
        _assertBacked(backed, fee);
    }

    function test_aPartialMetricFillLeavesTheRestAndTheNextHopSpendsOnlyWhatCameIn() public {
        MockMetricPool metric = _metricPool(address(coin), address(usdg));
        metric.setMaxFill(40e18);
        IndexPool index = _indexPool(address(usdg), address(backing));
        uint256 poolUsdg = usdg.balanceOf(address(index));
        SzrTreasury.Hop[] memory route = _route(
            _metricHop(address(metric), address(usdg)),
            _indexHop(address(index), address(backing))
        );
        (uint256 backed, uint256 fee) = _back(coin, 100e18, route);
        assertEq(coin.balanceOf(address(treasury)), 60e18, "unfilled input waits");
        assertEq(usdg.balanceOf(address(index)), poolUsdg + 40e18, "only what was received");
        assertEq(usdg.balanceOf(address(treasury)), 0);
        assertGt(backed + fee, 39e18 * 98 / 100);
        assertLt(backed + fee, 40e18);
    }

    function test_theIndexPoolsCutReachesCoreAsBacking() public {
        IndexPool pool = _indexPool(address(coin), address(backing));
        for (uint256 index; index < 4; index++) {
            pool.swap(address(coin), address(backing), 1_000e18, true, 0, address(this), FAR);
            pool.swap(address(backing), address(coin), 1_000e18, true, 0, address(this), FAR);
        }
        assertGt(pool.owed(address(coin)), 0);
        assertGt(pool.owed(address(backing)), 0);
        uint256 cutCoin = pool.payProtocol(address(coin));
        uint256 cutWeth = pool.payProtocol(address(backing));
        _mark();
        assertEq(coin.balanceOf(address(treasury)), cutCoin);
        assertEq(backing.balanceOf(address(treasury)), cutWeth);
        (uint256 backed, uint256 fee) = treasury.back(
            address(coin), cutCoin, _route(_indexHop(address(pool), address(backing))), 1, FAR
        );
        (uint256 more, uint256 moreFee) =
            treasury.back(address(backing), cutWeth, _empty(), cutWeth, FAR);
        assertEq(more + moreFee, cutWeth, "the cut in weth needs no hop");
        _assertBacked(backed + more, fee + moreFee);
        assertEq(coin.balanceOf(address(treasury)), 0);
    }
}

/// @dev Venues that lie, and code that runs mid-hop. Output comes from what the venue's
/// authority reports, never from a balance that anyone may raise.
contract SzrTreasuryHostileTest is TreasuryWorld {
    /// A pool the factory knows, with a liar's code in place of its own.
    function _fakeIndex() internal returns (FakeIndex fake) {
        IndexPool real = _indexPool(address(usdg), address(coin));
        vm.etch(address(real), address(new FakeIndex()).code);
        fake = FakeIndex(address(real));
        backing.mint(address(fake), 1_000e18);
    }

    function _one(address pool, address out) internal pure returns (SzrTreasury.Hop[] memory) {
        PoolKey memory none;
        SzrTreasury.Hop[] memory route = new SzrTreasury.Hop[](1);
        route[0] = SzrTreasury.Hop(SzrTreasury.Venue.INDEX, none, pool, out);
        return route;
    }

    function _asMetric(SzrTreasury.Hop[] memory route)
        internal
        pure
        returns (SzrTreasury.Hop[] memory)
    {
        route[0].venue = SzrTreasury.Venue.METRIC;
        return route;
    }

    function test_aMetricPoolAskingForMoreThanTheHopWasGivenReverts() public {
        MockMetricPool metric = _metricPool(address(coin), address(backing));
        metric.setMode(3, 1);
        coin.mint(address(treasury), 100e18);
        SzrTreasury.Hop[] memory route = _route(_metricHop(address(metric), address(backing)));
        vm.expectRevert(SzrTreasury.Overspent.selector);
        treasury.back(address(coin), 99e18, route, 0, FAR);
        assertEq(coin.balanceOf(address(treasury)), 100e18);
    }

    function test_aMetricCallbackFromAnyPoolButTheOneCalledReverts() public {
        MockMetricPool other = _metricPool(address(coin), address(backing));
        HostileMetric hostile = new HostileMetric(address(coin), address(backing));
        metricFactory.register(address(hostile));
        hostile.aim(address(other), abi.encodeCall(other.poke, (address(treasury))));
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.NotPool.selector);
        treasury.back(
            address(coin), 10e18, _route(_metricHop(address(hostile), address(backing))), 0, FAR
        );
    }

    function test_aMetricCallbackAskingForTheOutputTokenReverts() public {
        (address low, address high) = _sorted(address(coin), address(backing));
        HostileMetric hostile = new HostileMetric(low, high);
        metricFactory.register(address(hostile));
        // Selling `low`, the callback asks for `high`, which the treasury is to receive.
        hostile.aim(
            address(treasury), abi.encodeCall(treasury.metricOmmSwapCallback, (0, 1, ""))
        );
        TestAsset(low).mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.Overspent.selector);
        treasury.back(low, 10e18, _route(_metricHop(address(hostile), high)), 0, FAR);
    }

    function test_amountsAboveTheMaximumRevert() public {
        MockMetricPool metric = _metricPool(address(coin), address(backing));
        PoolKey memory pool = _v4Pool(address(backing), address(coin));
        vm.expectRevert(SzrTreasury.AboveMaximum.selector);
        treasury.back(
            address(coin),
            1 << 127,
            _route(_metricHop(address(metric), address(backing))),
            0,
            FAR
        );
        // At 2^255 the v4 amount would have negated into an exact-output swap.
        vm.expectRevert(SzrTreasury.AboveMaximum.selector);
        treasury.back(address(coin), 1 << 255, _route(_v4Hop(pool, address(backing))), 0, FAR);
        vm.expectRevert(SzrTreasury.AboveMaximum.selector);
        treasury.back(
            address(coin),
            uint256(type(uint128).max) + 1,
            _route(_v4Hop(pool, address(backing))),
            0,
            FAR
        );
    }

    function test_unknownMetricAndIndexPoolsRevert() public {
        HostileMetric hostile = new HostileMetric(address(coin), address(backing));
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.UnknownPool.selector);
        treasury.back(
            address(coin), 10e18, _route(_metricHop(address(hostile), address(backing))), 0, FAR
        );
        FakeIndex outsider = new FakeIndex();
        vm.expectRevert(SzrTreasury.UnknownPool.selector);
        treasury.back(address(coin), 10e18, _one(address(outsider), address(backing)), 0, FAR);
    }

    function test_aFakeIndexPoolThatPaysNothingReverts() public {
        FakeIndex fake = _fakeIndex();
        fake.aim(1, address(0), "");
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.BelowMinimum.selector);
        treasury.back(address(coin), 10e18, _one(address(fake), address(backing)), 1, FAR);
        assertEq(coin.balanceOf(address(treasury)), 10e18);
    }

    function test_aVenueThatReportsMoreThanItPaidRevertsShortDelivery() public {
        FakeIndex fake = _fakeIndex();
        fake.aim(5, address(0), "");
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.ShortDelivery.selector);
        treasury.back(address(coin), 10e18, _one(address(fake), address(usdg)), 1, FAR);
    }

    function test_aTokenThatDeliversLessThanReportedRevertsShortDelivery() public {
        ShortAsset short = new ShortAsset();
        FakeIndex fake = _fakeIndex();
        short.mint(address(fake), 100e18);
        short.setShort(true);
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.ShortDelivery.selector);
        treasury.back(address(coin), 10e18, _one(address(fake), address(short)), 1, FAR);
    }

    function test_aV4SettleThatReceivesLessThanOwedReverts() public {
        ShortAsset short = new ShortAsset();
        short.mint(address(this), 100_000_000e18);
        short.approve(address(provider), type(uint256).max);
        PoolKey memory pool = _v4Pool(address(short), address(backing));
        short.setShort(true);
        short.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.TransferMismatch.selector);
        treasury.back(address(short), 10e18, _route(_v4Hop(pool, address(backing))), 0, FAR);
    }

    function test_aFakeIndexPoolPullingMoreThanApprovedRevertsOnTheAllowance() public {
        FakeIndex fake = _fakeIndex();
        fake.aim(2, address(0), "");
        coin.mint(address(treasury), 100e18);
        vm.expectRevert(ERC20.InsufficientAllowance.selector);
        treasury.back(address(coin), 10e18, _one(address(fake), address(usdg)), 1, FAR);
    }

    function test_aPoolThatPullsLessThanApprovedLeavesNoAllowance() public {
        FakeIndex fake = _fakeIndex();
        fake.aim(4, address(0), "");
        coin.mint(address(treasury), 100e18);
        treasury.back(address(coin), 10e18, _one(address(fake), address(backing)), 1, FAR);
        // Without the reset the unspent unit would stay approved to the pool.
        assertEq(coin.allowance(address(treasury), address(fake)), 0);
    }

    function test_aTokenThatTakesMoreThanTheHopWasGivenIsCaught() public {
        GreedyAsset greedy = new GreedyAsset();
        FakeIndex fake = _fakeIndex();
        usdg.mint(address(fake), 100e18);
        greedy.mint(address(treasury), 100e18);
        vm.expectRevert(SzrTreasury.Overspent.selector);
        treasury.back(address(greedy), 10e18, _one(address(fake), address(usdg)), 1, FAR);
    }

    function test_aVenueThatReentersReverts() public {
        coin.mint(address(treasury), 10e18);
        FakeIndex fake = _fakeIndex();
        HostileMetric hostile = new HostileMetric(address(coin), address(backing));
        metricFactory.register(address(hostile));
        SzrTreasury.Hop[] memory empty = _empty();
        bytes[2] memory calls = [
            abi.encodeCall(treasury.back, (address(backing), 1, empty, 0, FAR)),
            abi.encodeCall(treasury.retire, (address(szrToken), 1, empty, 0, FAR))
        ];
        for (uint256 index; index < 2; index++) {
            fake.aim(3, address(treasury), calls[index]);
            hostile.aim(address(treasury), calls[index]);
            vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
            treasury.back(address(coin), 10e18, _one(address(fake), address(usdg)), 0, FAR);
            vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
            treasury.back(
                address(coin),
                10e18,
                _route(_metricHop(address(hostile), address(backing))),
                0,
                FAR
            );
        }
    }

    /// A pool Q whose cut of WETH is owed to the treasury, for code mid-hop to pay out.
    function _owing() internal returns (IndexPool pool, uint256 cut) {
        pool = _indexPool(address(usdg), address(backing));
        for (uint256 index; index < 4; index++) {
            usdg.mint(address(this), 1_000e18);
            backing.mint(address(this), 1_000e18);
            usdg.approve(address(pool), type(uint256).max);
            backing.approve(address(pool), type(uint256).max);
            pool.swap(address(usdg), address(backing), 1_000e18, true, 0, address(this), FAR);
            pool.swap(address(backing), address(usdg), 1_000e18, true, 0, address(this), FAR);
        }
        cut = pool.owed(address(backing));
        assertGt(cut, 0);
    }

    function _payoutV4Pool(IndexPool owing) internal returns (PoolKey memory key) {
        address hook = address(uint160(0xB00B << 144 | 0x80));
        deployCodeTo(
            "SzrTreasuryRoutes.t.sol:PayoutV4Hook", abi.encode(owing, address(backing)), hook
        );
        (address low, address high) = _sorted(address(coin), address(backing));
        key = PoolKey(Currency.wrap(low), Currency.wrap(high), 3_000, 60, IHooks(hook));
        manager.initialize(key, uint160(1 << 96));
        provider.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(10_000e18), 0
            ),
            ""
        );
    }

    function _payoutIndexPool(IndexPool owing) internal returns (IndexPool pool) {
        indexFactory.setOpenHooks(true);
        PayoutHook hook = new PayoutHook(owing, address(backing));
        (address low, address high) = _sorted(address(coin), address(backing));
        address[] memory list = new address[](2);
        list[0] = low;
        list[1] = high;
        uint256[] memory weights = new uint256[](2);
        weights[0] = 0.5e18;
        weights[1] = 0.5e18;
        pool = IndexPool(
            indexFactory.create("H", "H", list, weights, 3e15, address(hook), 1_000_000)
        );
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100_000e18;
        amounts[1] = 100_000e18;
        for (uint256 index; index < 2; index++) {
            TestAsset(list[index]).mint(address(this), 100_000e18);
            TestAsset(list[index]).approve(address(pool), type(uint256).max);
        }
        pool.start(amounts, 1e24, FAR);
    }

    /// The venue pays the treasury's pending cut mid-hop. The cut must not make a route that
    /// delivered too little look good, and when the route is good it stays uncounted.
    function _assertCutIsNotOutput(SzrTreasury.Hop[] memory route, uint256 cut) internal {
        coin.mint(address(treasury), 20e18);
        vm.expectRevert(SzrTreasury.BelowMinimum.selector);
        treasury.back(address(coin), 10e18, route, 10e18, FAR);
        // The same route with a fair minimum: only the venue's own output is backed.
        (uint256 backed, uint256 fee) = treasury.back(address(coin), 10e18, route, 9e18, FAR);
        assertLt(backed + fee, 10e18, "less than the input, with the cut not counted");
        assertEq(backing.balanceOf(address(treasury)), cut, "the payout stays here");
        assertEq(coin.balanceOf(address(treasury)), 10e18);
    }

    function test_aV4HooksPayoutOfTheCutIsNotCounted() public {
        (IndexPool owing, uint256 cut) = _owing();
        PoolKey memory key = _payoutV4Pool(owing);
        _assertCutIsNotOutput(_route(_v4Hop(key, address(backing))), cut);
    }

    function test_anIndexPoolHooksPayoutOfTheCutIsNotCounted() public {
        (IndexPool owing, uint256 cut) = _owing();
        IndexPool pool = _payoutIndexPool(owing);
        _assertCutIsNotOutput(_one(address(pool), address(backing)), cut);
    }

    function test_aMetricPoolsPayoutOfTheCutIsNotCounted() public {
        (IndexPool owing, uint256 cut) = _owing();
        HostileMetric hostile = new HostileMetric(address(coin), address(backing));
        metricFactory.register(address(hostile));
        // The pool pays nothing and, mid-swap, pays the treasury's pending cut.
        hostile.aim(address(owing), abi.encodeCall(owing.payProtocol, (address(backing))));
        coin.mint(address(treasury), 10e18);
        vm.expectRevert(SzrTreasury.BelowMinimum.selector);
        treasury.back(
            address(coin),
            10e18,
            _route(_metricHop(address(hostile), address(backing))),
            cut,
            FAR
        );
    }

    function test_aPartlyFilledNativeHopWrapsTheUnspentEtherBack() public {
        // Liquidity only within 60 ticks, so a large sale of ETH fills in part.
        (address low, address high) = _sorted(address(0), address(coin));
        PoolKey memory narrow =
            PoolKey(Currency.wrap(low), Currency.wrap(high), 3_000, 60, IHooks(address(0)));
        manager.initialize(narrow, uint160(1 << 96));
        provider.modifyLiquidity{ value: 100e18 }(
            narrow, IPoolManager.ModifyLiquidityParams(-60, 60, int256(1_000e18), 0), ""
        );
        PoolKey memory deep = _v4Pool(address(backing), address(coin));
        SzrTreasury.Hop[] memory route =
            _route(_v4Hop(narrow, address(coin)), _v4Hop(deep, address(backing)));
        backing.mint(address(treasury), 100e18);
        (uint256 backed, uint256 fee) = treasury.back(address(backing), 100e18, route, 1, FAR);
        assertLt(backed + fee, 10e18, "only a sliver filled");
        assertGt(backing.balanceOf(address(treasury)), 90e18, "the rest was wrapped back");
        assertEq(address(treasury).balance, 0, "no ether kept");
    }

    function test_theFactoryIsTheTreasurys() public view {
        assertEq(treasury.indexFactory().protocol(), address(treasury));
        assertEq(address(treasury.indexFactory().liquidity()), address(locker));
        assertEq(address(treasury.metricFactory()), address(metricFactory));
    }
}

/// @dev Retiring through a pool of the arbitrage hook, whose search runs inside the hop.
contract SzrTreasuryHookTest is ArbitrageWorld {
    uint256 internal constant FAR = type(uint256).max;
    uint256 internal constant SHORT_GAS = 300_000;
    SzrTreasury internal treasury;

    function setUp() public override {
        super.setUp();
        treasury = _treasury(core, manager, IMetricFactory(address(1)));
    }

    function _route() internal view returns (SzrTreasury.Hop[] memory route) {
        route = new SzrTreasury.Hop[](1);
        route[0] = SzrTreasury.Hop(SzrTreasury.Venue.V4, usdPool, address(0), address(szr));
    }

    function test_retireThroughTheHookedSzrPoolRunsTheSearch() public {
        usd.mint(address(treasury), 50_000e18);
        uint256 inventory = core.unreleasedSupply();
        uint256 supply = core.activeSupply();
        uint256 retired = treasury.retire(address(usd), 50_000e18, _route(), 1, FAR);
        // The buy left SZR dear in this pool, so the hook's cycle retired profit on top.
        assertGt(core.unreleasedSupply() - inventory, retired, "the search ran");
        assertLt(core.activeSupply(), supply - retired, "and retired more");
        assertEq(szr.balanceOf(address(treasury)), 0);
        assertEq(usd.balanceOf(address(treasury)), 0);
        _assertHookEmpty();
    }

    function test_tooLittleGasForTheRequiredCycleRevertsInsufficientGas() public {
        usd.mint(address(treasury), 50_000e18);
        uint256 inventory = core.unreleasedSupply();
        (bool ok, bytes memory data) = address(treasury).call{ gas: SHORT_GAS }(
            abi.encodeCall(treasury.retire, (address(usd), 50_000e18, _route(), 1, FAR))
        );
        assertFalse(ok);
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "the hook's own error");
        assertEq(usd.balanceOf(address(treasury)), 50_000e18, "nothing moved");
        assertEq(core.unreleasedSupply(), inventory);
        // With enough gas the same call goes through.
        treasury.retire{ gas: 9_000_000 }(address(usd), 50_000e18, _route(), 1, FAR);
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
}
