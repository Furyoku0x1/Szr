// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import { IMarketController } from "../interfaces/IMarketController.sol";

/// @dev Keeps a vault's creation code, which is larger than one contract may be, in two data
/// contracts, written by the constructor from the code it is given, and reads it back at each
/// deployment.
abstract contract StoredCode {
    error DeploymentFailed();

    address public immutable head;
    address public immutable tail;
    /// @notice The keccak of the creation code this deployer was given, for depositors to
    /// compare with the code they audited.
    bytes32 public immutable codeHash;

    constructor(bytes memory creationCode) {
        codeHash = keccak256(creationCode);
        uint256 half = creationCode.length / 2;
        bytes memory first = new bytes(half);
        bytes memory second = new bytes(creationCode.length - half);
        for (uint256 index; index < half; index++) {
            first[index] = creationCode[index];
        }
        for (uint256 index; index < second.length; index++) {
            second[index] = creationCode[half + index];
        }
        head = SSTORE2.write(first);
        tail = SSTORE2.write(second);
    }

    function _create(bytes memory args) internal returns (address vault) {
        bytes memory code = bytes.concat(SSTORE2.read(head), SSTORE2.read(tail), args);
        assembly ("memory-safe") {
            vault := create(0, add(code, 32), mload(code))
        }
        if (vault == address(0)) {
            // The vault's own error, when it gave one, is what the caller needs to see.
            assembly ("memory-safe") {
                if returndatasize() {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
            revert DeploymentFailed();
        }
    }
}

/// @notice Deploys `ArbitrageVault`s for the factory.
/// @dev Anyone may call `deploy`: it only creates a vault, and the factory records only
/// what it created itself.
contract ArbitrageVaultDeployer is StoredCode {
    constructor(bytes memory creationCode) StoredCode(creationCode) { }

    /// @notice Creates a vault from the stored code and the encoded constructor arguments.
    function deploy(bytes calldata args) external returns (address) {
        return _create(args);
    }
}

/// @notice Deploys `MetricVault`s for the factory, which has no room for their code. Built
/// like `ArbitrageVaultDeployer`, from the vault's creation code.
contract MetricVaultDeployer is StoredCode {
    constructor(bytes memory creationCode) StoredCode(creationCode) { }

    function deploy(
        IMetricFactory metricFactory,
        address pool,
        IMarketController controller,
        uint16 feeBps,
        address curator
    ) external returns (address) {
        return _create(abi.encode(metricFactory, pool, controller, feeBps, curator));
    }
}
