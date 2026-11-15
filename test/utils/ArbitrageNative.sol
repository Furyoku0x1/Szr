// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TestAsset } from "./TestAsset.sol";
import { ArbitrageProbe } from "./ArbitrageProbe.sol";

/// @dev The test world's WETH with the real token's `deposit()`. Its code is etched over
/// the world's `backing`, which keeps its balances because the storage layout is the same.
contract WrappingAsset is TestAsset {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}

/// @dev A WETH whose `deposit` reverts with no data.
contract BrokenWrapAsset is TestAsset {
    function deposit() external payable {
        revert();
    }
}

/// @dev A token that refuses to tell the hook its balance, to show the hook never asks.
contract HookShunningAsset is TestAsset {
    address internal immutable shunned;

    constructor(address hook) {
        shunned = hook;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        if (msg.sender == shunned) revert("called by the hook");
        return super.balanceOf(owner);
    }
}

/// @dev Owes the probe hook `profit` in ETH inside an unlock, so the probe can pay it out,
/// then returns what the payout cost. Needs `profit` in ETH.
contract PayoutMeter is IUnlockCallback {
    IPoolManager internal immutable manager;
    ArbitrageProbe internal immutable probe;

    constructor(IPoolManager poolManager, ArbitrageProbe hook) payable {
        manager = poolManager;
        probe = hook;
    }

    function measure(uint256 market, uint256 profit) external returns (uint256, uint256) {
        return abi.decode(manager.unlock(abi.encode(market, profit)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 market, uint256 profit) = abi.decode(data, (uint256, uint256));
        manager.settleFor{ value: profit }(address(probe));
        (uint256 used, uint256 reserved) = probe.payoutCost(market, profit);
        return abi.encode(used, reserved);
    }
}
