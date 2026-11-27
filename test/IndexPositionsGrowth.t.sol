// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexToken, IndexWorld, MockIndexHook } from "./utils/IndexWorld.sol";

/// @dev `IndexPool.growthIndex`: what moves it, what does not, and the reference values
/// from `tools/index_vectors.py`.
contract IndexPositionsGrowthTest is IndexWorld {
    string internal constant VECTORS = "test/fixtures/index-vectors.json";
    /// The power's margin, 1e-14, on each of two factors.
    uint256 internal constant POWER_BOUND = 2e4;
    uint256 internal constant B = 1e24;

    function testFeeRaisesItByTheFeeKept() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 before = pool.growthIndex();
        uint256 amount = 1e22;
        _swap(pool, list[0], list[1], amount, true);
        uint256 fee = FixedPointMathLib.mulWadUp(amount, FEE);
        uint256 cut = fee * pool.PROTOCOL_CUT_BPS() / 10_000;
        // A fee-free swap of what is left after the fee keeps the invariant; the fee less the
        // protocol's cut then stays in the pool, raising the half-weight factor by its root.
        uint256 ratio = FixedPointMathLib.sqrt((B + amount - cut) * 1e36 / (B + amount - fee));
        uint256 expected = before * ratio / 1e18;
        uint256 got = pool.growthIndex();
        assertGt(got, before);
        assertApproxEqRel(got, expected, 1e6, "fee kept");
    }

    function testHookSwapsWithoutAFeeLeaveItPut() public {
        (IndexPool pool, MockIndexHook hook) = _hooked();
        address[] memory list = pool.tokens();
        uint256 before = pool.growthIndex();
        // Large fee-free moves of the price, each way.
        for (uint256 index; index < 2; index++) {
            (, uint256 got) = hook.swapAsHook(list[0], list[1], 25e22, true, 0);
            hook.swapAsHook(list[1], list[0], got / 2, true, 0);
        }
        _assertPut(pool.growthIndex(), before);
        assertGt(pool.balances()[0], B * 12 / 10, "the price moved");
    }

    function testJoinAndExitLeaveItPut() public {
        IndexPool pool = _pool(_same(18, 4), _equal(4), 1e6, address(0), 0);
        uint256 before = pool.growthIndex();
        pool.join(3e23, _maxes(4), FAR);
        _assertPut(pool.growthIndex(), before);
        pool.exit(7e23, _zeros(4), _none(), FAR);
        _assertPut(pool.growthIndex(), before);
        pool.join(1e12, _maxes(4), FAR);
        pool.exit(1e12 + 1, _zeros(4), _none(), FAR);
        _assertPut(pool.growthIndex(), before);
    }

    function testDonationRaisesItOnlyAsItIsReleased() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        uint256 before = pool.growthIndex();
        uint256 amount = 1e23;
        pool.donate(list[0], amount);
        assertEq(pool.growthIndex(), before, "nothing released yet");
        vm.warp(block.timestamp + 1 days);
        uint256 partly = pool.growthIndex();
        assertGt(partly, before);
        vm.warp(block.timestamp + 2 days);
        uint256 kept = amount - amount * pool.DONATION_CUT_BPS() / 10_000;
        uint256 ratio = FixedPointMathLib.sqrt((B + kept) * 1e36 / B);
        assertGt(pool.growthIndex(), partly);
        assertApproxEqRel(pool.growthIndex(), before * ratio / 1e18, 1e6, "all released");
    }

    function testRevertsMidSwap() public {
        IndexPool pool = _pool(_same(18, 2), _equal(2), 1e6, address(0), 0);
        address[] memory list = pool.tokens();
        IndexToken(list[1]).setReenter(address(pool), abi.encodeCall(IndexPool.growthIndex, ()));
        _swap(pool, list[0], list[1], 1e18, true);
        assertTrue(IndexToken(list[1]).reentered());
        assertFalse(IndexToken(list[1]).reenterOk());
        assertEq(
            bytes4(IndexToken(list[1]).reenterResult()), ReentrancyGuard.Reentrancy.selector
        );
    }

    function testRevertsBeforeStart() public {
        IndexPool pool = _unstarted(_same(18, 2), _equal(2));
        vm.expectRevert(IndexPool.NotStarted.selector);
        pool.growthIndex();
    }

    /// Never above the exact value, and within 1e-13 below it, at 2, 5 and 8 tokens,
    /// unequal weights and mixed decimals included, up to the overflow bound of 8 tokens of
    /// 0 decimals at raw balances of `type(uint128).max`.
    function testMatchesTheReference() public {
        string memory data = vm.readFile(VECTORS);
        uint256[] memory counts = vm.parseJsonUintArray(data, ".growth.tokens");
        uint256[] memory places = vm.parseJsonUintArray(data, ".growth.decimals");
        uint256[] memory weights = vm.parseJsonUintArray(data, ".growth.weights");
        uint256[] memory amounts = vm.parseJsonUintArray(data, ".growth.balances");
        uint256[] memory shares = vm.parseJsonUintArray(data, ".growth.shares");
        uint256[] memory exact = vm.parseJsonUintArray(data, ".growth.exact36");
        uint256 at;
        for (uint256 index; index < counts.length; index++) {
            uint256 count = counts[index];
            IndexPool pool = _vectorPool(index, at, count, places, weights);
            pool.start(_slice(amounts, at, count), shares[index], FAR);
            uint256 got = pool.growthIndex() * 1e18;
            assertLe(got, exact[index], "above exact");
            assertApproxEqRel(got, exact[index], 1e5, "reference");
            at += count;
        }
    }

    function _vectorPool(
        uint256 index,
        uint256 at,
        uint256 count,
        uint256[] memory places,
        uint256[] memory weights
    ) internal returns (IndexPool) {
        address[] memory list = new address[](count);
        for (uint256 token; token < count; token++) {
            // Increasing addresses, so the vector's order is the pool's.
            list[token] = address(uint160(0xC0FFEE << 136 | index << 8 | token + 1));
            deployCodeTo(
                "IndexWorld.sol:IndexToken", abi.encode(uint8(places[at + token])), list[token]
            );
            IndexToken(list[token]).mint(address(this), type(uint128).max);
        }
        IndexPool pool = _create(list, _slice(weights, at, count), FEE, address(0), 0);
        for (uint256 token; token < count; token++) {
            IndexToken(list[token]).approve(address(pool), type(uint256).max);
        }
        return pool;
    }

    function _slice(uint256[] memory list, uint256 at, uint256 count)
        internal
        pure
        returns (uint256[] memory part)
    {
        part = new uint256[](count);
        for (uint256 index; index < count; index++) {
            part[index] = list[at + index];
        }
    }

    function _hooked() internal returns (IndexPool pool, MockIndexHook hook) {
        hook = new MockIndexHook();
        pool = _pool(_same(18, 2), _equal(2), 1e6, address(hook), 1_000_000);
        hook.setPool(pool);
        hook.setMode(MockIndexHook.Mode.Idle);
        address[] memory list = pool.tokens();
        IndexToken(list[0]).mint(address(hook), 1e30);
        IndexToken(list[1]).mint(address(hook), 1e30);
    }

    /// Within the power's error bound of `before`, either way.
    function _assertPut(uint256 got, uint256 before) internal pure {
        assertApproxEqRel(got, before, POWER_BOUND, "put");
    }
}
