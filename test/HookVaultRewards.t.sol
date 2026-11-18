// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VaultWorld } from "./utils/VaultWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IHookVault } from "../src/interfaces/IHookVault.sol";

/// @dev A reward token that refuses to pay one address, as a blocklisting token would.
contract BlockingAsset is TestAsset {
    address public blocked;

    function setBlocked(address who) external {
        blocked = who;
    }

    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        require(to != blocked, "blocked");
    }
}

/// @dev A token whose `balanceOf` can be made to burn every gas it is given.
contract GasHog is TestAsset {
    bool public hogging;

    function setHogging(bool value) external {
        hogging = value;
    }

    function balanceOf(address who) public view override returns (uint256) {
        if (hogging) {
            while (gasleft() > 1000) { }
        }
        return super.balanceOf(who);
    }
}

/// @dev Rewards: booking, streaming, the curator's fee, claims, and the cap.
contract HookVaultRewardsTest is VaultWorld {
    uint256 internal constant MAX = type(uint256).max;
    uint256 internal constant PERIOD = 3 days;

    function setUp() public override {
        super.setUp();
        _seed(1);
    }

    function _deposit(address who, uint256 shares) internal {
        vm.prank(who);
        vault.deposit(shares, MAX, MAX, block.timestamp);
    }

    function _withdraw(address who, uint256 shares) internal {
        vm.prank(who);
        vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _list(address one) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = one;
    }

    /// Sends a reward to the vault and books it, as a controller's push plus any checkpoint
    /// would.
    function _pay(address token, uint256 amount) internal {
        TestAsset(token).mint(address(vault), amount);
        vault.harvest();
    }

    // Streaming.

    function testRewardStreamsOverThePeriodAndStops() public {
        _pay(address(coin), 1000e18);
        // The fee is a tenth, and the rest streams.
        assertEq(vault.feeOwed(address(coin)), 100e18);
        assertEq(vault.owed(address(coin)), 1000e18);
        assertEq(vault.earned(curator, address(coin)), 0, "nothing at the start");
        skip(PERIOD / 2);
        // The curator holds all but the locked minimum.
        assertApproxEqRel(vault.earned(curator, address(coin)), 450e18, 1e9, "half");
        skip(PERIOD / 2);
        uint256 full = vault.earned(curator, address(coin));
        assertApproxEqRel(full, 900e18, 1e9, "all of it");
        skip(10 days);
        assertEq(vault.earned(curator, address(coin)), full, "the stream has ended");
        assertEq(vault.rewardRate(address(coin)), 0);
    }

    function testRateAddsWhatIsLeftToTheNewPayout() public {
        _pay(address(coin), 900e18);
        skip(PERIOD / 3);
        uint256 rate = vault.rewardRate(address(coin));
        assertGt(rate, 0);
        // Two thirds of 810 are left, and 900 more arrive: 1440 over a full period.
        _pay(address(coin), 1000e18);
        // The end moves by the amounts: 540 left for two thirds of a period and 1000 new for
        // a whole one stream over 1360/1540 of a period.
        assertApproxEqRel(
            vault.rewardRate(address(coin)), 1440e18 * 1e18 * 1540 / (PERIOD * 1360), 1e13
        );
        skip(PERIOD);
        // 270 streamed already, and the rest of the 1440 now.
        assertApproxEqRel(vault.earned(curator, address(coin)), 270e18 + 1440e18, 1e9);
    }

    /// A few wei arriving late in a period must not start a new period, or a stream could be
    /// kept going for ever at no cost.
    function testDustDoesNotRestartTheStream() public {
        _pay(address(coin), 1000e18);
        skip(PERIOD - 1 hours);
        _pay(address(coin), 1);
        skip(1 hours);
        assertEq(vault.rewardRate(address(coin)), 0, "the end did not move");
        assertApproxEqRel(vault.earned(curator, address(coin)), 900e18, 1e9);
    }

    /// A real payout still streams over nearly a whole period, and what is left joins it.
    function testALumpStillStreamsOverNearlyAFullPeriod() public {
        _pay(address(coin), 1000e18);
        skip(PERIOD / 2);
        _pay(address(coin), 1000e18);
        // 450 left for half a period and 1000 new for a whole one: 1450 over 0.845 periods.
        skip(PERIOD * 80 / 100);
        assertGt(vault.rewardRate(address(coin)), 0, "still streaming");
        skip(PERIOD * 6 / 100);
        assertEq(vault.rewardRate(address(coin)), 0, "done by 0.86 of a period");
    }

    /// A reward token that burns gas in `balanceOf` costs a bounded read and books nothing,
    /// and the other tokens still book.
    function testAGasBurningBalanceCannotLockTheVault() public {
        GasHog hog = new GasHog();
        vm.prank(curator);
        vault.addRewardToken(address(hog));
        hog.mint(address(vault), 100e18);
        hog.setHogging(true);
        // The mock controller reads balances without a cap, and the controller is trusted.
        mock.setBroken(true);
        coin.mint(address(vault), 100e18);
        uint256 gas = gasleft();
        vault.harvest();
        assertLt(gas - gasleft(), 1_000_000, "the read is capped");
        assertEq(vault.owed(address(hog)), 0, "a failed read books nothing");
        assertEq(vault.unbooked(address(hog)), 0);
        assertEq(vault.owed(address(coin)), 100e18, "the others book");
        _deposit(bob, 1e24);
        _withdraw(bob, 1e24);
        hog.setHogging(false);
        vault.harvest();
        assertEq(vault.owed(address(hog)), 100e18, "booked once it answers again");
    }

    /// A token with no code, or one that answers too little, reads as nothing.
    function testABalanceReadThatFailsBooksNothing() public {
        vm.prank(curator);
        vault.addRewardToken(address(0xDEAD0001));
        vault.harvest();
        assertEq(vault.owed(address(0xDEAD0001)), 0);
        _deposit(bob, 1e24);
    }

    /// A holder in for the whole payout and one in for half of it split what each held.
    function testALateDepositorEarnsOnlyForTheTimeHeld() public {
        _pay(address(coin), 1000e18);
        skip(PERIOD / 2);
        _deposit(bob, vault.balanceOf(curator));
        skip(PERIOD / 2);
        // The curator had all of the first half and a half of the second.
        assertApproxEqRel(vault.earned(curator, address(coin)), 450e18 + 225e18, 1e12);
        assertApproxEqRel(vault.earned(bob, address(coin)), 225e18, 1e12);
    }

    /// Joining just before a payout and leaving at once earns nothing from it: the payout
    /// streams, and the leaver was there for none of the stream.
    function testDepositingJustBeforeAPayoutThenLeavingEarnsNothing() public {
        uint256 shares = vault.balanceOf(curator);
        _deposit(bob, shares);
        TestAsset(address(coin)).mint(address(vault), 1000e18);
        uint256 before = coin.balanceOf(bob);
        _withdraw(bob, shares);
        assertGe(coin.balanceOf(bob), before, "paid its principal");
        assertEq(vault.earned(bob, address(coin)), 0, "and none of the payout");
        // The whole of it stays for the holders who remain.
        skip(PERIOD);
        assertApproxEqRel(vault.earned(curator, address(coin)), 900e18, 1e9);
    }

    // Booking.

    /// A deposit and a withdrawal book the fees their own unlock collects, against the
    /// supply as it was. Without it they would stay unbooked until the next checkpoint.
    function testFeesCollectedByADepositAreBookedAtOnce() public {
        _trade(first, address(coin), 50_000e18);
        _deposit(bob, 1e24);
        assertEq(vault.unbooked(address(coin)), 0, "nothing left unbooked");
        assertGt(vault.owed(address(coin)), 0, "it was booked");
        _trade(first, address(coin), 50_000e18);
        uint256 owedBefore = vault.owed(address(coin));
        _withdraw(bob, 1e24);
        assertEq(vault.unbooked(address(coin)), 0);
        assertGt(vault.owed(address(coin)), owedBefore, "a withdrawal books too");
    }

    /// A profit token that is also a pair token is told apart from idle principal.
    function testAProfitTokenThatIsAPairTokenIsKeptApartFromPrincipal() public {
        vm.prank(alice);
        vault.addIdle(5e18, 5e18);
        _pay(token0, 100e18);
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0, 5e18, "principal is untouched");
        assertEq(idle1, 5e18);
        assertEq(vault.owed(token0), 100e18, "only the profit is reserved");
        assertEq(vault.unbooked(token0), 0);
        // A holder who leaves takes its part of principal and none of the stream.
        _withdraw(curator, vault.balanceOf(curator));
        assertEq(vault.owed(token0), 100e18, "the stream is still reserved");
        assertEq(_surplus(token0), 100e18, "and still held, apart from principal");
    }

    /// A balance that falls below what is reserved reads as nothing new and never reverts.
    function testARebasingBalanceClampsInsteadOfReverting() public {
        _pay(address(coin), 100e18);
        vm.prank(address(vault));
        coin.transfer(address(0xB0B), 60e18);
        assertEq(vault.unbooked(address(coin)), 0);
        vault.harvest();
        _deposit(bob, 1e24);
        _withdraw(bob, 1e24);
        assertEq(vault.owed(address(coin)), 100e18, "what was booked stays booked");
    }

    function testTokensOutsideTheListSitIdleUntilAdded() public {
        TestAsset other = new TestAsset();
        other.mint(address(vault), 100e18);
        vault.harvest();
        assertEq(vault.owed(address(other)), 0, "not booked");
        vm.prank(curator);
        vault.addRewardToken(address(other));
        vault.harvest();
        assertEq(vault.owed(address(other)), 100e18, "booked once it is on the list");
    }

    // The curator's fee.

    function testTheFeeIsTakenFromNewRewardsAndClaimed() public {
        _pay(address(coin), 1000e18);
        uint256 before = coin.balanceOf(curator);
        // Anyone may ask for it, and it goes to the curator.
        vm.prank(bob);
        vault.claimFee(_list(address(coin)));
        assertEq(coin.balanceOf(curator) - before, 100e18);
        assertEq(vault.feeOwed(address(coin)), 0);
        assertEq(vault.owed(address(coin)), 900e18, "the stream is still reserved");
        vm.prank(bob);
        vault.claimFee(_list(address(coin)));
        assertEq(coin.balanceOf(curator) - before, 100e18, "paid once");
    }

    function testTheFeeCanOnlyBeLowered() public {
        vm.prank(curator);
        vm.expectRevert(IHookVault.InvalidFee.selector);
        vault.lowerFee(1_001);
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.lowerFee(0);
        vm.prank(curator);
        vault.lowerFee(500);
        assertEq(vault.feeBps(), 500);
        _pay(address(coin), 1000e18);
        assertEq(vault.feeOwed(address(coin)), 50e18, "the lower fee applies");
        vm.prank(curator);
        vm.expectRevert(IHookVault.InvalidFee.selector);
        vault.lowerFee(600);
    }

    function testTheFeeAtCreationIsCapped() public {
        vm.expectRevert(IHookVault.InvalidFee.selector);
        deployCode(
            "ArbitrageVault.sol:ArbitrageVault",
            abi.encode(hook, id, first, curator, address(0), uint16(2_001))
        );
    }

    // Claims.

    function testClaimPaysTheCallerOnce() public {
        _deposit(bob, vault.balanceOf(curator));
        _pay(address(coin), 1000e18);
        skip(PERIOD);
        uint256 owed = vault.earned(bob, address(coin));
        assertGt(owed, 0);
        uint256 before = coin.balanceOf(bob);
        vm.prank(bob);
        vault.claim(_list(address(coin)));
        assertEq(coin.balanceOf(bob) - before, owed, "paid what was earned");
        assertEq(vault.earned(bob, address(coin)), 0);
        vm.prank(bob);
        vault.claim(_list(address(coin)));
        assertEq(coin.balanceOf(bob) - before, owed, "and not twice");
    }

    function testWithdrawalPaysTheCallersRewards() public {
        uint256 shares = vault.balanceOf(curator);
        _deposit(bob, shares);
        _pay(address(coin), 1000e18);
        skip(PERIOD);
        uint256 owed = vault.earned(bob, address(coin));
        uint256 before = coin.balanceOf(bob);
        vm.prank(bob);
        (uint256 out0, uint256 out1) = vault.withdraw(shares, 0, 0, block.timestamp);
        uint256 principal = address(coin) == token0 ? out0 : out1;
        assertEq(coin.balanceOf(bob) - before, principal + owed, "principal and rewards");
        assertEq(vault.earned(bob, address(coin)), 0);
    }

    /// A reward token that will not pay a holder cannot hold that holder's principal back.
    function testARewardTokenThatRefusesCannotBlockAWithdrawal() public {
        BlockingAsset odd = new BlockingAsset();
        vm.prank(curator);
        vault.addRewardToken(address(odd));
        uint256 shares = vault.balanceOf(curator);
        _deposit(bob, shares);
        _pay(address(odd), 1000e18);
        skip(PERIOD);
        odd.setBlocked(bob);
        uint256 owed = vault.earned(bob, address(odd));
        assertGt(owed, 0);
        _withdraw(bob, shares);
        assertEq(vault.balanceOf(bob), 0, "the shares are gone");
        assertEq(vault.earned(bob, address(odd)), owed, "the reward waits to be claimed");
        odd.setBlocked(address(0));
        vm.prank(bob);
        vault.claim(_list(address(odd)));
        assertEq(odd.balanceOf(bob), owed);
    }

    // Transfers.

    function testAShareTransferMovesNoEarnedRewards() public {
        _pay(address(coin), 1000e18);
        skip(PERIOD / 2);
        uint256 earned = vault.earned(curator, address(coin));
        uint256 shares = vault.balanceOf(curator);
        vm.prank(curator);
        vault.transfer(bob, shares);
        assertEq(vault.earned(curator, address(coin)), earned, "the sender keeps its own");
        assertEq(vault.earned(bob, address(coin)), 0, "the receiver gets none of it");
        skip(PERIOD / 2);
        assertEq(vault.earned(curator, address(coin)), earned, "and earns no more");
        assertApproxEqRel(vault.earned(bob, address(coin)), 450e18, 1e9);
    }

    // The controller.

    function testTheControllersProfitIsPushedAndBookedFirst() public {
        coin.mint(address(mock), 500e18);
        uint256 before = mock.calls();
        _deposit(bob, 1e24);
        assertEq(mock.calls() - before, 1, "one call per deposit");
        assertEq(coin.balanceOf(address(mock)), 0, "pushed down");
        assertEq(vault.owed(address(coin)), 500e18, "and booked in the same action");
        assertEq(vault.unbooked(address(coin)), 0);
        vm.prank(curator);
        vault.transfer(alice, 1e18);
        assertEq(mock.calls() - before, 2, "a share transfer is a checkpoint too");
    }

    function testABrokenControllerNeverBlocksAWithdrawal() public {
        _deposit(bob, 1e24);
        mock.setBroken(true);
        _withdraw(bob, 1e24);
        assertEq(vault.balanceOf(bob), 0);
    }

    // The deposit cap.

    function testDepositsAreRefusedAboveTheCap() public {
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.setDepositCap(supply + 10);
        vm.prank(curator);
        vault.setDepositCap(supply + 1e24);
        vm.prank(bob);
        vm.expectRevert(IHookVault.DepositCapExceeded.selector);
        vault.deposit(1e24 + 1, MAX, MAX, block.timestamp);
        _deposit(bob, 1e24);
        assertEq(vault.totalSupply(), supply + 1e24);
    }

    // The list and its gas.

    function testTheListIsCappedAtTen() public {
        assertEq(vault.rewardTokens().length, 2);
        for (uint256 index; index < 8; index++) {
            address added = address(new TestAsset());
            vm.prank(curator);
            vault.addRewardToken(added);
        }
        address ninth = address(new TestAsset());
        vm.prank(curator);
        vm.expectRevert(IHookVault.TooManyRewardTokens.selector);
        vault.addRewardToken(ninth);
        vm.prank(curator);
        vm.expectRevert(IHookVault.InvalidRewardToken.selector);
        vault.addRewardToken(token0);
        vm.prank(alice);
        vm.expectRevert(IHookVault.NotCurator.selector);
        vault.addRewardToken(address(0xBEEF));
    }

    function testTenRewardTokensFitTheGas() public {
        address[] memory all = new address[](10);
        all[0] = token0;
        all[1] = token1;
        for (uint256 index = 2; index < 10; index++) {
            TestAsset extra = new TestAsset();
            all[index] = address(extra);
            vm.prank(curator);
            vault.addRewardToken(address(extra));
        }
        uint256 shares = vault.balanceOf(curator) / 2;
        _deposit(bob, shares);
        for (uint256 index; index < 10; index++) {
            TestAsset(all[index]).mint(address(vault), 1000e18);
        }
        skip(1 days);
        uint256 gas = gasleft();
        vm.prank(alice);
        vault.deposit(1e24, MAX, MAX, block.timestamp);
        uint256 depositGas = gas - gasleft();
        skip(1 days);
        gas = gasleft();
        vm.prank(bob);
        vault.withdraw(shares, 0, 0, block.timestamp);
        uint256 withdrawGas = gas - gasleft();
        emit log_named_uint("deposit gas with 10 reward tokens", depositGas);
        emit log_named_uint("withdraw gas with 10 reward tokens", withdrawGas);
        assertLt(depositGas, 3_000_000);
        assertLt(withdrawGas, 3_000_000);
        for (uint256 index; index < 10; index++) {
            assertGt(vault.owed(all[index]), 0, "every token was booked");
        }
    }
}
