// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { Basket } from "../src/basket/Basket.sol";
import { BasketFactory } from "../src/basket/BasketFactory.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { ManagerStub, ProtocolStub } from "./utils/BasketWorld.sol";
import { TestAsset } from "./utils/TestAsset.sol";

/// @dev A basket leg on the real arbitrage hook: two USD/COIN pools in a market that counts
/// in USD, the basket in one of them. The basket's own swaps open gaps the hook then closes.
contract BasketHookTest is MarketsWorld {
    int24 internal constant LOWER = -27_720;
    int24 internal constant UPPER = 27_720;
    PoolKey internal deep;
    PoolKey internal shallow;
    Basket internal basket;
    BasketFactory internal factory;

    function setUp() public override {
        super.setUp();
        vm.warp(1_000_000);
        deep = _create(address(usd), address(coin), 3_000);
        shallow = _create(address(usd), address(coin), 500);
        _lead(address(usd), address(coin), _list(_id(deep), _id(shallow)));
        _limits(address(usd), 1e15);
        ProtocolStub protocol = new ProtocolStub(address(new ManagerStub(address(this))));
        factory = new BasketFactory(
            manager, address(hook), address(protocol), type(Basket).creationCode
        );
        Basket.Leg[] memory legs = new Basket.Leg[](1);
        legs[0] = Basket.Leg(shallow, LOWER, UPPER);
        basket = Basket(factory.create("Basket", "BSKT", address(usd), 0, legs));
        TestAsset(address(usd)).mint(address(this), 1e30);
        coin.mint(address(this), 1e30);
        usd.approve(address(basket), type(uint256).max);
        coin.approve(address(basket), type(uint256).max);
        uint128[] memory seed = new uint128[](1);
        seed[0] = 1_000e18;
        uint256[] memory limits = new uint256[](2);
        limits[0] = type(uint256).max;
        limits[1] = type(uint256).max;
        basket.start(seed, 1_000e18, limits, block.timestamp);
        TestAsset(address(usd)).mint(alice, 1e30);
        vm.prank(alice);
        usd.approve(address(basket), type(uint256).max);
    }

    function _arbitraged() internal view returns (uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            if (logs[index].topics[0] == ArbitrageLogic.Arbitraged.selector) count++;
        }
    }

    function test_unitPathsThroughAHookedLeg() public {
        vm.recordLogs();
        vm.prank(alice);
        uint256 gas = gasleft();
        uint256 paid = basket.depositUnit(50_000e18, type(uint256).max, block.timestamp);
        emit log_named_uint("depositUnit gas, one hooked leg", gas - gasleft());
        assertGt(_arbitraged(), 0, "the basket's swap was searched and a gap closed");
        vm.recordLogs();
        vm.prank(alice);
        gas = gasleft();
        uint256 received = basket.redeemUnit(50_000e18, 0, block.timestamp);
        emit log_named_uint("redeemUnit gas, one hooked leg", gas - gasleft());
        assertGt(_arbitraged(), 0, "searched again on the way out");
        assertLe(received, paid, "no more than paid");
        _assertNothingHeld();
    }

    /// Three legs on the hook: every unit-path swap and the protocol payout run a search.
    /// The gas is recorded against the chain's 32M transaction cap (spec, "Hooked legs").
    function test_threeHookedLegsAndThePayout() public {
        _threeHooked(0);
    }

    /// Compounding and conversions run through hooked legs too; a hook's search inside a
    /// conversion may earn other legs fees, which must be collected before the share math.
    function test_threeHookedLegsCompound() public {
        _threeHooked(1);
    }

    function test_threeHookedLegsToUnit() public {
        _threeHooked(2);
    }

    function test_threeHookedLegsToStocks() public {
        _threeHooked(3);
    }

    function _threeHooked(uint8 mode) internal {
        Basket.Leg[] memory legs = new Basket.Leg[](3);
        legs[0] = Basket.Leg(shallow, LOWER, UPPER);
        for (uint256 index = 1; index < 3; index++) {
            TestAsset stock = new TestAsset();
            _approve(stock);
            PoolKey memory one = _create(address(usd), address(stock), 3_000);
            PoolKey memory other = _create(address(usd), address(stock), 500);
            _lead(address(usd), address(stock), _list(_id(one), _id(other)));
            legs[index] = Basket.Leg(other, LOWER, UPPER);
            stock.mint(address(this), 1e30);
        }
        Basket three = Basket(factory.create("Three", "THREE", address(usd), mode, legs));
        address[] memory list = three.tokens();
        uint256[] memory limits = new uint256[](4);
        for (uint256 index; index < 4; index++) {
            TestAsset(list[index]).approve(address(three), type(uint256).max);
            limits[index] = type(uint256).max;
        }
        uint128[] memory seed = new uint128[](3);
        for (uint256 index; index < 3; index++) {
            seed[index] = 1_000e18;
        }
        three.start(seed, 1_000e18, limits, block.timestamp);
        vm.prank(alice);
        usd.approve(address(three), type(uint256).max);
        vm.recordLogs();
        vm.prank(alice);
        uint256 gas = gasleft();
        uint256 paid = three.depositUnit(50_000e18, type(uint256).max, block.timestamp);
        uint256 depositGas = gas - gasleft();
        assertGt(_arbitraged(), 0, "searched");
        // A second later, so a conversion can run inside the redemption.
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        gas = gasleft();
        uint256 received = three.redeemUnit(50_000e18, 0, block.timestamp);
        uint256 redeemGas = gas - gasleft();
        gas = gasleft();
        uint256 cut = three.payProtocol(0, block.timestamp);
        uint256 payGas = gas - gasleft();
        emit log_named_uint("depositUnit gas, three hooked legs", depositGas);
        emit log_named_uint("redeemUnit gas, three hooked legs", redeemGas);
        emit log_named_uint("payProtocol gas, three hooked legs", payGas);
        assertLe(received, paid, "no more than paid");
        assertGt(cut, 0, "the cut was paid through hooked legs");
        assertLt(depositGas, 32_000_000, "deposit fits the chain cap");
        assertLt(redeemGas, 32_000_000, "redemption fits the chain cap");
    }
}
