// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console2 } from "forge-std/Test.sol";
import { MetricExtensionWorld, SwapPool } from "./MetricLiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The manager funds, adds and removes bins, swaps through Metric and v4, wraps, gives to
/// Core and calls the market; strangers try every entry point, both Metric callbacks, and the
/// pool calls the extension back outside any call the extension made. Calls that fail are
/// fine. A stranger's call that succeeds is recorded so the invariant reports it. The
/// modify-liquidity callback's out-of-turn path is not exercised by the pool, since the mock
/// never makes that call.
contract MetricExtensionHandler is Test {
    uint256 internal constant MIN = 1e9;
    uint256 internal constant KINDS = 19;

    MetricLiquidityExtension internal mext;
    address internal manager;
    Liquidity internal liquidity;
    bool public handedOver;
    SwapPool internal pool;
    TestAsset[3] internal coins;
    address internal szr;
    PoolKey internal route;
    address[3] internal strangers = [address(0x5757), address(0xA11CE), address(0xB0B0)];
    uint256[] public markets;
    uint256 public strangerSuccesses;
    // ETH created out of nothing by `fund`, for the ETH conservation check.
    uint256 public dealt;
    uint256 public adds;
    uint256 public removes;
    uint256 public marketCalls;
    uint256 public toCores;
    // Manager calls that succeeded although the extension must refuse them.
    uint256 public refusedSuccesses;
    uint256 public metricSwaps;
    uint256 internal step;
    // Shares the extension holds, per salt and bin, so removals leave 0 or at least MIN.
    uint256[3][2] public held;
    uint80 internal lastAddSalt;
    // What the pool took in (adds paid, swap input) and sent out, per token.
    uint256[2] public inPool;
    uint256[2] public outPool;
    // The ledger's four sums per salt: paid0, paid1, got0, got1.
    uint256[4][2] public sums;
    // The call being built, read back when it succeeds.
    uint80 internal pSalt;
    uint256[3] internal pShares;
    bool internal pZero;

    constructor(
        MetricLiquidityExtension mext_,
        address manager_,
        Liquidity liquidity_,
        SwapPool pool_,
        TestAsset[3] memory coins_,
        address szr_,
        PoolKey memory route_
    ) {
        mext = mext_;
        manager = manager_;
        liquidity = liquidity_;
        pool = pool_;
        coins = coins_;
        szr = szr_;
        route = route_;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    /// Funding by Liquidity arrives as a plain token transfer.
    function fund(uint256 which, uint256 amount) external {
        _work(which, amount);
        coins[which % 3].mint(address(mext), bound(amount, 0, 1_000e18));
        uint256 eth = bound(amount, 0, 10e18);
        dealt += eth;
        vm.deal(address(mext), address(mext).balance + eth);
    }

    /// A call that is valid by construction for the current manager, so it must succeed.
    function certain(uint256 amount) external {
        _work(amount, amount);
        uint256 balance = address(mext).balance;
        vm.prank(manager);
        (bool ok,) = address(mext).call(abi.encodeCall(mext.wrap, (bound(amount, 0, balance))));
        assertTrue(ok, "the manager's valid call failed");
    }

    /// Every handler call first takes one step of this cycle: add, remove, swap, an allowed
    /// marketCall and toCore, so a run always does each of them as the manager.
    /// The removal reuses the last add's salt, so the shares it takes are held and it removes
    /// something. The handover comes after the first cycle, so every run
    /// crosses it.
    function work(uint256 seed, uint256 amount) external {
        _work(seed, amount);
    }

    function _work(uint256 seed, uint256 amount) internal {
        uint256 turn = step++ % 5;
        if (step == 6) _handOver();
        uint256[5] memory cycle = [uint256(1), 2, 3, 8, 6];
        uint256 kind = cycle[turn];
        if (kind == 2) seed = (seed & ~uint256(16)) | (uint256(lastAddSalt) << 4);
        if (kind == 8) _open();
        _asManager(kind, _data(kind, seed, bound(amount, 1, kind == 6 ? 100e18 : 5_000e18)));
    }

    function act(uint256 kind, uint256 seed, uint256 amount) external {
        _work(seed, amount);
        kind = kind % KINDS;
        if (kind == 12) {
            _handOver();
            return;
        }
        if (kind == 13) {
            _callbacks(seed);
            return;
        }
        if (kind == 14) {
            _sendEther(bound(amount, 1, 1e18));
            return;
        }
        bytes memory data = _data(kind, seed, bound(amount, 1, 5_000e18));
        address stranger = strangers[(seed >> 8) % 3];
        if (seed % 3 == 0) {
            vm.prank(stranger);
            (bool ok,) = address(mext).call(data);
            if (ok) strangerSuccesses++;
            return;
        }
        if (seed % 3 == 1) {
            bytes[] memory batch = new bytes[](1);
            batch[0] = data;
            vm.prank(stranger);
            (bool ok,) = address(mext).call(abi.encodeCall(mext.multicall, (batch)));
            if (ok) strangerSuccesses++;
            return;
        }
        if (kind == 8) _open();
        if (kind == 17) _open();
        _asManager(kind, data);
    }

    function _asManager(uint256 kind, bytes memory data) internal {
        vm.prank(manager);
        (bool ok, bytes memory ret) = address(mext).call(data);
        if (!ok) return;
        if (kind == 6) toCores++;
        if (kind == 8) marketCalls++;
        if (kind == 7) refusedSuccesses++;
        if (kind == 9) refusedSuccesses++;
        if (kind == 10) refusedSuccesses++;
        if (kind == 11) refusedSuccesses++;
        if (kind == 1) _bookAdd(ret);
        if (kind == 2) _bookRemove(ret);
        if (kind == 3) _bookSwap(ret);
    }

    function _bookAdd(bytes memory ret) internal {
        (uint256 paid0, uint256 paid1) = abi.decode(ret, (uint256, uint256));
        adds++;
        lastAddSalt = pSalt;
        inPool[0] += paid0;
        inPool[1] += paid1;
        sums[pSalt][0] += paid0;
        sums[pSalt][1] += paid1;
        for (uint256 i; i < 3; i++) {
            held[pSalt][i] += pShares[i];
        }
    }

    function _bookRemove(bytes memory ret) internal {
        (uint256 got0, uint256 got1) = abi.decode(ret, (uint256, uint256));
        // An empty removal returns nothing, so it is not counted as one.
        if (pShares[0] + pShares[1] + pShares[2] > 0) removes++;
        outPool[0] += got0;
        outPool[1] += got1;
        sums[pSalt][2] += got0;
        sums[pSalt][3] += got1;
        for (uint256 i; i < 3; i++) {
            held[pSalt][i] -= pShares[i];
        }
    }

    function _bookSwap(bytes memory ret) internal {
        (uint256 spent, uint256 received) = abi.decode(ret, (uint256, uint256));
        metricSwaps++;
        inPool[pZero ? 0 : 1] += spent;
        outPool[pZero ? 1 : 0] += received;
    }

    /// Strangers call both Metric callbacks directly, and the pool calls back out of turn.
    function _callbacks(uint256 seed) internal {
        uint256 pick = seed % 3;
        if (pick == 2) {
            (bool ok,) = address(pool).call(abi.encodeCall(pool.callBack, (address(mext))));
            if (ok) strangerSuccesses++;
            return;
        }
        bytes memory data = pick == 0
            ? abi.encodeCall(mext.metricOmmModifyLiquidityCallback, (1, 1, ""))
            : abi.encodeCall(mext.metricOmmSwapCallback, (1, 1, ""));
        vm.prank(strangers[(seed >> 8) % 3]);
        (bool done,) = address(mext).call(data);
        if (done) strangerSuccesses++;
    }

    /// A stranger sends plain ETH. The extension refuses it; if it ever took it, the ether is
    /// accounted for so only the stranger check reports it.
    function _sendEther(uint256 amount) internal {
        address sender = address(0xE7E7);
        vm.deal(sender, 1e18);
        vm.prank(sender);
        (bool ok,) = address(mext).call{ value: amount }("");
        if (!ok) return;
        strangerSuccesses++;
        dealt += amount;
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
        try mext.openMarket() returns (uint256 id) {
            markets.push(id);
        } catch { }
    }

    function _bins() internal pure returns (int256[] memory list) {
        list = new int256[](3);
        list[0] = -1;
        list[1] = 0;
        list[2] = 1;
    }

    function _data(uint256 kind, uint256 seed, uint256 amount) internal returns (bytes memory) {
        if (kind == 0) {
            bool zero = (seed >> 24) % 2 == 0;
            return abi.encodeCall(
                mext.swap, (route, zero, amount, 0, _limit(zero), block.timestamp)
            );
        }
        if (kind == 1) return _addData(seed);
        if (kind == 2) return _removeData(seed);
        if (kind == 3) {
            pZero = (seed >> 24) % 2 == 0;
            return abi.encodeCall(
                mext.swapMetric, (address(pool), pZero, amount, 0, 0, block.timestamp)
            );
        }
        if (kind == 4) return abi.encodeCall(mext.wrap, (amount % 5e18));
        if (kind == 5) return abi.encodeCall(mext.unwrap, (amount % 5e18));
        if (kind == 6) {
            address[3] memory assets = [address(coins[2]), szr, address(coins[0])];
            return abi.encodeCall(mext.toCore, (assets[(seed >> 48) % 3], amount));
        }
        if (kind == 15) return abi.encodeCall(mext.addPool, (address(pool)));
        if (kind == 16) return abi.encodeCall(mext.registerRoute, (route));
        if (kind == 17) return abi.encodeCall(mext.openMarket, ());
        if (kind == 18) return abi.encodeCall(mext.unlockCallback, (""));
        uint256 id = markets.length == 0 ? 0 : markets[(seed >> 32) % markets.length];
        address[4] memory who = [address(0x5757), address(0xBEEF), address(0xA11CE), manager];
        return abi.encodeCall(mext.marketCall, (_market(kind, id, who[(seed >> 40) % 4])));
    }

    function _addData(uint256 seed) internal returns (bytes memory) {
        pSalt = uint80((seed >> 4) % 2);
        uint256[] memory shares = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            shares[i] = MIN + uint256(keccak256(abi.encode(seed, i))) % 50e18;
            pShares[i] = shares[i];
        }
        uint256 max = type(uint256).max;
        return abi.encodeCall(
            mext.addLiquidity,
            (address(pool), pSalt, _bins(), shares, max, max, block.timestamp)
        );
    }

    /// Takes only an amount that leaves nothing or at least the pool's minimum in the bin,
    /// so the mock does not refuse most removals.
    function _removeData(uint256 seed) internal returns (bytes memory) {
        pSalt = uint80((seed >> 4) % 2);
        uint256[] memory shares = new uint256[](3);
        for (uint256 i; i < 3; i++) {
            uint256 have = held[pSalt][i];
            uint256 take;
            if (have >= MIN) {
                take = MIN + uint256(keccak256(abi.encode(seed, i))) % (have - MIN + 1);
                if (have - take < MIN) take = have;
            }
            shares[i] = take;
            pShares[i] = take;
        }
        return abi.encodeCall(
            mext.removeLiquidity, (address(pool), pSalt, _bins(), shares, 0, 0, block.timestamp)
        );
    }

    /// The owner calls the extension must refuse, and one it may forward.
    function _market(uint256 kind, uint256 id, address target)
        internal
        view
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
        address[] memory chosen = new address[](1);
        chosen[0] = address(coins[1]);
        return abi.encodeWithSignature("setTokens(uint256,address[])", id, chosen);
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne
            ? 4_295_128_740
            : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;
    }
}

