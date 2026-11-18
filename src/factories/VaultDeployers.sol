// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SSTORE2 } from "solady/utils/SSTORE2.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import { IMarketController } from "../interfaces/IMarketController.sol";
import { MetricVault } from "../vaults/MetricVault.sol";

/// @notice Deploys `ArbitrageVault`s for the factory. The vault's creation code is larger
/// than one contract may be, so it is kept in two data contracts, written by the
/// constructor from the code it is given, and read back at each deployment.
/// @dev Anyone may call `deploy`: it only creates a vault, and the factory records only
/// what it created itself.
contract ArbitrageVaultDeployer {
    error DeploymentFailed();

    address public immutable head;
    address public immutable tail;

    constructor(bytes memory creationCode) {
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

    /// @notice Creates a vault from the stored code and the encoded constructor arguments.
    function deploy(bytes calldata args) external returns (address vault) {
        bytes memory code = bytes.concat(SSTORE2.read(head), SSTORE2.read(tail), args);
        assembly ("memory-safe") {
            vault := create(0, add(code, 32), mload(code))
        }
        if (vault == address(0)) revert DeploymentFailed();
    }
}

/// @notice Deploys `MetricVault`s for the factory, which has no room for their code.
contract MetricVaultDeployer {
    function deploy(
        IMetricFactory metricFactory,
        address pool,
        IMarketController controller,
        uint16 feeBps,
        address curator
    ) external returns (address) {
        return address(new MetricVault(metricFactory, pool, controller, feeBps, curator));
    }
}
