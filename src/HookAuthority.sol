// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Liquidity } from "./Liquidity.sol";

/// @notice What the arbitrage hook asks `Liquidity` for, answered on a chain where SZR is not
/// launched (docs/specs/hook-authority.md). The hook is deployed against this contract, and
/// its own code does not change. `core` and `token` are this contract, so nothing outside
/// the hook has to exist; SZR's market stays empty, and outside markets work as usual.
/// @dev The hook never calls Core's or SZR's own functions here: they are used only in SZR's
/// market, which can hold no pool. If one were called, this contract has none, and the call
/// reverts.
contract HookAuthority {
    address public immutable poolManager;
    address public immutable backingAsset;
    address public manager;
    address public pendingManager;

    error NotManager();
    error NotNominee();
    error ZeroAddress();
    error MissingCode();
    error InvalidModule();
    error NoPositions();

    event ManagerNominated(address indexed nominee);
    event ManagerChanged(address indexed previous, address indexed current);
    event Recovered(address indexed asset, address indexed to, uint256 amount);

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(address poolManager_, address weth_, address firstManager) {
        if (poolManager_.code.length == 0) revert MissingCode();
        if (weth_.code.length == 0) revert MissingCode();
        if (firstManager == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        backingAsset = weth_;
        manager = firstManager;
        emit ManagerChanged(address(0), firstManager);
    }

    function nominateManager(address nominee) external onlyManager {
        if (nominee == address(0)) revert ZeroAddress();
        if (nominee == manager) revert InvalidModule();
        pendingManager = nominee;
        emit ManagerNominated(nominee);
    }

    function cancelManagerNomination() external onlyManager {
        pendingManager = address(0);
        emit ManagerNominated(address(0));
    }

    function acceptManager() external {
        if (msg.sender != pendingManager) revert NotNominee();
        address previous = manager;
        manager = msg.sender;
        pendingManager = address(0);
        emit ManagerChanged(previous, msg.sender);
    }

    /// @dev Core and the token are this contract: the hook needs them to be addresses, and the
    /// token to have code, since it approves Core for it in its constructor.
    function core() external view returns (address) {
        return address(this);
    }

    function token() external view returns (address) {
        return address(this);
    }

    /// @dev Stands in for the token's `approve`, which the hook's constructor calls.
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function poolRegistered(bytes32) external pure returns (bool) {
        return false;
    }

    function position(uint256) external pure returns (Liquidity.Position memory) {
        revert NoPositions();
    }

    function key(uint256) external pure returns (PoolKey memory) {
        revert NoPositions();
    }

    /// @notice Sends out what the hook's protocol share left here before the treasury was set
    /// (the share of WETH goes to Core, which is this contract, until it is changed).
    function recover(address asset, address to, uint256 amount) external onlyManager {
        if (to == address(0)) revert ZeroAddress();
        if (asset == address(0)) SafeTransferLib.safeTransferETH(to, amount);
        else SafeTransferLib.safeTransfer(asset, to, amount);
        emit Recovered(asset, to, amount);
    }
}
