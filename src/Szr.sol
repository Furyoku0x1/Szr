// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract Szr is ERC20 {
    string private _name;
    string private _symbol;

    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_) ERC20() {
        _name = name_;
        _symbol = symbol_;
        _mint(msg.sender, MAX_SUPPLY);
    }

    // No implicit allowance to an unverified deployment-chain Permit2 address.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
