// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VaultWorld, VaultHarness } from "./utils/VaultWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IHookVault } from "../src/interfaces/IHookVault.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";

/// @dev A token that burns a tenth of what a receiver gets while `taxing`, and that tries
/// to call back into the vault when it moves while `target` is set.
contract OddAsset is TestAsset {
    bool public taxing;
    address public target;
    bool public reentered;
    bytes4 public refusal;

    function setTaxing(bool value) external {
        taxing = value;
    }

    function setTarget(address vault) external {
        target = vault;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (taxing) {
            if (from != address(0)) {
                if (to != address(0)) _burn(to, amount / 10);
            }
        }
        address vault = target;
        if (vault == address(0)) return;
        if (from == vault) return;
        target = address(0);
        // `harvest` is guarded like every entry point, so a call made while a deposit is in
        // the middle of paying must be refused.
        (bool ok, bytes memory reason) = vault.call(abi.encodeWithSignature("harvest()"));
        reentered = ok;
        if (!ok) refusal = bytes4(reason);
    }
}

/// @dev The market's WETH/odd-token pair, for tokens that misreport what a transfer moves
/// or that run code when they do.
contract HookVaultTokensTest is VaultWorld {
    OddAsset internal odd;
    VaultHarness internal oddVault;
    PoolKey internal pool;
    uint256 internal constant MAX = type(uint256).max;

    function setUp() public override {
        super.setUp();
        odd = new OddAsset();
        _approve(odd);
        pool = _create(address(backing), address(odd), 3_000);
        oddVault = VaultHarness(
            deployCode(
                "VaultWorld.sol:VaultHarness",
                abi.encode(hook, id, pool, curator, address(0), uint16(0))
            )
        );
        odd.mint(curator, 1e27);
        backing.mint(curator, 1e27);
        odd.mint(alice, 1e27);
        backing.mint(alice, 1e27);
        vm.startPrank(curator);
        odd.approve(address(oddVault), MAX);
        backing.approve(address(oddVault), MAX);
        vm.stopPrank();
        vm.startPrank(alice);
        odd.approve(address(oddVault), MAX);
        backing.approve(address(oddVault), MAX);
        vm.stopPrank();
        ArbitrageVault.Range[] memory ranges = new ArbitrageVault.Range[](1);
        ranges[0] = ArbitrageVault.Range(-60, 60);
        vm.prank(curator);
        oddVault.seed(ranges, _units(1, SEED_UNITS), MAX, MAX, block.timestamp);
    }

    /// Idle principal is booked at the amount asked for, so a token that delivers less is
    /// refused instead of leaving the vault owing more than it holds.
    function testATokenThatDeliversLessIsRefusedAsIdlePrincipal() public {
        odd.setTaxing(true);
        vm.prank(alice);
        vm.expectRevert(IHookVault.TransferAmountMismatch.selector);
        oddVault.addIdle(1e18, 1e18);
    }

    /// The pool manager settles what it received, so a token that delivers less than the
    /// vault owes it is refused in the middle of the unlock.
    function testATokenThatDeliversLessIsRefusedByThePool() public {
        odd.setTaxing(true);
        vm.prank(alice);
        vm.expectRevert(IHookVault.TransferAmountMismatch.selector);
        oddVault.deposit(1e24, MAX, MAX, block.timestamp);
        // Without the tax the same deposit works, and so does leaving.
        odd.setTaxing(false);
        vm.prank(alice);
        oddVault.deposit(1e24, MAX, MAX, block.timestamp);
        vm.prank(alice);
        oddVault.withdraw(1e24, 0, 0, block.timestamp);
    }

    /// A token that calls the vault while a deposit is paying is refused by the guard, so
    /// no entry point can be used in the middle of another.
    function testReentryFromATokenCallbackIsRefused() public {
        vm.prank(alice);
        oddVault.addIdle(1e18, 1e18);
        odd.setTarget(address(oddVault));
        vm.prank(alice);
        oddVault.deposit(1e24, MAX, MAX, block.timestamp);
        assertFalse(odd.reentered(), "the call went through");
        assertEq(odd.refusal(), ReentrancyGuard.Reentrancy.selector, "refused by the guard");
    }
}
