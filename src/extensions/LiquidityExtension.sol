// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { Multicallable } from "solady/utils/Multicallable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { Liquidity } from "../Liquidity.sol";
import { SzrCore } from "../SzrCore.sol";

interface IWrapped {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

interface IMarketHook {
    function openMarket(address recipient) external returns (uint256 id);
    function liquidity() external view returns (address);
}

/// @notice Shared base of the protocol's liquidity extensions: contracts that Liquidity's
/// manager funds with `sendFunding` and runs, to provide liquidity in pairs without SZR.
/// @dev Tokens leave only into pools (liquidity or swap input), to Core through `toCore`, and
/// into WETH by wrapping. No function pays an address the caller names. The manager is
/// trusted on prices and timing, as in Liquidity, but cannot take funds out. There are no
/// shares and no principal ledger: balances are the record, and every action emits an event.
abstract contract LiquidityExtension is ReentrancyGuard, Multicallable, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant KIND_SWAP = 0;
    // Owner calls that `marketCall` refuses, so profit stays payable to this contract and
    // no market can be given away or taken over.
    bytes4 internal constant SET_RECIPIENT = bytes4(keccak256("setRecipient(uint256,address)"));
    bytes4 internal constant NOMINATE_OWNER =
        bytes4(keccak256("nominateOwner(uint256,address)"));
    bytes4 internal constant OPEN_MARKET = bytes4(keccak256("openMarket(address)"));
    bytes4 internal constant ACCEPT_OWNERSHIP = bytes4(keccak256("acceptOwnership(uint256)"));

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        uint256 amount;
        uint256 minimumOut;
        uint160 sqrtPriceLimitX96;
    }

    Liquidity public immutable liquidity;
    SzrCore public immutable core;
    IPoolManager public immutable poolManager;
    address public immutable szr;
    address public immutable weth;
    address public immutable hook;
    mapping(bytes32 poolId => bool registered) public routeRegistered;
    /// Tokens of a registered route or pool, which anyone may give through `donate`.
    mapping(address asset => bool) public donatable;
    bytes32 internal expected;

    error ZeroAddress();
    error InvalidHook();
    error NotManager();
    error NotPoolManager();
    error UnexpectedCallback();
    error UnexpectedEther();
    error UnknownPool();
    error InvalidAsset();
    error InvalidDelta();
    error DeadlinePassed();
    error AboveMaximum();
    error BelowMinimum();
    error TransferAmountMismatch();
    error ForbiddenCall();
    error CallFailed();

    event RouteRegistered(bytes32 indexed poolId);
    event Swapped(bytes32 indexed poolId, bool zeroForOne, uint256 spent, uint256 received);
    event SentToCore(address indexed asset, uint256 amount);
    event Wrapped(uint256 amount);
    event Unwrapped(uint256 amount);
    event MarketOpened(uint256 indexed marketId);
    event MarketCalled(bytes4 indexed selector);
    event Donated(address indexed donor, address indexed asset, uint256 amount);

    constructor(Liquidity liquidity_, address hook_) {
        if (address(liquidity_) == address(0)) revert ZeroAddress();
        if (hook_ == address(0)) revert ZeroAddress();
        if (IMarketHook(hook_).liquidity() != address(liquidity_)) revert InvalidHook();
        liquidity = liquidity_;
        core = liquidity_.core();
        poolManager = liquidity_.poolManager();
        szr = liquidity_.token();
        weth = liquidity_.backingAsset();
        hook = hook_;
    }

    modifier onlyManager() {
        if (msg.sender != liquidity.manager()) revert NotManager();
        _;
    }

    /// @dev Plain ETH is taken only from WETH (an unwrap) and the pool manager (a take). A
    /// donor sends ETH through `donate`.
    receive() external payable {
        if (msg.sender == weth) return;
        if (msg.sender == address(poolManager)) return;
        revert UnexpectedEther();
    }

    /// @notice Marks an initialized v4 pool as one this contract may swap through.
    function registerRoute(PoolKey calldata pool) external nonReentrant onlyManager {
        PoolId poolId = pool.toId();
        (uint160 price,,,) = poolManager.getSlot0(poolId);
        if (price == 0) revert UnknownPool();
        routeRegistered[PoolId.unwrap(poolId)] = true;
        _allowDonations(Currency.unwrap(pool.currency0), Currency.unwrap(pool.currency1));
        emit RouteRegistered(PoolId.unwrap(poolId));
    }

    /// @notice Gives this contract tokens for its positions. It is a gift: the donor gets no
    /// shares and no claim, and the tokens leave only as any other balance does. Only WETH
    /// and the tokens of a registered route or pool are taken. ETH comes as `msg.value`, with
    /// `asset` zero, and stays ETH.
    function donate(address asset, uint256 amount) external payable nonReentrant {
        if (asset != weth) {
            if (!donatable[asset]) revert InvalidAsset();
        }
        if (asset == address(0)) {
            if (msg.value != amount) revert TransferAmountMismatch();
        } else {
            if (msg.value != 0) revert UnexpectedEther();
            uint256 beforeBalance = _balance(asset);
            SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount);
            // A token that takes a fee on transfer could not be used in a position either.
            if (_balance(asset) != beforeBalance + amount) revert TransferAmountMismatch();
        }
        emit Donated(msg.sender, asset, amount);
    }

    /// @notice One exact-input swap through a registered route, paid from this contract's
    /// balance. A swap through an arbitrage-hook pool carries the hook's own gas rule, so
    /// there is no gas check here.
    function swap(
        PoolKey calldata pool,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minimumOut,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 spent, uint256 received) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (!routeRegistered[PoolId.unwrap(pool.toId())]) revert UnknownPool();
        if (amountIn > uint256(type(uint128).max)) revert AboveMaximum();
        bytes memory response = _unlock(
            KIND_SWAP,
            abi.encode(SwapRequest(pool, zeroForOne, amountIn, minimumOut, sqrtPriceLimitX96))
        );
        (spent, received) = abi.decode(response, (uint256, uint256));
        emit Swapped(PoolId.unwrap(pool.toId()), zeroForOne, spent, received);
    }

    function wrap(uint256 amount) external nonReentrant onlyManager {
        IWrapped(weth).deposit{ value: amount }();
        emit Wrapped(amount);
    }

    function unwrap(uint256 amount) external nonReentrant onlyManager {
        IWrapped(weth).withdraw(amount);
        emit Unwrapped(amount);
    }

    /// @notice Gives WETH to Core as backing, or SZR to Core to retire. The approval is exact
    /// and reset to zero.
    function toCore(address asset, uint256 amount) external nonReentrant onlyManager {
        if (asset != weth) {
            if (asset != szr) revert InvalidAsset();
        }
        SafeTransferLib.safeApprove(asset, address(core), amount);
        if (asset == weth) core.donateBacking(amount);
        else core.donateSzr(amount);
        SafeTransferLib.safeApprove(asset, address(core), 0);
        emit SentToCore(asset, amount);
    }

    /// @notice Opens an arbitrage-hook market that this contract owns and is paid by.
    function openMarket() external nonReentrant onlyManager returns (uint256 marketId) {
        marketId = IMarketHook(hook).openMarket(address(this));
        emit MarketOpened(marketId);
    }

    /// @notice Forwards an owner call to the hook (createPool, addVenue, setLimits and so
    /// on). The hook's own owner check limits it to markets this contract owns. The calls
    /// that could redirect profit or give the market away are refused.
    function marketCall(bytes calldata data)
        external
        nonReentrant
        onlyManager
        returns (bytes memory result)
    {
        if (data.length < 4) revert ForbiddenCall();
        bytes4 pick = bytes4(data[:4]);
        if (pick == SET_RECIPIENT) revert ForbiddenCall();
        if (pick == NOMINATE_OWNER) revert ForbiddenCall();
        if (pick == OPEN_MARKET) revert ForbiddenCall();
        if (pick == ACCEPT_OWNERSHIP) revert ForbiddenCall();
        bool ok;
        (ok, result) = hook.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        emit MarketCalled(pick);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (expected == bytes32(0)) revert UnexpectedCallback();
        if (keccak256(data) != expected) revert UnexpectedCallback();
        expected = bytes32(0);
        (uint256 kind, bytes memory payload) = abi.decode(data, (uint256, bytes));
        if (kind == KIND_SWAP) return _swapCallback(abi.decode(payload, (SwapRequest)));
        return _unlockAction(kind, payload);
    }

    /// @dev Subclasses add their own unlock actions here, under kinds above `KIND_SWAP`.
    function _unlockAction(uint256 kind, bytes memory payload)
        internal
        virtual
        returns (bytes memory);

    function _unlock(uint256 kind, bytes memory payload) internal returns (bytes memory) {
        bytes memory data = abi.encode(kind, payload);
        expected = keccak256(data);
        bytes memory response = poolManager.unlock(data);
        if (expected != bytes32(0)) revert UnexpectedCallback();
        return response;
    }

    function _swapCallback(SwapRequest memory request) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.swap(
            request.key,
            IPoolManager.SwapParams({
                zeroForOne: request.zeroForOne,
                amountSpecified: -int256(request.amount),
                sqrtPriceLimitX96: request.sqrtPriceLimitX96
            }),
            ""
        );
        int128 input = request.zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = request.zeroForOne ? delta.amount1() : delta.amount0();
        if (input > 0) revert InvalidDelta();
        if (output < 0) revert InvalidDelta();
        uint256 spent = uint256(-int256(input));
        uint256 received = uint128(output);
        if (spent > request.amount) revert AboveMaximum();
        if (received < request.minimumOut) revert BelowMinimum();
        // A swap through an empty pool spends nothing and only moves its price.
        if (spent != 0) {
            _pay(request.zeroForOne ? request.key.currency0 : request.key.currency1, spent);
        }
        if (received != 0) {
            _take(request.zeroForOne ? request.key.currency1 : request.key.currency0, received);
        }
        return abi.encode(spent, received);
    }

    function _pay(Currency currency, uint256 amount) internal {
        address asset = Currency.unwrap(currency);
        if (asset == address(0)) {
            if (poolManager.settle{ value: amount }() != amount) {
                revert TransferAmountMismatch();
            }
            return;
        }
        poolManager.sync(currency);
        SafeTransferLib.safeTransfer(asset, address(poolManager), amount);
        if (poolManager.settle() != amount) revert TransferAmountMismatch();
    }

    function _take(Currency currency, uint256 amount) internal {
        address asset = Currency.unwrap(currency);
        uint256 beforeBalance = _balance(asset);
        poolManager.take(currency, address(this), amount);
        if (_balance(asset) != beforeBalance + amount) revert TransferAmountMismatch();
    }

    function _allowDonations(address one, address two) internal {
        donatable[one] = true;
        donatable[two] = true;
    }

    function _balance(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return SafeTransferLib.balanceOf(asset, address(this));
    }
}
