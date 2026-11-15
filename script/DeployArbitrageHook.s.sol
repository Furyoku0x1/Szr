// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";

/// @notice Deploys the arbitrage hook at an address whose low bits grant only `beforeSwap`
/// and `afterSwap`.
/// @dev v4 reads a hook's permissions from its address, so the address is searched for: the
/// script tries CREATE2 salts until one lands on a fitting address, about 16,000 tries.
contract DeployArbitrageHook is Script {
    /// @dev The Safe singleton factory: plain CREATE2, calldata is the salt then the initcode.
    /// It is deployed on Robinhood Chain; Foundry's default CREATE2 deployer is not.
    address public constant FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    uint256 internal constant MAX_TRIES = 1_000_000;
    uint160 internal constant PERMISSION_MASK = (1 << 14) - 1;
    uint160 internal constant SWAP_HOOKS = (1 << 7) | (1 << 6);

    error WrongChain();
    error MissingLiquidity();
    error MissingFactory();
    error NoSaltFound();
    error DeploymentFailed();

    function run() external returns (ArbitrageHook hook) {
        return run(vm.envUint("EXPECTED_CHAIN_ID"), Liquidity(vm.envAddress("LIQUIDITY")));
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    /// @dev Running it again for the same Liquidity returns the hook already deployed.
    function run(uint256 chainId, Liquidity liquidity) public returns (ArbitrageHook hook) {
        if (block.chainid != chainId) revert WrongChain();
        if (address(liquidity).code.length == 0) revert MissingLiquidity();
        if (FACTORY.code.length == 0) revert MissingFactory();
        bytes memory initcode =
            abi.encodePacked(type(ArbitrageHook).creationCode, abi.encode(liquidity));
        (bytes32 salt, address predicted) = mine(keccak256(initcode));
        hook = ArbitrageHook(payable(predicted));
        if (predicted.code.length == 0) {
            vm.broadcast();
            (bool deployed,) = FACTORY.call(abi.encodePacked(salt, initcode));
            if (!deployed) revert DeploymentFailed();
        }
        if (predicted.code.length == 0) revert DeploymentFailed();
        if (address(hook.liquidity()) != address(liquidity)) revert DeploymentFailed();
        console2.log("ARBITRAGE_HOOK", predicted);
        console2.log("SALT", uint256(salt));
    }

    /// @notice The first salt whose CREATE2 address carries exactly the two swap bits.
    function mine(bytes32 initcodeHash) public pure returns (bytes32 salt, address predicted) {
        for (uint256 attempt; attempt < MAX_TRIES; attempt++) {
            salt = bytes32(attempt);
            predicted = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), FACTORY, salt, initcodeHash))
                    )
                )
            );
            if (uint160(predicted) & PERMISSION_MASK == SWAP_HOOKS) {
                return (salt, predicted);
            }
        }
        revert NoSaltFound();
    }
}
