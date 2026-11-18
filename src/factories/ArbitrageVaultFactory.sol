// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { PoolKey } from "v4-core/types/PoolKey.sol";
import { ArbitrageApi } from "../arbitrage/ArbitrageApi.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import { IMarketController } from "../interfaces/IMarketController.sol";
import { IHookVault } from "../interfaces/IHookVault.sol";
import { MarketController } from "../vaults/MarketController.sol";
import { ArbitrageVaultDeployer, MetricVaultDeployer } from "./VaultDeployers.sol";

/// @notice Creates and lists the market controllers and pair vaults of one arbitrage hook.
/// A controller is made only by its market's owner, and a vault under a controller only by
/// that controller's curator, so every listed contract is the one its market meant.
contract ArbitrageVaultFactory {
    enum Kind {
        Arbitrage,
        Metric
    }

    event ControllerCreated(
        address indexed controller, uint256 indexed market, address indexed curator
    );
    event VaultCreated(
        address indexed vault,
        address indexed controller,
        Kind kind,
        address token0,
        address token1,
        address curator
    );

    error NotMarketOwner();
    error NotCurator();
    error UnknownController();
    error ControllerExists();

    ArbitrageApi public immutable hook;
    ArbitrageVaultDeployer public immutable arbitrageDeployer;
    MetricVaultDeployer public immutable metricDeployer;
    IMetricFactory public immutable metricFactory;

    address[] public controllers;
    address[] public vaults;
    mapping(address => bool) public isController;
    mapping(address => bool) public isVault;
    mapping(bytes32 => bool) internal made;

    constructor(
        ArbitrageApi arbitrageHook,
        ArbitrageVaultDeployer arbitrageDeployer_,
        MetricVaultDeployer metricDeployer_,
        IMetricFactory metricFactory_
    ) {
        hook = arbitrageHook;
        arbitrageDeployer = arbitrageDeployer_;
        metricDeployer = metricDeployer_;
        metricFactory = metricFactory_;
    }

    function controllerCount() external view returns (uint256) {
        return controllers.length;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Deploys the controller of `market`, which its owner must then nominate as
    /// the market's owner before `initialize`. The address depends on the market and the
    /// curator, so a repeat with the same two is refused before any code is deployed.
    function createController(uint256 market, address curator)
        external
        returns (address controller)
    {
        if (hook.market(market).owner != msg.sender) revert NotMarketOwner();
        bytes32 salt = keccak256(abi.encode(market, curator));
        if (made[salt]) revert ControllerExists();
        made[salt] = true;
        controller =
            address(new MarketController{ salt: salt }(hook, market, curator, address(this)));
        isController[controller] = true;
        controllers.push(controller);
        emit ControllerCreated(controller, market, curator);
    }

    /// @notice Deploys a vault of the controller's market around `home`, a pool the market
    /// tracks. The caller becomes its curator. The pair is the pool's currencies.
    function createArbitrageVault(address controller, PoolKey calldata home, uint16 feeBps)
        external
        returns (address vault)
    {
        _requireCurator(controller);
        bytes memory args = abi.encode(
            hook, MarketController(controller).market(), home, msg.sender, controller, feeBps
        );
        vault = arbitrageDeployer.deploy(args);
        _record(vault, controller, Kind.Arbitrage, msg.sender);
    }

    /// @notice Deploys a Metric vault around `pool`. With a controller, only its curator may;
    /// without one the vault only holds positions and anyone may.
    function createMetricVault(address controller, address pool, uint16 feeBps, address curator)
        external
        returns (address vault)
    {
        if (controller != address(0)) _requireCurator(controller);
        vault = metricDeployer.deploy(
            metricFactory, pool, IMarketController(controller), feeBps, curator
        );
        _record(vault, controller, Kind.Metric, curator);
    }

    function _requireCurator(address controller) internal view {
        if (!isController[controller]) revert UnknownController();
        if (MarketController(controller).curator() != msg.sender) revert NotCurator();
    }

    function _record(address vault, address controller, Kind kind, address curator) internal {
        isVault[vault] = true;
        vaults.push(vault);
        emit VaultCreated(
            vault,
            controller,
            kind,
            IHookVault(vault).token0(),
            IHookVault(vault).token1(),
            curator
        );
    }
}
