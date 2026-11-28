// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { OpenArbitrageMarket } from "../script/OpenArbitrageMarket.s.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

contract ArbitrageScriptLimitsTest is MarketsWorld {
    address internal owner = address(0xA7);

    function _full(address[] memory tokens, uint256 leadersPer, uint32 gas, uint256 market)
        internal
        returns (OpenArbitrageMarket.Config memory plan)
    {
        plan.hook = hook;
        plan.owner = owner;
        plan.recipient = address(0xA8);
        plan.market = market;
        plan.tokens = tokens;
        plan.gasLimit = gas;
        uint256 count = tokens.length * 8 * leadersPer;
        plan.pools = new PoolKey[](count);
        plan.prices = new uint160[](count);
        plan.groups = new OpenArbitrageMarket.Group[](tokens.length * 8);
        plan.limits = new OpenArbitrageMarket.Limit[](tokens.length);
        uint256 n;
        for (uint256 t; t < tokens.length; t++) {
            plan.limits[t] = OpenArbitrageMarket.Limit(tokens[t], 1e15);
        }
        uint24[3] memory fees = [uint24(3_000), 500, 10_000];
        for (uint256 p; p < 8; p++) {
            TestAsset other = partners[p];
            for (uint256 t; t < tokens.length; t++) {
                bytes32[] memory ids = new bytes32[](leadersPer);
                for (uint256 l; l < leadersPer; l++) {
                    plan.pools[n] = _pair(tokens[t], address(other), fees[l], address(hook));
                    plan.prices[n] = uint160(1 << 96);
                    ids[l] = _id(plan.pools[n]);
                    n++;
                }
                plan.groups[p * tokens.length + t] =
                    OpenArbitrageMarket.Group(tokens[t], address(other), ids);
            }
        }
    }

    TestAsset[8] internal partners;

    function _partners() internal {
        for (uint256 p; p < 8; p++) {
            partners[p] = new TestAsset();
            _approve(partners[p]);
        }
    }

    /// A market that is on, with one small group per token, to be changed by a later run.
    function _opened(address[] memory tokens) internal returns (uint256 opened) {
        OpenArbitrageMarket.Config memory plan = _full(tokens, 1, 0, 0);
        uint256 groups = tokens.length;
        // Keep the first partner's pools only.
        PoolKey[] memory pools = new PoolKey[](groups);
        uint160[] memory prices = new uint160[](groups);
        OpenArbitrageMarket.Group[] memory kept = new OpenArbitrageMarket.Group[](groups);
        for (uint256 t; t < groups; t++) {
            kept[t] = plan.groups[t];
            pools[t] = _pair(tokens[t], address(partners[0]), 3_000, address(hook));
            prices[t] = uint160(1 << 96);
        }
        plan.pools = pools;
        plan.prices = prices;
        plan.groups = kept;
        opened = new OpenArbitrageMarket().run(plan);
        assertGt(hook.market(opened).gasLimit, 0, "on");
    }

    function _twoTokens() internal returns (address[] memory tokens) {
        _partners();
        tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
    }

    function _threeTokens() internal returns (address[] memory tokens) {
        _partners();
        TestAsset third = new TestAsset();
        _approve(third);
        hook.setProfitToken(address(third), desk);
        tokens = new address[](3);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        tokens[2] = address(third);
    }

    /// 27-L-2: a market that is on, given the leaders of two full tokens (12.56M), is set up
    /// with no allowance given: the room made first is 13M, where it was 9M.
    function testScriptMakesRoomForTwoFullTokens() public {
        address[] memory tokens = _twoTokens();
        uint256 opened = _opened(tokens);
        OpenArbitrageMarket setup = new OpenArbitrageMarket();
        setup.run(_full(tokens, 3, 0, opened));
        assertEq(hook.minimumGasLimit(opened), 12_560_000, "two full tokens");
        assertEq(hook.market(opened).gasLimit, 12_560_000, "set at the least they need");
    }

    /// A market needing more than the room made refuses, and says so; the allowance asked for
    /// makes room for it.
    function testScriptFailsSafeWithoutRoomAndWorksWithTheAllowance() public {
        address[] memory tokens = _threeTokens();
        uint256 opened = _opened(tokens);
        OpenArbitrageMarket setup = new OpenArbitrageMarket();
        OpenArbitrageMarket.Config memory big = _full(tokens, 1, 0, opened);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        setup.run(big);
        // The refused run left its broadcast open.
        vm.stopBroadcast();
        big.gasLimit = 25_000_000;
        setup.run(big);
        assertEq(hook.minimumGasLimit(opened), 14_680_000, "three tokens");
        assertEq(hook.market(opened).gasLimit, 25_000_000, "the allowance asked for");
    }
}
