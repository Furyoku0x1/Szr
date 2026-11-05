// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";

/// @notice Test-only asset. The unrestricted mint is never part of production deployment.
contract TestAsset is ERC20 {
    function name() public pure override returns (string memory) {
        return "Test WETH";
    }

    function symbol() public pure override returns (string memory) {
        return "TWETH";
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }
}
