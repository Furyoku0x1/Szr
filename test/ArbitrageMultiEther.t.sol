// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { WrapWorld } from "./ArbitrageWrap.t.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev ETH and WETH are one asset in two forms, so a swap opens at most one book for
/// them, and a pool of the two is never searched (docs/specs/hook-final-items.md, 1a).
contract ArbitrageMultiEtherTest is WrapWorld {
    TestAsset internal dai;
    PoolKey internal stable;

    function setUp() public override {
        super.setUp();
        dai = new TestAsset();
        _approve(dai);
        stable = _make(address(coin), address(dai), 500, address(hook));
        vm.prank(team);
        hook.setConnector(id, stable, true);
    }

    function _count(address[] memory tokens) internal {
        vm.prank(team);
        hook.setTokens(id, tokens);
    }

    function _books(PoolKey memory pool) internal returns (address[] memory bases) {
        ArbitrageProbe probe = _probeInHook();
        (, bases,) = probe.centresOf(id, _id(pool), pool);
        assertTrue(probe.centresAgree(id, _id(pool), pool), "the same books as before");
    }

    /// A pool of ETH and WETH opens no book, in either token.
    function testPoolOfEthAndWethOpensNoBook() public {
        address[] memory tokens = new address[](3);
        tokens[0] = address(0);
        tokens[1] = address(backing);
        tokens[2] = address(usd);
        _count(tokens);
        PoolKey memory both = _make(address(0), address(backing), 3_000, address(hook));
        assertEq(_books(both).length, 0, "never searched");
    }

    /// A pool that holds neither ether token opens one book for the two, the first chosen.
    function testPoolOfNeitherOpensOneEtherBook() public {
        PoolKey memory ethCoin = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory wethCoin = _make(address(backing), address(coin), 200, address(hook));
        PoolKey memory ethDai = _make(address(0), address(dai), 3_000, address(hook));
        PoolKey memory wethDai = _make(address(backing), address(dai), 3_000, address(hook));
        address[] memory tokens = new address[](2);
        tokens[0] = address(0);
        tokens[1] = address(backing);
        _count(tokens);
        _lead(address(0), address(coin), _list(_id(ethCoin)));
        _lead(address(0), address(dai), _list(_id(ethDai)));
        _lead(address(backing), address(coin), _list(_id(wethCoin)));
        _lead(address(backing), address(dai), _list(_id(wethDai)));
        address[] memory bases = _books(stable);
        assertEq(bases.length, 1, "one book for both forms");
        assertEq(bases[0], address(0), "the first chosen");
    }

    /// A connecting pool that holds ETH opens a book for ETH, which also prices the WETH
    /// pools, and none for WETH beside it.
    function testEtherConnectorWhoseTwinIsChosenOpensOneBook() public {
        PoolKey memory ethCoin = _make(address(0), address(coin), 3_000, address(hook));
        PoolKey memory wethDai = _make(address(backing), address(dai), 3_000, address(hook));
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(0);
        _count(tokens);
        vm.prank(team);
        hook.setConnector(id, ethCoin, true);
        _lead(address(0), address(coin), _list(_id(ethCoin)));
        _lead(address(backing), address(dai), _list(_id(wethDai)));
        address[] memory bases = _books(ethCoin);
        assertEq(bases.length, 1, "one book");
        assertEq(bases[0], address(0), "in the token the pool holds");
    }

    /// With the twin not chosen, a connector holding ETH has no book for WETH either; the
    /// leader a WETH book would be centred on is not one that pool's swap can have moved.
    function testEtherConnectorWhoseTwinIsNotChosenOpensNoBookForIt() public {
        PoolKey memory ethDai = _make(address(0), address(dai), 3_000, address(hook));
        PoolKey memory wethDai = _make(address(backing), address(dai), 3_000, address(hook));
        address[] memory tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
        _count(tokens);
        vm.prank(team);
        hook.setConnector(id, ethDai, true);
        _lead(address(backing), address(dai), _list(_id(wethDai)));
        assertEq(_books(ethDai).length, 0, "WETH is not searched through its twin's pool");
    }
}
