// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { MarketController } from "../src/vaults/MarketController.sol";

/// @dev A nominated owner may accept only for `NOMINATION_WINDOW` (18-M-3).
contract ArbitrageNomineeTest is MarketsWorld {
    address internal heir = address(0xBADBAD);
    address internal factory = address(0xFAC7);
    uint256 internal window;

    function setUp() public override {
        super.setUp();
        window = hook.NOMINATION_WINDOW();
    }

    function _controller() internal returns (MarketController made) {
        made = MarketController(
            deployCode(
                "MarketController.sol:MarketController", abi.encode(hook, id, team, factory)
            )
        );
    }

    /// Hands the market to a controller the way the factory does.
    function _controlled() internal returns (MarketController controller) {
        controller = _controller();
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        vm.prank(factory);
        controller.initialize();
    }

    function _queueNomination(MarketController controller) internal {
        bytes memory nom = abi.encodeCall(hook.nominateOwner, (id, heir));
        vm.startPrank(team);
        controller.queue(nom);
        vm.warp(block.timestamp + controller.CONTROL_DELAY());
        controller.execute(nom);
        vm.stopPrank();
    }

    function testNomineeAcceptsInsideTheWindow() public {
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.warp(block.timestamp + window);
        vm.prank(heir);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, heir);
    }

    function testNomineeCannotAcceptAfterTheWindow() public {
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.warp(block.timestamp + window + 1);
        vm.prank(heir);
        vm.expectRevert(ArbitrageLogic.NominationExpired.selector);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, team);
    }

    function testFreshNominationRestartsTheWindow() public {
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.warp(block.timestamp + window + 1);
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.warp(block.timestamp + window);
        vm.prank(heir);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, heir);
    }

    function testAcceptedNominationLeavesNothingBehind() public {
        vm.prank(team);
        hook.nominateOwner(id, heir);
        vm.prank(heir);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).nominee, address(0));
        vm.prank(heir);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        hook.acceptOwnership(id);
    }

    /// The 18-M-3 proof of concept: the controller queues and executes a nomination, and the
    /// nominee takes the market 60 days later.
    function testQueuedNominationExpiresThroughTheController() public {
        MarketController controller = _controlled();
        assertEq(hook.market(id).owner, address(controller), "initialize takes it");
        _queueNomination(controller);
        assertEq(hook.market(id).nominee, heir);

        vm.warp(block.timestamp + 60 days);
        vm.prank(heir);
        vm.expectRevert(ArbitrageLogic.NominationExpired.selector);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, address(controller));
    }

    function testQueuedNominationAcceptsInsideTheWindow() public {
        MarketController controller = _controlled();
        _queueNomination(controller);
        vm.warp(block.timestamp + window);
        vm.prank(heir);
        hook.acceptOwnership(id);
        assertEq(hook.market(id).owner, heir);
    }

    /// The factory nominates and initialize runs later; a day apart still works.
    function testInitializeAfterADayStillTakesTheMarket() public {
        MarketController controller = _controller();
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        vm.warp(block.timestamp + 1 days);
        vm.prank(factory);
        controller.initialize();
        assertEq(hook.market(id).owner, address(controller));
    }
}
