// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract Szr is ERC20 {
    string private _name;
    string private _symbol;

    uint256 public constant MAX_SUPPLY = 1_000_000_000e18;
    /// @notice The reserve contract that deployed this token.
    address public immutable core;

    error InvalidRecipient();

    constructor(string memory name_, string memory symbol_) ERC20() {
        _name = name_;
        _symbol = symbol_;
        core = msg.sender;
        _mint(msg.sender, MAX_SUPPLY);
    }

    // No implicit allowance to an unverified deployment-chain Permit2 address.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @dev Tokens sent to these three places by mistake would be lost for good, so the
    /// transfer fails instead. Core takes tokens in only by pulling them itself, never by
    /// receiving a plain transfer.
    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        if (to == address(0)) revert InvalidRecipient();
        if (to == address(this)) revert InvalidRecipient();
        if (to == core) {
            if (msg.sender != core) revert InvalidRecipient();
        }
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}
