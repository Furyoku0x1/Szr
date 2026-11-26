// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ISzrLiquidity } from "../interfaces/ISzrModules.sol";
import { IndexPool } from "./IndexPool.sol";

/// @notice Creates index pools for anyone and records them, so front ends can tell a real one.
/// Liquidity's manager, read live, decides only which hooks new pools may use and with how
/// much gas; nothing here can touch a pool once it exists.
contract IndexPoolFactory {
    /// The same cap every pool enforces; checked here too so a bad approval fails at once.
    uint256 public constant MAX_HOOK_GAS = 8_000_000;
    ISzrLiquidity public immutable liquidity;
    /// Receives every pool's protocol cut.
    address public immutable protocol;
    bool public openHooks;
    /// The gas an approved hook's pools give it; zero means not approved.
    mapping(address hook => uint32) public approvedHookGas;
    mapping(address pool => bool) public isPool;

    error ZeroAddress();
    error NotManager();
    error HookNotApproved();
    error InvalidHookGas();

    event PoolCreated(
        address indexed pool, address indexed creator, address indexed hook, bool hookApproved
    );
    event HookApproved(address indexed hook, uint32 gas);
    event OpenHooksSet(bool open);

    constructor(ISzrLiquidity liquidity_, address protocol_) {
        if (address(liquidity_) == address(0)) revert ZeroAddress();
        if (protocol_ == address(0)) revert ZeroAddress();
        liquidity = liquidity_;
        protocol = protocol_;
    }

    /// @notice Creates a pool with the caller as its creator. An approved hook always gets
    /// the gas it was approved with, whatever `hookGas` says, so a creator cannot give it too
    /// little to run and still have the pool marked approved.
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory weights,
        uint256 swapFee,
        address hook,
        uint32 hookGas
    ) external returns (address pool) {
        uint32 gas = approvedHookGas[hook];
        bool approved = gas != 0;
        if (hook == address(0)) gas = 0;
        if (hook != address(0)) {
            if (!approved) {
                if (!openHooks) revert HookNotApproved();
                gas = hookGas;
            }
        }
        pool = address(
            new IndexPool(
                name,
                symbol,
                tokens,
                weights,
                swapFee,
                protocol,
                hook,
                gas,
                approved,
                msg.sender
            )
        );
        isPool[pool] = true;
        emit PoolCreated(pool, msg.sender, hook, approved);
    }

    /// @notice `gas` of zero removes the approval. Pools already created keep their hook.
    function setHookApproved(address hook, uint32 gas) external {
        _onlyManager();
        if (hook == address(0)) revert ZeroAddress();
        if (gas > MAX_HOOK_GAS) revert InvalidHookGas();
        approvedHookGas[hook] = gas;
        emit HookApproved(hook, gas);
    }

    /// @notice On: a creator may attach any hook. It can be turned back off.
    function setOpenHooks(bool open) external {
        _onlyManager();
        openHooks = open;
        emit OpenHooksSet(open);
    }

    function _onlyManager() internal view {
        if (msg.sender != liquidity.manager()) revert NotManager();
    }
}
