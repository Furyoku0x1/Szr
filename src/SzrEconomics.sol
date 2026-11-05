// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice Earned liquidity-revenue claims for the immutable team beneficiary.
/// @dev This module has no token allocation, vesting or token-release authority.
contract SzrEconomics is ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant TEAM_FEE_BPS = 3_300;

    address public immutable core;
    address public immutable beneficiary;
    address public immutable backingAsset;
    uint256 public claimableFees;

    error ZeroAddress();
    error InvalidBeneficiary();
    error NotCore();
    error ZeroAmount();
    error UnrecordedReceipt();
    error TransferAmountMismatch();

    event TeamFeeRecorded(uint256 amount);
    event TeamFeeClaimed(address indexed beneficiary, uint256 amount);

    constructor(address asset, address recipient) {
        if (asset == address(0)) revert ZeroAddress();
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == msg.sender) revert InvalidBeneficiary();
        if (recipient == address(this)) revert InvalidBeneficiary();
        core = msg.sender;
        backingAsset = asset;
        beneficiary = recipient;
    }

    function liquidityTeamFee(uint256 amount) external pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amount, TEAM_FEE_BPS, BPS);
    }

    /// @dev Called only after actual WETH liquidity revenue has been transferred by Core.
    function recordFees(uint256 amount) external {
        if (msg.sender != core) revert NotCore();
        if (amount == 0) revert ZeroAmount();
        if (SafeTransferLib.balanceOf(backingAsset, address(this)) < claimableFees + amount) {
            revert UnrecordedReceipt();
        }
        claimableFees += amount;
        emit TeamFeeRecorded(amount);
    }

    /// @notice Anyone may deliver earned fees, but the immutable recipient cannot be changed.
    function claimFees() external nonReentrant returns (uint256 amount) {
        amount = claimableFees;
        if (amount == 0) revert ZeroAmount();
        claimableFees = 0;
        uint256 beforeBalance = SafeTransferLib.balanceOf(backingAsset, beneficiary);
        SafeTransferLib.safeTransfer(backingAsset, beneficiary, amount);
        if (SafeTransferLib.balanceOf(backingAsset, beneficiary) != beforeBalance + amount) {
            revert TransferAmountMismatch();
        }
        emit TeamFeeClaimed(beneficiary, amount);
    }
}