/// @dev Whatever the manager and strangers do, every unit of each asset stays with an allowed
/// holder (the Metric pool among them), the pool's balances equal what the manager's calls
/// moved through it, the extension's ledger matches those calls, no stranger or out-of-turn
/// callback succeeds, and every market the extension opens keeps it as owner and recipient.
contract MetricLiquidityExtensionInvariantTest is MetricExtensionWorld {
    MetricExtensionHandler internal handler;
    address[13] internal allowed;
    address[4] internal assets;
    // What the supply of each asset held outside the allowed set at the start.
    uint256[4] internal outside;
    uint256 internal ethOutside;
    uint256 internal start0;
    uint256 internal start1;

    function setUp() public override {
        super.setUp();
        PoolKey memory open = _openPool(address(backing), address(coin), 3_000);
        mext.registerRoute(open);
        backing.mint(address(mext), HELD);
        szr.transfer(address(mext), 1_000e18);
        TestAsset[3] memory coins = [coin, usd, TestAsset(address(backing))];
        handler = new MetricExtensionHandler(
            mext, address(this), locker, pool, coins, address(szr), open
        );
        allowed = [
            address(ext),
            address(mext),
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
            address(pool)
        ];
        assets = [address(coin), address(usd), address(backing), address(szr)];
        for (uint256 a; a < assets.length; a++) {
            outside[a] = TestAsset(assets[a]).totalSupply() - _allowedHeld(assets[a]);
        }
        ethOutside = _allowedHeld(address(0));
        start0 = t0.balanceOf(address(pool));
        start1 = t1.balanceOf(address(pool));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MetricExtensionHandler.fund.selector;
        selectors[1] = MetricExtensionHandler.act.selector;
        selectors[2] = MetricExtensionHandler.certain.selector;
        selectors[3] = MetricExtensionHandler.work.selector;
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

    /// Catches a pool that takes more than the extension measured, which the allowed-holder
    /// check cannot see because the pool is itself allowed.
    function invariant_poolBalancesMatchTheManagersCalls() public view {
        assertEq(
            t0.balanceOf(address(pool)),
            start0 + handler.inPool(0) - handler.outPool(0),
            "pool token0 moved outside the manager's calls"
        );
        assertEq(
            t1.balanceOf(address(pool)),
            start1 + handler.inPool(1) - handler.outPool(1),
            "pool token1 moved outside the manager's calls"
        );
    }

    function invariant_ledgerMatchesTheCalls() public view {
        for (uint256 salt; salt < 2; salt++) {
            (uint256 in0, uint256 in1, uint256 out0, uint256 out1) =
                mext.ledger(address(pool), uint80(salt));
            assertEq(in0, handler.sums(salt, 0), "ledger paid0");
            assertEq(in1, handler.sums(salt, 1), "ledger paid1");
            assertEq(out0, handler.sums(salt, 2), "ledger got0");
            assertEq(out1, handler.sums(salt, 3), "ledger got1");
        }
    }

    function invariant_onlyTheManagerChangesState() public view {
        assertEq(handler.strangerSuccesses(), 0, "a stranger's call succeeded");
    }

    /// Per salt and bin, the pool's shares of the extension are what the handler tracked.
    function invariant_poolSharesMatchTheCalls() public view {
        for (uint256 salt; salt < 2; salt++) {
            for (uint256 i; i < 3; i++) {
                assertEq(
                    pool.sharesOf(address(mext), uint80(salt), int16(int256(i)) - 1),
                    handler.held(salt, i),
                    "pool shares differ from the calls"
                );
            }
        }
    }

    function invariant_refusedCallsNeverSucceed() public view {
        assertEq(handler.refusedSuccesses(), 0, "the manager got a refused call through");
    }

    function invariant_marketsStayWithTheExtension() public view {
        for (uint256 index; index < handler.marketCount(); index++) {
            uint256 market = handler.markets(index);
            assertEq(hook.market(market).owner, address(mext), "owner moved");
            assertEq(hook.market(market).recipient, address(mext), "recipient moved");
        }
    }

    /// Reverts are swallowed by the handler, so a run that never added, removed or swapped
    /// would pass the rest vacuously.
    function afterInvariant() public view {
        console2.log("adds", handler.adds());
        console2.log("removes", handler.removes());
        console2.log("metric swaps", handler.metricSwaps());
        console2.log("market calls", handler.marketCalls());
        console2.log("to core", handler.toCores());
        console2.log("handed over", handler.handedOver());
        assertTrue(handler.handedOver(), "the handover never happened");
        assertGt(handler.marketCalls(), 0, "no allowed marketCall succeeded");
        assertGt(handler.toCores(), 0, "no toCore succeeded");
        assertGt(handler.adds(), 0, "no add succeeded");
        assertGt(handler.removes(), 0, "no removal succeeded");
        assertGt(handler.metricSwaps(), 0, "no Metric swap succeeded");
    }
}
