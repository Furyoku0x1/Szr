// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SizingScenarios } from "./ArbitrageSizing.t.sol";
import { SizingScenariosTail } from "./ArbitrageSizingTail.t.sol";
import { SizingShapes } from "./ArbitrageSizingShapes.t.sol";

/// @dev The same table at SZR's real default minimum profit (10 SZR), where the small
/// second cycles should not trade.
contract ArbitrageSizingDefaultTest is SizingScenarios {
    function setUp() public override {
        super.setUp();
        minProfit = 10e18;
    }
}

/// @dev The shapes at SZR's real default minimum profit.
contract ArbitrageSizingShapesDefaultTest is SizingShapes {
    function setUp() public override {
        super.setUp();
        minProfit = 10e18;
    }
}

/// @dev The tail of the table at the same minimum profit.
contract ArbitrageSizingTailDefaultTest is SizingScenariosTail {
    function setUp() public override {
        super.setUp();
        minProfit = 10e18;
    }
}
