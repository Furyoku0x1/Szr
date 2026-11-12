// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SzrWorld } from "./utils/SzrWorld.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { ReleaseSchedule } from "../src/ReleaseSchedule.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Szr } from "../src/Szr.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";

contract SzrHandler is Test {
    SzrCore public core;
    Liquidity public locker;
    FeeCollector public jar;
    TestAsset public backing;
    Szr public token;
    PoolSwapTest public swapper;
    address[3] internal actors;
    bool public floorFell;
    bool public soldBelowMinimum;
    uint256 public acquisitions;
    uint256 public draws;
    uint256 public repayments;
    uint256 public settlements;

    constructor(
        SzrCore reserveCore,
        Liquidity liquidity,
        FeeCollector feeJar,
        PoolSwapTest swaps
    ) {
        core = reserveCore;
        swapper = swaps;
        locker = liquidity;
        jar = feeJar;
        backing = TestAsset(reserveCore.backingAsset());
        token = reserveCore.token();
        actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];
    }

    modifier preserveNAV() {
        uint256 oldBacking = core.backingAmount();
        uint256 oldSupply = core.activeSupply();
        _;
        uint256 supply = core.activeSupply();
        if (oldSupply != 0) {
            if (supply != 0) {
                if (core.backingAmount() * oldSupply < oldBacking * supply) floorFell = true;
            }
        }
    }

    function acquire(uint256 actor) external preserveNAV {
        uint256 quantity = core.availableRelease();
        if (quantity == 0) return;
        if (quantity > 100e18) quantity = 100e18;
        address owner = actors[actor % 3];
        (uint256 payment,,) = core.quote(quantity);
        if (payment * 2 < core.backingRequired(quantity) * 3) soldBelowMinimum = true;
        if (backing.balanceOf(owner) < payment) return;
        vm.prank(owner);
        core.buy(quantity, payment, block.timestamp);
        acquisitions++;
    }

    function borrow(uint256 actor, uint256 rawCollateral, uint256 rawPrincipal)
        external
        preserveNAV
    {
        address owner = actors[actor % 3];
        (uint256 locked, uint256 debt, uint256 expiry) = core.loans(owner);
        if (debt != 0) {
            if (block.timestamp >= expiry) return;
        }
        uint256 added = bound(rawCollateral, 0, token.balanceOf(owner));
        uint256 capacity = FixedPointMathLib.fullMulDiv(
            locked + added, core.backingAmount(), core.activeSupply()
        );
        if (capacity <= debt + 1) return;
        uint256 available = capacity - debt;
        if (available > core.reserveCash()) available = core.reserveCash();
        if (available < 2) return;
        uint256 principal = bound(rawPrincipal, 2, available);
        vm.prank(owner);
        core.borrow(added, principal);
        draws++;
    }

    function repay(uint256 actor, uint256 rawAmount, bool reclaimNow) external preserveNAV {
        address owner = actors[actor % 3];
        (, uint256 principal,) = core.loans(owner);
        if (principal == 0) return;
        uint256 amount = bound(rawAmount, 1, principal);
        vm.prank(owner);
        if (reclaimNow) core.repayAndReclaim(amount);
        else core.repay(amount);
        repayments++;
    }

    function reclaim(uint256 actor, uint256 rawAmount) external preserveNAV {
        address owner = actors[actor % 3];
        uint256 available = core.reclaimableCollateral(owner);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.prank(owner);
        core.reclaimCollateral(amount);
    }

    function redeemTokens(uint256 actor, uint256 rawAmount) external preserveNAV {
        address owner = actors[actor % 3];
        uint256 held = token.balanceOf(owner);
        if (held == 0) return;
        uint256 amount = bound(rawAmount, 1, held);
        uint256 payout =
            FixedPointMathLib.fullMulDiv(amount, core.backingAmount(), core.activeSupply());
        if (payout > core.reserveCash()) return;
        vm.prank(owner);
        core.redeem(amount, payout);
    }

    function renew(uint256 actor) external preserveNAV {
        address owner = actors[actor % 3];
        (, uint256 principal, uint256 expiry) = core.loans(owner);
        if (principal == 0) return;
        if (block.timestamp >= expiry) return;
        vm.prank(owner);
        core.poke();
    }

    function expire(uint256 actor) external preserveNAV {
        address owner = actors[actor % 3];
        (, uint256 principal, uint256 expiry) = core.loans(owner);
        if (principal == 0) return;
        if (block.timestamp < expiry) return;
        core.settleExpired(owner);
        settlements++;
    }

    function claimTeamFees() external preserveNAV {
        if (core.economics().claimableFees() == 0) return;
        core.economics().claimFees();
    }

    function donate(uint256 actor, uint256 rawAmount) external preserveNAV {
        uint256 amount = bound(rawAmount, 1, 1e18);
        vm.prank(actors[actor % 3]);
        core.donateBacking(amount);
    }

    function donateTokens(uint256 actor, uint256 rawAmount) external preserveNAV {
        address owner = actors[actor % 3];
        uint256 held = token.balanceOf(owner);
        if (held == 0) return;
        uint256 amount = bound(rawAmount, 1, held);
        if (amount == core.activeSupply()) return;
        vm.prank(owner);
        core.donateSzr(amount);
    }

    function swap(uint256 actor, bool inputBacking, uint256 rawAmount) external preserveNAV {
        address owner = actors[actor % 3];
        address input = inputBacking ? address(backing) : address(token);
        uint256 held = inputBacking ? backing.balanceOf(owner) : token.balanceOf(owner);
        if (held == 0) return;
        uint256 limit = held > 10e18 ? 10e18 : held;
        uint256 amount = bound(rawAmount, 1, limit);
        PoolKey memory key = locker.key(0);
        bool zeroForOne = Currency.unwrap(key.currency0) == input;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings;
        vm.prank(owner);
        swapper.swap(key, params, settings, "");
    }

    function acceptManagement() external {
        locker.acceptManager();
    }

    function collect() external preserveNAV {
        locker.collect(0);
    }

    function reallocate(uint256 rawUnits) external preserveNAV {
        uint256 held = locker.liquidityHeld(0);
        if (held < 100) return;
        uint256 units = bound(rawUnits, 10, held / 2);
        locker.withdrawPrincipal(0, units, 0, 0, block.timestamp);
        locker.deployPrincipal(
            0,
            units / 2,
            Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
    }

    function elapse(uint256 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 1, 40 days));
    }
}

