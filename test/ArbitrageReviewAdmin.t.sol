// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { WrappedPool, WrappedPricer } from "./utils/WrappedPool.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A minimum profit for every token of a market that is on with several
/// (docs/specs/hook-review-2026-11-21.md, item 1).
contract ArbitrageReviewMinimumsTest is MarketsWorld {
    function _fresh(address[] memory tokens) internal returns (uint256 fresh) {
        vm.startPrank(team);
        fresh = hook.openMarket(treasury);
        hook.setTokens(fresh, tokens);
        vm.stopPrank();
    }

    function _two() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(backing);
        tokens[1] = address(usd);
    }

    function testSwitchingOnWithAZeroMinimumReverts() public {
        uint256 fresh = _fresh(_two());
        uint32 gas = uint32(hook.minimumGasLimit(fresh));
        vm.startPrank(team);
        hook.setMinimumProfit(fresh, address(backing), 1e15);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(fresh, address(backing), gas, 1e15, 1.0001e18);
        hook.setMinimumProfit(fresh, address(usd), 1);
        hook.setLimits(fresh, address(backing), gas, 1e15, 1.0001e18);
        vm.stopPrank();
        assertEq(hook.market(fresh).gasLimit, gas, "on once each has a minimum");
    }

    /// A market that is on cannot be given a zero minimum by `setLimits` either.
    function testSetLimitsToZeroOnAMarketThatIsOnReverts() public {
        uint32 gas = uint32(hook.market(id).gasLimit);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(id, address(usd), gas, 0, 1.0001e18);
    }

    function testZeroMinimumOnAMarketThatIsOnReverts() public {
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setMinimumProfit(id, address(usd), 0);
        vm.prank(team);
        hook.setMinimumProfit(id, address(usd), 1);
    }

    function testAddingATokenWithNoMinimumToAMarketThatIsOnReverts() public {
        // Room first, so the allowance is not what refuses the change.
        vm.prank(team);
        hook.setLimits(id, address(backing), 30_000_000, 1e15, 1.0001e18);
        hook.setProfitToken(address(coin), desk);
        address[] memory three = new address[](3);
        three[0] = address(backing);
        three[1] = address(usd);
        three[2] = address(coin);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setTokens(id, three);
        vm.startPrank(team);
        hook.setMinimumProfit(id, address(coin), 1);
        hook.setTokens(id, three);
        vm.stopPrank();
        assertEq(hook.tokensOf(id).length, 3);
    }

    function testAMarketThatIsOffTakesZeroMinimums() public {
        uint256 fresh = _fresh(_two());
        vm.startPrank(team);
        hook.setMinimumProfit(fresh, address(backing), 0);
        hook.setMinimumProfit(fresh, address(usd), 0);
        vm.stopPrank();
        assertEq(hook.minimumProfit(fresh, address(usd)), 0);
    }

    function testAMarketWithOneTokenTakesAZeroMinimum() public {
        address[] memory one = new address[](1);
        one[0] = address(backing);
        uint256 fresh = _fresh(one);
        uint32 gas = uint32(hook.minimumGasLimit(fresh));
        vm.startPrank(team);
        hook.setLimits(fresh, address(backing), gas, 0, 1.0001e18);
        hook.setMinimumProfit(fresh, address(backing), 0);
        vm.stopPrank();
        assertEq(hook.market(fresh).gasLimit, gas, "on with no minimum");
    }

    function testSzrMarketIsUnaffected() public {
        hook.setMinimumProfit(1, address(szr), 0);
        assertEq(hook.minimumProfit(1, address(szr)), 0);
    }
}

