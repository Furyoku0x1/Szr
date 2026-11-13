// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrEconomics } from "../src/SzrEconomics.sol";

contract SzrEconomicsTest is SzrWorld {
    function testFixedBillionSupplyHasNoReservedTeamInventory() public view {
        assertEq(core.token().totalSupply(), 1_000_000_000e18);
        assertEq(core.token().MAX_SUPPLY(), 1_000_000_000e18);
        assertEq(core.economics().TEAM_FEE_BPS(), 3_300);
        assertEq(core.publicInventory(), core.unreleasedSupply());
        assertEq(core.token().name(), "Sazare");
        assertEq(core.token().symbol(), "SZR");
    }

    function testOnlyRealizedFeesAreSplitAndDustStaysInReserves() public {
        uint256 beforeReserves = core.reserveCash();
        backing.mint(address(jar), 101);
        vm.prank(address(locker));
        jar.recordFees(address(backing), 101);
        assertEq(core.reserveCash() - beforeReserves, 68);
        assertEq(core.economics().claimableFees(), 33);
        assertEq(backing.balanceOf(address(core.economics())), 33);
        _assertCash();
    }

    function testTeamFeeClaimsCannotSpendFloorReserves() public {
        backing.mint(address(jar), 100e18);
        vm.prank(address(locker));
        jar.recordFees(address(backing), 100e18);
        uint256 reserves = core.reserveCash();
        uint256 nav = core.NAV();
        uint256 teamCash = backing.balanceOf(address(this));
        vm.prank(alice);
        core.economics().claimFees();
        assertEq(backing.balanceOf(address(this)) - teamCash, 33e18);
        assertEq(core.economics().claimableFees(), 0);
        assertEq(core.reserveCash(), reserves);
        assertEq(core.NAV(), nav);
        _assertCash();
    }

    function testWethSentByMistakeIsPaidToTheBeneficiaryWithTheNextClaim() public {
        SzrEconomics economics = core.economics();
        backing.mint(address(economics), 5e18); // a direct transfer, never recorded as fees
        assertEq(economics.claimableFees(), 0);
        uint256 reserves = core.reserveCash();
        uint256 teamCash = backing.balanceOf(address(this));
        vm.prank(alice);
        assertEq(economics.claimFees(), 5e18);
        assertEq(backing.balanceOf(address(this)) - teamCash, 5e18);

        backing.mint(address(economics), 1e18);
        backing.mint(address(jar), 100e18);
        vm.prank(address(locker));
        jar.recordFees(address(backing), 100e18);
        assertEq(economics.claimableFees(), 33e18);
        economics.claimFees();
        assertEq(backing.balanceOf(address(this)) - teamCash, 39e18);
        assertEq(economics.claimableFees(), 0);
        assertEq(backing.balanceOf(address(economics)), 0);
        assertEq(core.reserveCash(), reserves + 67e18);
        vm.expectRevert(SzrEconomics.ZeroAmount.selector);
        economics.claimFees();
        _assertCash();
    }

    function testBeneficiaryHandoverRequiresNominationAndAcceptance() public {
        SzrEconomics economics = core.economics();
        vm.prank(alice);
        vm.expectRevert(SzrEconomics.NotBeneficiary.selector);
        economics.nominateBeneficiary(alice);
        vm.expectRevert(SzrEconomics.ZeroAddress.selector);
        economics.nominateBeneficiary(address(0));
        vm.expectRevert(SzrEconomics.InvalidBeneficiary.selector);
        economics.nominateBeneficiary(address(this));

        economics.nominateBeneficiary(alice);
        vm.prank(alice);
        vm.expectRevert(SzrEconomics.NotBeneficiary.selector);
        economics.cancelBeneficiaryNomination();
        economics.cancelBeneficiaryNomination();
        vm.prank(alice);
        vm.expectRevert(SzrEconomics.NotNominee.selector);
        economics.acceptBeneficiary();

        // A nomination alone moves nothing: fees still reach the current beneficiary.
        economics.nominateBeneficiary(alice);
        backing.mint(address(economics), 2e18);
        uint256 teamCash = backing.balanceOf(address(this));
        economics.claimFees();
        assertEq(backing.balanceOf(address(this)) - teamCash, 2e18);
        vm.prank(bob);
        vm.expectRevert(SzrEconomics.NotNominee.selector);
        economics.acceptBeneficiary();

        vm.prank(alice);
        economics.acceptBeneficiary();
        assertEq(economics.beneficiary(), alice);
        assertEq(economics.pendingBeneficiary(), address(0));
        vm.expectRevert(SzrEconomics.NotBeneficiary.selector);
        economics.nominateBeneficiary(bob);

        uint256 reserves = core.reserveCash();
        backing.mint(address(jar), 100e18);
        vm.prank(address(locker));
        jar.recordFees(address(backing), 100e18);
        uint256 aliceCash = backing.balanceOf(alice);
        economics.claimFees();
        assertEq(backing.balanceOf(alice) - aliceCash, 33e18);
        assertEq(backing.balanceOf(address(this)) - teamCash, 2e18);
        assertEq(core.reserveCash(), reserves + 67e18);
        _assertCash();
    }

    function testLoanOpeningFeeRemainsInReserves() public {
        _acquire(alice);
        uint256 reserves = core.reserveCash();
        uint256 team = core.economics().claimableFees();
        uint256 beforeCash = backing.balanceOf(alice);
        vm.prank(alice);
        core.borrow(100e18, 100e12);
        assertEq(core.reserveCash(), reserves - 99e12);
        assertEq(backing.balanceOf(alice), beforeCash + 99e12);
        assertEq(core.loanPrincipal(), 100e12);
        assertEq(core.economics().claimableFees(), team);
        _assertCash();
    }

    function testFuzzFeeSplitConservesEveryWei(uint128 raw) public {
        uint256 amount = bound(raw, 1, 1_000_000e18);
        uint256 cash = core.reserveCash();
        backing.mint(address(jar), amount);
        vm.prank(address(locker));
        jar.recordFees(address(backing), amount);
        uint256 team = core.economics().claimableFees();
        assertEq(team, amount * 3_300 / 10_000);
        assertEq(core.reserveCash() - cash + team, amount);
        _assertCash();
    }

    function testTeamBeneficiaryBuysThroughTheSamePublicAuction() public {
        uint256 amount = 1_000e18;
        (uint256 payment,,) = core.quote(amount);
        uint256 inventory = core.publicInventory();
        uint256 nav = core.NAV();
        uint256 beforeTokens = core.token().balanceOf(address(this));
        uint256 fees = core.economics().claimableFees();
        backing.mint(address(this), payment);
        core.buy(amount, payment, block.timestamp);
        assertEq(core.token().balanceOf(address(this)), beforeTokens + amount);
        assertEq(core.publicInventory(), inventory - amount);
        assertEq(core.economics().claimableFees(), fees);
        assertGe(core.NAV(), nav);
        _assertCash();
    }

    function testRemovedTeamClaimSelectorsCannotReleaseTokens() public {
        vm.warp(core.startedAt() + 731 days);
        backing.mint(address(this), 1e18);
        address feeModule = address(core.economics());
        uint256 inventory = core.publicInventory();
        uint256 beforeTokens = core.token().balanceOf(address(this));
        (bool success,) = feeModule.call(
            abi.encodeWithSignature(
                "claimTeamTokens(uint256,uint256)", uint256(1e18), type(uint256).max
            )
        );
        assertFalse(success);
        vm.prank(feeModule);
        (success,) = address(core)
            .call(
                abi.encodeWithSignature(
                    "releaseTeamTokens(uint256,uint256)", uint256(1e18), type(uint256).max
                )
            );
        assertFalse(success);
        assertEq(core.publicInventory(), inventory);
        assertEq(core.token().balanceOf(address(this)), beforeTokens);
        _assertCash();
    }
}
