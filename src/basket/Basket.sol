// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Pool } from "v4-core/libraries/Pool.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";

/// @dev The protocol recipient is a liquidity extension; its Liquidity names the manager.
interface IBasketProtocol {
    function liquidity() external view returns (address);
}

interface IBasketManaged {
    function manager() external view returns (address);
}

/// @notice A pairing token: every share is the same slice of a fixed set of wide-range
/// Uniswap v4 positions, each in a pool of the unit token (USDG) and one other token. The
/// positions earn their pools' swap fees, so a share is worth more over time. Shares count
/// liquidity, never value: a deposit adds `shares / totalSupply` of every position and of
/// every idle balance, so existing holders' slice can never shrink and no price is needed.
/// @dev Spec: `docs/specs/lp-basket.md`. There is no owner. The legs, their ranges, the unit
/// token and the protocol cut are fixed in the constructor. Collected fees stay as pool
/// manager claims, never ERC20 balances, so the USDG paths never move a stock token: a
/// paused or blocklisted stock stops only in-kind deposits and redemptions.
/// @dev The creator also fixes `feeMode`, what holders' idle fees become: held as they are,
/// compounded into the legs, or converted to the unit token or to the stocks in capped
/// pieces (spec, "Fee modes").
/// @dev Disclosure: the stock tokens' issuer can upgrade, pause, blocklist or burn from any
/// address, the pool manager included. ERC20 tokens sent straight to this contract are lost;
/// claims transferred to it are a gift to holders. Views (`liquidityOf`, `previewInKind`, idle
/// claims) disagree with `totalSupply` in the middle of a deposit or redemption, while tokens
/// move; an integrator reading them from a token callback must not trust them.
contract Basket is ERC20, ReentrancyGuard, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct Leg {
        PoolKey pool;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @dev `changes` is the liquidity added to or removed from each leg. `limits` is one
    /// bound per token in kind, or one bound on the unit token alone.
    struct Request {
        uint8 kind;
        bool inUnit;
        address who;
        uint256 shares;
        uint256 supply;
        uint128[] changes;
        uint256[] limits;
    }

    uint256 public constant MAX_LEGS = 10;
    uint256 public constant DEAD_SHARES = 1000;
    uint256 public constant PROTOCOL_CUT_BPS = 1500;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant BPS = 10_000;
    uint8 internal constant KIND_ADD = 0;
    uint8 internal constant KIND_REMOVE = 1;
    uint8 internal constant KIND_PAY = 2;
    uint8 public constant FEE_HOLD = 0;
    uint8 public constant FEE_COMPOUND = 1;
    uint8 public constant FEE_TO_UNIT = 2;
    uint8 public constant FEE_TO_STOCKS = 3;
    // A conversion sells at most a quarter of the pool fee's share of what the basket holds.
    uint256 internal constant CAP_DIVISOR = 4_000_000;

    IPoolManager public immutable poolManager;
    address public immutable unit;
    address public immutable protocol;
    address public immutable creator;
    uint8 public immutable feeMode;
    bool public started;
    /// The last timestamp fees were compounded or converted, so either runs once a second.
    uint64 public convertedAt;
    string internal tokenName;
    string internal tokenSymbol;
    Leg[] internal legs;
    // The unit token first, then each leg's other token in leg order.
    address[] internal tokenList;
    uint128[] internal held;
    /// The protocol's part of collected fees, per token, not yet paid.
    mapping(address token => uint256 amount) public owed;
    bytes32 internal transient expected;

    error InvalidLeg();
    error InvalidFeeMode();
    error InvalidAmount();
    error NotCreator();
    error NotManager();
    error NotStarted();
    error AlreadyStarted();
    error DeadlinePassed();
    error AboveMaximum();
    error BelowMinimum();
    error PartialFill();
    error InvalidDelta();
    error NotPoolManager();
    error UnexpectedCallback();
    error TransferAmountMismatch();

    event Started(address indexed creator, uint256 shares);
    event Deposited(address indexed who, uint256 shares, bool inUnit, uint256[] paid);
    event Redeemed(address indexed who, uint256 shares, bool inUnit, uint256[] received);
    event FeesCollected(address indexed token, uint256 amount, uint256 cut);
    event ProtocolPaid(address indexed to, uint256 amount);
    event FeesCompounded(uint256 indexed leg, uint128 liquidity);
    event FeesConverted(address indexed from, uint256 amount, uint256 received);

    constructor(
        string memory name_,
        string memory symbol_,
        IPoolManager poolManager_,
        address unit_,
        address arbitrageHook,
        address protocol_,
        Leg[] memory legs_,
        address creator_,
        uint8 feeMode_
    ) {
        if (address(poolManager_) == address(0)) revert InvalidLeg();
        if (unit_ == address(0)) revert InvalidLeg();
        if (protocol_ == address(0)) revert InvalidLeg();
        if (creator_ == address(0)) revert InvalidLeg();
        if (legs_.length == 0) revert InvalidLeg();
        if (legs_.length > MAX_LEGS) revert InvalidLeg();
        if (feeMode_ > FEE_TO_STOCKS) revert InvalidFeeMode();
        poolManager = poolManager_;
        feeMode = feeMode_;
        unit = unit_;
        protocol = protocol_;
        creator = creator_;
        tokenName = name_;
        tokenSymbol = symbol_;
        tokenList.push(unit_);
        for (uint256 index; index < legs_.length; index++) {
            address other = _checkLeg(legs_[index], unit_, arbitrageHook, poolManager_);
            for (uint256 seen = 1; seen < tokenList.length; seen++) {
                if (tokenList[seen] == other) revert InvalidLeg();
            }
            tokenList.push(other);
            legs.push(legs_[index]);
            held.push(0);
        }
    }

    // No implicit allowance to an unverified deployment-chain Permit2 address, as in `Szr`.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    function name() public view override returns (string memory) {
        return tokenName;
    }

    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /// @notice Once, by the creator: adds `liquidity[i]` to leg i, paid in kind, and mints
    /// `shares` to the creator and `DEAD_SHARES` to `DEAD`.
    function start(
        uint128[] calldata liquidity,
        uint256 shares,
        uint256[] calldata maxIn,
        uint256 deadline
    ) external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (started) revert AlreadyStarted();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (shares == 0) revert InvalidAmount();
        // Keeps `held * shares` inside 256 bits for every later share calculation.
        if (shares > type(uint128).max) revert InvalidAmount();
        if (liquidity.length != legs.length) revert InvalidAmount();
        if (maxIn.length != tokenList.length) revert InvalidAmount();
        for (uint256 index; index < liquidity.length; index++) {
            if (liquidity[index] == 0) revert InvalidAmount();
        }
        started = true;
        uint256[] memory paid =
            _unlock(Request(KIND_ADD, false, msg.sender, shares, 0, liquidity, maxIn));
        _mint(msg.sender, shares);
        _mint(DEAD, DEAD_SHARES);
        emit Started(msg.sender, shares);
        emit Deposited(msg.sender, shares, false, paid);
    }

    /// @notice Mints `shares`, paid in every token at current prices (see `previewInKind`).
    function deposit(uint256 shares, uint256[] calldata maxIn, uint256 deadline)
        external
        nonReentrant
    {
        if (maxIn.length != tokenList.length) revert InvalidAmount();
        _deposit(shares, maxIn, false, deadline);
    }

    /// @notice Mints `shares`, paid in the unit token alone. Each leg's other token is
    /// bought in that leg's own pool inside the same unlock.
    function depositUnit(uint256 shares, uint256 maxUnit, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid)
    {
        paid = _deposit(shares, _one(maxUnit), true, deadline)[0];
    }

    /// @notice Burns `shares` for the same slice of every position and idle balance, in kind.
    function redeem(uint256 shares, uint256[] calldata minOut, uint256 deadline)
        external
        nonReentrant
    {
        if (minOut.length != tokenList.length) revert InvalidAmount();
        _redeem(shares, minOut, false, deadline);
    }

    /// @notice Burns `shares` and pays the unit token alone. Each leg's other token is sold
    /// in that leg's own pool inside the same unlock.
    function redeemUnit(uint256 shares, uint256 minUnit, uint256 deadline)
        external
        nonReentrant
        returns (uint256 received)
    {
        received = _redeem(shares, _one(minUnit), true, deadline)[0];
    }

    /// @notice Pays the protocol its cut in the unit token. Only Liquidity's manager may
    /// call it, because the swaps it makes need a floor someone trusted sets.
    function payProtocol(uint256 minUnit, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid)
    {
        if (!started) revert NotStarted();
        if (block.timestamp > deadline) revert DeadlinePassed();
        address manager = IBasketManaged(IBasketProtocol(protocol).liquidity()).manager();
        if (msg.sender != manager) revert NotManager();
        uint128[] memory none = new uint128[](0);
        paid = _unlock(Request(KIND_PAY, true, protocol, 0, 0, none, _one(minUnit)))[0];
        emit ProtocolPaid(protocol, paid);
    }

    function legCount() external view returns (uint256) {
        return legs.length;
    }

    function leg(uint256 index) external view returns (Leg memory) {
        return legs[index];
    }

    function tokens() external view returns (address[] memory) {
        return tokenList;
    }

    function liquidityOf(uint256 index) external view returns (uint128) {
        return held[index];
    }

    /// @notice What `deposit(shares, …)` would take of each token at current prices, in
    /// `tokens()` order. Fees not yet collected, and what the fee mode would do with them, are
    /// left out: the deposit does both first, so in modes other than hold the split between
    /// tokens can differ. Leave room in `maxIn`.
    function previewInKind(uint256 shares) external view returns (uint256[] memory amounts) {
        if (!started) revert NotStarted();
        uint256 supply = totalSupply();
        amounts = new uint256[](tokenList.length);
        for (uint256 index; index < legs.length; index++) {
            uint256 change = FixedPointMathLib.mulDivUp(held[index], shares, supply);
            (uint256 inUnit, uint256 inOther) =
                _amountsFor(legs[index], SafeCastLib.toUint128(change));
            amounts[0] += inUnit;
            amounts[index + 1] += inOther;
        }
        for (uint256 index; index < tokenList.length; index++) {
            uint256 idle = _idle(tokenList[index]);
            amounts[index] += FixedPointMathLib.mulDivUp(idle, shares, supply);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (expected == bytes32(0)) revert UnexpectedCallback();
        if (keccak256(data) != expected) revert UnexpectedCallback();
        expected = bytes32(0);
        Request memory request = abi.decode(data, (Request));
        _harvest();
        _useFees(request);
        uint256[] memory moved = new uint256[](tokenList.length);
        if (request.kind == KIND_PAY) {
            _takeOwed(moved);
            _sellOthers(moved);
            _payOut(request, moved);
            return abi.encode(moved);
        }
        bool adding = request.kind == KIND_ADD;
        // Figured only now, after the fee mode may have added liquidity; `start` brings its own
        if (request.supply != 0) {
            request.changes = _changes(request.shares, request.supply, adding);
        }
        _moveLegs(request, moved, adding);
        _moveIdle(request, moved, adding);
        if (adding) {
            if (request.inUnit) _buyOthers(moved);
            _payIn(request, moved);
        } else {
            if (request.inUnit) _sellOthers(moved);
            _payOut(request, moved);
        }
        return abi.encode(moved);
    }

    function _deposit(uint256 shares, uint256[] memory limits, bool inUnit, uint256 deadline)
        internal
        returns (uint256[] memory paid)
    {
        _live(shares, deadline);
        uint256 supply = totalSupply();
        uint128[] memory changes = new uint128[](0);
        paid = _unlock(Request(KIND_ADD, inUnit, msg.sender, shares, supply, changes, limits));
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, shares, inUnit, paid);
    }

    /// @dev The shares are burnt before the unlock, so nothing in it can spend them again;
    /// the slice is figured on the supply before the burn.
    function _redeem(uint256 shares, uint256[] memory limits, bool inUnit, uint256 deadline)
        internal
        returns (uint256[] memory received)
    {
        _live(shares, deadline);
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        uint128[] memory changes = new uint128[](0);
        Request memory request =
            Request(KIND_REMOVE, inUnit, msg.sender, shares, supply, changes, limits);
        received = _unlock(request);
        emit Redeemed(msg.sender, shares, inUnit, received);
    }

    function _live(uint256 shares, uint256 deadline) internal view {
        if (!started) revert NotStarted();
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (shares == 0) revert InvalidAmount();
    }

    /// @dev A deposit rounds every leg's liquidity up and a redemption rounds it down, so
    /// rounding never takes from holders.
    function _changes(uint256 shares, uint256 supply, bool up)
        internal
        view
        returns (uint128[] memory changes)
    {
        changes = new uint128[](legs.length);
        for (uint256 index; index < legs.length; index++) {
            uint256 change = up
                ? FixedPointMathLib.mulDivUp(held[index], shares, supply)
                : FixedPointMathLib.mulDiv(held[index], shares, supply);
            changes[index] = SafeCastLib.toUint128(change);
        }
    }

    function _unlock(Request memory request) internal returns (uint256[] memory moved) {
        bytes memory payload = abi.encode(request);
        expected = keccak256(payload);
        bytes memory response = poolManager.unlock(payload);
        if (expected != bytes32(0)) revert UnexpectedCallback();
        moved = abi.decode(response, (uint256[]));
    }

    /// @dev Collects every leg's fees as claims before any share is figured, so a depositor
    /// never shares fees earned before they joined. The pool refuses to touch an empty
    /// position, so one is skipped.
    function _harvest() internal {
        for (uint256 index; index < legs.length; index++) {
            if (held[index] == 0) continue;
            Leg storage entry = legs[index];
            (BalanceDelta delta,) =
                poolManager.modifyLiquidity(entry.pool, _params(entry, 0), "");
            _keepFees(entry.pool.currency0, delta.amount0());
            _keepFees(entry.pool.currency1, delta.amount1());
        }
    }

    function _keepFees(Currency currency, int128 amount) internal {
        if (amount < 0) revert InvalidDelta();
        if (amount == 0) return;
        uint256 size = uint128(amount);
        uint256 cut = size * PROTOCOL_CUT_BPS / BPS;
        owed[Currency.unwrap(currency)] += cut;
        poolManager.mint(address(this), currency.toId(), size);
        emit FeesCollected(Currency.unwrap(currency), size, cut);
    }

    /// @dev An in-kind redemption never converts, so its exit never depends on a swap.
    /// @dev The fees each sale earns its legs, and any a hook's search earns other legs, are
    /// collected straight after, so the share math that follows sees none.
    function _useFees(Request memory request) internal {
        if (feeMode == FEE_HOLD) return;
        if (convertedAt == block.timestamp) return;
        if (feeMode == FEE_COMPOUND) return _compound();
        if (request.kind == KIND_REMOVE) {
            if (!request.inUnit) return;
        }
        if (feeMode == FEE_TO_UNIT) _sellIdleStocks();
        else _buyIdleStocks();
        if (convertedAt == block.timestamp) _harvest();
    }

    /// @dev Adds the most liquidity each leg's idle pair covers at the current price, paid by
    /// burning the claims, up to the same cap as a conversion: adding at a pushed price loses
    /// to the pusher too. One wei less of each is offered, so rounding up never asks for more
    /// than is idle.
    function _compound() internal {
        for (uint256 index; index < legs.length; index++) {
            if (held[index] == 0) continue;
            Leg storage entry = legs[index];
            address other = tokenList[index + 1];
            uint256 liquidity = FixedPointMathLib.min(
                _liquidityFor(entry, _idle(unit), _idle(other)), _cap(entry, held[index])
            );
            if (liquidity == 0) continue;
            if (liquidity > _room(entry)) continue;
            held[index] += uint128(liquidity);
            convertedAt = uint64(block.timestamp);
            (BalanceDelta delta, BalanceDelta fees) =
                poolManager.modifyLiquidity(entry.pool, _params(entry, int256(liquidity)), "");
            if (BalanceDelta.unwrap(fees) != 0) revert InvalidDelta();
            (int128 inUnit, int128 inOther) = _split(entry.pool, delta);
            _burnClaim(unit, _size(inUnit, true));
            _burnClaim(other, _size(inOther, true));
            emit FeesCompounded(index, uint128(liquidity));
        }
    }

    function _sellIdleStocks() internal {
        for (uint256 index; index < legs.length; index++) {
            Leg storage entry = legs[index];
            (, uint256 side) = _amountsFor(entry, held[index]);
            uint256 piece =
                FixedPointMathLib.min(_idle(tokenList[index + 1]), _cap(entry, side));
            if (piece == 0) continue;
            _convert(entry, tokenList[index + 1], unit, piece);
        }
    }

    /// @dev Splits the idle unit token across legs in proportion to each leg's held unit.
    function _buyIdleStocks() internal {
        uint256 idle = _idle(unit);
        if (idle == 0) return;
        uint256[] memory sides = new uint256[](legs.length);
        uint256 total;
        for (uint256 index; index < legs.length; index++) {
            (sides[index],) = _amountsFor(legs[index], held[index]);
            total += sides[index];
        }
        if (total == 0) return;
        for (uint256 index; index < legs.length; index++) {
            Leg storage entry = legs[index];
            uint256 share = FixedPointMathLib.mulDiv(idle, sides[index], total);
            uint256 piece = FixedPointMathLib.min(share, _cap(entry, sides[index]));
            if (piece == 0) continue;
            _convert(entry, unit, tokenList[index + 1], piece);
        }
    }

    /// @dev Pushing the price by d through the basket's own liquidity costs about
    /// `side * fee * d` in pool fees; a piece of `side * fee / 4` can gain at most a quarter of
    /// that. A pool with no fee is never converted in.
    function _cap(Leg storage entry, uint256 side) internal view returns (uint256) {
        (,,, uint24 fee) = poolManager.getSlot0(entry.pool.toId());
        return FixedPointMathLib.mulDiv(side, fee, CAP_DIVISOR);
    }

    /// @dev Sells up to `amount` of `from` claims for `to` claims in the leg's pool, so no
    /// token leaves the pool manager. The sale stops at the leg's own range edge, and a price
    /// already at or past it sells nothing: beyond the edge the basket's liquidity is not
    /// there to make a push cost anything, and a sale could run the price to the limit.
    function _convert(Leg storage entry, address from, address to, uint256 amount) internal {
        PoolKey memory pool = entry.pool;
        bool zeroForOne = Currency.unwrap(pool.currency0) == from;
        (uint160 price,,,) = poolManager.getSlot0(pool.toId());
        uint160 edge =
            TickMath.getSqrtPriceAtTick(zeroForOne ? entry.tickLower : entry.tickUpper);
        // A full-range leg on a fine tick spacing ends exactly at v4's bounds, which v4 refuses
        // as a limit; one step inside is the same edge for any swap.
        if (edge == TickMath.MIN_SQRT_PRICE) edge++;
        if (edge == TickMath.MAX_SQRT_PRICE) edge--;
        if (zeroForOne) {
            if (price <= edge) return;
        } else {
            if (price >= edge) return;
        }
        // Only a sale counts toward once a second, so a collection with nothing to sell does
        // not hold back the next one.
        convertedAt = uint64(block.timestamp);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -SafeCastLib.toInt256(amount),
            sqrtPriceLimitX96: edge
        });
        BalanceDelta delta = poolManager.swap(pool, params, "");
        (int128 paid, int128 got) = (delta.amount0(), delta.amount1());
        if (!zeroForOne) (paid, got) = (got, paid);
        uint256 spent = _size(paid, true);
        uint256 received = _size(got, false);
        _burnClaim(from, spent);
        if (received != 0) poolManager.mint(address(this), Currency.wrap(to).toId(), received);
        emit FeesConverted(from, spent, received);
    }

    function _burnClaim(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.burn(address(this), Currency.wrap(token).toId(), amount);
    }

    /// @dev Fees were collected just before, and nothing has traded since, so the delta is
    /// principal alone.
    function _moveLegs(Request memory request, uint256[] memory moved, bool adding) internal {
        for (uint256 index; index < legs.length; index++) {
            uint128 change = request.changes[index];
            if (change == 0) continue;
            Leg storage entry = legs[index];
            int256 liquidityDelta = adding ? int256(uint256(change)) : -int256(uint256(change));
            if (adding) held[index] += change;
            else held[index] -= change;
            (BalanceDelta delta, BalanceDelta fees) =
                poolManager.modifyLiquidity(entry.pool, _params(entry, liquidityDelta), "");
            if (BalanceDelta.unwrap(fees) != 0) revert InvalidDelta();
            (int128 inUnit, int128 inOther) = _split(entry.pool, delta);
            moved[0] += _size(inUnit, adding);
            moved[index + 1] += _size(inOther, adding);
        }
    }

    /// @dev The same slice of every idle claim the holders own. A deposit mints the slice
    /// to this contract and pays for it; a redemption burns it and takes it out.
    function _moveIdle(Request memory request, uint256[] memory moved, bool adding) internal {
        if (request.supply == 0) return;
        for (uint256 index; index < tokenList.length; index++) {
            uint256 idle = _idle(tokenList[index]);
            uint256 part = adding
                ? FixedPointMathLib.mulDivUp(idle, request.shares, request.supply)
                : FixedPointMathLib.mulDiv(idle, request.shares, request.supply);
            if (part == 0) continue;
            uint256 id = Currency.wrap(tokenList[index]).toId();
            if (adding) poolManager.mint(address(this), id, part);
            else poolManager.burn(address(this), id, part);
            moved[index] += part;
        }
    }

    /// @dev Burns every owed claim, so its tokens become this call's credit.
    function _takeOwed(uint256[] memory moved) internal {
        for (uint256 index; index < tokenList.length; index++) {
            address token = tokenList[index];
            uint256 amount = owed[token];
            if (amount == 0) continue;
            owed[token] = 0;
            poolManager.burn(address(this), Currency.wrap(token).toId(), amount);
            moved[index] += amount;
        }
    }

    /// @dev Covers each leg's debt in its other token by buying exactly that much with the
    /// unit token in the leg's own pool, so only the unit token is ever paid in.
    function _buyOthers(uint256[] memory moved) internal {
        for (uint256 index; index < legs.length; index++) {
            uint256 amount = moved[index + 1];
            if (amount == 0) continue;
            PoolKey memory pool = legs[index].pool;
            bool zeroForOne = Currency.unwrap(pool.currency0) == unit;
            BalanceDelta delta = _swap(pool, zeroForOne, SafeCastLib.toInt256(amount));
            (int128 inUnit, int128 inOther) = _split(pool, delta);
            if (int256(inOther) != SafeCastLib.toInt256(amount)) revert PartialFill();
            moved[0] += _size(inUnit, true);
            moved[index + 1] = 0;
        }
    }

    /// @dev Sells each leg's credit in its other token for the unit token in the leg's own
    /// pool, so only the unit token is ever taken out.
    function _sellOthers(uint256[] memory moved) internal {
        for (uint256 index; index < legs.length; index++) {
            uint256 amount = moved[index + 1];
            if (amount == 0) continue;
            PoolKey memory pool = legs[index].pool;
            bool zeroForOne = Currency.unwrap(pool.currency0) != unit;
            BalanceDelta delta = _swap(pool, zeroForOne, -SafeCastLib.toInt256(amount));
            (int128 inUnit, int128 inOther) = _split(pool, delta);
            if (int256(inOther) != -SafeCastLib.toInt256(amount)) revert PartialFill();
            moved[0] += _size(inUnit, false);
            moved[index + 1] = 0;
        }
    }

    function _payIn(Request memory request, uint256[] memory moved) internal {
        for (uint256 index; index < tokenList.length; index++) {
            uint256 amount = moved[index];
            if (amount > _limitOf(request, index)) revert AboveMaximum();
            if (amount == 0) continue;
            Currency currency = Currency.wrap(tokenList[index]);
            poolManager.sync(currency);
            SafeTransferLib.safeTransferFrom(
                tokenList[index], request.who, address(poolManager), amount
            );
            if (poolManager.settle() != amount) revert TransferAmountMismatch();
        }
    }

    function _payOut(Request memory request, uint256[] memory moved) internal {
        for (uint256 index; index < tokenList.length; index++) {
            uint256 amount = moved[index];
            if (amount < _limitOf(request, index)) revert BelowMinimum();
            if (amount == 0) continue;
            poolManager.take(Currency.wrap(tokenList[index]), request.who, amount);
        }
    }

    function _limitOf(Request memory request, uint256 index) internal pure returns (uint256) {
        if (request.inUnit) return index == 0 ? request.limits[0] : 0;
        return request.limits[index];
    }

    function _swap(PoolKey memory pool, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta)
    {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        return poolManager.swap(pool, params, "");
    }

    function _params(Leg storage entry, int256 liquidityDelta)
        internal
        view
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: entry.tickLower,
            tickUpper: entry.tickUpper,
            liquidityDelta: liquidityDelta,
            salt: bytes32(0)
        });
    }

    /// @dev A delta's two sides as (unit token, other token).
    function _split(PoolKey memory pool, BalanceDelta delta)
        internal
        view
        returns (int128 inUnit, int128 inOther)
    {
        if (Currency.unwrap(pool.currency0) == unit) {
            return (delta.amount0(), delta.amount1());
        }
        return (delta.amount1(), delta.amount0());
    }

    /// @dev A paying side must be negative or zero and a receiving side positive or zero.
    function _size(int128 amount, bool paying) internal pure returns (uint256) {
        if (paying) {
            if (amount > 0) revert InvalidDelta();
            return uint256(-int256(amount));
        }
        if (amount < 0) revert InvalidDelta();
        return uint256(int256(amount));
    }

    function _one(uint256 value) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = value;
    }

    /// @dev The holders' claims of a token: the contract's claims less the protocol's.
    function _idle(address token) internal view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(token).toId()) - owed[token];
    }

    /// @dev What `liquidity` of a leg costs at the pool's current price, rounded up.
    function _amountsFor(Leg storage entry, uint128 liquidity)
        internal
        view
        returns (uint256 inUnit, uint256 inOther)
    {
        (uint160 price,,,) = poolManager.getSlot0(entry.pool.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        if (price < lower) price = lower;
        if (price > upper) price = upper;
        uint256 amount0 = SqrtPriceMath.getAmount0Delta(price, upper, liquidity, true);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(lower, price, liquidity, true);
        if (Currency.unwrap(entry.pool.currency0) == unit) return (amount0, amount1);
        return (amount1, amount0);
    }

    /// @dev The most liquidity `unitAmount` and `otherAmount`, less a wei each, buy in a leg
    /// at the current price.
    function _liquidityFor(Leg storage entry, uint256 unitAmount, uint256 otherAmount)
        internal
        view
        returns (uint256 most)
    {
        if (unitAmount != 0) unitAmount--;
        if (otherAmount != 0) otherAmount--;
        (uint160 price,,,) = poolManager.getSlot0(entry.pool.toId());
        uint160 lower = TickMath.getSqrtPriceAtTick(entry.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(entry.tickUpper);
        if (price < lower) price = lower;
        if (price > upper) price = upper;
        bool unitFirst = Currency.unwrap(entry.pool.currency0) == unit;
        (uint256 amount0, uint256 amount1) =
            unitFirst ? (unitAmount, otherAmount) : (otherAmount, unitAmount);
        most = type(uint256).max;
        if (price < upper) {
            uint256 scale = FixedPointMathLib.mulDiv(price, upper, 1 << 96);
            most = FixedPointMathLib.mulDiv(amount0, scale, upper - price);
        }
        if (price > lower) {
            uint256 fromOne = FixedPointMathLib.mulDiv(amount1, 1 << 96, price - lower);
            most = FixedPointMathLib.min(most, fromOne);
        }
    }

    /// @dev How much more liquidity both of a leg's ticks can take under v4's per-tick cap.
    function _room(Leg storage entry) internal view returns (uint256) {
        uint256 cap = Pool.tickSpacingToMaxLiquidityPerTick(entry.pool.tickSpacing);
        (uint128 atLower,) = poolManager.getTickLiquidity(entry.pool.toId(), entry.tickLower);
        (uint128 atUpper,) = poolManager.getTickLiquidity(entry.pool.toId(), entry.tickUpper);
        return cap - FixedPointMathLib.max(atLower, atUpper);
    }

    /// @dev One pool of the unit token and a distinct non-native token, initialised, with no
    /// hook or the arbitrage hook, and a range inside the usable ticks. Returns the other
    /// token.
    function _checkLeg(Leg memory entry, address unit_, address hook, IPoolManager manager)
        internal
        view
        returns (address other)
    {
        address zero = Currency.unwrap(entry.pool.currency0);
        address one = Currency.unwrap(entry.pool.currency1);
        if (zero == address(0)) revert InvalidLeg();
        if (zero == unit_) other = one;
        else if (one == unit_) other = zero;
        else revert InvalidLeg();
        address hooked = address(entry.pool.hooks);
        if (hooked != address(0)) {
            if (hooked != hook) revert InvalidLeg();
        }
        (uint160 price,,,) = manager.getSlot0(entry.pool.toId());
        if (price == 0) revert InvalidLeg();
        int24 spacing = entry.pool.tickSpacing;
        if (entry.tickLower >= entry.tickUpper) revert InvalidLeg();
        if (entry.tickLower < TickMath.minUsableTick(spacing)) revert InvalidLeg();
        if (entry.tickUpper > TickMath.maxUsableTick(spacing)) revert InvalidLeg();
        if (entry.tickLower % spacing != 0) revert InvalidLeg();
        if (entry.tickUpper % spacing != 0) revert InvalidLeg();
    }
}
