// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    IMetricOmmExtensions,
    IMetricAfterSwap
} from "../../../src/interfaces/metric/IMetricOmmExtensions.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

interface IFill {
    function onFill() external;
}

/// @dev A Metric pool as far as its swap extensions see it: it calls `beforeSwap` and
/// `afterSwap` around a "fill" that calls back into the caller, reports `inSwap()` only
/// during a real swap, and like Metric reverts the whole swap if an extension reverts.
contract MockExtensionPool {
    IMetricOmmExtensions public immutable extension;
    bool internal running;
    uint256 public lastBeforeGas;
    uint256 public lastAfterGas;
    uint256 public swaps;
    /// Gas the rest of the swap needs after each extension call; the swap reverts without it.
    uint256 public rest;

    function setRest(uint256 amount) external {
        rest = amount;
    }

    constructor(IMetricOmmExtensions extension_) {
        extension = extension_;
    }

    function inSwap() external view returns (address) {
        return running ? address(this) : address(0);
    }

    /// `simulate` models `simulateSwapAndRevert`, where `inSwap()` reports zero.
    function swap(bool simulate) external {
        running = !simulate;
        uint256 start = gasleft();
        bytes4 one = extension.beforeSwap(msg.sender, msg.sender, true, 1, 0, 0, 1, 1, 1, "");
        lastBeforeGas = start - gasleft();
        require(one == IMetricOmmExtensions.beforeSwap.selector, "before selector");
        require(gasleft() >= rest, "out of gas after before");
        IFill(msg.sender).onFill();
        start = gasleft();
        // Fourteen arguments overflow the stack when encoded in one expression, so the head
        // is built in two halves: thirteen static words, the offset of the empty bytes, and
        // its zero length.
        bytes memory head = abi.encode(msg.sender, msg.sender, true, 1, 0, 0, 0);
        head = abi.encodePacked(head, abi.encode(1, 1, 1, 0, 0, 0, 14 * 32), uint256(0));
        (bool ok, bytes memory out) =
            address(extension).call(abi.encodePacked(IMetricAfterSwap.afterSwap.selector, head));
        require(ok, "after reverted");
        bytes4 two = abi.decode(out, (bytes4));
        lastAfterGas = start - gasleft();
        require(two == IMetricAfterSwap.afterSwap.selector, "after selector");
        require(gasleft() >= rest, "out of gas after after");
        running = false;
        swaps++;
    }
}

/// @dev Starts a Metric swap inside a v4 unlock, as a route through a wrapper hook does.
contract UnlockedCaller is IUnlockCallback, IFill {
    IPoolManager internal immutable manager;
    MockExtensionPool internal pool;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function run(MockExtensionPool pool_) external {
        pool = pool_;
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pool.swap(false);
        return "";
    }

    function onFill() external { }
}

/// @dev A hook whose sweep always fails.
contract FailingSweep {
    function sweep(uint256, address) external pure returns (uint256) {
        revert("no");
    }
}

/// @dev A hook that counts its sweeps.
contract CountingSweep {
    uint256 public calls;

    function sweep(uint256, address) external returns (uint256) {
        calls++;
        return 0;
    }
}

/// @dev A hook whose sweep uses every unit of gas it is given.
contract BurningSweep {
    function sweep(uint256, address) external pure returns (uint256) {
        while (true) { }
    }
}
