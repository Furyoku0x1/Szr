// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { SzrCore } from "./SzrCore.sol";
import { FeeCollector } from "./FeeCollector.sol";

/// @notice Native v4 treasury. All positions and idle principal belong to this contract.
/// @dev Core alone funds acquisition WETH. The manager allocates it; no withdrawal recipient
/// exists.
contract Liquidity is ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 public constant INITIAL_POSITION = type(uint256).max;
    uint256 internal constant Q96 = 1 << 96;

    struct PoolConfig {
        address partner;
        uint24 feePips;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint160 initialSqrtPriceX96;
        IHooks hooks;
    }

    struct Position {
        PoolKey key;
        address partner;
        int24 tickLower;
        int24 tickUpper;
        uint128 units;
    }

    struct Bounds {
        uint256 szrMaximum;
        uint256 partnerMaximum;
        uint256 deadline;
    }

    struct Deposit {
        uint256 units;
        uint256 szr;
        uint256 partner;
        uint256 szrFees;
        uint256 partnerFees;
    }

    struct Request {
        uint256 id;
        int256 delta;
        Bounds bounds;
    }

    struct SwapRequest {
        PoolKey key;
        bool zeroForOne;
        uint256 amount;
        uint256 minimumOut;
        uint160 sqrtPriceLimitX96;
    }

    struct Move {
        uint256 source;
        uint256 destination;
        uint256 removedUnits;
        uint256 addedUnits;
        uint256 minimumSzr;
        uint256 minimumPartner;
        Bounds depositBounds;
    }

    SzrCore public immutable core;
    FeeCollector public immutable feeJar;
    IPoolManager public immutable poolManager;
    address public immutable token;
    bytes32 public immutable poolManagerHash;
    address public manager;
    address public pendingManager;
    bool public initialLiquidityFunded;
    bool public started;
    uint256 public poolCount;
    mapping(uint256 id => Position) internal positions;
    mapping(bytes32 identity => bool used) public positionUsed;
    mapping(address asset => uint256 amount) public heldPrincipal;
    bytes32 internal expectedCallback;

    error ZeroAddress();
    error InvalidModule();
    error NotManager();
    error NotNominee();
    error NotCore();
    error NotPoolManager();
    error UnexpectedCallback();
    error UnknownPool();
    error InvalidAsset();
    error InvalidPool();
    error InvalidRange();
    error InvalidPrice();
    error DuplicatePosition();
    error AlreadyLaunched();
    error InitialLiquidityExists();
    error NotStarted();
    error InvalidUnits();
    error OutsideRange();
    error AboveMaximum();
    error BelowMinimum();
    error MissingContribution();
    error InvalidDelta();
    error DeadlinePassed();
    error PositionMismatch();
    error TransferAmountMismatch();
    error AccountingMismatch();

    event PoolAdded(uint256 indexed id, bytes32 indexed poolId, address indexed partner);
    event ManagerNominated(address indexed nominee);
    event ManagerChanged(address indexed previous, address indexed current);
    event LiquidityFunded(uint256 weth);
    event InitialLiquidityFunded(address indexed contributor, uint256 tokens, uint256 units);
    event PrincipalHeld(uint256 indexed id, uint256 units, uint256 szr, uint256 partner);
    event PrincipalDeployed(uint256 indexed id, uint256 units, uint256 szr, uint256 partner);
    event PrincipalSwapped(
        address indexed input, address indexed output, uint256 spent, uint256 received
    );
    event FeesCollected(uint256 indexed id, uint256 szr, uint256 partner);

    modifier onlyManager() {
        if (msg.sender != manager) revert NotManager();
        _;
    }

    constructor(
        SzrCore reserveCore,
        FeeCollector collector,
        IPoolManager venue,
        address operator
    ) {
        if (address(reserveCore).code.length == 0) revert InvalidModule();
        if (address(collector).code.length == 0) revert InvalidModule();
        if (address(collector.core()) != address(reserveCore)) revert InvalidModule();
        if (address(venue).code.length == 0) revert InvalidModule();
        if (operator == address(0)) revert ZeroAddress();
        core = reserveCore;
        feeJar = collector;
        poolManager = venue;
        poolManagerHash = address(venue).codehash;
        token = address(reserveCore.token());
        manager = operator;
    }

    function nominateManager(address nominee) external nonReentrant onlyManager {
        if (nominee == address(0)) revert ZeroAddress();
        if (nominee == manager) revert InvalidModule();
        pendingManager = nominee;
        emit ManagerNominated(nominee);
    }

    function cancelManagerNomination() external nonReentrant onlyManager {
        pendingManager = address(0);
        emit ManagerNominated(address(0));
    }

    function acceptManager() external nonReentrant {
        if (msg.sender != pendingManager) revert NotNominee();
        address previous = manager;
        manager = msg.sender;
        pendingManager = address(0);
        emit ManagerChanged(previous, msg.sender);
    }

    function position(uint256 id) external view returns (Position memory) {
        return _position(id);
    }

    function key(uint256 id) external view returns (PoolKey memory) {
        return _position(id).key;
    }

    function liquidityHeld(uint256 id) external view returns (uint256) {
        return _position(id).units;
    }

    function addPool(PoolConfig calldata config, FeeCollector.AssetConfig calldata feeConfig)
        external
        nonReentrant
        onlyManager
        returns (uint256 id)
    {
        id = poolCount++;
        _registerPool(id, config);
        feeJar.registerAsset(config.partner, feeConfig);
    }

    /// @notice Registers the one-sided position that an existing holder will fund after launch.
    function setInitialPool(
        PoolConfig calldata config,
        FeeCollector.AssetConfig calldata feeConfig
    ) external nonReentrant onlyManager {
        if (core.launched()) {
            revert AlreadyLaunched();
        }
        if (positions[INITIAL_POSITION].partner != address(0)) revert InitialLiquidityExists();
        _registerPool(INITIAL_POSITION, config);
        feeJar.registerAsset(config.partner, feeConfig);
    }

    function _registerPool(uint256 id, PoolConfig calldata config) internal {
        if (config.partner.code.length == 0) revert InvalidAsset();
        if (config.partner == token) revert InvalidAsset();
        if (address(config.hooks) != address(0)) {
            if (address(config.hooks).code.length == 0) revert InvalidPool();
        }
        _validateFee(config.feePips);
        _validateRange(config, id == INITIAL_POSITION);
        bool first = token < config.partner;
        PoolKey memory pool = _poolKey(config, first);
        bytes32 identity =
            keccak256(abi.encode(pool.toId(), config.tickLower, config.tickUpper));
        if (positionUsed[identity]) revert DuplicatePosition();
        positionUsed[identity] = true;
        (uint160 current,,,) = poolManager.getSlot0(pool.toId());
        if (current == 0) poolManager.initialize(pool, config.initialSqrtPriceX96);
        else if (current != config.initialSqrtPriceX96) revert InvalidPrice();
        if (id == INITIAL_POSITION) _validateInitialPrice(config, first);
        positions[id] = Position(pool, config.partner, config.tickLower, config.tickUpper, 0);
        emit PoolAdded(id, PoolId.unwrap(pool.toId()), config.partner);
    }

    function _poolKey(PoolConfig calldata config, bool first)
        internal
        view
        returns (PoolKey memory pool)
    {
        pool = PoolKey({
            currency0: Currency.wrap(first ? token : config.partner),
            currency1: Currency.wrap(first ? config.partner : token),
            fee: config.feePips,
            tickSpacing: config.tickSpacing,
            hooks: config.hooks
        });
    }

    function _validateFee(uint24 fee) internal pure {
        if (fee == 0x800000) return;
        if (fee == 0) revert InvalidPool();
        if (fee > 100_000) revert InvalidPool();
    }

    function _validateRange(PoolConfig calldata config, bool initialOnly) internal pure {
        if (config.tickSpacing <= 0) revert InvalidRange();
        if (config.tickSpacing > type(int16).max) revert InvalidRange();
        if (config.tickLower >= config.tickUpper) revert InvalidRange();
        if (config.tickLower < TickMath.MIN_TICK) revert InvalidRange();
        if (config.tickUpper > TickMath.MAX_TICK) revert InvalidRange();
        if (config.tickLower % config.tickSpacing != 0) revert InvalidRange();
        if (config.tickUpper % config.tickSpacing != 0) revert InvalidRange();
        if (initialOnly) return;
        _validateFullRange(config);
    }

    function _validateFullRange(PoolConfig calldata config) internal pure {
        if (config.tickLower != TickMath.minUsableTick(config.tickSpacing)) {
            revert InvalidRange();
        }
        if (config.tickUpper != TickMath.maxUsableTick(config.tickSpacing)) {
            revert InvalidRange();
        }
    }

    function _validateInitialPrice(PoolConfig calldata config, bool first) internal pure {
        if (first) {
            if (config.initialSqrtPriceX96 > TickMath.getSqrtPriceAtTick(config.tickLower)) {
                revert InvalidRange();
            }
        } else if (config.initialSqrtPriceX96 < TickMath.getSqrtPriceAtTick(config.tickUpper)) {
            revert InvalidRange();
        }
    }

    /// @notice A holder explicitly contributes active SZR to permanent initial POL.
    /// @dev Migration pays the holder 1:1 first; this function never draws Core inventory.
    function fundInitialLiquidity(uint256 minimumUnits, uint256 deadline)
        external
        nonReentrant
        returns (uint256 spent)
    {
        if (!started) revert NotStarted();
        if (initialLiquidityFunded) revert InitialLiquidityExists();
        if (block.timestamp > deadline) revert DeadlinePassed();
        uint256 maximum = core.initialLiquidityTarget();
        if (maximum == 0) revert InvalidUnits();
        Position storage entry = _position(INITIAL_POSITION);
        uint256 units = _initialUnits(entry, maximum);
        if (units < minimumUnits) revert BelowMinimum();
        uint256 beforeBalance = SafeTransferLib.balanceOf(token, address(this));
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), maximum);
        if (SafeTransferLib.balanceOf(token, address(this)) != beforeBalance + maximum) {
            revert TransferAmountMismatch();
        }
        initialLiquidityFunded = true;
        Deposit memory result =
            _modify(INITIAL_POSITION, int256(units), Bounds(maximum, 0, deadline));
        spent = _settleInitialContribution(maximum, beforeBalance, result);
        emit InitialLiquidityFunded(msg.sender, spent, units);
    }

    function _settleInitialContribution(
        uint256 maximum,
        uint256 beforeBalance,
        Deposit memory result
    ) internal returns (uint256 spent) {
        spent = result.szr;
        if (spent == 0) revert InvalidUnits();
        if (result.partner != 0) revert AccountingMismatch();
        if (spent > maximum) revert AboveMaximum();
        _routeFees(INITIAL_POSITION, result);
        if (spent != maximum) {
            SafeTransferLib.safeTransfer(token, msg.sender, maximum - spent);
        }
        if (SafeTransferLib.balanceOf(token, address(this)) != beforeBalance) {
            revert TransferAmountMismatch();
        }
    }

    function _initialUnits(Position storage entry, uint256 maximum)
        internal
        view
        returns (uint256 units)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        if (Currency.unwrap(entry.key.currency0) == token) {
            uint256 product = FixedPointMathLib.fullMulDiv(lower, upper, Q96);
            units = FixedPointMathLib.fullMulDiv(maximum, product, upper - lower);
        } else {
            units = FixedPointMathLib.fullMulDiv(maximum, Q96, upper - lower);
        }
        if (units == 0) revert InvalidUnits();
        SafeCastLib.toUint128(units);
    }

    function onLaunch() external {
        if (msg.sender != address(core)) revert NotCore();
        if (started) revert AlreadyLaunched();
        started = true;
    }

    /// @notice Core transfers only sale proceeds left after fully funding the reserve claim.
    function recordFunding(uint256 amount) external nonReentrant {
        if (msg.sender != address(core)) revert NotCore();
        if (!started) revert NotStarted();
        address weth = core.backingAsset();
        if (SafeTransferLib.balanceOf(weth, address(this)) < heldPrincipal[weth] + amount) {
            revert AccountingMismatch();
        }
        heldPrincipal[weth] += amount;
        emit LiquidityFunded(amount);
    }

    function quotePosition(uint256 id, uint256 units)
        public
        view
        returns (uint256 szr, uint256 partner)
    {
        if (units == 0) revert InvalidUnits();
        uint128 amount = SafeCastLib.toUint128(units);
        Position storage entry = _position(id);
        (uint160 current,,,) = poolManager.getSlot0(entry.key.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        if (id != INITIAL_POSITION) {
            if (current <= lower) revert OutsideRange();
            if (current >= upper) revert OutsideRange();
        }
        uint256 amount0;
        uint256 amount1;
        if (current <= lower) {
            amount0 = SqrtPriceMath.getAmount0Delta(lower, upper, amount, true);
        } else if (current >= upper) {
            amount1 = SqrtPriceMath.getAmount1Delta(lower, upper, amount, true);
        } else {
            amount0 = SqrtPriceMath.getAmount0Delta(current, upper, amount, true);
            amount1 = SqrtPriceMath.getAmount1Delta(lower, current, amount, true);
        }
        bool first = Currency.unwrap(entry.key.currency0) == token;
        return (first ? amount0 : amount1, first ? amount1 : amount0);
    }

    function collect(uint256 id) external nonReentrant {
        _collect(id);
    }

    function _collect(uint256 id) internal {
        Position storage entry = _position(id);
        if (!started) revert NotStarted();
        if (entry.units == 0) return;
        Deposit memory result = _modify(id, 0, Bounds(0, 0, block.timestamp));
        _routeFees(id, result);
    }

    function withdrawPrincipal(
        uint256 id,
        uint256 units,
        uint256 minSzr,
        uint256 minPartner,
        uint256 deadline
    ) external nonReentrant onlyManager {
        _withdrawHeld(id, units, minSzr, minPartner, deadline);
    }

    function deployPrincipal(uint256 id, uint256 units, Bounds calldata bounds)
        external
        nonReentrant
        onlyManager
    {
        _deployHeld(id, units, bounds);
    }

    function moveLiquidity(Move calldata request) external nonReentrant onlyManager {
        if (request.source == request.destination) revert InvalidPool();
        _withdrawHeld(
            request.source,
            request.removedUnits,
            request.minimumSzr,
            request.minimumPartner,
            request.depositBounds.deadline
        );
        _deployHeld(request.destination, request.addedUnits, request.depositBounds);
    }

    function _withdrawHeld(
        uint256 id,
        uint256 units,
        uint256 minSzr,
        uint256 minPartner,
        uint256 deadline
    ) internal {
        if (!started) revert NotStarted();
        // Genesis POL is permanent: its SZR leaves only to pool buyers, never via the manager.
        if (id == INITIAL_POSITION) revert InvalidPool();
        if (units == 0) revert InvalidUnits();
        SafeCastLib.toUint128(units);
        Deposit memory result =
            _modify(id, -int256(units), Bounds(minSzr, minPartner, deadline));
        heldPrincipal[token] += result.szr;
        heldPrincipal[_position(id).partner] += result.partner;
        _routeFees(id, result);
        emit PrincipalHeld(id, units, result.szr, result.partner);
    }

    function _deployHeld(uint256 id, uint256 units, Bounds memory bounds) internal {
        if (!started) revert NotStarted();
        if (id == INITIAL_POSITION) revert InvalidPool();
        address partner = _position(id).partner;
        (uint256 ownAmount, uint256 pairAmount) = quotePosition(id, units);
        if (ownAmount > heldPrincipal[token]) revert MissingContribution();
        if (pairAmount > heldPrincipal[partner]) revert MissingContribution();
        if (bounds.szrMaximum > heldPrincipal[token]) bounds.szrMaximum = heldPrincipal[token];
        if (bounds.partnerMaximum > heldPrincipal[partner]) {
            bounds.partnerMaximum = heldPrincipal[partner];
        }
        Deposit memory result = _modify(id, int256(units), bounds);
        heldPrincipal[token] -= result.szr;
        heldPrincipal[partner] -= result.partner;
        _routeFees(id, result);
        emit PrincipalDeployed(id, units, result.szr, result.partner);
    }

    /// @notice Exact-input treasury trade through an existing v4 pool, including WETH/partner
    /// routes.
    function swapPrincipal(
        PoolKey calldata pool,
        bool zeroForOne,
        uint256 amount,
        uint256 minimumOut,
        uint160 sqrtPriceLimitX96,
        uint256 deadline
    ) external nonReentrant onlyManager returns (uint256 spent, uint256 received) {
        if (!started) revert NotStarted();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (amount == 0) revert InvalidUnits();
        if (amount > uint256(uint128(type(int128).max))) revert InvalidUnits();
        address input = Currency.unwrap(zeroForOne ? pool.currency0 : pool.currency1);
        address output = Currency.unwrap(zeroForOne ? pool.currency1 : pool.currency0);
        if (input.code.length == 0) revert InvalidAsset();
        if (output.code.length == 0) revert InvalidAsset();
        if (amount > heldPrincipal[input]) revert MissingContribution();
        SwapRequest memory request =
            SwapRequest(pool, zeroForOne, amount, minimumOut, sqrtPriceLimitX96);
        bytes memory response = _unlock(abi.encode(true, abi.encode(request)));
        (spent, received) = abi.decode(response, (uint256, uint256));
        heldPrincipal[input] -= spent;
        heldPrincipal[output] += received;
        emit PrincipalSwapped(input, output, spent, received);
    }

    function _position(uint256 id) internal view returns (Position storage entry) {
        entry = positions[id];
        if (entry.partner == address(0)) revert UnknownPool();
    }

    function _salt(uint256 id) internal pure returns (bytes32) {
        if (id == INITIAL_POSITION) return bytes32(type(uint256).max);
        return bytes32(id + 1);
    }

    function _modify(uint256 id, int256 delta, Bounds memory bounds)
        internal
        returns (Deposit memory result)
    {
        if (block.timestamp > bounds.deadline) revert DeadlinePassed();
        Position storage entry = _position(id);
        uint256 units = uint256(delta < 0 ? -delta : delta);
        uint128 amount = SafeCastLib.toUint128(units);
        if (delta < 0) {
            if (amount > entry.units) revert InvalidUnits();
            entry.units -= amount;
        } else {
            entry.units += amount;
        }
        Request memory request = Request(id, delta, bounds);
        result = abi.decode(_unlock(abi.encode(false, abi.encode(request))), (Deposit));
        (uint128 actual,,) = poolManager.getPositionInfo(
            entry.key.toId(), address(this), entry.tickLower, entry.tickUpper, _salt(id)
        );
        if (actual != entry.units) revert PositionMismatch();
        result.units = units;
    }

    function _unlock(bytes memory payload) internal returns (bytes memory response) {
        if (address(poolManager).codehash != poolManagerHash) revert InvalidModule();
        expectedCallback = keccak256(payload);
        response = poolManager.unlock(payload);
        if (expectedCallback != bytes32(0)) revert UnexpectedCallback();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (expectedCallback == bytes32(0)) revert UnexpectedCallback();
        if (keccak256(data) != expectedCallback) revert UnexpectedCallback();
        expectedCallback = bytes32(0);
        (bool swapping, bytes memory payload) = abi.decode(data, (bool, bytes));
        if (swapping) {
            (uint256 spent, uint256 received) = _swap(abi.decode(payload, (SwapRequest)));
            return abi.encode(spent, received);
        }
        return abi.encode(_modifyCallback(abi.decode(payload, (Request))));
    }

    function _modifyCallback(Request memory request) internal returns (Deposit memory result) {
        Position storage entry = _position(request.id);
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: entry.tickLower,
            tickUpper: entry.tickUpper,
            liquidityDelta: request.delta,
            salt: _salt(request.id)
        });
        (BalanceDelta delta, BalanceDelta fees) =
            poolManager.modifyLiquidity(entry.key, params, "");
        if (fees.amount0() < 0) revert InvalidDelta();
        if (fees.amount1() < 0) revert InvalidDelta();
        BalanceDelta principal = delta - fees;
        if (request.delta > 0) result = _settleAdd(entry, request, principal);
        else if (request.delta < 0) result = _settleRemoval(entry, request, principal);
        else if (BalanceDelta.unwrap(principal) != 0) revert InvalidDelta();
        uint256 fee0 = uint128(fees.amount0());
        uint256 fee1 = uint128(fees.amount1());
        if (fee0 != 0) _take(entry.key.currency0, fee0);
        if (fee1 != 0) _take(entry.key.currency1, fee1);
        bool first = Currency.unwrap(entry.key.currency0) == token;
        result.szrFees = first ? fee0 : fee1;
        result.partnerFees = first ? fee1 : fee0;
    }

    function _settleAdd(Position storage entry, Request memory request, BalanceDelta principal)
        internal
        returns (Deposit memory result)
    {
        if (principal.amount0() > 0) revert InvalidDelta();
        if (principal.amount1() > 0) revert InvalidDelta();
        uint256 amount0 = uint256(-int256(principal.amount0()));
        uint256 amount1 = uint256(-int256(principal.amount1()));
        bool first = Currency.unwrap(entry.key.currency0) == token;
        result.szr = first ? amount0 : amount1;
        result.partner = first ? amount1 : amount0;
        if (result.szr > request.bounds.szrMaximum) revert AboveMaximum();
        if (result.partner > request.bounds.partnerMaximum) revert AboveMaximum();
        if (request.id != INITIAL_POSITION) _requireTwoSided(amount0, amount1);
        if (amount0 != 0) _pay(entry.key.currency0, amount0);
        if (amount1 != 0) _pay(entry.key.currency1, amount1);
    }

    function _requireTwoSided(uint256 amount0, uint256 amount1) internal pure {
        if (amount0 == 0) revert OutsideRange();
        if (amount1 == 0) revert OutsideRange();
    }

    function _settleRemoval(
        Position storage entry,
        Request memory request,
        BalanceDelta principal
    ) internal returns (Deposit memory result) {
        if (principal.amount0() < 0) revert InvalidDelta();
        if (principal.amount1() < 0) revert InvalidDelta();
        uint256 amount0 = uint128(principal.amount0());
        uint256 amount1 = uint128(principal.amount1());
        bool first = Currency.unwrap(entry.key.currency0) == token;
        result.szr = first ? amount0 : amount1;
        result.partner = first ? amount1 : amount0;
        if (result.szr < request.bounds.szrMaximum) revert BelowMinimum();
        if (result.partner < request.bounds.partnerMaximum) revert BelowMinimum();
        if (amount0 != 0) _take(entry.key.currency0, amount0);
        if (amount1 != 0) _take(entry.key.currency1, amount1);
    }

    function _swap(SwapRequest memory request)
        internal
        returns (uint256 spent, uint256 received)
    {
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
        (spent, received) = _swapAmounts(input, output, request.amount, request.minimumOut);
        _pay(request.zeroForOne ? request.key.currency0 : request.key.currency1, spent);
        if (received != 0) {
            _take(request.zeroForOne ? request.key.currency1 : request.key.currency0, received);
        }
    }

    function _swapAmounts(int128 input, int128 output, uint256 maximum, uint256 minimum)
        internal
        pure
        returns (uint256 spent, uint256 received)
    {
        if (input > 0) revert InvalidDelta();
        if (output < 0) revert InvalidDelta();
        spent = uint256(-int256(input));
        received = uint128(output);
        if (spent == 0) revert InvalidUnits();
        if (spent > maximum) revert AboveMaximum();
        if (received < minimum) revert BelowMinimum();
    }

    function _pay(Currency currency, uint256 amount) internal {
        poolManager.sync(currency);
        SafeTransferLib.safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        if (poolManager.settle() != amount) revert TransferAmountMismatch();
    }

    function _take(Currency currency, uint256 amount) internal {
        uint256 beforeBalance =
            SafeTransferLib.balanceOf(Currency.unwrap(currency), address(this));
        poolManager.take(currency, address(this), amount);
        if (
            SafeTransferLib.balanceOf(Currency.unwrap(currency), address(this))
                != beforeBalance + amount
        ) {
            revert TransferAmountMismatch();
        }
    }

    function _routeFees(uint256 id, Deposit memory result) internal {
        if (result.szrFees != 0) {
            SafeTransferLib.safeApprove(token, address(core), result.szrFees);
            core.recycle(result.szrFees);
            SafeTransferLib.safeApprove(token, address(core), 0);
        }
        if (result.partnerFees != 0) {
            address partner = _position(id).partner;
            SafeTransferLib.safeTransfer(partner, address(feeJar), result.partnerFees);
            feeJar.recordFees(partner, result.partnerFees);
        }
        emit FeesCollected(id, result.szrFees, result.partnerFees);
    }
}
