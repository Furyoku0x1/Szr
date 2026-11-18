// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { VaultWorld, VaultHarness } from "./utils/VaultWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageVault } from "../src/vaults/ArbitrageVault.sol";
import { MarketController } from "../src/vaults/MarketController.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev A reward token whose balance is absurd: booking it would overflow.
contract HugeAsset is TestAsset {
    function balanceOf(address) public pure override returns (uint256) {
        return type(uint256).max;
    }
}

/// @dev A token that burns all the gas it is given when asked for a balance.
contract BurnAsset is TestAsset {
    function balanceOf(address) public view override returns (uint256) {
        while (gasleft() > 1000) { }
        return 0;
    }
}

/// @dev A controller whose push burns every gas it is given.
contract BurningController {
    function distribute(address[] calldata) external view {
        while (gasleft() > 1000) { }
    }
}

interface IReceiver {
    function onSend() external;
}

/// @dev A token that calls the receiver before it moves the balance, as a token with a send
/// hook (ERC777) does.
contract CallbackAsset is TestAsset {
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to.code.length != 0) {
            try IReceiver(to).onSend() { } catch { }
        }
        return super.transfer(to, amount);
    }
}

/// @dev A holder that, when a token calls it in the middle of a payout, moves a share of
/// the vault.
contract Leaver is IReceiver {
    ArbitrageVault internal immutable vault;
    uint256 public calls;

    constructor(ArbitrageVault vault_) {
        vault = vault_;
    }

    function onSend() external {
        calls++;
        vault.transfer(address(0xDEAD1), 1);
    }

    function deposit(uint256 shares, address a, address b) external {
        TestAsset(a).approve(address(vault), type(uint256).max);
        TestAsset(b).approve(address(vault), type(uint256).max);
        vault.deposit(shares, type(uint256).max, type(uint256).max, block.timestamp);
    }

    function leave(uint256 shares) external {
        vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function claim(address token) external {
        address[] memory list = new address[](1);
        list[0] = token;
        vault.claim(list);
    }
}

/// @dev The fixes of the 2026-11-17 review that belong to the vault core.
contract HookVaultReviewTest is VaultWorld {
    uint256 internal constant MAX = type(uint256).max;

    function setUp() public override {
        super.setUp();
        _seed(1);
    }

    function _deposit(address who, uint256 shares) internal {
        vm.prank(who);
        vault.deposit(shares, MAX, MAX, block.timestamp);
    }

    // A huge balance.

    /// A reward token that reports 2^256-1 would overflow the booking. It reads as a failed
    /// read instead, and holders can still leave.
    function testAnAbsurdBalanceRewardTokenDoesNotBlockWithdrawals() public {
        HugeAsset huge = new HugeAsset();
        vm.prank(curator);
        vault.addRewardToken(address(huge));
        _deposit(alice, 1e24);
        vault.harvest();
        assertEq(vault.unbooked(address(huge)), 0, "nothing is booked for it");
        assertEq(vault.owed(address(huge)), 0);
        vm.prank(alice);
        vault.withdraw(1e24, 0, 0, block.timestamp);
        assertEq(vault.balanceOf(alice), 0);
    }

    // Gas burned by the controller.

    /// The vault caps what the controller's push may use, so one that burns all it is given
    /// cannot take the gas a withdrawal needs.
    function testAControllerThatBurnsGasCannotBlockAWithdrawal() public {
        BurningController burner = new BurningController();
        VaultHarness made = VaultHarness(
            deployCode(
                "VaultWorld.sol:VaultHarness",
                abi.encode(hook, id, first, curator, address(burner), FEE_BPS)
            )
        );
        vault = made;
        _fundVault(curator);
        _fundVault(alice);
        _seed(1);
        _deposit(alice, 1e24);
        vm.prank(alice);
        vault.withdraw{ gas: 4_000_000 }(1e24, 0, 0, block.timestamp);
        assertEq(vault.balanceOf(alice), 0);
    }

    /// With the real controller, a reward token that burns gas in `balanceOf` is skipped
    /// by both the controller and the vault.
    function testAGasBurningTokenBehindARealControllerCannotBlockAWithdrawal() public {
        MarketController real = MarketController(
            deployCode(
                "MarketController.sol:MarketController",
                abi.encode(hook, id, curator, address(this))
            )
        );
        vm.prank(team);
        hook.nominateOwner(id, address(real));
        real.initialize();
        VaultHarness made = VaultHarness(
            deployCode(
                "VaultWorld.sol:VaultHarness",
                abi.encode(hook, id, first, curator, address(real), FEE_BPS)
            )
        );
        vault = made;
        vm.startPrank(curator);
        real.addVault(address(made), 6_000);
        made.addRewardToken(address(new BurnAsset()));
        vm.stopPrank();
        _fundVault(curator);
        _fundVault(alice);
        _seed(1);
        _deposit(alice, 1e24);
        backing.mint(address(real), 100e18);
        vm.prank(alice);
        vault.withdraw{ gas: 4_000_000 }(1e24, 0, 0, block.timestamp);
        assertEq(vault.balanceOf(alice), 0);
        assertGt(vault.owed(address(backing)), 0, "the push still ran for the honest token");
    }

    // A payout that calls back.

    function _callbackVault() internal returns (CallbackAsset token, Leaver leaver) {
        token = new CallbackAsset();
        _approve(token);
        PoolKey memory pool = _create(address(backing), address(token), 3_000);
        vault = _makeVault(pool);
        leaver = new Leaver(vault);
        address[3] memory who = [curator, alice, address(leaver)];
        for (uint256 index; index < who.length; index++) {
            backing.mint(who[index], 1e12 ether);
            token.mint(who[index], 1e12 ether);
            vm.startPrank(who[index]);
            backing.approve(address(vault), MAX);
            token.approve(address(vault), MAX);
            vm.stopPrank();
        }
        ArbitrageVault.Range[] memory ranges = new ArbitrageVault.Range[](1);
        ranges[0] = ArbitrageVault.Range(-60, 60);
        vm.prank(curator);
        vault.seed(ranges, _units(1, SEED_UNITS), MAX, MAX, block.timestamp);
        vm.prank(alice);
        vault.addIdle(1_000e18, 1_000e18);
    }

    function _assertBacked(CallbackAsset token) internal view {
        (uint256 idle0, uint256 idle1) = vault.principal();
        uint256 idle = vault.token0() == address(token) ? idle0 : idle1;
        assertLe(
            idle + vault.owed(address(token)),
            token.balanceOf(address(vault)),
            "owed and idle are within the balance"
        );
    }

    /// A token that calls its receiver before it debits the vault gives that receiver a
    /// moment in which the vault's balance has not yet fallen. A share transfer made then
    /// must book nothing, so what is owed and idle never exceeds what the vault holds.
    function testAWithdrawalReenteredByAShareTransferStaysBacked() public {
        (CallbackAsset token, Leaver leaver) = _callbackVault();
        leaver.deposit(2e24, address(backing), address(token));
        leaver.leave(1e24);
        assertGt(leaver.calls(), 0, "the token called back");
        _assertBacked(token);
        assertEq(vault.owed(address(token)), 0, "nothing was booked from the payout");
    }

    /// The same for a reward claim, where what is owed has already fallen by the amount
    /// being paid when the token calls back.
    function testAClaimReenteredByAShareTransferStaysBacked() public {
        (CallbackAsset token, Leaver leaver) = _callbackVault();
        leaver.deposit(2e24, address(backing), address(token));
        token.mint(address(vault), 1_000e18);
        vault.harvest();
        skip(3 days);
        uint256 owedBefore = vault.owed(address(token));
        leaver.claim(address(token));
        assertGt(leaver.calls(), 0, "the token called back");
        _assertBacked(token);
        assertLt(vault.owed(address(token)), owedBefore, "it was paid, not booked again");
    }
}