/// @dev A ceiling on what a swap must bring, set by Liquidity's manager (item 2).
contract ArbitrageReviewCeilingTest is MarketsWorld {
    WrappedPool internal wrapper;
    WrappedPricer internal pricer;
    address internal owner = address(0x0A11CE);

    function setUp() public override {
        super.setUp();
        wrapper = WrappedPool(payable(address(uint160(0xBEEF << 24 | 1 << 7 | 1 << 3))));
        deployCodeTo("WrappedPool.sol:WrappedPool", abi.encode(manager), address(wrapper));
        pricer = new WrappedPricer(wrapper);
        hook.setPricer(address(wrapper), address(pricer));
    }

    function _fake(uint256 seed) internal pure returns (address) {
        return address(uint160(0x1000_0000 + seed));
    }

    function _wrapped(uint24 fee) internal view returns (PoolKey memory) {
        return _pair(address(backing), address(coin), fee, address(wrapper));
    }

    // ----- the setter -----

    function testCeilingStartsAtThirtyMillion() public view {
        assertEq(hook.swapGasCeiling(), 30_000_000);
    }

    function testOnlyLiquiditysManagerSetsTheCeiling() public {
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.setSwapGasCeiling(40_000_000);
        vm.expectEmit(false, false, false, true, address(hook));
        emit ArbitrageLogic.SwapGasCeilingSet(40_000_000);
        hook.setSwapGasCeiling(40_000_000);
        assertEq(hook.swapGasCeiling(), 40_000_000);
    }

    function testZeroCeilingIsRefused() public {
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setSwapGasCeiling(0);
    }

    // ----- the two worlds of the review -----

    /// The documented maximum: eight tokens, each with eight groups of three leaders.
    function testEightTokenMarketIsRefusedThenAcceptedWithAHigherCeiling() public {
        vm.prank(owner);
        uint256 plain = hook.openMarket(owner);
        address[] memory tokens = new address[](8);
        for (uint256 t; t < 8; t++) {
            tokens[t] = _fake(100 + t);
            hook.setProfitToken(tokens[t], desk);
        }
        vm.startPrank(owner);
        hook.setTokens(plain, tokens);
        for (uint256 t; t < 8; t++) {
            hook.setMinimumProfit(plain, tokens[t], 1e15);
            for (uint256 g; g < 8; g++) {
                address partner = _fake(200 + g);
                bytes32[] memory three = new bytes32[](3);
                for (uint24 k; k < 3; k++) {
                    PoolKey memory pool = _pair(tokens[t], partner, 100 + k, address(0));
                    hook.addVenue(plain, pool);
                    three[k] = _id(pool);
                }
                hook.setLeaders(plain, tokens[t], partner, three);
            }
        }
        uint32 minimum = uint32(hook.minimumGasLimit(plain));
        assertGt(hook.gasForSwap(plain), hook.swapGasCeiling(), "above the ceiling");
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(plain, tokens[0], minimum, 1e15, 1.0001e18);
        vm.stopPrank();
        hook.setSwapGasCeiling(40_000_000);
        vm.prank(owner);
        hook.setLimits(plain, tokens[0], minimum, 1e15, 1.0001e18);
        assertEq(hook.market(plain).gasLimit, minimum, "accepted at the higher ceiling");
    }

    /// Sixteen wrapped venues at the largest pricer gas.
    function testSixteenWrappedVenuesAreRefused() public {
        address[] memory one = new address[](1);
        one[0] = address(backing);
        vm.startPrank(owner);
        uint256 plain = hook.openMarket(owner);
        hook.setTokens(plain, one);
        for (uint24 n = 1; n <= 16; n++) {
            hook.addVenue(plain, _wrapped(100 + n));
            if (n == 1) hook.setPricerGas(plain, 1_020_000);
        }
        uint32 minimum = uint32(hook.minimumGasLimit(plain));
        assertGt(hook.gasForSwap(plain), hook.swapGasCeiling(), "above the ceiling");
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(plain, address(backing), minimum, 1e15, 1.0001e18);
        vm.stopPrank();
        hook.setSwapGasCeiling(type(uint256).max);
        vm.prank(owner);
        hook.setLimits(plain, address(backing), minimum, 1e15, 1.0001e18);
    }

    // ----- growing a market that is on -----

    /// The world's market, on with an allowance far above what it needs so that the
    /// allowance is never what refuses a change, with one wrapped pool, and with the ceiling
    /// at exactly what it now needs.
    function _atTheCeiling() internal {
        vm.startPrank(team);
        hook.setLimits(id, address(backing), 100_000_000, 1e15, 1.0001e18);
        hook.addVenue(id, _wrapped(100));
        hook.setPricerGas(id, 100_000);
        vm.stopPrank();
        hook.setSwapGasCeiling(hook.gasForSwap(id));
    }

    function _raise() internal {
        hook.setSwapGasCeiling(type(uint256).max);
    }

    function testListingAWrappedPoolPastTheCeilingReverts() public {
        _atTheCeiling();
        PoolKey memory more = _wrapped(200);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.addVenue(id, more);
        _raise();
        vm.prank(team);
        hook.addVenue(id, more);
    }

    function testSettingAWrappedConnectorPastTheCeilingReverts() public {
        _atTheCeiling();
        PoolKey memory route = _pair(address(coin), address(usd), 100, address(wrapper));
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setConnector(id, route, true);
        _raise();
        vm.prank(team);
        hook.setConnector(id, route, true);
    }

    function testRaisingPricerGasPastTheCeilingReverts() public {
        _atTheCeiling();
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setPricerGas(id, 1_020_000);
        _raise();
        vm.prank(team);
        hook.setPricerGas(id, 1_020_000);
    }

    function testAddingALeaderPastTheCeilingReverts() public {
        PoolKey memory third = _create(address(backing), address(coin), 100);
        _atTheCeiling();
        bytes32[] memory three = new bytes32[](3);
        three[0] = _id(first);
        three[1] = _id(second);
        three[2] = _id(third);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLeaders(id, address(backing), address(coin), three);
        _raise();
        vm.prank(team);
        hook.setLeaders(id, address(backing), address(coin), three);
    }

    function testAddingATokenPastTheCeilingReverts() public {
        hook.setProfitToken(address(coin), desk);
        vm.prank(team);
        hook.setMinimumProfit(id, address(coin), 1e15);
        _atTheCeiling();
        address[] memory four = new address[](3);
        four[0] = address(backing);
        four[1] = address(usd);
        four[2] = address(coin);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setTokens(id, four);
        _raise();
        vm.prank(team);
        hook.setTokens(id, four);
    }

    /// Lowering the ceiling switches nothing off, and the market's next change is refused
    /// until it is switched off or shrunk.
    function testLoweringTheCeilingLeavesAMarketRunningAndRefusesItsNextChange() public {
        _atTheCeiling();
        uint256 running = hook.market(id).gasLimit;
        hook.setSwapGasCeiling(hook.gasForSwap(id) - 1);
        assertEq(hook.market(id).gasLimit, running, "still running");
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(id, address(backing), 100_000_000, 1e15, 1.0001e18);
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        assertEq(hook.market(id).gasLimit, 0, "can be switched off");
    }

    /// A market that is off grows past the ceiling, and is refused when switched on, until
    /// the owner shrinks it.
    function testAMarketThatIsOffGrowsAndShrinksAndSwitchesOnUnderTheCeiling() public {
        vm.prank(team);
        hook.setLimits(id, address(backing), 0, 1e15, 1.0001e18);
        hook.setSwapGasCeiling(hook.gasForSwap(id));
        PoolKey memory more = _wrapped(100);
        vm.startPrank(team);
        hook.addVenue(id, more);
        hook.setPricerGas(id, 100_000);
        assertGt(hook.gasForSwap(id), hook.swapGasCeiling(), "grown past it while off");
        uint32 minimum = uint32(hook.minimumGasLimit(id));
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        hook.setLimits(id, address(backing), minimum, 1e15, 1.0001e18);
        hook.untrack(id, _id(more));
        minimum = uint32(hook.minimumGasLimit(id));
        hook.setLimits(id, address(backing), minimum, 1e15, 1.0001e18);
        vm.stopPrank();
        assertEq(hook.market(id).gasLimit, minimum, "on again once shrunk");
    }
}
