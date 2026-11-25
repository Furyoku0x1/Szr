// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { MetricExtensionWorld, SwapPool } from "./MetricLiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The manager funds, swaps on v4 and Metric, deploys, withdraws, wraps, gives to Core
/// and calls the market; strangers try every entry point, and strangers and the Metric pool
/// call the Metric swap callback out of turn. Calls that fail are fine. A stranger's call that
/// succeeds is recorded so the invariant reports it, except `donate`, which anyone may call:
/// a donor gives pool tokens, WETH and ETH in its own action.
contract ExtensionHandler is Test {
    V4LiquidityExtension internal ext;
    address internal manager;
    Liquidity internal liquidity;
    bool internal handedOver;
    TestAsset[3] internal coins;
    address internal szr;
    PoolKey[2] internal pools;
    SwapPool internal metricPool;
    // The last slot takes the old manager after the handover.
    address[3] internal strangers = [address(0x5757), address(0xA11CE), address(0xB0B0)];
    uint256[] public markets;
    uint256 public strangerSuccesses;
    // ETH created out of nothing by `fund`, for the ETH conservation check.
    uint256 public dealt;

    constructor(
        V4LiquidityExtension ext_,
        address manager_,
        Liquidity liquidity_,
        TestAsset[3] memory coins_,
        address szr_,
        PoolKey memory one,
        PoolKey memory two,
        SwapPool metricPool_
    ) {
        ext = ext_;
        manager = manager_;
        liquidity = liquidity_;
        coins = coins_;
        szr = szr_;
        pools[0] = one;
        pools[1] = two;
        metricPool = metricPool_;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /// Funding by Liquidity arrives as a plain token transfer.
    function fund(uint256 which, uint256 amount) external {
        coins[which % 3].mint(address(ext), bound(amount, 0, 1_000e18));
        uint256 eth = bound(amount, 0, 10e18);
        dealt += eth;
        vm.deal(address(ext), address(ext).balance + eth);
    }

    /// Anyone may give a pool token, WETH or ETH. A gift that is allowed must arrive whole;
    /// one that isn't is skipped, since the giver would keep what was minted for it.
    function donate(uint256 which, uint256 amount) external {
        address giver = address(0xD0D0);
        uint256 pick = which % 4;
        address asset = pick == 3 ? address(0) : address(coins[pick]);
        if (!ext.donatable(asset)) {
            if (asset != ext.weth()) return;
        }
        bool ok;
        if (asset == address(0)) {
            uint256 eth = bound(amount, 0, 10e18);
            dealt += eth;
            vm.deal(giver, eth);
            vm.prank(giver);
            (ok,) = address(ext).call{ value: eth }(abi.encodeCall(ext.donate, (asset, eth)));
        } else {
            uint256 gift = bound(amount, 0, 1_000e18);
            coins[pick].mint(giver, gift);
            vm.prank(giver);
            coins[pick].approve(address(ext), gift);
            vm.prank(giver);
            (ok,) = address(ext).call(abi.encodeCall(ext.donate, (asset, gift)));
        }
        assertTrue(ok, "an allowed donation failed");
    }

    /// A call that is valid by construction for the current manager, so it must succeed.
    /// This fails if the gate refuses the manager, whatever the other calls do.
    function certain(uint256 amount) external {
        uint256 held = address(ext).balance;
        vm.prank(manager);
        (bool ok,) = address(ext).call(abi.encodeCall(ext.wrap, (bound(amount, 0, held))));
        assertTrue(ok, "the manager's valid call failed");
    }

    function act(uint256 kind, uint256 seed, uint256 amount) external {
        if (kind % 14 == 13) {
            _handOver();
            return;
        }
        bytes memory data = _call(kind % 14, seed, bound(amount, 1, 5_000e18));
        if (seed % 3 == 0) {
            vm.prank(strangers[(seed >> 8) % 3]);
            (bool ok,) = address(ext).call(data);
            if (ok) strangerSuccesses++;
            return;
        }
        if (seed % 3 == 1) {
            bytes[] memory batch = new bytes[](1);
            batch[0] = data;
            vm.prank(strangers[(seed >> 8) % 3]);
            (bool ok,) = address(ext).call(abi.encodeCall(ext.multicall, (batch)));
            if (ok) strangerSuccesses++;
            return;
        }
        if (kind % 14 == 8) _open();
        vm.prank(manager);
        address(ext).call(data);
    }

    /// Liquidity's manager passes the role on; the old one is then a stranger.
    function _handOver() internal {
        if (handedOver) return;
        handedOver = true;
        address heir = address(0xFEED);
        vm.prank(manager);
        liquidity.nominateManager(heir);
        vm.prank(heir);
        liquidity.acceptManager();
        strangers[2] = manager;
        manager = heir;
    }

    function _open() internal {
        vm.prank(manager);
        try ext.openMarket() returns (uint256 id) {
            markets.push(id);
        } catch { }
    }

    function _call(uint256 kind, uint256 seed, uint256 amount)
        internal
        view
        returns (bytes memory)
    {
        // Separate bits of the seed pick the pool, the direction, the market and the target.
        uint256 index = (seed >> 16) % 2;
        bool zeroForOne = (seed >> 24) % 2 == 0;
        uint256 id = markets.length == 0 ? 0 : markets[(seed >> 32) % markets.length];
        address[4] memory who = [address(0x5757), address(0xBEEF), address(0xA11CE), manager];
        address target = who[(seed >> 40) % 4];
        if (kind == 0) {
            return abi.encodeCall(
                ext.swap,
                (pools[index], zeroForOne, amount, 0, _limit(zeroForOne), block.timestamp)
            );
        }
        if (kind == 1) {
            return abi.encodeCall(
                ext.deploy,
                (index, uint128(amount), type(uint256).max, type(uint256).max, block.timestamp)
            );
        }
        if (kind == 2) {
            return abi.encodeCall(ext.withdraw, (index, uint128(amount), 0, 0, block.timestamp));
        }
        if (kind == 3) return abi.encodeCall(ext.collect, (index));
        if (kind == 4) return abi.encodeCall(ext.wrap, (amount % 5e18));
        if (kind == 5) return abi.encodeCall(ext.unwrap, (amount % 5e18));
        if (kind == 6) {
            address[3] memory assets = [address(coins[2]), szr, address(coins[0])];
            return abi.encodeCall(ext.toCore, (assets[(seed >> 48) % 3], amount));
        }
        if (kind == 12) {
            return abi.encodeCall(
                ext.swapMetric, (address(metricPool), zeroForOne, amount, 0, 0, block.timestamp)
            );
        }
        return abi.encodeCall(ext.marketCall, (_market(kind, id, target)));
    }

    /// A Metric swap the manager can afford and the pool can fill, so it must succeed.
    function swapOnMetric(uint256 seed, uint256 amount) external {
        _swapOnMetric(seed, amount);
    }

    function _swapOnMetric(uint256 seed, uint256 amount) internal {
        bool zeroForOne = seed % 2 == 0;
        (address input, address output) = zeroForOne
            ? (metricPool.token0(), metricPool.token1())
            : (metricPool.token1(), metricPool.token0());
        uint256 most = TestAsset(input).balanceOf(address(ext));
        uint256 room = TestAsset(output).balanceOf(address(metricPool));
        if (room < most) most = room;
        if (most == 0) return;
        uint256 size = bound(amount, 1, most);
        vm.prank(manager);
        (bool ok,) = address(ext)
            .call(
                abi.encodeCall(
                    ext.swapMetric,
                    (address(metricPool), zeroForOne, size, size, 0, block.timestamp)
                )
            );
        assertTrue(ok, "the manager's valid Metric swap failed");
    }

    /// The Metric swap callback pays only the pool being called, and only while it is.
    /// Foundry clears transient storage between the handler's calls, so a pool calling back
    /// while another swap is active is tested inside one swap, in
    /// `V4LiquidityExtensionMetricTest`.
    function callBack(uint256 seed) external {
        vm.prank(strangers[seed % 3]);
        (bool ok,) =
            address(ext).call(abi.encodeCall(ext.metricOmmSwapCallback, (1e18, 1e18, "")));
        if (ok) strangerSuccesses++;
        try metricPool.callBack(address(ext)) {
            strangerSuccesses++;
        } catch { }
    }

    /// The owner calls the extension must refuse, and one it may forward.
    function _market(uint256 kind, uint256 id, address target)
        internal
        pure
        returns (bytes memory)
    {
        if (kind == 7) {
            return abi.encodeWithSignature("setRecipient(uint256,address)", id, target);
        }
        if (kind == 9) {
            return abi.encodeWithSignature("nominateOwner(uint256,address)", id, target);
        }
        if (kind == 10) return abi.encodeWithSignature("acceptOwnership(uint256)", id);
        if (kind == 11) return abi.encodeWithSignature("openMarket(address)", target);
        return abi.encodeWithSignature("untrack(uint256,bytes32)", id, bytes32(0));
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne
            ? 4_295_128_740
            : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    }
}

/// @dev Whatever the manager and strangers do, every unit of each asset stays with the
/// extension, the pool manager, Core, Liquidity, WETH (for ETH), the treasury that takes the
/// hook's share of market profit, the Metric pool, the idle Metric extension, and the test's
/// own LP and swapper accounts, only the
/// current manager changes state, and every market the extension opens keeps the extension
/// as owner and recipient.
contract LiquidityExtensionInvariantTest is MetricExtensionWorld {
    ExtensionHandler internal handler;
    address[13] internal allowed;
    address[4] internal assets;
    // What the supply of each asset held outside the allowed set at the start.
    uint256[4] internal outside;
    uint256 internal ethOutside;

    function setUp() public override {
        super.setUp();
        PoolKey memory open = _openPool(address(backing), address(coin), 3_000);
        _route(open);
        _route(first);
        // An ETH route, so that ETH is donatable and the donor's ETH gifts are fuzzed.
        _route(_openPool(address(0), address(coin), 3_000));
        ext.addPosition(open, -600, 600);
        ext.addPosition(first, -600, 600);
        ext.addPool(address(pool));
        TestAsset[3] memory coins = [coin, usd, TestAsset(address(backing))];
        handler = new ExtensionHandler(
            ext, address(this), locker, coins, address(szr), open, first, pool
        );
        allowed = [
            address(ext),
            address(manager),
            address(core),
            address(locker),
            address(this),
            alice,
            bob,
            address(provider),
            address(swapper),
            address(backing),
            treasury,
            address(mext),
            address(pool)
        ];
        assets = [address(coin), address(usd), address(backing), address(szr)];
        for (uint256 a; a < assets.length; a++) {
            outside[a] = TestAsset(assets[a]).totalSupply() - _allowedHeld(assets[a]);
        }
        ethOutside = _allowedHeld(address(0));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ExtensionHandler.fund.selector;
        selectors[1] = ExtensionHandler.act.selector;
        selectors[2] = ExtensionHandler.certain.selector;
        selectors[3] = ExtensionHandler.donate.selector;
        selectors[4] = ExtensionHandler.callBack.selector;
        selectors[5] = ExtensionHandler.swapOnMetric.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function _allowedHeld(address asset) internal view returns (uint256 total) {
        for (uint256 w; w < allowed.length; w++) {
            total += asset == address(0)
                ? allowed[w].balance
                : TestAsset(asset).balanceOf(allowed[w]);
        }
    }

    /// Only the handler mints, and only to the extension, so a transfer to any other address
    /// makes the allowed holders fall short of the supply.
    function invariant_everyUnitStaysWithAllowedHolders() public view {
        for (uint256 a; a < assets.length; a++) {
            assertEq(
                _allowedHeld(assets[a]),
                TestAsset(assets[a]).totalSupply() - outside[a],
                "a token left to a stranger"
            );
        }
        assertEq(
            _allowedHeld(address(0)), ethOutside + handler.dealt(), "ether left to a stranger"
        );
    }

    function invariant_onlyTheManagerChangesState() public view {
        assertEq(handler.strangerSuccesses(), 0, "a stranger's call succeeded");
    }

    function invariant_marketsStayWithTheExtension() public view {
        for (uint256 index; index < handler.marketCount(); index++) {
            uint256 market = handler.markets(index);
            assertEq(hook.market(market).owner, address(ext), "owner moved");
            assertEq(hook.market(market).recipient, address(ext), "recipient moved");
        }
    }
}
