// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMarketController } from "./IMarketController.sol";

/// @notice What every market vault exposes, whatever its primary hook. The share token is
/// an ERC20 and is not repeated here.
interface IHookVault {
    error DeadlinePassed();
    error DepositsPaused();
    error NotCurator();
    error InvalidCurator();
    error NotSeeded();
    error AlreadySeeded();
    error ZeroShares();
    error AboveMaximum();
    error BelowMinimum();
    error InvalidPair();
    error InvalidPool();
    error InvalidPosition();
    error TooManyPositions();
    error InvalidDelta();
    error UnexpectedCallback();
    error NotPoolManager();
    error TransferAmountMismatch();
    error InvalidFee();
    error InvalidRewardToken();
    error TooManyRewardTokens();
    error DepositCapExceeded();
    error NotSelf();

    event Seeded(address indexed curator, uint256 shares);
    event Deposited(address indexed holder, uint256 shares, uint256 paid0, uint256 paid1);
    event Withdrawn(address indexed holder, uint256 shares, uint256 out0, uint256 out1);
    event Harvested(address indexed caller);
    event DepositsPausedSet(bool paused);
    event CuratorNominated(address indexed nominee);
    event CuratorSet(address indexed curator);
    event RewardBooked(address indexed token, uint256 amount, uint256 fee);
    event RewardClaimed(address indexed holder, address indexed token, uint256 amount);
    event FeeClaimed(address indexed token, uint256 amount);
    event RewardTokenAdded(address indexed token);
    event FeeLowered(uint256 feeBps);
    event DepositCapSet(uint256 maxSupply);

    /// @notice Adds `shares / totalSupply` of every position and of idle principal, paid by
    /// the caller in both tokens at current prices, and mints `shares`.
    function deposit(uint256 shares, uint256 max0, uint256 max1, uint256 deadline)
        external
        returns (uint256 paid0, uint256 paid1);

    /// @notice Burns `shares` and pays out the same fraction of every position and of idle
    /// principal. It can never be paused.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        external
        returns (uint256 out0, uint256 out1);

    /// @notice Collects fees from every position. They are kept out of principal.
    function harvest() external;

    function token0() external view returns (address);

    function token1() external view returns (address);

    function primaryHook() external view returns (address);

    function positionCount() external view returns (uint256);

    /// @notice Idle principal, which is booked from deltas and never read from balances.
    function principal() external view returns (uint256 idle0, uint256 idle1);

    /// @notice What `deposit(shares, ...)` would cost at current prices.
    function quoteDeposit(uint256 shares) external view returns (uint256 need0, uint256 need1);

    /// @notice The market's controller, or zero when the vault has none.
    function controller() external view returns (IMarketController);

    /// @notice The curator's share of new rewards, in basis points. It only ever falls.
    function feeBps() external view returns (uint16);

    function depositCap() external view returns (uint256);

    /// @notice The tokens that pay rewards. It starts with the pair and only grows.
    function rewardTokens() external view returns (address[] memory);

    /// @notice What `holder` could claim now in `token`, streamed so far.
    function earned(address holder, address token) external view returns (uint256);

    /// @notice Tokens per second streaming now, scaled by 1e18, or zero when none is.
    function rewardRate(address token) external view returns (uint256);

    /// @notice Pays the caller what it has earned in each listed token.
    function claim(address[] calldata tokens) external;

    /// @notice Pays the curator its accrued fee in each listed token. Anyone may call it.
    function claimFee(address[] calldata tokens) external;

    function addRewardToken(address token) external;

    function lowerFee(uint16 newFeeBps) external;

    function setDepositCap(uint256 maxSupply) external;
}
