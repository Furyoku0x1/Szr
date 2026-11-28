// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageSearch } from "../src/arbitrage/ArbitrageSearch.sol";
import { ArbitrageSearchMany } from "../src/arbitrage/ArbitrageSearchMany.sol";
import { ArbitrageCycle } from "../src/arbitrage/ArbitrageCycle.sol";
import { ArbitrageSizer } from "../src/arbitrage/ArbitrageSizer.sol";
import { ArbitrageAdmin } from "../src/arbitrage/ArbitrageAdmin.sol";
import { Liquidity } from "../src/Liquidity.sol";

/// @notice Deploys the arbitrage hook, and the five modules it reaches by delegatecall, the
/// hook at an address whose low bits grant only `beforeSwap` and `afterSwap`.
/// @dev The modules go first, each by CREATE2 with salt zero, so their addresses depend only
/// on the Liquidity and a repeat run finds them again. The hook's address is then mined with
/// their addresses in its constructor arguments. v4 reads a hook's permissions from its
/// address, so the address is searched for: the script tries CREATE2 salts until one lands on
/// a fitting address, about 16,000 tries.
contract DeployArbitrageHook is Script {
    /// @dev The Safe singleton factory: plain CREATE2, calldata is the salt then the initcode.
    /// It is used because the hook's address is mined against it. Foundry's default CREATE2
    /// deployer is on Robinhood Chain too, but the mined salt would not fit it.
    address public constant FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    uint256 internal constant MAX_TRIES = 1_000_000;
    uint160 internal constant PERMISSION_MASK = (1 << 14) - 1;
    uint160 internal constant SWAP_HOOKS = (1 << 7) | (1 << 6);

    error WrongChain();
    error MissingLiquidity();
    error MissingFactory();
    error NoSaltFound();
    error DeploymentFailed();

    function run() external returns (ArbitrageApi hook) {
        return run(vm.envUint("EXPECTED_CHAIN_ID"), Liquidity(vm.envAddress("LIQUIDITY")));
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    /// @dev Running it again for the same Liquidity returns the hook already deployed.
    function run(uint256 chainId, Liquidity liquidity) public returns (ArbitrageApi hook) {
        if (block.chainid != chainId) revert WrongChain();
        if (address(liquidity).code.length == 0) revert MissingLiquidity();
        if (FACTORY.code.length == 0) revert MissingFactory();
        bytes memory initcode = abi.encodePacked(
            type(ArbitrageHook).creationCode,
            abi.encode(
                liquidity,
                _module(type(ArbitrageSearch).creationCode, liquidity),
                _module(type(ArbitrageSearchMany).creationCode, liquidity),
                _module(type(ArbitrageCycle).creationCode, liquidity),
                _module(type(ArbitrageSizer).creationCode, liquidity),
                _module(type(ArbitrageAdmin).creationCode, liquidity)
            )
        );
        (bytes32 salt, address predicted) = mine(keccak256(initcode));
        hook = ArbitrageApi(payable(predicted));
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

    /// @dev Deploys one module through the factory unless it is already there.
    function _module(bytes memory creation, Liquidity liquidity) internal returns (address at) {
        bytes memory initcode = abi.encodePacked(creation, abi.encode(liquidity));
        at = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), FACTORY, bytes32(0), keccak256(initcode))
                    )
                )
            )
        );
        if (at.code.length != 0) return at;
        vm.broadcast();
        (bool deployed,) = FACTORY.call(abi.encodePacked(bytes32(0), initcode));
        if (!deployed) revert DeploymentFailed();
        if (at.code.length == 0) revert DeploymentFailed();
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
