// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { TestAsset } from "./TestAsset.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

/// @dev A router that trades through two pools inside one unlock, as an aggregator would:
/// the output of the first swap pays for the second.
contract TwoHopRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(
        PoolKey calldata first,
        PoolKey calldata second,
        address input,
        uint256 amount
    ) external returns (uint256 received) {
        bytes memory result =
            manager.unlock(abi.encode(msg.sender, first, second, input, amount));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            address payer,
            PoolKey memory first,
            PoolKey memory second,
            address input,
            uint256 amount
        ) = abi.decode(data, (address, PoolKey, PoolKey, address, uint256));
        (address middle, uint256 held) = _swap(first, input, amount);
        (address output, uint256 received) = _swap(second, middle, held);
        manager.sync(Currency.wrap(input));
        TestAsset(input).transferFrom(payer, address(manager), amount);
        manager.settle();
        manager.take(Currency.wrap(output), payer, received);
        return abi.encode(received);
    }

    function _swap(PoolKey memory pool, address input, uint256 amount)
        internal
        returns (address output, uint256 received)
    {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        output = Currency.unwrap(zeroForOne ? pool.currency1 : pool.currency0);
        received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
    }
}

/// @dev A router that pays the pool manager before it swaps: sync, transfer, swap, settle.
contract PayFirstRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(PoolKey calldata pool, address input, uint256 amount)
        external
        returns (uint256 received)
    {
        bytes memory result = manager.unlock(abi.encode(msg.sender, pool, input, amount));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, address input, uint256 amount) =
            abi.decode(data, (address, PoolKey, address, uint256));
        manager.sync(Currency.wrap(input));
        TestAsset(input).transferFrom(payer, address(manager), amount);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        manager.settle();
        // A swap that could not use all of the payment gets the rest back.
        uint256 spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        if (spent != amount) manager.take(Currency.wrap(input), payer, amount - spent);
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (received != 0) {
            manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        }
        return abi.encode(received);
    }
}

/// @dev A router that pays half of its input in before it swaps and the rest afterwards,
/// settling once at the end.
contract TopUpRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(PoolKey calldata pool, address input, uint256 amount)
        external
        returns (uint256 received)
    {
        bytes memory result = manager.unlock(abi.encode(msg.sender, pool, input, amount));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, address input, uint256 amount) =
            abi.decode(data, (address, PoolKey, address, uint256));
        manager.sync(Currency.wrap(input));
        TestAsset(input).transferFrom(payer, address(manager), amount / 2);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        TestAsset(input).transferFrom(payer, address(manager), amount - amount / 2);
        manager.settle();
        // A swap that could not use all of the payment gets the rest back.
        uint256 spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        if (spent != amount) manager.take(Currency.wrap(input), payer, amount - spent);
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (received != 0) {
            manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        }
        return abi.encode(received);
    }
}

/// @dev A router that marks a chosen token as synced with the pool manager before it swaps,
/// without paying anything in, then settles in the ordinary way afterwards. Anyone can do
/// this; it is what someone would try in order to make the hook stand aside.
contract PresyncRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(PoolKey calldata pool, address input, uint256 amount, address synced)
        external
        returns (uint256 received)
    {
        bytes memory result =
            manager.unlock(abi.encode(msg.sender, pool, input, amount, synced));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, address input, uint256 amount, address synced) =
            abi.decode(data, (address, PoolKey, address, uint256, address));
        manager.sync(Currency.wrap(synced));
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        uint256 spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (spent == 0) return abi.encode(received);
        manager.sync(Currency.wrap(input));
        TestAsset(input).transferFrom(payer, address(manager), spent);
        manager.settle();
        manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        return abi.encode(received);
    }
}

/// @dev A router that marks its input token as synced before it swaps and pays only
/// afterwards, without marking it again: sync, swap, transfer, settle.
contract SyncEarlyRouter is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    function trade(PoolKey calldata pool, address input, uint256 amount)
        external
        returns (uint256 received)
    {
        bytes memory result = manager.unlock(abi.encode(msg.sender, pool, input, amount));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, address input, uint256 amount) =
            abi.decode(data, (address, PoolKey, address, uint256));
        manager.sync(Currency.wrap(input));
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        uint256 spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        TestAsset(input).transferFrom(payer, address(manager), spent);
        manager.settle();
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        return abi.encode(received);
    }
}

/// @dev Pays a token into the pool manager itself and then swaps through a separate
/// router, so the payer and the swapper are different contracts.
contract SplitPayer {
    IPoolManager internal immutable manager;
    PoolSwapTest internal immutable router;

    constructor(IPoolManager poolManager, PoolSwapTest swapRouter) {
        manager = poolManager;
        router = swapRouter;
    }

    /// Pays a token in and then calls the given target (the hook's `arb`) directly.
    function payThenCall(address input, uint256 amount, address target, bytes calldata call)
        external
    {
        manager.sync(Currency.wrap(input));
        TestAsset(input).transfer(address(manager), amount);
        (bool ok, bytes memory reason) = target.call(call);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function payThenSwapThroughRouter(PoolKey calldata pool, address input, uint256 amount)
        external
    {
        manager.sync(Currency.wrap(input));
        TestAsset(input).transfer(address(manager), amount);
        TestAsset(input).approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        PoolSwapTest.TestSettings memory settings;
        router.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
    }
}

/// @dev A token written to misbehave once it has been marked as synced: its balance of the
/// pool manager reads as zero at first, and then according to `mode`.
contract HostileToken {
    uint256 public mode;

    function arm(uint256 value) external {
        mode = value;
    }

    function balanceOf(address) external view returns (uint256) {
        if (mode == 1) return 1 << 200;
        if (mode == 2) revert("hostile");
        if (mode == 3) {
            uint256 spin;
            while (gasleft() > 2_000) spin++;
            return spin;
        }
        return 0;
    }
}

/// @dev Marks a hostile token as synced, arms it, and then swaps and settles in the
/// ordinary way. What someone would try in order to make the hook stand aside.
contract HostileSyncRouter is IUnlockCallback {
    IPoolManager internal immutable manager;
    HostileToken public immutable hostile;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
        hostile = new HostileToken();
    }

    function trade(PoolKey calldata pool, address input, uint256 amount, uint256 mode)
        external
        returns (uint256 received)
    {
        bytes memory result = manager.unlock(abi.encode(msg.sender, pool, input, amount, mode));
        return abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory pool, address input, uint256 amount, uint256 mode) =
            abi.decode(data, (address, PoolKey, address, uint256, uint256));
        hostile.arm(0);
        manager.sync(Currency.wrap(address(hostile)));
        hostile.arm(mode);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        BalanceDelta delta = manager.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        uint256 spent = uint128(-(zeroForOne ? delta.amount0() : delta.amount1()));
        uint256 received = uint128(zeroForOne ? delta.amount1() : delta.amount0());
        if (spent == 0) return abi.encode(received);
        manager.sync(Currency.wrap(input));
        TestAsset(input).transferFrom(payer, address(manager), spent);
        manager.settle();
        manager.take(zeroForOne ? pool.currency1 : pool.currency0, payer, received);
        return abi.encode(received);
    }
}
