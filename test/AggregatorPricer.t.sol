// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { AggregatorPricer, IAggregatorHook } from "../src/pricers/AggregatorPricer.sol";

contract MockManager {
    uint256 public word;

    function setProtocolFee(uint24 fee) external {
        word = uint256(fee) << 184;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(word);
    }
}

contract MockOutside {
    address public token0;
    address public token1;
    uint160 public root = 2 ** 96 * 2;
    uint128 public liquidity = 7e18;
    uint24 public fee = 300;

    constructor(address first, address second) {
        token0 = first;
        token1 = second;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        return (root, 0, 0, 0, 0, true);
    }

    function setFee(uint24 value) external {
        fee = value;
    }
}

contract MockAggregator {
    address public poolManager;
    uint24 public protocolFeeMultiplier = 25;
    mapping(bytes32 => address) public poolIdToExternalPool;

    constructor(address manager) {
        poolManager = manager;
    }

    function wrap(PoolKey calldata pool, address outside) external {
        poolIdToExternalPool[PoolId.unwrap(PoolIdLibrary.toId(pool))] = outside;
    }
}

/// The aggregator pricer against mocks of the hook, the pool manager and the outside pool.
contract AggregatorPricerTest is Test {
    address internal constant A = address(0xA);
    address internal constant B = address(0xB);

    MockManager internal manager;
    MockAggregator internal hook;
    AggregatorPricer internal pricer;

    function setUp() public {
        manager = new MockManager();
        hook = new MockAggregator(address(manager));
        pricer = new AggregatorPricer(IAggregatorHook(address(hook)));
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(a), Currency.wrap(b), 0x800000, 1, IHooks(address(0xAA)));
    }

    function _wrap(PoolKey memory key, address first, address second)
        internal
        returns (MockOutside outside)
    {
        outside = new MockOutside(first, second);
        hook.wrap(key, address(outside));
    }

    function testPriceInPoolOrder() public {
        PoolKey memory key = _key(A, B);
        MockOutside outside = _wrap(key, A, B);
        (uint160 root, uint24 fee, uint128 depth, uint160 low, uint160 high) = pricer.price(key);
        assertEq(root, outside.root());
        assertEq(low, root);
        assertEq(high, root);
        assertEq(depth, 7e18);
        assertEq(fee, 300);
    }

    function testPriceInvertedWhenOutsideOrderDiffers() public {
        PoolKey memory key = _key(A, B);
        _wrap(key, B, A);
        (uint160 root,,,,) = pricer.price(key);
        assertEq(root, 2 ** 96 / 2);
    }

    function testFeeAddsTheLiveCutOfTheLargerDirection() public {
        PoolKey memory key = _key(A, B);
        _wrap(key, A, B);
        // 40 one way and 10 the other, times the hook's multiplier of 25.
        manager.setProtocolFee(uint24(10) << 12 | 40);
        (, uint24 fee,,,) = pricer.price(key);
        assertEq(fee, 300 + 40 * 25);
        manager.setProtocolFee(uint24(60) << 12 | 40);
        (, fee,,,) = pricer.price(key);
        assertEq(fee, 300 + 60 * 25);
    }

    function testRefusesMismatchedTokens() public {
        PoolKey memory key = _key(A, B);
        _wrap(key, A, address(0xC));
        vm.expectRevert(bytes("tokens"));
        pricer.price(key);
        PoolKey memory other = _key(A, address(0xD));
        _wrap(other, address(0xC), address(0xD));
        vm.expectRevert(bytes("tokens"));
        pricer.price(other);
    }

    function testRefusesNativeEther() public {
        PoolKey memory key = _key(address(0), B);
        _wrap(key, address(0), B);
        vm.expectRevert(bytes("ETH"));
        pricer.price(key);
        key = _key(A, address(0));
        _wrap(key, A, address(0));
        vm.expectRevert(bytes("ETH"));
        pricer.price(key);
    }

    function testRefusesATotalFeeOfAMillionOrMore() public {
        PoolKey memory key = _key(A, B);
        MockOutside outside = _wrap(key, A, B);
        outside.setFee(1_000_000);
        vm.expectRevert(bytes("fee"));
        pricer.price(key);
        outside.setFee(1_000_000 - 300);
        manager.setProtocolFee(12);
        vm.expectRevert(bytes("fee"));
        pricer.price(key);
        outside.setFee(1_000_000 - 301);
        manager.setProtocolFee(0);
        (, uint24 fee,,,) = pricer.price(key);
        assertEq(fee, 999_699);
    }

    function testUnknownPoolReverts() public {
        vm.expectRevert();
        pricer.price(_key(A, B));
    }
}
