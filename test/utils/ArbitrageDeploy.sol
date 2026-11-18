// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { Liquidity } from "../../src/Liquidity.sol";

/// @dev Deploys the split arbitrage hook the way the deploy script does: the five modules
/// first, then the hook at an address with the permission bits it needs, which is not a salt
/// this helper mines but one the test picks. Everything is built from artifacts, so a test
/// contract does not carry the modules' code, which would put it over the size limit. The
/// modules sit at fixed addresses and the nonce is put back, so that adding them leaves
/// every later address in a test where it was.
abstract contract ArbitrageDeploy is Test {
    /// Builds the modules for `treasury` and then the hook at `at`.
    function _deployHookAt(address at, Liquidity treasury) internal {
        bytes memory args = abi.encode(treasury);
        // Each deployment bumps this contract's nonce, which the addresses of everything
        // it creates later come from, and some tests depend on how those addresses order.
        uint64 nonce = vm.getNonce(address(this));
        bytes memory modules = abi.encode(
            _module("ArbitrageSearch.sol:ArbitrageSearch", args),
            _module("ArbitrageSearchMany.sol:ArbitrageSearchMany", args),
            _module("ArbitrageCycle.sol:ArbitrageCycle", args),
            _module("ArbitrageSizer.sol:ArbitrageSizer", args),
            _module("ArbitrageAdmin.sol:ArbitrageAdmin", args)
        );
        vm.setNonceUnsafe(address(this), nonce);
        deployCodeTo(
            "ArbitrageHook.sol:ArbitrageHook",
            abi.encodePacked(abi.encode(treasury), modules),
            at
        );
    }

    function _module(string memory artifact, bytes memory args) private returns (address at) {
        at = address(uint160(uint256(keccak256(bytes(artifact)))));
        deployCodeTo(artifact, args, at);
    }
}
