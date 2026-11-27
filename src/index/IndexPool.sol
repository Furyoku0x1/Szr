// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IIndexHook } from "../interfaces/IIndexHook.sol";
import { IndexMath } from "./IndexMath.sol";

interface IIndexToken {
    function decimals() external view returns (uint8);
}

/// @notice A weighted pool of 2 to 8 tokens whose share is itself an ERC20: every share is a
/// fixed fraction of every token the pool holds, so it is an index of them that earns swap
/// fees. Anyone may swap between the tokens; deposits and withdrawals are proportional only.
/// @dev Spec: `docs/specs/index-pool.md`. There is no owner and nothing can be changed after
/// creation. The pool prices on the balances it records, never on `balanceOf`, so tokens sent
/// to it directly change nothing. Disclosure: an issuer that burns tokens from this address
/// leaves the last holders to withdraw that token short.
contract IndexPool is ERC20, ReentrancyGuard {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for address;

    struct Release {
        uint256 amount;
        uint256 last;
        uint256 end;
    }

    /// A token's level: its stored balance and the share supply at its first swap of
    /// either kind in `window`, and the level of the window just before, when it had one.
    /// A previous supply of zero means there is none.
    struct Level {
        uint256 window;
        uint256 balance;
        uint256 supply;
        uint256 previousBalance;
        uint256 previousSupply;
    }

    struct Quote {
        uint256 amountIn;
        uint256 amountOut;
        uint256 cut;
    }

    struct Order {
        address tokenIn;
        address tokenOut;
        uint256 amount;
        bool exactIn;
        uint256 limit;
        address recipient;
    }

    uint256 public constant MIN_TOKENS = 2;
    uint256 public constant MAX_TOKENS = 8;
    uint256 public constant MIN_WEIGHT = 1e16;
    uint256 public constant MIN_SWAP_FEE = 1e13; // 0.001%
    uint256 public constant MAX_SWAP_FEE = 1e17; // 10%
    uint256 public constant MAX_IN_RATIO = 30e16;
    uint256 public constant MAX_OUT_RATIO = 30e16;
    uint256 public constant MIN_TRADE = 1e6; // 18-decimal
    uint256 public constant MIN_BALANCE = 1e6; // 18-decimal
    uint256 public constant DEAD_SHARES = 1e6;
    uint256 public constant PROTOCOL_CUT_BPS = 1500; // of swap fees
    uint256 public constant DONATION_CUT_BPS = 3000; // of donated profit
    uint256 public constant DONATION_RELEASE = 3 days;
    uint256 public constant MAX_HOOK_GAS = 8_000_000;
    uint256 public constant MIN_START_SHARES = 1e12;
    uint256 public constant OUTFLOW_WINDOW = 24 hours;
    uint256 public constant OUTFLOW_FLOOR = 70e16; // of balance per share at the window's start
    /// Gas kept back for the swap itself when the hook is first called. It only makes a
    /// swap that could not finish revert early; no amount lets a hook call go short. A cold
    /// swap of real Robinhood stock tokens and USDG used at most 333,571 once both tokens
    /// record a level (fork test, 2026-11-25), so 300,000 was raised to leave a third spare.
    uint256 public constant SWAP_GAS = 450_000;
    /// Gas a hook call needs on top of what the hook is given: the call itself and what
    /// runs between the gas check and the call.
    uint256 public constant HOOK_CALL_GAS = 10_000;
    /// Holds the locked first shares; nobody can spend from it.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable swapFee;
    address public immutable protocol;
    address public immutable hook;
    uint256 public immutable hookGas;
    bool public immutable hookApproved;
    address public immutable creator;

    bool public started;
    string internal tokenName;
    string internal tokenSymbol;
    address[] internal tokenList;
    uint256[] internal weightList;
    uint256[] internal scaleList;
    /// Each token's index plus one, so zero means not a pool token.
    mapping(address token => uint256) internal slot;
    /// Raw balances the pool prices on: the cut, deferred amounts and unreleased donations
    /// are kept out.
    uint256[] internal stored;
    Release[] internal releases;
    Level[] internal levels;
    mapping(address token => uint256) public owed;
    mapping(address holder => mapping(address token => uint256)) public deferred;

    error InvalidTokenCount();
    error NativeToken();
    error UnsortedTokens();
    error WeightTooLow();
    error WeightsNotWhole();
    error TooManyDecimals();
    error InvalidSwapFee();
    error InvalidHookGas();
    error ZeroAddress();
    error NotCreator();
    error AlreadyStarted();
    error NotStarted();
    error InvalidShares();
    error StartTooSmall();
    error LengthMismatch();
    error Expired();
    error UnknownToken();
    error SameToken();
    error InvalidRecipient();
    error TradeTooSmall();
    error BalanceTooLow();
    error OutflowLimit();
    error Slippage();
    error TransferMismatch();
    error ZeroAmount();
    error InsufficientGas();
    error HookBlocked();

    event Started(address indexed creator, uint256 shares, uint256[] amounts);
    event Joined(address indexed holder, uint256 shares, uint256[] amounts);
    event Exited(address indexed holder, uint256 shares, uint256[] amounts, uint256 deferMask);
    event Claimed(address indexed holder, address indexed token, uint256 amount);
    event Swapped(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event Donated(address indexed donor, address indexed token, uint256 amount, uint256 cut);
    event ProtocolPaid(address indexed token, uint256 amount);

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens_,
        uint256[] memory weights_,
        uint256 swapFee_,
        address protocol_,
        address hook_,
        uint32 hookGas_,
        bool hookApproved_,
        address creator_
    ) {
        if (tokens_.length < MIN_TOKENS) revert InvalidTokenCount();
        if (tokens_.length > MAX_TOKENS) revert InvalidTokenCount();
        if (weights_.length != tokens_.length) revert LengthMismatch();
        if (swapFee_ < MIN_SWAP_FEE) revert InvalidSwapFee();
        if (swapFee_ > MAX_SWAP_FEE) revert InvalidSwapFee();
        if (protocol_ == address(0)) revert ZeroAddress();
        if (creator_ == address(0)) revert ZeroAddress();
        uint256 total;
        address previous;
        for (uint256 index; index < tokens_.length; index++) {
            _addToken(tokens_[index], weights_[index], previous);
            previous = tokens_[index];
            total += weights_[index];
        }
        if (total != 1e18) revert WeightsNotWhole();
        // A hook that is given no gas could never run, and one given more than the cap could
        // not be called twice inside Robinhood Chain's 32M transaction limit.
        if (hook_ != address(0)) {
            if (hookGas_ == 0) revert InvalidHookGas();
            if (hookGas_ > MAX_HOOK_GAS) revert InvalidHookGas();
        }
        tokenName = name_;
        tokenSymbol = symbol_;
        swapFee = swapFee_;
        protocol = protocol_;
        hook = hook_;
        hookGas = hook_ == address(0) ? 0 : hookGas_;
        hookApproved = hook_ != address(0) && hookApproved_;
        creator = creator_;
    }

    function name() public view override returns (string memory) {
        return tokenName;
    }

    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /// Shares carry no built-in Permit2 allowance, as with `Szr`.
    function _givePermit2InfiniteAllowance() internal pure override returns (bool) {
        return false;
    }

    /// @notice The first deposit, by the creator, who chooses the share count. The amounts
    /// set the starting prices; `DEAD_SHARES` of the shares are locked for good.
    function start(uint256[] calldata amounts, uint256 shares, uint256 deadline)
        external
        nonReentrant
    {
        if (block.timestamp > deadline) revert Expired();
        if (msg.sender != creator) revert NotCreator();
        if (started) revert AlreadyStarted();
        if (shares < MIN_START_SHARES) revert InvalidShares();
        if (shares > type(uint128).max) revert InvalidShares();
        if (amounts.length != tokenList.length) revert LengthMismatch();
        started = true;
        for (uint256 index; index < amounts.length; index++) {
            // A thousand times the minimum keeps a fresh pool far from where one unit counts.
            if (amounts[index] < 1000 * _minimumRaw(index)) revert StartTooSmall();
            _pull(tokenList[index], amounts[index]);
            stored[index] = amounts[index];
        }
        _mint(DEAD, DEAD_SHARES);
        _mint(msg.sender, shares - DEAD_SHARES);
        emit Started(msg.sender, shares, amounts);
    }

    /// @notice Mints `shares` for the same fraction of every token, each rounded up.
    function join(uint256 shares, uint256[] calldata maxIn, uint256 deadline)
        external
        nonReentrant
    {
        _ready(deadline);
        if (shares == 0) revert ZeroAmount();
        if (maxIn.length != tokenList.length) revert LengthMismatch();
        _releaseAll();
        uint256 supply = totalSupply();
        uint256[] memory amounts = new uint256[](maxIn.length);
        for (uint256 index; index < maxIn.length; index++) {
            uint256 amount = stored[index].fullMulDivUp(shares, supply);
            if (amount > maxIn[index]) revert Slippage();
            _pull(tokenList[index], amount);
            stored[index] += amount;
            amounts[index] = amount;
        }
        _mint(msg.sender, shares);
        emit Joined(msg.sender, shares, amounts);
    }

    /// @notice Burns `shares` for the same fraction of every token, each rounded down. Tokens
    /// in `deferring` are recorded for `claim` instead of sent, so a token that cannot move
    /// never keeps a holder from leaving with the rest.
    function exit(
        uint256 shares,
        uint256[] calldata minOut,
        address[] calldata deferring,
        uint256 deadline
    ) external nonReentrant {
        _ready(deadline);
        if (shares == 0) revert ZeroAmount();
        if (minOut.length != tokenList.length) revert LengthMismatch();
        uint256 mask = _deferMask(deferring);
        _releaseAll();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        uint256[] memory amounts = new uint256[](minOut.length);
        for (uint256 index; index < minOut.length; index++) {
            uint256 amount = stored[index].fullMulDiv(shares, supply);
            if (amount < minOut[index]) revert Slippage();
            stored[index] -= amount;
            amounts[index] = amount;
            if (mask & (1 << index) != 0) deferred[msg.sender][tokenList[index]] += amount;
        }
        // Balances and supply are final before any token leaves.
        for (uint256 index; index < amounts.length; index++) {
            if (mask & (1 << index) != 0) continue;
            if (amounts[index] == 0) continue;
            tokenList[index].safeTransfer(msg.sender, amounts[index]);
        }
        emit Exited(msg.sender, shares, amounts, mask);
    }

    /// @notice Pays what an earlier `exit` deferred of `token`.
    function claim(address token) external nonReentrant returns (uint256 amount) {
        if (!started) revert NotStarted();
        amount = deferred[msg.sender][token];
        if (amount == 0) return 0;
        deferred[msg.sender][token] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, token, amount);
    }

    /// @notice `exactIn`: `amount` is what is paid and `limit` the least to receive.
    /// Otherwise `amount` is what is received and `limit` the most to pay.
    /// @dev Runs in three steps: the hook's `beforeSwap`, the swap under the lock, then
    /// `afterSwap`. The hook is called with the lock released and the books settled, so its
    /// own swaps and donations enter the pool normally. The hook's own swaps pay no fee and
    /// do not call it again.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn,
        uint256 limit,
        address recipient,
        uint256 deadline
    ) external nonReadReentrant returns (uint256 amountIn, uint256 amountOut) {
        _ready(deadline);
        if (recipient == address(this)) revert InvalidRecipient();
        Order memory order = Order(tokenIn, tokenOut, amount, exactIn, limit, recipient);
        if (msg.sender == hook) return _swap(order, 0);
        bool hooked = hook != address(0);
        uint256 callGas = hookGas * 64 / 63 + HOOK_CALL_GAS;
        if (hooked) {
            // Both hook calls and the swap must be affordable before the first is made, so
            // a caller can never send just enough to run the swap but starve a hook call.
            if (gasleft() < 2 * callGas + SWAP_GAS) revert InsufficientGas();
            bytes memory before =
                abi.encodeCall(IIndexHook.beforeSwap, (msg.sender, tokenIn, tokenOut));
            // Only an approved hook may refuse a swap, and only before it is priced.
            if (_callHook(before, hookApproved)) revert HookBlocked();
        }
        (amountIn, amountOut) = _swap(order, swapFee);
        if (hooked) {
            if (gasleft() < callGas) revert InsufficientGas();
            // `afterSwap` can never block: the swap has already been made.
            _callHook(
                abi.encodeCall(
                    IIndexHook.afterSwap, (msg.sender, tokenIn, tokenOut, amountIn, amountOut)
                ),
                false
            );
        }
    }

    /// @notice Sends the protocol's cut of `token` to `protocol`. Anyone may call it.
    function payProtocol(address token) external nonReentrant returns (uint256 paid) {
        if (!started) revert NotStarted();
        paid = owed[token];
        if (paid == 0) return 0;
        owed[token] = 0;
        token.safeTransfer(protocol, paid);
        emit ProtocolPaid(token, paid);
    }

    /// @notice Gives `amount` of `token` to every share, less the protocol's 30%, released
    /// over 3 days. Released slowly so nobody can join, set off a donation and leave with
    /// most of it in one transaction.
    function donate(address token, uint256 amount) external nonReentrant {
        if (!started) revert NotStarted();
        uint256 index = _index(token);
        if (amount == 0) revert ZeroAmount();
        _release(index);
        _pull(token, amount);
        uint256 cut = amount * DONATION_CUT_BPS / 10_000;
        owed[token] += cut;
        Release storage release = releases[index];
        uint256 added = amount - cut;
        uint256 held = release.amount;
        release.end = block.timestamp + _timeLeft(held, release.end, added);
        release.amount = held + added;
        release.last = block.timestamp;
        emit Donated(msg.sender, token, amount, cut);
    }

    function tokens() external view returns (address[] memory) {
        return tokenList;
    }

    function weights() external view returns (uint256[] memory) {
        return weightList;
    }

    /// @notice Raw balances as the next call would price them, released donations included.
    function balances() public view nonReadReentrant returns (uint256[] memory result) {
        result = new uint256[](tokenList.length);
        for (uint256 index; index < result.length; index++) {
            result[index] = stored[index] + _due(releases[index]);
        }
    }

    /// @notice What of a donation in `token` is still to be released.
    function unreleased(address token) external view returns (uint256) {
        Release memory release = releases[_index(token)];
        return release.amount - _due(release);
    }

    /// @notice The amounts `swap` would take and pay now, for this caller.
    function quoteSwap(address tokenIn, address tokenOut, uint256 amount, bool exactIn)
        external
        view
        nonReadReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        (uint256 indexIn, uint256 indexOut) = _pair(tokenIn, tokenOut);
        uint256 balanceIn = stored[indexIn] + _due(releases[indexIn]);
        uint256 balanceOut = stored[indexOut] + _due(releases[indexOut]);
        uint256 fee = msg.sender == hook ? 0 : swapFee;
        Quote memory quote =
            _price(indexIn, indexOut, balanceIn, balanceOut, amount, exactIn, fee);
        _checkOutflow(balanceOut - quote.amountOut, _levelNow(indexOut, balanceOut));
        return (quote.amountIn, quote.amountOut);
    }

    /// @notice Invariant per share, WAD. Rises only with swap fees and released donations.
    /// @dev `Π (bᵢ × scaleᵢ) ^ wᵢ × 1e18 / supply`, each power and product rounded down.
    /// Overflow bound, at 8 tokens of raw `type(uint128).max` with 0 decimals, so a scaled
    /// balance of B = 3.4e56 (3.4e38 whole tokens): the weights sum to one, so every running
    /// product, and so every `mulWad` result, is at most `max(1e18, B)`. A `mulWad` input is
    /// the previous product times the next power, which is that result times 1e18, so at
    /// most 3.4e74, as is the final `divWad`'s product times 1e18: all under 2^256 (1.2e77).
    /// `lnWad` of B is 88.7e18 (ln 2^128), and times a weight below one it stays inside
    /// `expWad`'s 135e18 limit. The bound is not enforced: a pool whose balances pass it, as
    /// a large donation can make them, reverts here.
    function growthIndex() external view returns (uint256 value) {
        uint256 supply = _supply();
        uint256[] memory current = balances();
        value = 1e18;
        for (uint256 index; index < current.length; index++) {
            uint256 scaled = current[index] * scaleList[index];
            value = value.mulWad(IndexMath.powDown(scaled, weightList[index]));
        }
        return value.divWad(supply);
    }

    function previewJoin(uint256 shares) external view returns (uint256[] memory amounts) {
        amounts = balances();
        uint256 supply = _supply();
        for (uint256 index; index < amounts.length; index++) {
            amounts[index] = amounts[index].fullMulDivUp(shares, supply);
        }
    }

    function previewExit(uint256 shares) external view returns (uint256[] memory amounts) {
        amounts = balances();
        uint256 supply = _supply();
        for (uint256 index; index < amounts.length; index++) {
            amounts[index] = amounts[index].fullMulDiv(shares, supply);
        }
    }

    function _addToken(address token, uint256 weight, address previous) internal {
        if (token == address(0)) revert NativeToken();
        if (token <= previous) revert UnsortedTokens();
        if (weight < MIN_WEIGHT) revert WeightTooLow();
        uint8 decimals = IIndexToken(token).decimals();
        if (decimals > 18) revert TooManyDecimals();
        tokenList.push(token);
        weightList.push(weight);
        scaleList.push(10 ** (18 - decimals));
        slot[token] = tokenList.length;
        stored.push(0);
        releases.push();
        levels.push();
    }

    /// @dev The locked middle of a swap. It prices on the balances as they are now, after
    /// whatever the hook did, and reuses nothing read before `beforeSwap`.
    function _swap(Order memory order, uint256 fee)
        internal
        nonReentrant
        returns (uint256 amountIn, uint256 amountOut)
    {
        (uint256 indexIn, uint256 indexOut) = _pair(order.tokenIn, order.tokenOut);
        _release(indexIn);
        _release(indexOut);
        uint256 balanceIn = stored[indexIn];
        uint256 balanceOut = stored[indexOut];
        Quote memory quote =
            _price(indexIn, indexOut, balanceIn, balanceOut, order.amount, order.exactIn, fee);
        amountIn = quote.amountIn;
        amountOut = quote.amountOut;
        if (order.exactIn) {
            if (amountOut < order.limit) revert Slippage();
        } else {
            if (amountIn > order.limit) revert Slippage();
        }
        // Both tokens are touched, so a level can never be recorded after an inflow that
        // the same window has already seen.
        _touch(indexIn, balanceIn);
        _checkOutflow(balanceOut - amountOut, _touch(indexOut, balanceOut));
        _pull(order.tokenIn, amountIn);
        owed[order.tokenIn] += quote.cut;
        stored[indexIn] = balanceIn + amountIn - quote.cut;
        stored[indexOut] = balanceOut - amountOut;
        order.tokenOut.safeTransfer(order.recipient, amountOut);
        emit Swapped(msg.sender, order.tokenIn, order.tokenOut, amountIn, amountOut, fee);
    }

    /// Records the token's level if this is its first swap in the window.
    function _touch(uint256 index, uint256 balance) internal returns (Level memory level) {
        level = _levelNow(index, balance);
        if (levels[index].window != level.window) levels[index] = level;
    }

    function _price(
        uint256 indexIn,
        uint256 indexOut,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        bool exactIn,
        uint256 fee
    ) internal view returns (Quote memory quote) {
        if (balanceIn < _minimumRaw(indexIn)) revert BalanceTooLow();
        uint256 paidFee;
        if (exactIn) {
            (quote.amountOut, paidFee) =
                _priceExactIn(indexIn, indexOut, balanceIn, balanceOut, amount, fee);
            quote.amountIn = amount;
        } else {
            (quote.amountIn, paidFee) =
                _priceExactOut(indexIn, indexOut, balanceIn, balanceOut, amount, fee);
            quote.amountOut = amount;
        }
        if (balanceOut - quote.amountOut < _minimumRaw(indexOut)) revert BalanceTooLow();
        quote.cut = paidFee * PROTOCOL_CUT_BPS / 10_000;
    }

    /// The fee comes off what is paid before the maths.
    function _priceExactIn(
        uint256 indexIn,
        uint256 indexOut,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        uint256 fee
    ) internal view returns (uint256 amountOut, uint256 paidFee) {
        uint256 scaleIn = scaleList[indexIn];
        uint256 scaleOut = scaleList[indexOut];
        if (amount * scaleIn < MIN_TRADE) revert TradeTooSmall();
        paidFee = amount.mulWadUp(fee);
        uint256 out = IndexMath.outGivenExactIn(
            balanceIn * scaleIn,
            weightList[indexIn],
            balanceOut * scaleOut,
            weightList[indexOut],
            (amount - paidFee) * scaleIn
        );
        if (out < MIN_TRADE) revert TradeTooSmall();
        // The maths bounds what was given; the pool bounds what it gives as well, or a 30%
        // exact-in swap at a 99/1 weight would take almost all of the other token.
        if (out > (balanceOut * scaleOut).mulWad(MAX_OUT_RATIO)) {
            revert IndexMath.MaxOutRatio();
        }
        amountOut = IndexMath.fromWadDown(out, scaleOut);
        // A swap that takes payment and sends nothing is refused, not filled.
        if (amountOut == 0) revert TradeTooSmall();
    }

    /// The fee is added to what the maths asks, at the rate that makes it the same share of
    /// the total paid as an exact-in fee.
    function _priceExactOut(
        uint256 indexIn,
        uint256 indexOut,
        uint256 balanceIn,
        uint256 balanceOut,
        uint256 amount,
        uint256 fee
    ) internal view returns (uint256 amountIn, uint256 paidFee) {
        uint256 scaleIn = scaleList[indexIn];
        uint256 scaleOut = scaleList[indexOut];
        if (amount * scaleOut < MIN_TRADE) revert TradeTooSmall();
        uint256 needed = IndexMath.inGivenExactOut(
            balanceIn * scaleIn,
            weightList[indexIn],
            balanceOut * scaleOut,
            weightList[indexOut],
            amount * scaleOut
        );
        if (needed < MIN_TRADE) revert TradeTooSmall();
        if (needed > (balanceIn * scaleIn).mulWad(MAX_IN_RATIO)) revert IndexMath.MaxInRatio();
        uint256 net = IndexMath.fromWadUp(needed, scaleIn);
        paidFee = net.fullMulDivUp(fee, 1e18 - fee);
        amountIn = net + paidFee;
    }

    /// The level a swap now would use, recording nothing: the stored one if this window has
    /// one, otherwise the one its first touch would record, which keeps the stored level as
    /// the previous one only if it is from the window just before.
    function _levelNow(uint256 index, uint256 balance) internal view returns (Level memory) {
        Level memory level = levels[index];
        uint256 window = _window();
        if (level.window == window) return level;
        if (level.window + 1 != window) return Level(window, balance, totalSupply(), 0, 0);
        return Level(window, balance, totalSupply(), level.balance, level.supply);
    }

    /// A swap out must leave the balance per share at or above 70% of the lower of this
    /// window's level and, where there is one, the previous window's, so it passes if it
    /// passes against either. The previous level is what defeats an inflow made just before a
    /// boundary and recorded just after it.
    function _checkOutflow(uint256 newBalance, Level memory level) internal view {
        if (_aboveFloor(newBalance, level.balance, level.supply)) return;
        if (level.previousSupply == 0) revert OutflowLimit();
        bool previous = _aboveFloor(newBalance, level.previousBalance, level.previousSupply);
        if (!previous) revert OutflowLimit();
    }

    /// `newBalance / supply >= 70% × balance / levelSupply`, cross-multiplied so no division
    /// rounds it. 70 / 100 is `OUTFLOW_FLOOR`.
    function _aboveFloor(uint256 newBalance, uint256 balance, uint256 levelSupply)
        internal
        view
        returns (bool)
    {
        return IndexMath.productAtLeast(
            newBalance * 100, levelSupply, balance * 70, totalSupply()
        );
    }

    function _window() internal view returns (uint256) {
        // Plus one, so the zero a fresh level holds never matches a real window.
        return block.timestamp / OUTFLOW_WINDOW + 1;
    }

    function _releaseAll() internal {
        for (uint256 index; index < tokenList.length; index++) {
            _release(index);
        }
    }

    function _release(uint256 index) internal {
        Release storage release = releases[index];
        if (release.amount == 0) return;
        uint256 due = _due(release);
        // Moving the start only when something is released keeps a busy pool on the
        // straight line, instead of rounding every small step to nothing until the end.
        if (due == 0) return;
        release.last = block.timestamp;
        release.amount -= due;
        stored[index] += due;
    }

    /// The time left after adding `added` to `held`: the average of what was left and a full
    /// period, weighted by the two amounts and rounded down. Resetting to a full period on every
    /// donation would let anyone hold the release back for ever with dust.
    function _timeLeft(uint256 held, uint256 end, uint256 added)
        internal
        view
        returns (uint256)
    {
        // What is still held was not all due, so its end is still ahead.
        if (held == 0) return DONATION_RELEASE;
        uint256 left = end - block.timestamp;
        uint256 total = held * left + added * DONATION_RELEASE;
        // Rounded down: rounding up added a whole second for every 1-wei donation. The
        // average is never below what was left, since a full period is never less.
        return total / (held + added);
    }

    /// Straight-line share of what is left, for the time since it was last released.
    function _due(Release memory release) internal view returns (uint256) {
        if (release.amount == 0) return 0;
        if (block.timestamp >= release.end) return release.amount;
        uint256 elapsed = block.timestamp - release.last;
        return release.amount * elapsed / (release.end - release.last);
    }

    /// Calls the hook with exactly `hookGas` and copies at most four bytes of what it
    /// returns, so a hook that fails, burns its gas or returns a huge blob costs the swap
    /// nothing more. True only if `canBlock` and the call reverted with exactly the four
    /// bytes of `IIndexHook.Blocked()`.
    function _callHook(bytes memory data, bool canBlock) internal returns (bool blocked) {
        address target = hook;
        uint256 gasAmount = hookGas;
        uint256 refusal = uint32(IIndexHook.Blocked.selector);
        assembly ("memory-safe") {
            let ok := call(gasAmount, target, 0, add(data, 0x20), mload(data), 0, 0)
            if iszero(ok) {
                if canBlock {
                    if eq(returndatasize(), 4) {
                        returndatacopy(0, 0, 4)
                        blocked := eq(shr(224, mload(0)), refusal)
                    }
                }
            }
        }
    }

    /// Pulls exactly `amount`, which rules out tokens that take a fee on transfer.
    function _pull(address token, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != before + amount) revert TransferMismatch();
    }

    function _deferMask(address[] calldata deferring) internal view returns (uint256 mask) {
        for (uint256 index; index < deferring.length; index++) {
            mask |= 1 << _index(deferring[index]);
        }
    }

    function _pair(address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 indexIn, uint256 indexOut)
    {
        if (tokenIn == tokenOut) revert SameToken();
        indexIn = _index(tokenIn);
        indexOut = _index(tokenOut);
    }

    function _index(address token) internal view returns (uint256) {
        uint256 found = slot[token];
        if (found == 0) revert UnknownToken();
        return found - 1;
    }

    /// The smallest raw balance a swap may start from or leave: `MIN_BALANCE` in 18
    /// decimals, or one raw unit when that is larger.
    function _minimumRaw(uint256 index) internal view returns (uint256) {
        uint256 scale = scaleList[index];
        if (scale >= MIN_BALANCE) return 1;
        return MIN_BALANCE / scale;
    }

    function _supply() internal view returns (uint256 supply) {
        supply = totalSupply();
        if (supply == 0) revert NotStarted();
    }

    function _ready(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired();
        if (!started) revert NotStarted();
    }
}
