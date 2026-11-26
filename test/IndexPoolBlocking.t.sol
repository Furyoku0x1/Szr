// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { IndexPool } from "../src/index/IndexPool.sol";
import { IndexToken, IndexWorld, MockIndexHook } from "./utils/IndexWorld.sol";

/// @dev The one way a hook may make a swap fail: an approved hook reverting exactly
/// `Blocked()` from `beforeSwap`. Everything else a hook does is ignored as before.
contract IndexPoolBlockingTest is IndexWorld {
    uint32 internal constant GAS = 1_000_000;

    function _pool(MockIndexHook.Mode mode, bool approved)
        internal
        returns (IndexPool pool, MockIndexHook hook)
    {
        hook = new MockIndexHook();
        address[] memory list = _tokens(_same(18, 2));
        if (approved) {
            pool = _create(list, _equal(2), FEE, address(hook), GAS);
        } else {
            factory.setOpenHooks(true);
            pool = IndexPool(
                factory.create("Index", "IDX", list, _equal(2), FEE, address(hook), GAS)
            );
        }
        assertEq(pool.hookApproved(), approved, "approval recorded");
        uint256[] memory units = new uint256[](2);
        units[0] = 1e6;
        units[1] = 1e6;
        _start(pool, units, 1e24);
        _fundAll(address(this), pool, 1e40);
        hook.setPool(pool);
        hook.setMode(mode);
    }

    /// An approved hook's `Blocked()` before the swap refuses it, and nothing changes.
    function testApprovedHookBlockingBeforeRefusesTheSwap() public {
        (IndexPool pool,) = _pool(MockIndexHook.Mode.BlockBefore, true);
        address[] memory list = pool.tokens();
        uint256[] memory held = pool.balances();
        uint256 mine = IndexToken(list[0]).balanceOf(address(this));
        vm.expectRevert(IndexPool.HookBlocked.selector);
        _swap(pool, list[0], list[1], 1e18, true);
        assertEq(pool.balances()[0], held[0], "unchanged");
        assertEq(pool.balances()[1], held[1], "unchanged");
        assertEq(IndexToken(list[0]).balanceOf(address(this)), mine, "nothing taken");
        assertEq(pool.owed(list[0]), 0, "no fee");
    }

    /// The same revert after the swap is ignored, and the swap stands.
    function testBlockingAfterTheSwapIsIgnored() public {
        _assertIgnored(MockIndexHook.Mode.BlockAfter, true);
    }

    /// A hook that was not approved cannot block.
    function testUnapprovedHookCannotBlock() public {
        _assertIgnored(MockIndexHook.Mode.BlockBefore, false);
    }

    /// Other data, `Blocked()` with extra bytes, fewer than four bytes, a normal return of
    /// the four bytes, 100 KB starting with them, and running out of gas are all ignored.
    function testEveryOtherFailureIsIgnored() public {
        MockIndexHook.Mode[6] memory modes = [
            MockIndexHook.Mode.Revert,
            MockIndexHook.Mode.BlockLong,
            MockIndexHook.Mode.BlockShort,
            MockIndexHook.Mode.ReturnBlocked,
            MockIndexHook.Mode.HugeRevert,
            MockIndexHook.Mode.Burn
        ];
        for (uint256 index; index < modes.length; index++) {
            _assertIgnored(modes[index], true);
        }
    }

    function _assertIgnored(MockIndexHook.Mode mode, bool approved) internal {
        (IndexPool pool,) = _pool(mode, approved);
        address[] memory list = pool.tokens();
        (, uint256 quoted) = pool.quoteSwap(list[0], list[1], 1e18, true);
        (, uint256 got) = _swap(pool, list[0], list[1], 1e18, true);
        assertEq(got, quoted, "the swap stands");
        _assertSolvent(pool, _none());
    }

    /// A 100 KB revert costs the swap no more than a 100 KB return did before.
    function testHugeRevertCostsNoMore() public {
        uint256 record = _swapGas(MockIndexHook.Mode.Record);
        uint256 huge = _swapGas(MockIndexHook.Mode.HugeRevert);
        assertLe(huge, record + 70_000, "copies nothing");
        console2.log("swap gas: recording hook, 100 KB revert", record, huge);
    }

    function _swapGas(MockIndexHook.Mode mode) internal returns (uint256 used) {
        (IndexPool pool,) = _pool(mode, true);
        address[] memory list = pool.tokens();
        uint256 before = gasleft();
        _swap(pool, list[0], list[1], 1e18, true);
        used = before - gasleft();
    }

    /// Joining, leaving, claiming, donating and paying the protocol all work while the hook
    /// is blocking every swap.
    function testEverythingElseWorksWhileBlocking() public {
        (IndexPool pool,) = _pool(MockIndexHook.Mode.BlockBefore, true);
        address[] memory list = pool.tokens();
        pool.join(1e18, _maxes(2), FAR);
        address[] memory deferring = new address[](1);
        deferring[0] = list[0];
        pool.exit(1e18, _zeros(2), deferring, FAR);
        assertGt(pool.claim(list[0]), 0, "claimed");
        pool.donate(list[1], 1e18);
        assertGt(pool.payProtocol(list[1]), 0, "protocol paid");
        vm.expectRevert(IndexPool.HookBlocked.selector);
        _swap(pool, list[0], list[1], 1e18, true);
    }
}
