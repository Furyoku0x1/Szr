// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { SearchPart } from "../src/arbitrage/ArbitrageSearch.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Guards that other tests pin only on the monolithic probe, pinned on the real split
/// hook (docs/specs/hook-fund-safety-tests.md, items 3 and 4; 28-T-5, 28-T-1). Nothing here
/// etches the probe over the hook.
contract ArbitrageRealHookGuardsTest is WrapWorld {
    function _countBoth() internal {
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        vm.prank(team);
        hook.setTokens(id, tokens);
    }

    /// A swap in a pool of ETH and WETH opens no book at all: the pool has no token to count
    /// profit in, so nothing is searched, before or after the swap.
    function testASwapInAnEthWethPoolSearchesNothing() public {
        _countBoth();
        PoolKey memory both = _make(address(0), address(backing), 3_000, address(hook));
        assertEq(hook.partnerOf(_id(both)), address(0), "not searched");
        vm.expectCall(address(hook), abi.encodeWithSelector(SearchPart.search.selector), 0);
        vm.recordLogs();
        _in(both, address(0), 1e15);
        _in(both, address(backing), 1e15);
        assertEq(vm.getRecordedLogs().length > 0, true, "the swaps ran");
    }
}
