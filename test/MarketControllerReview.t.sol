// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { MockVault } from "./MarketController.t.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IMarketController } from "../src/interfaces/IMarketController.sol";

/// @dev A token that calls a recipient that registered, after the balances move.
contract CallbackToken is TestAsset {
    mapping(address => bool) public hooked;
    bool public frozen;

    function register() external {
        hooked[msg.sender] = true;
    }

    function freeze(bool on) external {
        frozen = on;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!frozen, "frozen");
        super.transfer(to, amount);
        if (hooked[to]) HostileVault(to).onTokenTransfer();
        return true;
    }
}

/// @dev A vault that calls `distribute` again when it is paid.
contract HostileVault {
    address public immutable controller;
    uint256 public immutable market;
    CallbackToken internal immutable token;
    bool public armed;
    bool public inside;
    bool public reenteredOk;

    constructor(address controller_, uint256 market_, CallbackToken token_) {
        controller = controller_;
        market = market_;
        token = token_;
        token_.register();
    }

    function arm() external {
        armed = true;
    }

    function onTokenTransfer() external {
        if (!armed) return;
        if (inside) return;
        inside = true;
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        (reenteredOk,) = controller.call(abi.encodeCall(MarketController.distribute, (tokens)));
        inside = false;
    }
}

/// @dev A curator's vault that runs a ready queued call on the controller when paid.
contract ExecutingVault {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address public immutable controller;
    uint256 public immutable market;
    address internal immutable curator;
    bytes internal queued;
    bool public executeOk;
    bool public armed;

    constructor(address controller_, uint256 market_, address curator_) {
        controller = controller_;
        market = market_;
        curator = curator_;
    }

    function arm(bytes calldata call, CallbackToken token) external {
        queued = call;
        armed = true;
        token.register();
    }

    function onTokenTransfer() external {
        if (!armed) return;
        armed = false;
        // The vault stands for the curator's own code, so the call comes from the curator.
        vm.prank(curator);
        (executeOk,) = controller.call(abi.encodeCall(MarketController.execute, (queued)));
    }
}

