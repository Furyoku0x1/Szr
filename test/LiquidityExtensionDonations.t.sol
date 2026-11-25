// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MetricExtensionWorld } from "./MetricLiquidityExtension.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { IMetricFactory } from "../src/interfaces/metric/IMetricFactory.sol";
import { LiquidityExtension } from "../src/extensions/LiquidityExtension.sol";
import { V4LiquidityExtension } from "../src/extensions/V4LiquidityExtension.sol";
import { MetricLiquidityExtension } from "../src/extensions/MetricLiquidityExtension.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";

/// @dev Keeps 1% of every `transferFrom`.
contract TaxedAsset is TestAsset {
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        uint256 tax = amount / 100;
        _burn(from, tax);
        return super.transferFrom(from, to, amount - tax);
    }
}

/// @dev Anyone may give either extension the tokens of its pools, as a gift the manager
/// then puts into positions (`docs/specs/extension-donations.md`).
contract LiquidityExtensionDonationsTest is MetricExtensionWorld {
    uint256 internal constant GIFT = 1_000e18;

    function testADonatedV4PositionIsPaidForByTheDonorAlone() public {
        V4LiquidityExtension fresh = new V4LiquidityExtension(
            locker, address(hook), IMetricFactory(address(metricFactory))
        );
        PoolKey memory pool = _openPool(address(backing), address(coin), 3_000);
        fresh.registerRoute(pool);
        _give(LiquidityExtension(payable(address(fresh))), coin, GIFT);
        _give(LiquidityExtension(payable(address(fresh))), backing, GIFT);
        uint256 pid = fresh.addPosition(pool, -600, 600);
        fresh.deploy(pid, 10_000e18, MAX, MAX, block.timestamp);
        assertLt(coin.balanceOf(address(fresh)), GIFT, "donated coin deployed");
        assertLt(backing.balanceOf(address(fresh)), GIFT, "donated WETH deployed");
    }

    function testADonatedMetricPositionIsPaidForByTheDonorAlone() public {
        MetricLiquidityExtension fresh = MetricLiquidityExtension(
            payable(deployCode(
                    "MetricLiquidityExtension.sol:MetricLiquidityExtension",
                    abi.encode(locker, address(hook), address(metricFactory))
                ))
        );
        fresh.addPool(address(pool));
        _give(LiquidityExtension(payable(address(fresh))), t0, GIFT);
        _give(LiquidityExtension(payable(address(fresh))), t1, GIFT);
        (uint256 paid0, uint256 paid1) = fresh.addLiquidity(
            address(pool), 1, _bins(), _shares(1e18), MAX, MAX, block.timestamp
        );
        assertGt(paid0, 0, "token0 paid from the gift");
        assertGt(paid1, 0, "token1 paid from the gift");
        assertEq(t0.balanceOf(address(fresh)), GIFT - paid0, "the rest stays");
    }

    function testWethIsDonatableWithNoPoolHoldingIt() public {
        _give(LiquidityExtension(payable(address(ext))), backing, GIFT);
        _give(LiquidityExtension(payable(address(mext))), backing, GIFT);
    }

    function testTokensOutsideEveryPoolAreRefused() public {
        _refused(_x(address(ext)), address(coin));
        _refused(_x(address(mext)), address(szr));
        _refused(_x(address(mext)), address(new TestAsset()));
        _etherRefused(_x(address(ext)));
        _etherRefused(_x(address(mext)));
    }

    function testEtherDonationsStayEther() public {
        PoolKey memory route = _openPool(address(0), address(coin), 3_000);
        ext.registerRoute(route);
        mext.registerRoute(route);
        _etherStaysEther(_x(address(ext)));
        _etherStaysEther(_x(address(mext)));
    }

    function testATokenThatTakesAFeeOnTransferIsRefused() public {
        TaxedAsset taxed = new TaxedAsset();
        PoolKey memory route = _pair(address(taxed), address(coin), 3_000, address(0));
        manager.initialize(route, uint160(1 << 96));
        ext.registerRoute(route);
        mext.registerRoute(route);
        _taxedRefused(_x(address(ext)), taxed);
        _taxedRefused(_x(address(mext)), taxed);
    }

    function testATokenDonationWorksInsideABatch() public {
        _batched(_x(address(ext)), backing);
        _batched(_x(address(mext)), t0);
    }

    /// `multicall` refuses ether, so an ether donation can't be counted once per batch entry.
    function testAnEtherDonationCannotBeBatched() public {
        PoolKey memory route = _openPool(address(0), address(coin), 3_000);
        ext.registerRoute(route);
        mext.registerRoute(route);
        _etherBatchRefused(_x(address(ext)));
        _etherBatchRefused(_x(address(mext)));
    }

    function _etherStaysEther(LiquidityExtension x) internal {
        uint256 held = address(x).balance;
        uint256 wrapped = backing.balanceOf(address(x));
        vm.deal(alice, 10e18);
        vm.expectEmit(true, true, false, true, address(x));
        emit LiquidityExtension.Donated(alice, address(0), 5e18);
        vm.prank(alice);
        x.donate{ value: 5e18 }(address(0), 5e18);
        assertEq(address(x).balance, held + 5e18, "kept as ETH");
        assertEq(backing.balanceOf(address(x)), wrapped, "nothing wrapped");
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        x.donate{ value: 1 }(address(0), 2);
        // Ether sent with a token donation would be kept without being counted.
        coin.mint(alice, 1);
        vm.prank(alice);
        coin.approve(address(x), 1);
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.UnexpectedEther.selector);
        x.donate{ value: 1 }(address(coin), 1);
        // Plain ether is still refused: a donation goes through `donate`.
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(x).call{ value: 1 }("");
        assertFalse(ok, "receive refuses a donor");
        assertEq(bytes4(reason), LiquidityExtension.UnexpectedEther.selector, "named error");
    }

    function _etherRefused(LiquidityExtension x) internal {
        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        x.donate{ value: 1 }(address(0), 1);
    }

    function _taxedRefused(LiquidityExtension x, TaxedAsset taxed) internal {
        taxed.mint(alice, GIFT);
        vm.prank(alice);
        taxed.approve(address(x), GIFT);
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.TransferAmountMismatch.selector);
        x.donate(address(taxed), GIFT);
    }

    function _batched(LiquidityExtension x, TestAsset asset) internal {
        uint256 before = asset.balanceOf(address(x));
        asset.mint(alice, GIFT);
        vm.prank(alice);
        asset.approve(address(x), GIFT);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(x.donate, (address(asset), GIFT / 2));
        calls[1] = abi.encodeCall(x.donate, (address(asset), GIFT / 2));
        vm.expectEmit(true, true, false, true, address(x));
        emit LiquidityExtension.Donated(alice, address(asset), GIFT / 2);
        vm.prank(alice);
        x.multicall(calls);
        assertEq(asset.balanceOf(address(x)), before + GIFT, "both entries donated");
    }

    function _etherBatchRefused(LiquidityExtension x) internal {
        uint256 held = address(x).balance;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(x.donate, (address(0), 1e18));
        calls[1] = abi.encodeCall(x.donate, (address(0), 1e18));
        vm.deal(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        x.multicall{ value: 1e18 }(calls);
        assertEq(address(x).balance, held, "nothing counted");
    }

    function _x(address target) internal pure returns (LiquidityExtension) {
        return LiquidityExtension(payable(target));
    }

    /// Alice gives `amount`; the balance and the event show exactly that.
    function _give(LiquidityExtension x, TestAsset asset, uint256 amount) internal {
        uint256 before = asset.balanceOf(address(x));
        uint256 own = asset.balanceOf(alice);
        asset.mint(alice, amount);
        vm.prank(alice);
        asset.approve(address(x), amount);
        vm.expectEmit(true, true, false, true, address(x));
        emit LiquidityExtension.Donated(alice, address(asset), amount);
        vm.prank(alice);
        x.donate(address(asset), amount);
        assertEq(asset.balanceOf(address(x)), before + amount, "donation received");
        assertEq(asset.balanceOf(alice), own, "donor paid it all");
    }

    function _refused(LiquidityExtension x, address asset) internal {
        vm.prank(alice);
        vm.expectRevert(LiquidityExtension.InvalidAsset.selector);
        x.donate(asset, 1);
    }
}
