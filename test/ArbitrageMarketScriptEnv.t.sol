// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { OpenArbitrageMarket } from "../script/OpenArbitrageMarket.s.sol";

/// @dev Reads `OpenArbitrageMarket`'s environment.
contract MarketReader is OpenArbitrageMarket {
    function read() external view returns (Config memory) {
        return _readConfig();
    }
}

/// @dev Foundry loads `.env` into every script, so the names other scripts read must not
/// reach `OpenArbitrageMarket`, and its own `MARKET_` names must.
contract ArbitrageMarketScriptEnvTest is Test {
    address internal constant HOOK = address(0xB0B);
    address internal constant WETH = address(0x111);
    address internal constant USD = address(0x222);

    function _clear(string[] memory names) internal {
        for (uint256 index; index < names.length; index++) {
            vm.setEnv(names[index], "");
        }
    }

    function testMarketScriptReadsOnlyItsOwnNames() public {
        MarketReader reader = new MarketReader();
        vm.setEnv("ARBITRAGE_HOOK", vm.toString(HOOK));
        vm.setEnv("MARKET_OWNER", vm.toString(address(0xA7)));
        vm.setEnv("POOL_FEE", "3000");
        vm.setEnv("POOL_TICK_SPACING", "60");
        vm.setEnv("POOL_TOKEN0", vm.toString(WETH));
        vm.setEnv("CONNECTOR_TOKEN0", vm.toString(WETH));
        vm.setEnv("CONNECTOR_TOKEN1", vm.toString(USD));
        vm.setEnv("LEADER_BASE", vm.toString(USD));
        vm.setEnv("PROFIT_TOKEN", vm.toString(USD));
        vm.setEnv("MINIMUM_EDGE", "5");
        OpenArbitrageMarket.Config memory plan = reader.read();
        assertEq(plan.pools.length, 0, "no pools from POOL_*");
        assertEq(plan.connectors.length, 0, "no connectors from CONNECTOR_*");
        assertEq(plan.groups.length, 0, "no group from LEADER_*");
        assertEq(plan.limits.length, 0, "no limit from PROFIT_TOKEN");
        assertEq(plan.edge, 0, "no edge from MINIMUM_EDGE");
        vm.setEnv("MARKET_CONNECTOR_TOKEN0", vm.toString(WETH));
        vm.setEnv("MARKET_CONNECTOR_TOKEN1", vm.toString(USD));
        vm.setEnv("MARKET_CONNECTOR_FEE", "3000");
        vm.setEnv("MARKET_CONNECTOR_TICK_SPACING", "60");
        vm.setEnv("MARKET_MINIMUM_EDGE", "5");
        plan = reader.read();
        assertEq(plan.connectors.length, 1, "MARKET_CONNECTOR_* is read");
        assertEq(plan.edge, 5, "MARKET_MINIMUM_EDGE is read");
        string[] memory names = new string[](13);
        names[0] = "POOL_FEE";
        names[1] = "POOL_TICK_SPACING";
        names[2] = "POOL_TOKEN0";
        names[3] = "CONNECTOR_TOKEN0";
        names[4] = "CONNECTOR_TOKEN1";
        names[5] = "LEADER_BASE";
        names[6] = "PROFIT_TOKEN";
        names[7] = "MINIMUM_EDGE";
        names[8] = "MARKET_CONNECTOR_TOKEN0";
        names[9] = "MARKET_CONNECTOR_TOKEN1";
        names[10] = "MARKET_CONNECTOR_FEE";
        names[11] = "MARKET_CONNECTOR_TICK_SPACING";
        names[12] = "MARKET_MINIMUM_EDGE";
        _clear(names);
    }
}
