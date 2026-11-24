// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MultiWorld } from "./ArbitrageMultiToken.t.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev Owns a market and, in one external call, swaps, changes the market so the pool has
/// no book, and swaps again. Foundry clears transient storage between a test's top-level
/// calls, so only a call made from a contract reaches same-transaction staleness.
contract OwnerBatch {
    ArbitrageApi internal hook;
    PoolSwapTest internal swapper;
    uint256 internal id;
    PoolKey internal pool;
    TestAsset internal coin;
    TestAsset internal weth;
    TestAsset internal usd;
    TestAsset internal dai;
    address internal treasury;

    constructor(
        ArbitrageApi hook_,
        PoolSwapTest swapper_,
        uint256 id_,
        PoolKey memory pool_,
        TestAsset[4] memory tokens,
        address treasury_
    ) {
        hook = hook_;
        swapper = swapper_;
        id = id_;
        pool = pool_;
        (coin, weth, usd, dai) = (tokens[0], tokens[1], tokens[2], tokens[3]);
        treasury = treasury_;
    }

    function _swap() internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(coin);
        PoolSwapTest.TestSettings memory settings;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(50_000e18),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
    }

    function _paid() internal view returns (uint256) {
        return weth.balanceOf(treasury) + usd.balanceOf(treasury);
    }

    /// USD alone, with no leader on either side of the pool: no book is left for it.
    function _leaveNoBook() internal {
        address[] memory only = new address[](1);
        only[0] = address(usd);
        hook.setTokens(id, only);
        uint128 profit = hook.minimumProfit(id, address(usd));
        uint64 edge = hook.market(id).minimumEdge;
        uint32 allowance = hook.market(id).gasLimit;
        hook.setLimits(id, address(usd), 0, profit, edge);
        bytes32[] memory none = new bytes32[](0);
        hook.setLeaders(id, address(usd), address(coin), none);
        hook.setLeaders(id, address(usd), address(dai), none);
        hook.setLimits(id, address(usd), allowance, profit, edge);
    }

    function run() external returns (uint256 paidA, uint256 paidB) {
        hook.acceptOwnership(id);
        coin.approve(address(swapper), type(uint256).max);
        _swap();
        paidA = _paid();
        _leaveNoBook();
        _swap();
        paidB = _paid() - paidA;
    }
}

/// @dev The books kept for the search after a swap never outlive it. Two clears guard that:
/// the search after the swap clears what it recalls, and the search before the next swap
/// clears first. Either one alone is enough, so removing one leaves this test passing; it
/// fails only when both are removed, and pins that at least one stays.
contract ArbitrageGasSavingStaleTest is MultiWorld {
    function testBooksOfAnEarlierSwapAreNotSearchedAfterTheMarketChanged() public {
        TestAsset[4] memory tokens = [coin, backing, usd, dai];
        OwnerBatch batch = new OwnerBatch(hook, swapper, id, stable, tokens, treasury);
        vm.prank(team);
        hook.nominateOwner(id, address(batch));
        coin.mint(address(batch), 200_000e18);
        (uint256 first, uint256 second) = batch.run();
        assertGt(first, 0, "the first swap's books were paid");
        assertEq(second, 0, "no book, no search");
    }
}