contract SzrInvariantTest is SzrWorld {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;
    SzrHandler internal handler;

    function setUp() public override {
        super.setUp();
        _acquire(alice);
        handler = new SzrHandler(core, locker, jar, swapper);
        locker.nominateManager(address(handler));
        handler.acceptManagement();
        bytes4[] memory selectors = new bytes4[](14);
        selectors[13] = handler.donateTokens.selector;
        selectors[0] = handler.acquire.selector;
        selectors[1] = handler.borrow.selector;
        selectors[2] = handler.repay.selector;
        selectors[3] = handler.renew.selector;
        selectors[4] = handler.expire.selector;
        selectors[5] = handler.collect.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.elapse.selector;
        selectors[8] = handler.swap.selector;
        selectors[9] = handler.reclaim.selector;
        selectors[10] = handler.redeemTokens.selector;
        selectors[11] = handler.claimTeamFees.selector;
        selectors[12] = handler.reallocate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantCashInventoryDebtAndLoanCoverage() public view {
        _assertCash();
        uint256 totalDebt;
        uint256 totalCollateral;
        uint256 reclaimable;
        address[3] memory actors = [alice, bob, charlie];
        for (uint256 index; index < 3; index++) {
            (uint256 collateral, uint256 debt,) = core.loans(actors[index]);
            totalDebt += debt;
            totalCollateral += collateral;
            reclaimable += core.reclaimableCollateral(actors[index]);
            assertLe(debt * core.activeSupply(), collateral * core.backingAmount());
        }
        assertEq(core.loanPrincipal(), totalDebt);
        assertEq(core.pledgedSupply(), totalCollateral);
        assertEq(core.totalReclaimable(), reclaimable);
        uint256 unlocked = core.activeSupply() - totalCollateral;
        assertGe(core.reserveCash() * core.activeSupply(), core.backingAmount() * unlocked);
        assertFalse(handler.floorFell());
        assertFalse(handler.soldBelowMinimum());
        assertEq(core.publicInventory() + core.migrationRemaining(), core.unreleasedSupply());
        assertGe(backing.balanceOf(address(core.economics())), core.economics().claimableFees());
    }

    function invariantGrossReleaseAndPhysicalLP() public view {
        Liquidity.Position memory entry = locker.position(0);
        assertGt(entry.units, 0);
        (uint128 held,,) = manager.getPositionInfo(
            entry.key.toId(),
            address(locker),
            entry.tickLower,
            entry.tickUpper,
            bytes32(uint256(1))
        );
        assertEq(held, entry.units);
        assertEq(
            core.token().balanceOf(address(locker)), locker.heldPrincipal(address(core.token()))
        );
        assertEq(backing.balanceOf(address(locker)), locker.heldPrincipal(address(backing)));
        assertLe(core.availableRelease(), core.publicInventory());
        uint256 elapsed = block.timestamp - core.auctionsOpenAt();
        uint256 scheduled = ReleaseSchedule.cumulativeScaled(elapsed) / 1 days;
        assertEq(core.releaseCredit() + core.totalReleased(), scheduled);
    }
}
