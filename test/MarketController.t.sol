// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { IMarketController } from "../src/interfaces/IMarketController.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Stands in for a pair vault: it only names its controller and market.
contract MockVault {
    address public controller;
    uint256 public market;

    constructor(address controller_, uint256 market_) {
        controller = controller_;
        market = market_;
    }
}

/// @dev A token that refuses to pay one address, for a vault that cannot be paid.
contract PickyToken is TestAsset {
    address public blocked;

    function block_(address who) external {
        blocked = who;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(to != blocked, "blocked");
        return super.transfer(to, amount);
    }
}

/// @dev A token that burns all the gas it is given when asked for a balance, and one that
/// does so when asked to send.
contract HoggingToken is TestAsset {
    bool public onBalance;
    bool public onSend;

    function hog(bool balance, bool send) external {
        onBalance = balance;
        onSend = send;
    }

    function balanceOf(address who) public view override returns (uint256) {
        if (onBalance) {
            while (gasleft() > 1000) { }
        }
        return super.balanceOf(who);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (onSend) {
            while (gasleft() > 1000) { }
        }
        return super.transfer(to, amount);
    }
}

/// @dev The controller over the real hook's outside market, and mock vaults.
contract MarketControllerTest is MarketsWorld {
    MarketController internal controller;
    MockVault internal vaultA;
    MockVault internal vaultB;
    address internal factory = address(0xFAC7);
    address internal stranger = address(0x57A9);
    uint256 internal constant DELAY = 3 days;

    function setUp() public override {
        super.setUp();
        controller = _build(team);
        vm.prank(team);
        hook.nominateOwner(id, address(controller));
        vm.prank(factory);
        controller.initialize();
        vaultA = new MockVault(address(controller), id);
        vaultB = new MockVault(address(controller), id);
    }

    function _build(address curator) internal returns (MarketController made) {
        made = MarketController(
            deployCode(
                "MarketController.sol:MarketController", abi.encode(hook, id, curator, factory)
            )
        );
    }

    function _tokens(address one) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = one;
    }

    function _tokens(address one, address two) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = one;
        list[1] = two;
    }

    function _addBoth(uint16 weightA, uint16 weightB) internal {
        vm.startPrank(team);
        controller.addVault(address(vaultA), weightA);
        controller.queue(abi.encodeCall(controller.addVault, (address(vaultB), weightB)));
        vm.warp(block.timestamp + DELAY);
        controller.execute(abi.encodeCall(controller.addVault, (address(vaultB), weightB)));
        vm.stopPrank();
    }

    // Setup.

    function testTakesTheMarketAndTheRecipient() public view {
        ArbitrageLogic.Market memory settings = hook.market(id);
        assertEq(settings.owner, address(controller), "owner");
        assertEq(settings.recipient, address(controller), "recipient");
        assertEq(settings.nominee, address(0), "nominee cleared");
        assertTrue(controller.initialized());
    }

    function testInitializeNeedsTheNomination() public {
        MarketController other = _build(team);
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.NotManager.selector);
        other.initialize();
    }

    function testInitializeRunsOnceAndOnlyForCuratorOrFactory() public {
        vm.prank(team);
        vm.expectRevert(IMarketController.AlreadyInitialized.selector);
        controller.initialize();
        MarketController other = _build(team);
        vm.prank(stranger);
        vm.expectRevert(IMarketController.NotCurator.selector);
        other.initialize();
    }

    function testNothingRunsBeforeInitialize() public {
        MarketController other = _build(team);
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotInitialized.selector);
        other.forward(abi.encodeCall(hook.setMinimumProfit, (id, address(backing), 1)));
        vm.expectRevert(IMarketController.NotInitialized.selector);
        other.addVault(address(vaultA), 1);
        vm.stopPrank();
    }

    // Rewards.

    function testRealProfitIsSplitAcrossVaultsAndTheCuratorKeepsTheRest() public {
        _addBoth(5_000, 3_000);
        _trade(first, address(coin), 50_000e18);
        uint256 profit = backing.balanceOf(address(controller));
        assertGt(profit, 0, "the hook paid the controller");
        assertEq(backing.balanceOf(treasury), 0, "and not the old recipient");
        usd.mint(address(controller), 1_000e18);
        controller.distribute(_tokens(address(backing), address(usd)));
        assertEq(backing.balanceOf(address(vaultA)), profit * 5_000 / 10_000, "A weth");
        assertEq(backing.balanceOf(address(vaultB)), profit * 3_000 / 10_000, "B weth");
        assertEq(usd.balanceOf(address(vaultA)), 500e18, "A usd");
        assertEq(usd.balanceOf(address(vaultB)), 300e18, "B usd");
        assertEq(controller.owed(address(usd)), 200e18, "curator usd");
        assertEq(controller.owed(address(backing)), profit * 2_000 / 10_000, "curator weth");
    }

    function testDistributeIsOpenToAnyone() public {
        _addBoth(5_000, 5_000);
        backing.mint(address(controller), 100e18);
        vm.prank(stranger);
        controller.distribute(_tokens(address(backing)));
        assertEq(backing.balanceOf(address(vaultA)), 50e18);
    }

    function testDistributeTwiceDoesNotPayTheCuratorsShareOut() public {
        _addBoth(4_000, 4_000);
        backing.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(backing)));
        controller.distribute(_tokens(address(backing)));
        assertEq(backing.balanceOf(address(vaultA)), 40e18, "nothing more for A");
        assertEq(controller.owed(address(backing)), 20e18, "curator share unchanged");
        assertEq(backing.balanceOf(address(controller)), 20e18, "and still held");
    }

    function testCuratorClaimsTheRemainderAndNobodyElse() public {
        _addBoth(4_000, 4_000);
        backing.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(backing)));
        vm.prank(stranger);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.claim(address(backing), stranger);
        vm.prank(team);
        controller.claim(address(backing), address(0xBEEF));
        assertEq(backing.balanceOf(address(0xBEEF)), 20e18);
        assertEq(controller.owed(address(backing)), 0);
        assertEq(backing.balanceOf(address(controller)), 0);
    }

    function testWithNoVaultsAllIsTheCurators() public {
        backing.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(backing)));
        assertEq(controller.owed(address(backing)), 100e18);
    }

    function testAVaultThatCannotBePaidKeepsItsShareWithoutRevertingTheCall() public {
        PickyToken picky = new PickyToken();
        _addBoth(5_000, 3_000);
        picky.block_(address(vaultA));
        picky.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(picky)));
        assertEq(picky.balanceOf(address(vaultA)), 0, "A not paid");
        assertEq(picky.balanceOf(address(vaultB)), 30e18, "B paid");
        assertEq(picky.balanceOf(address(controller)), 70e18, "A's share and the curator's");
        assertEq(controller.pending(address(vaultA), address(picky)), 50e18, "held for A");
        assertEq(controller.pendingTotal(address(picky)), 50e18);
        picky.block_(address(0));
        controller.distribute(_tokens(address(picky)));
        // A's 50 is retried for A alone, and is not split again.
        assertEq(picky.balanceOf(address(vaultA)), 50e18, "A paid on the next call");
        assertEq(picky.balanceOf(address(vaultB)), 30e18, "B not paid twice");
        assertEq(controller.owed(address(picky)), 20e18, "the curator's share is not re-split");
        assertEq(controller.pending(address(vaultA), address(picky)), 0);
        assertEq(controller.pendingTotal(address(picky)), 0);
    }

    // Vault registry.

    function testOnlyTheCuratorAddsTheFirstVault() public {
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.addVault(address(vaultA), 1);
        vm.prank(team);
        controller.addVault(address(vaultA), 1_000);
        assertEq(controller.vaultCount(), 1);
        assertEq(controller.weights(address(vaultA)), 1_000);
    }

    function testAVaultMustNameThisControllerAndMarket() public {
        MockVault wrongController = new MockVault(address(0x1234), id);
        MockVault wrongMarket = new MockVault(address(controller), id + 1);
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotAVault.selector);
        controller.addVault(address(wrongController), 1);
        vm.expectRevert(IMarketController.NotAVault.selector);
        controller.addVault(address(wrongMarket), 1);
        vm.stopPrank();
    }

    function testLaterVaultsWaitForTheTimelock() public {
        vm.startPrank(team);
        controller.addVault(address(vaultA), 1_000);
        vm.expectRevert(IMarketController.Timelocked.selector);
        controller.addVault(address(vaultB), 1_000);
        vm.stopPrank();
    }

    function testAVaultIsAddedOnce() public {
        _addBoth(1_000, 1_000);
        bytes memory again = abi.encodeCall(controller.addVault, (address(vaultB), 1));
        vm.startPrank(team);
        controller.queue(again);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IMarketController.AlreadyAdded.selector);
        controller.execute(again);
        vm.stopPrank();
    }

    function testWeightsNeverSumPastTenThousand() public {
        vm.startPrank(team);
        vm.expectRevert(IMarketController.WeightTooHigh.selector);
        controller.addVault(address(vaultA), 10_001);
        controller.addVault(address(vaultA), 6_000);
        bytes memory more = abi.encodeCall(controller.addVault, (address(vaultB), 4_001));
        controller.queue(more);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IMarketController.WeightTooHigh.selector);
        controller.execute(more);
        vm.stopPrank();
    }

    function testRetiringZeroesTheWeightAfterTheDelayOnly() public {
        _addBoth(5_000, 3_000);
        vm.startPrank(team);
        vm.expectRevert(IMarketController.Timelocked.selector);
        controller.retireVault(address(vaultA));
        vm.expectRevert(IMarketController.Timelocked.selector);
        controller.setWeight(address(vaultA), 1);
        bytes memory retire = abi.encodeCall(controller.retireVault, (address(vaultA)));
        controller.queue(retire);
        vm.warp(block.timestamp + DELAY);
        controller.execute(retire);
        vm.stopPrank();
        assertEq(controller.weights(address(vaultA)), 0);
        assertEq(controller.totalWeight(), 3_000);
        backing.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(backing)));
        assertEq(backing.balanceOf(address(vaultA)), 0, "retired vault gets nothing");
        assertEq(backing.balanceOf(address(vaultB)), 30e18);
    }

    function testNoMoreThanSixteenVaults() public {
        vm.startPrank(team);
        controller.addVault(address(vaultA), 0);
        for (uint256 index = 1; index < 16; index++) {
            MockVault more = new MockVault(address(controller), id);
            bytes memory call = abi.encodeCall(controller.addVault, (address(more), 0));
            controller.queue(call);
            vm.warp(block.timestamp + DELAY);
            controller.execute(call);
        }
        bytes memory last = abi.encodeCall(controller.addVault, (address(vaultB), 0));
        controller.queue(last);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IMarketController.TooManyVaults.selector);
        controller.execute(last);
        vm.stopPrank();
    }

    function testASetWeightMustNameAVault() public {
        bytes memory call = abi.encodeCall(controller.setWeight, (address(0x99), 1));
        vm.startPrank(team);
        controller.queue(call);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IMarketController.NotAVault.selector);
        controller.execute(call);
        vm.stopPrank();
    }

    // Gas burned by a token.

    /// A token that burns the gas it is given in `balanceOf` reads as empty, so the other
    /// tokens in the same call are still split.
    function testATokenThatBurnsGasOnItsBalanceCannotStopTheSplit() public {
        _addBoth(5_000, 3_000);
        HoggingToken hog = new HoggingToken();
        hog.hog(true, false);
        backing.mint(address(controller), 100e18);
        controller.distribute{ gas: 1_500_000 }(_tokens(address(hog), address(backing)));
        assertEq(backing.balanceOf(address(vaultA)), 50e18, "the honest token is split");
        assertEq(backing.balanceOf(address(vaultB)), 30e18);
    }

    /// A token that burns the gas it is given when it sends fails that send only: the
    /// share is kept as pending, and the call goes on.
    function testATokenThatBurnsGasOnASendCannotStopTheSplit() public {
        _addBoth(5_000, 3_000);
        HoggingToken hog = new HoggingToken();
        hog.mint(address(controller), 100e18);
        hog.hog(false, true);
        backing.mint(address(controller), 100e18);
        controller.distribute{ gas: 1_500_000 }(_tokens(address(hog), address(backing)));
        assertEq(hog.balanceOf(address(vaultA)), 0, "not paid");
        assertEq(controller.pending(address(vaultA), address(hog)), 50e18, "kept for A");
        assertEq(controller.pending(address(vaultB), address(hog)), 30e18, "kept for B");
        assertEq(backing.balanceOf(address(vaultA)), 50e18, "the honest token is split");
    }

    /// A balance that fell below what is reserved (a rebasing token) splits nothing and
    /// does not revert.
    function testABalanceBelowWhatIsReservedDoesNotRevert() public {
        _addBoth(5_000, 3_000);
        backing.mint(address(controller), 100e18);
        controller.distribute(_tokens(address(backing)));
        assertEq(controller.owed(address(backing)), 20e18);
        vm.prank(address(controller));
        backing.transfer(address(0xB0B0), 15e18);
        controller.distribute(_tokens(address(backing)));
        assertEq(controller.owed(address(backing)), 20e18, "nothing new is claimed");
    }

    // Expiry.

    function testAQueuedItemExpiresAfterItsGracePeriod() public {
        bytes memory call = abi.encodeCall(controller.addVault, (address(vaultA), 1_000));
        vm.startPrank(team);
        controller.addVault(address(vaultB), 1);
        controller.queue(call);
        vm.warp(block.timestamp + DELAY + controller.GRACE() + 1);
        vm.expectRevert(IMarketController.Expired.selector);
        controller.execute(call);
        vm.stopPrank();
    }

    function testAQueuedItemRunsAtTheLastMomentOfItsGrace() public {
        bytes memory call = abi.encodeCall(controller.addVault, (address(vaultA), 1_000));
        vm.startPrank(team);
        controller.addVault(address(vaultB), 1);
        controller.queue(call);
        vm.warp(block.timestamp + DELAY + controller.GRACE());
        controller.execute(call);
        vm.stopPrank();
        assertTrue(controller.isVault(address(vaultA)));
    }

    // The market, through the controller.

    function testImmediateCallsReachTheHook() public {
        PoolKey memory extra = _pair(address(backing), address(coin), 100, address(hook));
        vm.prank(team);
        controller.forward(abi.encodeCall(hook.createPool, (id, extra, uint160(1 << 96))));
        assertEq(hook.market(id).poolCount, 3, "pool created in the market");
    }

    function testRecipientCanNeverBeChanged() public {
        bytes memory call = abi.encodeCall(hook.setRecipient, (id, treasury));
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(call);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.queue(call);
        vm.stopPrank();
        assertEq(hook.market(id).recipient, address(controller));
    }

    function testOnlyTheCuratorForwardsAndOnlyAllowedCalls() public {
        bytes memory profit = abi.encodeCall(hook.setPricerGas, (id, 400_000));
        vm.prank(stranger);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.forward(profit);
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(abi.encodeCall(hook.setLimits, (id, address(backing), 0, 0, 1e18)));
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(abi.encodeCall(hook.setProfitToken, (address(usd), desk)));
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.queue(profit);
        vm.expectRevert(IMarketController.BadCall.selector);
        controller.forward(hex"deadbeef");
        vm.stopPrank();
    }

    function testAnotherMarketIsRefused() public {
        vm.startPrank(team);
        vm.expectRevert(IMarketController.WrongMarket.selector);
        controller.forward(abi.encodeCall(hook.setPricerGas, (1, 400_000)));
        bytes memory other = abi.encodeCall(hook.setTokens, (1, _tokens(address(usd))));
        vm.expectRevert(IMarketController.WrongMarket.selector);
        controller.queue(other);
        vm.stopPrank();
    }

    function testHookFailuresBubbleUp() public {
        vm.prank(team);
        vm.expectRevert(ArbitrageLogic.InvalidLimit.selector);
        controller.forward(abi.encodeCall(hook.setPricerGas, (id, 1)));
    }

    /// Each selector the controller allows is the hook's own, so a typo in a signature
    /// would show here as the wrong kind.
    function testAllowedSelectorsAreTheHooksOwn() public {
        uint256 word = id;
        bytes4[6] memory now_ = [
            hook.setLeaders.selector,
            hook.setConnector.selector,
            hook.setPricerGas.selector,
            hook.createPool.selector,
            hook.addVenue.selector,
            hook.retrack.selector
        ];
        bytes4[5] memory later = [
            hook.setTokens.selector,
            hook.setMinimumProfit.selector,
            hook.untrack.selector,
            hook.setLimits.selector,
            hook.nominateOwner.selector
        ];
        vm.startPrank(team);
        for (uint256 index; index < now_.length; index++) {
            bytes memory call = abi.encodeWithSelector(now_[index], word);
            (bool ok, bytes memory data) =
                address(controller).call(abi.encodeCall(controller.forward, (call)));
            assertFalse(ok);
            assertTrue(bytes4(data) != IMarketController.NotAllowed.selector, "immediate");
        }
        for (uint256 index; index < later.length; index++) {
            bytes memory call = abi.encodeWithSelector(later[index], word);
            controller.queue(call);
            assertTrue(controller.readyAt(keccak256(call)) != 0, "delayed");
        }
        vm.stopPrank();
    }

    // The timelock.

    function testTimelockedCallWaitsThenRuns() public {
        bytes memory call = abi.encodeCall(hook.setTokens, (id, _tokens(address(backing))));
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotQueued.selector);
        controller.execute(call);
        controller.queue(call);
        assertEq(controller.readyAt(keccak256(call)), block.timestamp + DELAY);
        vm.expectRevert(IMarketController.AlreadyQueued.selector);
        controller.queue(call);
        vm.expectRevert(IMarketController.NotReady.selector);
        controller.execute(call);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectRevert(IMarketController.NotReady.selector);
        controller.execute(call);
        vm.warp(block.timestamp + 1);
        controller.execute(call);
        vm.stopPrank();
        assertEq(hook.tokensOf(id).length, 1, "tokens changed");
        vm.prank(team);
        vm.expectRevert(IMarketController.NotQueued.selector);
        controller.execute(call);
    }

    function testACancelledCallDoesNotRun() public {
        bytes memory call = abi.encodeCall(hook.setTokens, (id, _tokens(address(backing))));
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotQueued.selector);
        controller.cancel(call);
        controller.queue(call);
        controller.cancel(call);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(IMarketController.NotQueued.selector);
        controller.execute(call);
        vm.stopPrank();
        assertEq(hook.tokensOf(id).length, 2);
    }

    function testOnlyTheCuratorQueuesExecutesAndCancels() public {
        bytes memory call = abi.encodeCall(hook.setTokens, (id, _tokens(address(backing))));
        vm.prank(team);
        controller.queue(call);
        vm.startPrank(stranger);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.queue(call);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.execute(call);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.cancel(call);
        vm.stopPrank();
    }

    function testHandingTheMarketOnIsTimelocked() public {
        bytes memory call = abi.encodeCall(hook.nominateOwner, (id, stranger));
        vm.startPrank(team);
        vm.expectRevert(IMarketController.NotAllowed.selector);
        controller.forward(call);
        controller.queue(call);
        vm.warp(block.timestamp + DELAY);
        controller.execute(call);
        vm.stopPrank();
        assertEq(hook.market(id).nominee, stranger);
    }

    // The curator.

    function testCuratorHandoverIsTwoStep() public {
        vm.prank(stranger);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.nominateCurator(stranger);
        vm.prank(team);
        controller.nominateCurator(stranger);
        vm.prank(address(0xBAD));
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.acceptCurator();
        assertEq(controller.curator(), team, "not yet");
        vm.prank(stranger);
        controller.acceptCurator();
        assertEq(controller.curator(), stranger);
        vm.prank(team);
        vm.expectRevert(IMarketController.NotCurator.selector);
        controller.nominateCurator(team);
    }
}
