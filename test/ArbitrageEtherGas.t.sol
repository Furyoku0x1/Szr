// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { EtherWorld } from "./ArbitrageEther.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev The gas reserves per venue must hold for the largest book an ether token can have:
/// the pool, the other leaders of its group and the first leader of each other group under
/// ETH, and the same again under WETH.
contract ArbitrageEtherGasTest is EtherWorld {
    uint24[3] internal fees = [uint24(100), 500, 10_000];

    function _leaders(address base, address partner) internal returns (bytes32[] memory list) {
        list = new bytes32[](3);
        for (uint256 index; index < 3; index++) {
            PoolKey memory pool = _make(base, partner, fees[index], address(0));
            _venue(pool);
            list[index] = _id(pool);
        }
        _lead(base, partner, list);
    }

    /// Another group under each ether token, with the pool two hops away that connects it.
    function _otherGroup(address partner) internal {
        PoolKey memory cross = _make(partner, address(team0), 500, address(0));
        vm.prank(team);
        hook.setConnector(id, cross, true);
        PoolKey memory eth = _make(address(0), partner, 500, address(0));
        PoolKey memory weth = _make(address(backing), partner, 500, address(0));
        _venue(eth);
        _venue(weth);
        _lead(address(0), partner, _list(_id(eth)));
        _lead(address(backing), partner, _list(_id(weth)));
    }

    /// Eight groups under each ether token, three leaders in the searched pool's own, and
    /// a searched pool that leads nothing, so a search prices 21 venues.
    function _fullBook() internal returns (PoolKey memory hooked) {
        _etherMarket(true);
        hooked = _make(address(0), address(team0), 3_000, address(hook));
        _leaders(address(0), address(team0));
        _leaders(address(backing), address(team0));
        for (uint256 index; index < 7; index++) {
            TestAsset partner = new TestAsset();
            _approve(partner);
            _otherGroup(address(partner));
        }
        _limits(address(0), 1e15);
        _limits(address(backing), 1e15);
    }

    /// Reading the prices and ranking the venues, each read for the first time, cost less
    /// than the search holds back for that many venues, and the allowance counts them all.
    function testScanCostStaysWithinItsAllowanceAtTheMostEtherVenues() public {
        PoolKey memory hooked = _fullBook();
        // A gap, so that every venue is taken all the way through to the depth reads. The
        // market is switched off while the pool moves so that no search closes it.
        vm.startPrank(team);
        hook.setLimits(id, address(0), 0, 1e15, 1.0001e18);
        vm.stopPrank();
        _in(hooked, address(team0), 20_000e18);
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), address(hook));
        // Mark what the setup touched as untouched, so the reads cost what a first read does.
        vm.cool(address(manager));
        vm.cool(address(hook));
        vm.cool(address(core));
        ArbitrageProbe probe = ArbitrageProbe(payable(address(hook)));
        (uint256 book, uint256 best, uint256 venues, uint256 each, uint256 bookEach) =
            probe.scanCostIn(id, address(0), _id(hooked));
        assertEq(venues, 21, "the most venues");
        emit log_named_uint("reading prices, gas", book);
        emit log_named_uint("reserved for reading prices, gas", bookEach * venues);
        emit log_named_uint("ranking, gas", best);
        emit log_named_uint("reserved for ranking, gas", each * venues);
        assertLt(book, bookEach * venues, "reading prices within its allowance");
        assertLt(best, each * venues, "ranking within its allowance");
        assertGe(probe.mostVenues(id), venues, "the allowance counts every venue read");
    }
}
