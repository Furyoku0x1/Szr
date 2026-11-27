// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexPositions } from "../src/index/IndexPositions.sol";
import { IndexToken } from "./utils/IndexWorld.sol";
import { PositionsWorld } from "./IndexPositions.t.sol";

/// @dev An owner contract that records, when ETH reaches it, what it already holds of the
/// share and the baseline the position shows, and tries one call back in.
contract EtherOwner {
    IndexPositions internal immutable positions;
    address internal immutable share;
    uint256 public id;
    uint256 public shareAtEther;
    uint256 public lastAtEther;
    uint256 public received;
    bytes public reentry;
    bool public tried;
    bool public reentryOk;
    bytes public reentryError;

    constructor(IndexPositions positions_, address share_) {
        positions = positions_;
        share = share_;
        ERC20(share_).approve(address(positions_), type(uint256).max);
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function open(PoolKey calldata key, int24 lower, int24 upper, uint128 units)
        external
        payable
    {
        id = positions.open{ value: msg.value }(key, lower, upper, units, 1e30, 1e30, 1e30);
    }

    function increase(uint128 units) external payable {
        positions.increase{ value: msg.value }(id, units, 1e30, 1e30, 1e30);
    }

    function decrease(uint128 units) external {
        positions.decrease(id, units, 0, 0, 1e30);
    }

    function harvest() external returns (uint128) {
        return positions.harvest(id, 0, 0, 1e30);
    }

    receive() external payable {
        received += msg.value;
        shareAtEther = ERC20(share).balanceOf(address(this));
        (,,,,,, lastAtEther) = positions.position(id);
        if (reentry.length == 0) return;
        tried = true;
        (reentryOk, reentryError) = address(positions).call(reentry);
    }
}

/// @dev Native ETH pools, the order payments go out in, refunds and re-entry.
contract IndexPositionsPaymentTest is PositionsWorld {
    IndexPool internal share;
    PoolKey internal key;
    EtherOwner internal owner;

    function setUp() public override {
        super.setUp();
        share = _share();
        key = _venue(address(0), address(share), address(0));
        owner = new EtherOwner(positions, address(share));
        share.transfer(address(owner), 1e23);
        vm.deal(address(owner), 1e30);
        (int24 lower, int24 upper) = _full();
        owner.open{ value: 1e24 }(key, lower, upper, UNITS);
    }

    function testEtherIsPaidLastAndAfterTheRecord() public {
        _grow(share, 20);
        uint256 managerBefore = address(manager).balance;
        uint256 before = address(owner).balance;
        uint256 received = owner.received();
        assertGt(owner.harvest(), 0);
        uint256 paid = address(owner).balance - before;
        assertGt(paid, 0);
        assertEq(paid, managerBefore - address(manager).balance, "exactly what the pool paid");
        assertEq(owner.received() - received, paid, "in one payment");
        // The share had already arrived, and the new baseline was already written.
        assertEq(owner.shareAtEther(), share.balanceOf(address(owner)), "share first");
        assertEq(owner.lastAtEther(), share.growthIndex(), "record first");
        _assertEmpty(key);
    }

    function testSurplusEtherIsRefunded() public {
        uint256 managerBefore = address(manager).balance;
        uint256 before = address(owner).balance;
        vm.deal(address(this), 1e24);
        owner.increase{ value: 1e24 }(UNITS);
        // The ETH came from here, and what was not used went back to the owner.
        uint256 cost = 1e24 - (address(owner).balance - before);
        assertGt(cost, 0);
        assertLt(cost, 1e24);
        assertEq(cost, address(manager).balance - managerBefore, "only the deposit kept");
        _assertEmpty(key);
        // A pool without ETH refunds all of it.
        PoolKey memory plain = _venue(address(share), _plain(), address(0));
        _fund(alice, plain);
        (int24 lower, int24 upper) = _full();
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        positions.open{ value: 5 ether }(plain, lower, upper, UNITS, FAR, FAR, FAR);
        assertEq(alice.balance, 5 ether);
        _assertEmpty(plain);
    }

    function testTooLittleEtherReverts() public {
        vm.expectRevert(IndexPositions.InsufficientEther.selector);
        owner.increase{ value: 1 }(UNITS);
    }

    /// Every call made back in while ETH is being paid is refused, so the receiver gets
    /// only the one payment.
    function testReentryDuringAnEtherPaymentGetsNothing() public {
        uint256 id = owner.id();
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(IndexPositions.harvest, (id, 0, 0, FAR));
        calls[1] = abi.encodeCall(IndexPositions.decrease, (id, 1e18, 0, 0, FAR));
        calls[2] = abi.encodeCall(IndexPositions.collect, (id));
        calls[3] = abi.encodeCall(IndexPositions.increase, (id, 1e18, FAR, FAR, FAR));
        calls[4] = abi.encodeCall(IndexPositions.transferOwner, (id, address(this)));
        calls[5] = abi.encodeCall(
            IndexPositions.open, (key, -SPACING, SPACING, 1e18, FAR, FAR, FAR)
        );
        for (uint256 index; index < calls.length; index++) {
            owner.setReentry(calls[index]);
            uint128 liquidity = _liquidity(id);
            uint256 managerBefore = address(manager).balance;
            uint256 before = address(owner).balance;
            owner.decrease(1e18);
            assertTrue(owner.tried());
            assertFalse(owner.reentryOk());
            assertEq(bytes4(owner.reentryError()), ReentrancyGuard.Reentrancy.selector);
            assertEq(address(owner).balance - before, managerBefore - address(manager).balance);
            assertEq(_liquidity(id), liquidity - 1e18);
            (address holder,,,,,,) = positions.position(id);
            assertEq(holder, address(owner));
        }
        assertEq(positions.positionCount(), 1);
        _assertEmpty(key);
    }

    /// A token that calls back while it is paid is refused the same way.
    function testReentryFromATokenTransferIsRefused() public {
        address plain = _plain();
        PoolKey memory pool = _venue(address(share), plain, address(0));
        _fund(alice, pool);
        (int24 lower, int24 upper) = _full();
        uint256 id = _open(alice, pool, lower, upper, UNITS);
        IndexToken(plain)
            .setReenter(address(positions), abi.encodeCall(IndexPositions.collect, (id)));
        vm.prank(alice);
        positions.decrease(id, 1e18, 0, 0, FAR);
        assertTrue(IndexToken(plain).reentered());
        assertFalse(IndexToken(plain).reenterOk());
        assertEq(bytes4(IndexToken(plain).reenterResult()), ReentrancyGuard.Reentrancy.selector);
        _assertEmpty(pool);
    }

    function testCollectPaysTheOwnerItsFees() public {
        // Fees in ETH from a swap through the v4 pool.
        vm.deal(address(this), 1e24);
        share.approve(address(swapper), FAR);
        _swapEther(1e20);
        uint256 before = address(owner).balance;
        uint256 id = owner.id();
        vm.prank(address(owner));
        (uint256 fees0, uint256 fees1) = positions.collect(id);
        assertGt(fees0, 0);
        assertEq(fees1, 0);
        assertEq(address(owner).balance - before, fees0);
        _assertEmpty(key);
    }

    function _swapEther(uint256 amount) internal {
        PoolSwapTest.TestSettings memory settings;
        swapper.swap{ value: amount }(
            key,
            IPoolManager.SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1),
            settings,
            ""
        );
    }
}
