// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { SzrCore } from "./SzrCore.sol";

/// @dev Exact ABI of the legacy modular hook's quote, including its next-state tuple.
interface ILegacySzrHook {
    struct MarketState {
        uint256 backedSupply;
        uint256 mintedEver;
        uint256 issuancePrice;
        uint256 floorReserve;
        uint256 bandReserve;
        uint256 bandInventory;
    }

    struct SellQuote {
        uint256 tokensIn;
        uint256 bandTokensIn;
        uint256 floorTokensBurned;
        uint256 grossWethOut;
        uint256 bandGrossWethOut;
        uint256 floorGrossWethOut;
        uint256 feeToFloor;
        uint256 bandFeeToFloor;
        uint256 floorFeeToFloor;
        uint256 protocolFee;
        uint256 netWethOut;
        MarketState nextState;
    }

    function token() external view returns (address);
    function weth() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function TICK_SPACING() external view returns (int24);
    function quoteSellExactIn(uint256 tokensIn) external view returns (SellQuote memory);
}

interface ILegacySzrToken {
    function hook() external view returns (address);
}

/// @notice Atomic 1:1 migration funded by selling old SZR through its canonical v4 hook.
/// @dev No custody owner, withdrawals, arbitrary swap routes, or mint permission exist.
contract SzrMigration is ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    SzrCore public immutable core;
    ILegacySzrHook public immutable legacyHook;
    address public immutable legacyToken;
    address public immutable backingAsset;
    IPoolManager public immutable poolManager;
    bytes32 public immutable hookCodehash;
    bytes32 public immutable managerCodehash;
    uint256 public totalMigrated;
    PoolKey private legacyKey;
    bytes32 private callbackHash;

    error InvalidLegacy();
    error NotConfigured();
    error NotLaunched();
    error InvalidAmount();
    error DeadlinePassed();
    error InsufficientAllocation();
    error BelowMinimum();
    error TransferAmountMismatch();
    error InvalidCallback();
    error InvalidDelta();
    error CodeChanged();

    event Migrated(address indexed owner, uint256 tokens, uint256 recoveredBacking);

    constructor(SzrCore core_, address oldToken, ILegacySzrHook hook_) {
        if (address(core_).code.length == 0) revert InvalidLegacy();
        if (oldToken.code.length == 0) revert InvalidLegacy();
        if (address(hook_).code.length == 0) revert InvalidLegacy();
        if (oldToken == address(core_.token())) revert InvalidLegacy();
        if (oldToken == core_.backingAsset()) revert InvalidLegacy();
        if (ERC20(oldToken).decimals() != 18) revert InvalidLegacy();
        if (ILegacySzrToken(oldToken).hook() != address(hook_)) revert InvalidLegacy();
        if (hook_.token() != oldToken) revert InvalidLegacy();
        address asset = core_.backingAsset();
        (IPoolManager manager, PoolKey memory key) = _legacyPool(asset, oldToken, hook_);
        legacyKey = key;
        core = core_;
        legacyToken = oldToken;
        legacyHook = hook_;
        backingAsset = asset;
        poolManager = manager;
        hookCodehash = address(hook_).codehash;
        managerCodehash = address(manager).codehash;
    }

    function _legacyPool(address asset, address oldToken, ILegacySzrHook hook_)
        internal
        view
        returns (IPoolManager manager, PoolKey memory key)
    {
        if (hook_.weth() != asset) revert InvalidLegacy();
        manager = hook_.poolManager();
        if (address(manager).code.length == 0) revert InvalidLegacy();
        int24 spacing = hook_.TICK_SPACING();
        if (spacing <= 0) revert InvalidLegacy();
        bool first = oldToken < asset;
        key = PoolKey(
            Currency.wrap(first ? oldToken : asset),
            Currency.wrap(first ? asset : oldToken),
            0,
            spacing,
            IHooks(address(hook_))
        );
        (uint160 price,,,) = manager.getSlot0(key.toId());
        if (price == 0) revert InvalidLegacy();
    }

    /// @notice Returns net legacy proceeds and an informational current-NAV comparison.
    /// @dev The comparison does not restrict migration; only the holder's minimum is enforced.
    function quote(uint256 amount)
        external
        view
        returns (uint256 recoveredBacking, uint256 requiredBacking, bool covered)
    {
        recoveredBacking = legacyHook.quoteSellExactIn(amount).netWethOut;
        requiredBacking = core.backingRequired(amount);
        covered = recoveredBacking >= requiredBacking;
    }

    function poolKey() external view returns (PoolKey memory) {
        return legacyKey;
    }

    function migrate(uint256 amount, uint256 minimumBacking, uint256 deadline)
        external
        nonReentrant
        returns (uint256 recoveredBacking)
    {
        _validateMigration(amount, deadline);
        uint256 beforeOld = ERC20(legacyToken).balanceOf(address(this));
        uint256 beforeBacking = ERC20(backingAsset).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(legacyToken, msg.sender, address(this), amount);
        if (ERC20(legacyToken).balanceOf(address(this)) != beforeOld + amount) {
            revert TransferAmountMismatch();
        }
        bytes memory request = abi.encode(amount);
        callbackHash = keccak256(request);
        recoveredBacking = abi.decode(poolManager.unlock(request), (uint256));
        if (callbackHash != bytes32(0)) revert InvalidCallback();
        if (ERC20(legacyToken).balanceOf(address(this)) != beforeOld) {
            revert TransferAmountMismatch();
        }
        if (ERC20(backingAsset).balanceOf(address(this)) != beforeBacking + recoveredBacking) {
            revert TransferAmountMismatch();
        }
        if (recoveredBacking < minimumBacking) revert BelowMinimum();
        totalMigrated += amount;
        SafeTransferLib.safeApprove(backingAsset, address(core), recoveredBacking);
        core.releaseMigration(msg.sender, amount, recoveredBacking);
        SafeTransferLib.safeApprove(backingAsset, address(core), 0);
        if (ERC20(backingAsset).balanceOf(address(this)) != beforeBacking) {
            revert TransferAmountMismatch();
        }
        emit Migrated(msg.sender, amount, recoveredBacking);
    }

    function _validateMigration(uint256 amount, uint256 deadline) internal view {
        if (core.migration() != address(this)) revert NotConfigured();
        if (!core.launched()) revert NotLaunched();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amount == 0) revert InvalidAmount();
        if (amount > uint256(uint128(type(int128).max))) revert InvalidAmount();
        if (amount > core.migrationRemaining()) revert InsufficientAllocation();
        if (address(legacyHook).codehash != hookCodehash) revert CodeChanged();
        if (address(poolManager).codehash != managerCodehash) revert CodeChanged();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidCallback();
        if (callbackHash == bytes32(0)) revert InvalidCallback();
        if (keccak256(data) != callbackHash) revert InvalidCallback();
        callbackHash = bytes32(0);
        uint256 amount = abi.decode(data, (uint256));
        Currency input = Currency.wrap(legacyToken);
        poolManager.sync(input);
        SafeTransferLib.safeTransfer(legacyToken, address(poolManager), amount);
        if (poolManager.settle() != amount) revert TransferAmountMismatch();
        bool first = Currency.unwrap(legacyKey.currency0) == legacyToken;
        BalanceDelta delta = poolManager.swap(
            legacyKey,
            IPoolManager.SwapParams({
                zeroForOne: first,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: first
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 spent = first ? delta.amount0() : delta.amount1();
        int128 output = first ? delta.amount1() : delta.amount0();
        if (spent != -int256(amount)) revert InvalidDelta();
        if (output <= 0) revert InvalidDelta();
        uint256 recovered = uint256(uint128(output));
        poolManager.take(Currency.wrap(backingAsset), address(this), recovered);
        return abi.encode(recovered);
    }
}
