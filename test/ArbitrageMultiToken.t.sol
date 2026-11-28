// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A swap searches in every token its market counts profit in that a cycle through
/// its pool can end in (docs/specs/hook-multi-token-search.md). The world's market counts
/// in WETH and USD. `coin` and `dai` stand for two stablecoins neither of which is counted
/// in, with a pool of their own that is the market's connecting pool between them.
abstract contract MultiWorld is MarketsWorld {
    TestAsset internal dai;
    PoolKey internal stable;
    PoolKey internal wethDai;
    PoolKey internal usdCoin;
    PoolKey internal usdDai;

    function setUp() public virtual override {
        super.setUp();
        dai = _newAsset();
        _approve(dai);
        wethDai = _create(address(backing), address(dai), 3_000);
        _lead(address(backing), address(dai), _list(_id(wethDai)));
        usdCoin = _create(address(usd), address(coin), 3_000);
        usdDai = _create(address(usd), address(dai), 3_000);
        _lead(address(usd), address(coin), _list(_id(usdCoin)));
        _lead(address(usd), address(dai), _list(_id(usdDai)));
        _limits(address(usd), 1e15);
        stable = _create(address(coin), address(dai), 500);
        vm.prank(team);
        hook.setConnector(id, stable, true);
    }

    function _tradeWithGas(PoolKey memory pool, address input, uint256 gas)
        internal
        returns (bool ok, bytes memory data)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams(
            zeroForOne,
            -int256(50_000e18),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        (ok, data) = address(swapper).call{ gas: gas }(
            abi.encodeCall(swapper.swap, (pool, params, settings, ""))
        );
    }

    /// The pool manager wraps a hook's error, so look for its selector inside the data.
    function _has(bytes memory data, bytes4 wanted) internal pure returns (bool) {
        for (uint256 index; index + 4 <= data.length; index++) {
            bytes4 found = bytes4(
                bytes.concat(data[index], data[index + 1], data[index + 2], data[index + 3])
            );
            if (found == wanted) return true;
        }
        return false;
    }
}

contract ArbitrageMultiTokenTest is MultiWorld {
    /// A pool holding neither token used to be left alone. As the connecting pool between
    /// its two tokens, its swap now opens a book in each, and both are paid out.
    function testStablePoolIsSearchedInEveryToken() public {
        _trade(stable, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        assertGt(usd.balanceOf(treasury), 0, "and in USD");
        assertGt(usd.balanceOf(desk), 0, "with the protocol's share of USD");
        assertEq(coin.balanceOf(treasury), 0, "never in a stablecoin counted in nothing");
        assertEq(dai.balanceOf(treasury), 0);
        _assertNothingHeld();
    }

    /// With only WETH's groups touching it, the stable pool opens one book, centred on
    /// WETH's leader for one of its tokens.
    function testStablePoolWithOneTokenOpensOneBook() public {
        bytes32[] memory none = new bytes32[](0);
        _lead(address(usd), address(coin), none);
        _lead(address(usd), address(dai), none);
        _trade(stable, address(coin), 50_000e18);
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        assertEq(usd.balanceOf(treasury), 0, "not in USD");
        _assertNothingHeld();
    }

    /// No route passes through a pool that is not its market's connecting pool, so its swap
    /// is still left alone.
    function testPoolThatIsNotAConnectorIsNotSearched() public virtual {
        vm.prank(team);
        hook.setConnector(id, stable, false);
        uint256 price = _price(stable);
        _trade(stable, address(coin), 50_000e18);
        assertLt(_price(stable), price, "the swap moved its pool");
        assertEq(backing.balanceOf(treasury), 0, "no search in WETH");
        assertEq(usd.balanceOf(treasury), 0, "nor in USD");
        _assertNothingHeld();
    }

    /// A pool of WETH and USD counts in WETH, the market's first choice, and used to be
    /// searched only in WETH. A gap that only USD's groups can see is now closed too.
    function testPoolHoldingTwoTokensIsSearchedInBoth() public {
        PoolKey memory both = _create(address(backing), address(usd), 3_000);
        assertEq(hook.partnerOf(_id(both)), address(usd), "its own token is WETH");
        // USD's book reaches WETH from `coin` through the market's WETH/coin pool.
        vm.prank(team);
        hook.setConnector(id, first, true);
        _trade(both, address(backing), 50_000e18);
        assertGt(usd.balanceOf(treasury), 0, "paid in USD");
        assertGt(usd.balanceOf(desk), 0, "with the protocol's share of USD");
        _assertNothingHeld();
    }

    /// The reviewer's case. Profit stays a credit until the search ends, so once WETH's book
    /// earned, every cycle of USD's book through WETH used to fail `Unsettled`, five times,
    /// and was benched. Both books earn, and nothing fails.
    function testTwoBooksBothEarnInOneSwap() public {
        PoolKey memory both = _create(address(backing), address(usd), 3_000);
        vm.startPrank(team);
        hook.addVenue(id, publicPool);
        hook.setConnector(id, second, true);
        vm.stopPrank();
        _lead(address(backing), address(usd), _list(_id(both), _id(publicPool)));
        vm.recordLogs();
        _trade(both, address(backing), 50_000e18);
        assertEq(_failures(), 0, "no cycle failed");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        assertGt(usd.balanceOf(treasury), 0, "and in USD");
        _assertNothingHeld();
    }

    /// A cycle prices again every pool it traded, links included. Here the pool that links
    /// WETH's cycle (USD/coin) is a venue of USD's book. Left at its old price there, it
    /// shows USD's book a gap that is gone, and a cycle to close it fails.
    function testLinkTradedInOneBookIsPricedAgainInTheOther() public {
        PoolKey memory both = _create(address(backing), address(usd), 3_000);
        vm.startPrank(team);
        hook.setConnector(id, usdCoin, true);
        hook.setConnector(id, first, true);
        vm.stopPrank();
        _lead(address(backing), address(usd), _list(_id(both)));
        vm.recordLogs();
        _trade(both, address(backing), 50_000e18);
        assertEq(_failures(), 0, "no cycle failed on a stale price");
        assertGt(backing.balanceOf(treasury), 0, "paid in WETH");
        _assertNothingHeld();
    }

    /// Every book a swap can open is in the gas it must bring, and the failure budget is
    /// counted once, not per token.
    function testGasForSwapCountsEveryBook() public {
        uint256 both = hook.gasForSwap(id);
        address[] memory only = new address[](1);
        only[0] = address(backing);
        vm.prank(team);
        hook.setTokens(id, only);
        uint256 one = hook.gasForSwap(id);
        assertGt(both, one, "a second token costs more");
        assertLt(both, one * 2, "but far less than a second search");
    }

    /// A swap meeting a gap with too little gas fails as a whole, whichever book the gap
    /// is in, and one with the gas it was told to bring, or more, never does.
    function testShortGasFailsAndMoreGasNeverDoes() public {
        uint256 snapshot = vm.snapshotState();
        (bool ok, bytes memory data) = _tradeWithGas(stable, address(coin), 2_000_000);
        assertFalse(ok, "short swap fails");
        assertTrue(_has(data, ArbitrageLogic.InsufficientGas.selector), "for gas");
        uint256 enough = hook.gasForSwap(id) + 1_000_000;
        uint256[3] memory limits = [enough, enough + 3_000_000, 30_000_000];
        for (uint256 index; index < limits.length; index++) {
            vm.revertToState(snapshot);
            (ok,) = _tradeWithGas(stable, address(coin), limits[index]);
            assertTrue(ok, "enough gas passes");
            assertGt(backing.balanceOf(treasury), 0, "and closes the gap");
        }
    }
}
