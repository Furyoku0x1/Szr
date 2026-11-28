// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { WrappingAsset } from "./ArbitrageNative.sol";

/// @dev A WETH whose `balanceOf` reverts, cheaply and with data, for one chosen caller (the
/// hook) once switched on. The pool manager and everyone else read it as usual, so pools that
/// hold it still settle.
contract BrokenBalanceAsset is WrappingAsset {
    address public breaksFor;

    function breakFor(address reader) external {
        breaksFor = reader;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (msg.sender == breaksFor) revert("broken");
        return super.balanceOf(account);
    }
}
