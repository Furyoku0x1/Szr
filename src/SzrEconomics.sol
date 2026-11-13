// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice Earned liquidity-revenue claims for the team beneficiary.
/// @dev This module has no token allocation, vesting or token-release authority. Only the
/// beneficiary can hand the claim to another address, and that address must accept it.
contract SzrEconomics is ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant TEAM_FEE_BPS = 3_300;

    address public immutable core;
    address public immutable backingAsset;
    address public beneficiary;
    address public pendingBeneficiary;
    uint256 public claimableFees;

    error ZeroAddress();
    error InvalidBeneficiary();
    error NotBeneficiary();
    error NotNominee();
    error NotCore();
    error ZeroAmount();
    error UnrecordedReceipt();
    error TransferAmountMismatch();

    event BeneficiaryNominated(address indexed nominee);
    event BeneficiaryChanged(address indexed previous, address indexed current);
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

    /// @dev Fees not yet claimed when the nominee accepts are paid to the nominee.
    function nominateBeneficiary(address nominee) external nonReentrant {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (nominee == address(0)) revert ZeroAddress();
        if (nominee == beneficiary) revert InvalidBeneficiary();
        pendingBeneficiary = nominee;
        emit BeneficiaryNominated(nominee);
    }

    function cancelBeneficiaryNomination() external nonReentrant {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        pendingBeneficiary = address(0);
        emit BeneficiaryNominated(address(0));
    }

    function acceptBeneficiary() external nonReentrant {
        if (msg.sender != pendingBeneficiary) revert NotNominee();
        address previous = beneficiary;
        beneficiary = msg.sender;
        pendingBeneficiary = address(0);
        emit BeneficiaryChanged(previous, msg.sender);
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

    /// @notice Anyone may deliver earned fees, but only to the current beneficiary.
    /// @dev Pays the whole WETH balance, so WETH sent here by mistake also reaches the beneficiary.
    function claimFees() external nonReentrant returns (uint256 amount) {
        amount = SafeTransferLib.balanceOf(backingAsset, address(this));
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
