// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageVaultFactory } from "../../src/factories/ArbitrageVaultFactory.sol";

/// @dev Builds the factory from artifacts, so the test that calls it does not carry the
/// creation code of the vaults, which together are far over a contract's size.
library FactoryDeploy {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function build(ArbitrageApi hook, address metricFactory)
        internal
        returns (ArbitrageVaultFactory)
    {
        bytes memory vaultCode = VM.getCode("ArbitrageVault.sol:ArbitrageVault");
        address arbitrage =
            VM.deployCode("VaultDeployers.sol:ArbitrageVaultDeployer", abi.encode(vaultCode));
        address metric = VM.deployCode("VaultDeployers.sol:MetricVaultDeployer");
        return ArbitrageVaultFactory(
            VM.deployCode(
                "ArbitrageVaultFactory.sol:ArbitrageVaultFactory",
                abi.encode(hook, arbitrage, metric, metricFactory)
            )
        );
    }
}
