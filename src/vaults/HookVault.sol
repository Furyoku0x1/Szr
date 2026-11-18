// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IHookVault } from "../interfaces/IHookVault.sol";
import { IMarketController } from "../interfaces/IMarketController.sol";

/// @notice The core of a market vault: a share token over positions and idle principal,
/// with pro-rata deposits and withdrawals in kind, so no price is ever read. A vault kind
/// says what a position is by implementing the internal functions at the bottom.
/// @dev Principal is booked only from the deltas of the vault's own pool calls. Anything
/// else that reaches the vault (swap fees, arbitrage profit paid while the vault is the
/// market's recipient) is unbooked: a reward for later, never principal.
abstract contract HookVault is ERC20, ReentrancyGuard, IHookVault {
    uint256 public constant MINIMUM_SHARES = 1e6;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant REWARD_PERIOD = 3 days;
    uint256 public constant MAX_REWARD_TOKENS = 10;
    uint256 public constant MAX_FEE_BPS = 2_000;
    uint256 internal constant SCALE = 1e36;
    uint256 internal constant RATE_SCALE = 1e18;
    // Gas a withdrawal gives each reward payout, so a token that burns gas or refuses a
    // holder cannot hold principal back.
    uint256 internal constant PAYOUT_GAS = 300_000;
    // Gas a balance read may use, so a reward token that burns gas in `balanceOf` cannot
    // lock the vault.
    uint256 internal constant BALANCE_GAS = 50_000;
    // Gas the controller's push may use, so one that burns gas cannot hold an action back.
    uint256 internal constant CONTROLLER_GAS = 1_500_000;
    // A balance this large is read as a failed read: booking it would overflow, and no real
    // token holds so much.
    uint256 internal constant MAX_BALANCE = type(uint128).max;
    // Solady's guard slot, read to tell when an action of the vault is in progress.
    uint256 private constant GUARD_SLOT = 0x929eee149b4bd21268;

    /// @dev `owed` is all that is reserved for rewards in a token and not yet paid: what is
    /// still to stream, what has streamed to holders and is unclaimed, and the curator's
    /// fee. `rate` is tokens per second scaled by 1e18; `acc` is per share, scaled by 1e36.
    struct Reward {
        uint256 acc;
        uint256 rate;
        uint256 owed;
        uint256 feeOwed;
        uint64 end;
        uint64 last;
    }

    struct Holder {
        uint256 paid;
        uint256 accrued;
    }

    address public immutable token0;
    address public immutable token1;
    IMarketController public immutable controller;
    uint16 public feeBps;
    uint256 public depositCap = type(uint256).max;
    address[] internal rewardList;
    mapping(address => bool) public isRewardToken;
    mapping(address => Reward) internal rewards;
    mapping(address => mapping(address => Holder)) internal holders;
    address public curator;
    address public nominee;
    bool public depositsPaused;
    uint256 internal idle0;
    uint256 internal idle1;

    constructor(
        address curator_,
        address first,
        address second,
        IMarketController controller_,
        uint16 feeBps_
    ) {
        if (curator_ == address(0)) revert InvalidCurator();
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee();
        // Native ETH is currency zero, so ordering the pair also keeps it out.
        if (first == address(0)) revert InvalidPair();
        if (first >= second) revert InvalidPair();
        token0 = first;
        token1 = second;
        curator = curator_;
        controller = controller_;
        feeBps = feeBps_;
        rewardList.push(first);
        rewardList.push(second);
        isRewardToken[first] = true;
        isRewardToken[second] = true;
    }

    function name() public pure override returns (string memory) {
        return "Market Vault Share";
    }

    function symbol() public pure override returns (string memory) {
        return "MVS";
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert NotCurator();
        _;
    }

    function nominateCurator(address next) external onlyCurator {
        nominee = next;
        emit CuratorNominated(next);
    }

    function acceptCurator() external {
        if (msg.sender != nominee) revert NotCurator();
        curator = msg.sender;
        nominee = address(0);
        emit CuratorSet(msg.sender);
    }

    /// @notice Only deposits can be paused. Withdrawals never can.
    function setDepositsPaused(bool paused) external onlyCurator {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setDepositCap(uint256 maxSupply) external onlyCurator {
        depositCap = maxSupply;
        emit DepositCapSet(maxSupply);
    }

    /// @notice The fee can only be lowered, so holders never pay more than they joined at.
    function lowerFee(uint16 newFeeBps) external onlyCurator {
        if (newFeeBps > feeBps) revert InvalidFee();
        feeBps = newFeeBps;
        emit FeeLowered(newFeeBps);
    }

    /// @notice The list only grows. A token outside it sits idle in the vault.
    function addRewardToken(address token) external onlyCurator {
        if (token == address(0)) revert InvalidRewardToken();
        if (isRewardToken[token]) revert InvalidRewardToken();
        if (rewardList.length >= MAX_REWARD_TOKENS) revert TooManyRewardTokens();
        rewardList.push(token);
        isRewardToken[token] = true;
        emit RewardTokenAdded(token);
    }

    function deposit(uint256 shares, uint256 max0, uint256 max1, uint256 deadline)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (depositsPaused) revert DepositsPaused();
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();
        if (supply + shares > depositCap) revert DepositCapExceeded();
        // Fees and profit up to now belong to the holders there are now, so they are booked
        // before the supply changes.
        _harvest();
        _checkpoint();
        // Everything the depositor pays rounds up, and everything a holder is paid rounds
        // down, so rounding is always against the one who acts.
        paid0 = FixedPointMathLib.fullMulDivUp(idle0, shares, supply);
        paid1 = FixedPointMathLib.fullMulDivUp(idle1, shares, supply);
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
        idle0 += paid0;
        idle1 += paid1;
        _pull(token0, paid0);
        _pull(token1, paid1);
        (uint256 in0, uint256 in1) = _addFraction(shares, supply, max0 - paid0, max1 - paid1);
        paid0 += in0;
        paid1 += in1;
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, shares, paid0, paid1);
    }

    function withdraw(uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        _harvest();
        _checkpoint();
        _burn(msg.sender, shares);
        uint256 rest0 = FixedPointMathLib.fullMulDiv(idle0, shares, supply);
        uint256 rest1 = FixedPointMathLib.fullMulDiv(idle1, shares, supply);
        (out0, out1) = _removeFraction(shares, supply);
        out0 += rest0;
        out1 += rest1;
        if (out0 < min0) revert BelowMinimum();
        if (out1 < min1) revert BelowMinimum();
        // Idle principal falls only once its tokens have gone, so a token that calls back
        // while sending never sees a balance below what is reserved.
        if (rest0 != 0) SafeTransferLib.safeTransfer(token0, msg.sender, rest0);
        idle0 -= rest0;
        if (rest1 != 0) SafeTransferLib.safeTransfer(token1, msg.sender, rest1);
        idle1 -= rest1;
        emit Withdrawn(msg.sender, shares, out0, out1);
        _payAll(msg.sender);
    }

    function harvest() external nonReentrant {
        _harvest();
        _checkpoint();
        emit Harvested(msg.sender);
    }

    function claim(address[] calldata tokens) external nonReentrant {
        _checkpoint();
        for (uint256 index; index < tokens.length; index++) {
            _settle(msg.sender, tokens[index]);
            uint256 amount = holders[tokens[index]][msg.sender].accrued;
            if (amount != 0) _pay(tokens[index], msg.sender, amount);
        }
    }

    function claimFee(address[] calldata tokens) external nonReentrant {
        _checkpoint();
        for (uint256 index; index < tokens.length; index++) {
            Reward storage entry = rewards[tokens[index]];
            uint256 amount = entry.feeOwed;
            if (amount == 0) continue;
            entry.feeOwed = 0;
            entry.owed -= amount;
            SafeTransferLib.safeTransfer(tokens[index], curator, amount);
            emit FeeClaimed(tokens[index], amount);
        }
    }

    /// @dev Only a withdrawal calls this, on itself, so a payout that fails is caught there
    /// and leaves what is owed in place to claim later.
    function payOut(address token, address holder, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        _pay(token, holder, amount);
    }

    function rewardTokens() external view returns (address[] memory) {
        return rewardList;
    }

    function earned(address holder, address token) external view returns (uint256) {
        (uint256 acc,) = _streamed(rewards[token], totalSupply());
        Holder storage entry = holders[token][holder];
        return entry.accrued
            + FixedPointMathLib.fullMulDiv(balanceOf(holder), acc - entry.paid, SCALE);
    }

    function rewardRate(address token) external view returns (uint256) {
        Reward storage entry = rewards[token];
        return block.timestamp < entry.end ? entry.rate : 0;
    }

    /// @notice Everything reserved for rewards in `token` and not yet paid, including the
    /// curator's fee.
    function owed(address token) external view returns (uint256) {
        return rewards[token].owed;
    }

    function feeOwed(address token) external view returns (uint256) {
        return rewards[token].feeOwed;
    }

    function principal() external view returns (uint256, uint256) {
        return (idle0, idle1);
    }

    /// @notice A token's balance that is neither principal nor reserved for rewards: what
    /// the next checkpoint will book. A balance below what is reserved (a rebasing token)
    /// reads as zero.
    function unbooked(address asset) external view returns (uint256) {
        (bool ok, uint256 held) = _readBalance(asset);
        uint256 reserved = rewards[asset].owed + _idleOf(asset);
        if (!ok) return 0;
        return held > reserved ? held - reserved : 0;
    }

    function positionCount() external view returns (uint256) {
        return _positionCount();
    }

    function unitsOf(uint256 index) external view returns (uint256) {
        return _unitsOf(index);
    }

    function quoteDeposit(uint256 shares) external view returns (uint256 need0, uint256 need1) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();
        need0 = FixedPointMathLib.fullMulDivUp(idle0, shares, supply);
        need1 = FixedPointMathLib.fullMulDivUp(idle1, shares, supply);
        (uint256 in0, uint256 in1) = _quoteAdd(shares, supply);
        need0 += in0;
        need1 += in1;
    }

    /// @dev The first deposit's shares. `MINIMUM_SHARES` of them are locked for good, so
    /// the supply can never be emptied.
    function _open(uint256 total) internal {
        if (total <= MINIMUM_SHARES) revert ZeroShares();
        _mint(DEAD, MINIMUM_SHARES);
        _mint(msg.sender, total - MINIMUM_SHARES);
        emit Seeded(msg.sender, total - MINIMUM_SHARES);
    }

    /// @dev Pulls a token from the caller and checks all of it arrived, since idle principal
    /// is booked at the amount asked for.
    function _pull(address asset, uint256 amount) internal {
        if (amount == 0) return;
        uint256 before = SafeTransferLib.balanceOf(asset, address(this));
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount);
        if (SafeTransferLib.balanceOf(asset, address(this)) != before + amount) {
            revert TransferAmountMismatch();
        }
    }

    /// @dev A balance read with a gas cap. A token that fails, runs out of the cap, has no
    /// code or answers with too little reads as not ok, and the caller books nothing.
    function _readBalance(address asset) internal view returns (bool ok, uint256 amount) {
        uint256 cap = BALANCE_GAS;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), address())
            mstore(add(ptr, 0x24), 0)
            ok := staticcall(cap, asset, ptr, 0x24, add(ptr, 0x24), 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            amount := mload(add(ptr, 0x24))
        }
        if (amount > MAX_BALANCE) ok = false;
        if (!ok) amount = 0;
    }

    function _idleOf(address asset) internal view returns (uint256) {
        if (asset == token0) return idle0;
        if (asset == token1) return idle1;
        return 0;
    }

    /// @dev Pushes the market's pending profit down, then books what is new in every reward
    /// token. A controller that fails is skipped, so it can never hold withdrawals back.
    /// Before the first deposit there are no holders, so nothing is booked.
    function _checkpoint() internal {
        if (address(controller).code.length != 0) {
            try controller.distribute{ gas: CONTROLLER_GAS }(rewardList) { } catch { }
        }
        uint256 supply = totalSupply();
        if (supply == 0) return;
        uint256 count = rewardList.length;
        for (uint256 index; index < count; index++) {
            _book(rewardList[index], supply);
        }
    }

    /// @dev What is new is the balance less idle principal and less everything already
    /// reserved, so principal is never read from balances. It is split into the curator's
    /// fee and the rest, which streams with whatever of the last period is left.
    function _book(address token, uint256 supply) internal {
        Reward storage entry = rewards[token];
        (entry.acc, entry.last) = _streamed(entry, supply);
        (bool ok, uint256 held) = _readBalance(token);
        if (!ok) return;
        uint256 reserved = entry.owed + _idleOf(token);
        if (held <= reserved) return;
        uint256 fresh = held - reserved;
        uint256 fee = fresh * feeBps / 10_000;
        // The stream's end moves by the amounts: a lump streams over nearly a full period
        // and dust barely moves the end, so dust cannot keep a stream going for ever.
        uint256 left;
        uint256 span = REWARD_PERIOD;
        if (block.timestamp < entry.end) {
            uint256 remaining = entry.end - block.timestamp;
            left = entry.rate * remaining / RATE_SCALE;
            if (left != 0) span = (left * remaining + fresh * REWARD_PERIOD) / (left + fresh);
        }
        entry.feeOwed += fee;
        entry.owed += fresh;
        entry.rate = (left + fresh - fee) * RATE_SCALE / span;
        entry.end = uint64(block.timestamp + span);
        entry.last = uint64(block.timestamp);
        emit RewardBooked(token, fresh, fee);
    }

    /// @dev The per-share accumulator as of now, and the time it is current to.
    function _streamed(Reward storage entry, uint256 supply)
        internal
        view
        returns (uint256 acc, uint64 last)
    {
        acc = entry.acc;
        last = entry.last;
        if (supply == 0) return (acc, last);
        uint64 stop = uint64(block.timestamp);
        if (stop > entry.end) stop = entry.end;
        if (stop <= last) return (acc, last);
        acc += FixedPointMathLib.fullMulDiv(entry.rate * (stop - last), RATE_SCALE, supply);
        last = stop;
    }

    /// @dev Moves what `holder` has earned since its last update into `accrued`, at the
    /// balance it held until now. Call it before the balance changes.
    function _settle(address holder, address token) internal {
        Holder storage entry = holders[token][holder];
        uint256 acc = rewards[token].acc;
        uint256 shares = balanceOf(holder);
        if (shares != 0) {
            entry.accrued += FixedPointMathLib.fullMulDiv(shares, acc - entry.paid, SCALE);
        }
        entry.paid = acc;
    }

    function _pay(address token, address holder, uint256 amount) internal {
        holders[token][holder].accrued -= amount;
        rewards[token].owed -= amount;
        SafeTransferLib.safeTransfer(token, holder, amount);
        emit RewardClaimed(holder, token, amount);
    }

    /// @dev Pays a leaving holder what it has earned in every reward token. A token that
    /// fails to pay is skipped, and what is owed stays claimable.
    function _payAll(address holder) internal {
        uint256 count = rewardList.length;
        for (uint256 index; index < count; index++) {
            address token = rewardList[index];
            uint256 amount = holders[token][holder].accrued;
            if (amount == 0) continue;
            try this.payOut{ gas: PAYOUT_GAS }(token, holder, amount) { } catch { }
        }
    }

    /// @dev Rewards follow the shares: both sides are brought up to date before any share
    /// moves, which covers mint, burn and transfer. A plain transfer also books what is new;
    /// a deposit or a withdrawal has done that already.
    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        if (from != address(0)) {
            // A transfer made from inside an action (by a token that calls back while the
            // vault pays) books nothing: the balances are in the middle of moving.
            if (to != address(0)) {
                if (!_acting()) _checkpoint();
            }
        }
        uint256 count = rewardList.length;
        for (uint256 index; index < count; index++) {
            if (from != address(0)) _settle(from, rewardList[index]);
            if (to != address(0)) _settle(to, rewardList[index]);
        }
    }

    /// @dev Whether one of the vault's own guarded actions is running.
    function _acting() internal view returns (bool held) {
        uint256 slot = GUARD_SLOT;
        assembly ("memory-safe") {
            held := eq(sload(slot), address())
        }
    }

    function _positionCount() internal view virtual returns (uint256);

    function _unitsOf(uint256 index) internal view virtual returns (uint256);

    /// @dev Adds `shares / supply` of every position, paid by the caller, rounding up.
    function _addFraction(uint256 shares, uint256 supply, uint256 max0, uint256 max1)
        internal
        virtual
        returns (uint256 paid0, uint256 paid1);

    /// @dev Removes `shares / supply` of every position, paid to the caller, rounding down.
    function _removeFraction(uint256 shares, uint256 supply)
        internal
        virtual
        returns (uint256 out0, uint256 out1);

    function _quoteAdd(uint256 shares, uint256 supply)
        internal
        view
        virtual
        returns (uint256 need0, uint256 need1);

    function _harvest() internal virtual;
}
