// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Basket } from "../src/basket/Basket.sol";
import { BasketWorld, ClaimDonor, PausableAsset } from "./utils/BasketWorld.sol";

/// @dev Acts on a basket at random and checks after each action that no holder's slice of
/// any leg or idle claim shrank (invariants 1 and 9), that claims cover what is owed
/// (invariant 8), and that a round trip returns no more than it paid (invariant 2). Every
/// unlock settling (invariant 6) is covered by `fail_on_revert`. Idle claims a fee mode spends
/// are left out of the slice check: every one in compound, the stocks' in to unit, the unit
/// token's in to stocks.
contract BasketHandler is Test {
    using CurrencyLibrary for Currency;

    struct Snapshot {
        uint256 supply;
        uint256[] held;
        uint256[] idle;
    }

    Basket internal basket;
    IPoolManager internal manager;
    PoolSwapTest internal swapper;
    address internal managerRole;
    PoolKey[] internal pools;
    address[] internal list;
    ClaimDonor internal donor;
    uint8 internal mode;
    string public broken;
    uint256 public actions;

    constructor(
        Basket basket_,
        IPoolManager manager_,
        PoolSwapTest swapper_,
        address managerRole_,
        PoolKey[] memory pools_,
        uint8 mode_
    ) {
        basket = basket_;
        mode = mode_;
        manager = manager_;
        swapper = swapper_;
        managerRole = managerRole_;
        list = basket_.tokens();
        donor = new ClaimDonor(manager_);
        for (uint256 index; index < pools_.length; index++) {
            pools.push(pools_[index]);
        }
        for (uint256 index; index < list.length; index++) {
            PausableAsset(list[index]).mint(address(donor), 1e40);
            PausableAsset(list[index]).mint(address(this), 1e40);
            PausableAsset(list[index]).approve(address(basket_), type(uint256).max);
            PausableAsset(list[index]).approve(address(swapper_), type(uint256).max);
        }
    }

    function deposit(uint256 shares, bool inUnit) external {
        shares = bound(shares, 1, basket.totalSupply());
        Snapshot memory before = _snap();
        if (inUnit) basket.depositUnit(shares, type(uint256).max, block.timestamp);
        else basket.deposit(shares, _limits(type(uint256).max), block.timestamp);
        _check(before, "deposit");
    }

    function redeem(uint256 shares, bool inUnit) external {
        uint256 mine = basket.balanceOf(address(this));
        if (mine == 0) return;
        shares = bound(shares, 1, mine);
        Snapshot memory before = _snap();
        if (inUnit) basket.redeemUnit(shares, 0, block.timestamp);
        else basket.redeem(shares, _limits(0), block.timestamp);
        _check(before, "redeem");
    }

    function swap(uint256 which, uint256 amount, bool unitIn) external {
        PoolKey memory pool = pools[bound(which, 0, pools.length - 1)];
        amount = bound(amount, 1e18, 1e23);
        address stock = Currency.unwrap(pool.currency0) == list[0]
            ? Currency.unwrap(pool.currency1)
            : Currency.unwrap(pool.currency0);
        address input = unitIn ? list[0] : stock;
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        Snapshot memory before = _snap();
        swapper.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        _check(before, "swap");
    }

    /// Tokens sent straight to the basket are lost to it and change nothing.
    function donate(uint256 which, uint256 amount) external {
        address token = list[bound(which, 0, list.length - 1)];
        Snapshot memory before = _snap();
        PausableAsset(token).transfer(address(basket), bound(amount, 1, 1e24));
        _check(before, "donate");
    }

    /// Claims given to the basket are a gift to its holders. Kept well below the pools'
    /// depth: a pile of idle stock larger than its pool can sell makes deposits in the unit
    /// token revert (disclosed in the spec), while in-kind deposits still work.
    function donateClaims(uint256 which, uint256 amount) external {
        address token = list[bound(which, 0, list.length - 1)];
        Snapshot memory before = _snap();
        donor.donate(address(basket), token, bound(amount, 1, 1e21));
        _check(before, "donateClaims");
    }

    function roundTrip(uint256 shares, bool inUnit) external {
        shares = bound(shares, 1, basket.totalSupply());
        Snapshot memory before = _snap();
        if (inUnit) {
            uint256 paid = basket.depositUnit(shares, type(uint256).max, block.timestamp);
            uint256 received = basket.redeemUnit(shares, 0, block.timestamp);
            if (received > paid) broken = "unit round trip paid out more";
        } else {
            uint256[] memory start = _held();
            basket.deposit(shares, _limits(type(uint256).max), block.timestamp);
            basket.redeem(shares, _limits(0), block.timestamp);
            uint256[] memory end = _held();
            for (uint256 index; index < list.length; index++) {
                if (end[index] > start[index]) broken = "in-kind round trip paid out more";
            }
        }
        _check(before, "roundTrip");
    }

    function _held() internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            amounts[index] = PausableAsset(list[index]).balanceOf(address(this));
        }
    }

    /// Lets time pass, so conversions can run again.
    function wait(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 3600));
    }

    function pay() external {
        Snapshot memory before = _snap();
        vm.prank(managerRole);
        basket.payProtocol(0, block.timestamp);
        _check(before, "pay");
    }

    function _limits(uint256 value) internal view returns (uint256[] memory limits) {
        limits = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            limits[index] = value;
        }
    }

    function _snap() internal returns (Snapshot memory shot) {
        shot.supply = basket.totalSupply();
        shot.held = new uint256[](pools.length);
        shot.idle = new uint256[](list.length);
        for (uint256 index; index < pools.length; index++) {
            shot.held[index] = basket.liquidityOf(index);
        }
        for (uint256 index; index < list.length; index++) {
            uint256 claims =
                manager.balanceOf(address(basket), Currency.wrap(list[index]).toId());
            if (claims < basket.owed(list[index])) broken = "claims below owed";
            else shot.idle[index] = claims - basket.owed(list[index]);
        }
    }

    function _check(Snapshot memory before, string memory what) internal {
        actions++;
        Snapshot memory afterwards = _snap();
        for (uint256 index; index < before.held.length; index++) {
            uint256 was = before.held[index] * afterwards.supply;
            if (afterwards.held[index] * before.supply < was) broken = what;
        }
        for (uint256 index; index < before.idle.length; index++) {
            if (_spent(index)) continue;
            uint256 was = before.idle[index] * afterwards.supply;
            if (afterwards.idle[index] * before.supply < was) broken = what;
        }
    }

    function _spent(uint256 index) internal view returns (bool) {
        if (mode == 1) return true;
        if (mode == 2) return index != 0;
        if (mode == 3) return index == 0;
        return false;
    }
}

contract BasketInvariantTest is BasketWorld {
    BasketHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        Basket basket = _basket(3, _mode());
        PoolKey[] memory legs = new PoolKey[](3);
        for (uint256 index; index < 3; index++) {
            legs[index] = pools[index];
        }
        handler = new BasketHandler(basket, manager, swapper, address(this), legs, _mode());
        targetContract(address(handler));
    }

    function _mode() internal pure virtual returns (uint8) {
        return 0;
    }

    function invariant_noHolderSliceShrinks() public view {
        assertEq(handler.broken(), "", "a slice shrank, claims fell short, or a trip paid");
    }

    function afterInvariant() public view {
        assertGt(handler.actions(), 0, "the handler acted");
    }
}

contract BasketCompoundInvariantTest is BasketInvariantTest {
    function _mode() internal pure override returns (uint8) {
        return 1;
    }
}

contract BasketToUnitInvariantTest is BasketInvariantTest {
    function _mode() internal pure override returns (uint8) {
        return 2;
    }
}

contract BasketToStocksInvariantTest is BasketInvariantTest {
    function _mode() internal pure override returns (uint8) {
        return 3;
    }
}