/// @dev The 2026-11-23 review fixes to the controller (F-1, F-2).
contract MarketControllerReviewTest is MarketsWorld {
    MarketController internal controller;
    address internal factory = address(0xFAC7);
    uint256 internal constant DELAY = 3 days;

    function setUp() public virtual override {
        super.setUp();
        controller = MarketController(
            deployCode(
                "MarketController.sol:MarketController", abi.encode(hook, id, team, factory)
            )
        );
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        vm.prank(factory);
        controller.initialize();
    }

    function _queueAndRun(bytes memory call) internal {
        vm.startPrank(team);
        controller.queue(call);
        vm.warp(block.timestamp + DELAY);
        controller.execute(call);
        vm.stopPrank();
    }

    function _leaders(bytes32[] memory list) internal view returns (bytes memory) {
        return _leaders(list, address(usd));
    }

    function _leaders(bytes32[] memory list, address partner)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(hook.setLeaders, (id, address(backing), partner, list));
    }

    // F-1.

    function testMinimumProfitIsDelayedBothWays() public {
        bytes memory raise = abi.encodeCall(hook.setMinimumProfit, (id, address(usd), 5e15));
        vm.prank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(raise);
        _queueAndRun(raise);
        assertEq(hook.minimumProfit(id, address(usd)), 5e15, "raised");
        bytes memory lower = abi.encodeCall(hook.setMinimumProfit, (id, address(usd), 1));
        vm.prank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(lower);
        _queueAndRun(lower);
        assertEq(hook.minimumProfit(id, address(usd)), 1, "lowered");
    }

    function testEmptyLeadersAreDelayedAndNonEmptyAreNot() public {
        bytes32[] memory none = new bytes32[](0);
        vm.prank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(_leaders(none));
        _queueAndRun(_leaders(none));
        bytes32[] memory one = new bytes32[](1);
        one[0] = bytes32(uint256(1));
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.queue(_leaders(one));
        // The call reaches the hook, which refuses the unknown pool: it was not classified
        // as delayed.
        (bool ok, bytes memory data) =
            address(controller).call(abi.encodeCall(controller.forward, (_leaders(one))));
        vm.stopPrank();
        assertFalse(ok);
        assertTrue(bytes4(data) != IMarketController.NotAllowed.selector, "immediate");
    }

    /// The array offset is moved, leaving a non-empty-looking word where a fixed-offset
    /// read would look. It is classified as the hook decodes it: empty, so delayed.
    function testMovedArrayOffsetIsClassifiedAsTheHookDecodesIt() public {
        bytes memory moved = abi.encodePacked(
            hook.setLeaders.selector,
            abi.encode(id, address(backing), address(usd), uint256(0xc0)),
            abi.encode(uint256(7), uint256(7)),
            abi.encode(uint256(0))
        );
        vm.prank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(moved);
        vm.prank(team);
        controller.queue(moved);
        vm.warp(block.timestamp + DELAY);
        vm.prank(team);
        controller.execute(moved);
        assertEq(hook.leadersOf(id, address(backing), address(usd)).length, 0, "empty");
    }

    function testNonEmptyLeadersOfRealPoolsAreForwardedAtOnce() public {
        bytes32[] memory swapped = _list(_id(second), _id(first));
        vm.prank(team);
        controller.forward(_leaders(swapped, address(coin)));
        bytes32[] memory now_ = hook.leadersOf(id, address(backing), address(coin));
        assertEq(now_.length, 2, "applied");
        assertEq(now_[0], _id(second), "new head");
        assertEq(now_[1], _id(first), "second");
    }

    /// A token new to the market needs its minimum before `setTokens`, which checks every
    /// chosen token. `coin` has none yet, unlike `usd`.
    function testASecondTokenQueuedWithItsMinimumProfit() public {
        hook.setProfitToken(address(coin), desk);
        address[] memory only = new address[](1);
        only[0] = address(backing);
        _queueAndRun(abi.encodeCall(hook.setTokens, (id, only)));
        address[] memory both = new address[](2);
        both[0] = address(backing);
        both[1] = address(coin);
        bytes memory tokens = abi.encodeCall(hook.setTokens, (id, both));
        bytes memory profit = abi.encodeCall(hook.setMinimumProfit, (id, address(coin), 2e15));
        vm.startPrank(team);
        controller.queue(tokens);
        controller.queue(profit);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        controller.execute(tokens);
        controller.execute(profit);
        controller.execute(tokens);
        vm.stopPrank();
        assertEq(hook.tokensOf(id).length, 2);
        assertEq(hook.minimumProfit(id, address(coin)), 2e15);
    }

    // F-2.

    /// A hostile vault listed before an honest one re-enters `distribute` when paid. The
    /// inner call must fail, and the honest vault gets its pending share and its fresh one.
    function testDistributeCannotBeReentered() public {
        CallbackToken token = new CallbackToken();
        HostileVault hostile = new HostileVault(address(controller), id, token);
        MockVault honest = new MockVault(address(controller), id);
        vm.startPrank(team);
        controller.addVault(address(hostile), 5_000);
        bytes memory add = abi.encodeCall(controller.addVault, (address(honest), 5_000));
        controller.queue(add);
        vm.warp(block.timestamp + DELAY);
        controller.execute(add);
        vm.stopPrank();
        address[] memory list = new address[](1);
        list[0] = address(token);
        // 100 is split while the token refuses to send, so each vault has 50 pending.
        token.freeze(true);
        token.mint(address(controller), 100e18);
        controller.distribute(list);
        token.freeze(false);
        hostile.arm();
        token.mint(address(controller), 100e18);
        controller.distribute(list);
        assertFalse(hostile.reenteredOk(), "inner call refused");
        assertEq(token.balanceOf(address(hostile)), 100e18, "hostile fair share");
        assertEq(token.balanceOf(address(honest)), 100e18, "honest fair share");
        assertEq(token.balanceOf(address(controller)), 0, "nothing left");
        assertEq(controller.pendingTotal(address(token)), 0, "nothing pending");
    }

    /// A vault paid in the middle of a split runs a ready `setWeight`. It must fail, or the
    /// weights would change after `rest` and `fresh` were fixed.
    function testExecuteCannotBeReenteredFromDistribute() public {
        CallbackToken token = new CallbackToken();
        ExecutingVault vault = new ExecutingVault(address(controller), id, team);
        vm.prank(team);
        controller.addVault(address(vault), 5_000);
        bytes memory change = abi.encodeCall(controller.setWeight, (address(vault), 4_000));
        vm.prank(team);
        controller.queue(change);
        vm.warp(block.timestamp + DELAY);
        vault.arm(change, token);
        address[] memory list = new address[](1);
        list[0] = address(token);
        token.mint(address(controller), 100e18);
        controller.distribute(list);
        assertFalse(vault.executeOk(), "inner execute refused");
        assertEq(controller.weights(address(vault)), 5_000, "weight unchanged");
        assertEq(token.balanceOf(address(vault)), 50e18, "paid its share");
    }
}
