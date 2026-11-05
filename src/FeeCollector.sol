// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ContinuousAuction } from "./ContinuousAuction.sol";
import { SzrCore } from "./SzrCore.sol";

/// @notice Per-asset partial-fill auctions. Receipts add depth; empty auctions freeze their price.
contract FeeCollector is ReentrancyGuard {
    struct AssetConfig {
        uint256 initialPoolRateWad;
        uint256 buffer;
        uint256 floorWad;
    }

    struct Auction {
        ContinuousAuction.State curve;
        uint256 buffer;
        uint256 inventory;
        uint256 updatedAt;
    }

    SzrCore public immutable core;
    address public immutable backingAsset;
    address[] public assets;
    mapping(address asset => Auction) internal auctions;

    error ZeroAddress();
    error InvalidAsset();
    error InvalidRate();
    error NotLiquidity();
    error ZeroAmount();
    error UnrecordedReceipt();
    error InsufficientInventory();
    error AboveMaximum();
    error DeadlinePassed();
    error AuctionNotOpen();
    error TransferAmountMismatch();

    event AssetRegistered(address indexed asset, uint256 buffer, uint256 openingRateWad);
    event FeesRecorded(address indexed asset, uint256 amount);
    event AuctionTaken(
        address indexed asset, address indexed buyer, uint256 amount, uint256 paid
    );

    constructor(SzrCore reserveCore) {
        if (address(reserveCore) == address(0)) revert ZeroAddress();
        if (address(reserveCore).code.length == 0) revert ZeroAddress();
        core = reserveCore;
        backingAsset = reserveCore.backingAsset();
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function auction(address asset) external view returns (Auction memory) {
        return auctions[asset];
    }

    function accepts(address asset) public view returns (bool) {
        if (asset == backingAsset) return true;
        return auctions[asset].buffer != 0;
    }

    /// @notice First registration only. A second program cannot reprice or overwrite an asset.
    function registerAsset(address asset, AssetConfig calldata config) external nonReentrant {
        if (msg.sender != core.liquidity()) revert NotLiquidity();
        if (asset == address(core.token())) revert InvalidAsset();
        if (asset == backingAsset) return;
        if (asset.code.length == 0) revert InvalidAsset();
        if (auctions[asset].buffer != 0) return;
        if (config.initialPoolRateWad > type(uint256).max / 2) revert InvalidRate();
        uint256 opening = config.initialPoolRateWad * 2;
        Auction storage entry = auctions[asset];
        entry.curve = ContinuousAuction.create(config.buffer, opening, config.floorWad);
        entry.buffer = config.buffer;
        _checkSupplyDepth(asset, entry.curve, entry.buffer);
        entry.updatedAt = block.timestamp;
        assets.push(asset);
        emit AssetRegistered(asset, config.buffer, opening);
    }

    /// @notice Only actual received fees are recorded. Own-token fees bypass this contract.
    function recordFees(address asset, uint256 amount) external nonReentrant {
        if (msg.sender != core.liquidity()) revert NotLiquidity();
        if (amount == 0) revert ZeroAmount();
        if (!accepts(asset)) revert InvalidAsset();
        uint256 held = SafeTransferLib.balanceOf(asset, address(this));
        if (asset == backingAsset) {
            if (held < amount) revert UnrecordedReceipt();
            uint256 beforeBalance = SafeTransferLib.balanceOf(asset, address(core));
            SafeTransferLib.safeTransfer(asset, address(core), amount);
            if (SafeTransferLib.balanceOf(asset, address(core)) != beforeBalance + amount) {
                revert TransferAmountMismatch();
            }
            core.recognizeFees(amount);
        } else {
            Auction storage entry = auctions[asset];
            if (held < entry.inventory + amount) revert UnrecordedReceipt();
            ContinuousAuction.State memory curve = _project(entry);
            entry.inventory += amount;
            ContinuousAuction.project(curve, 0, entry.inventory + entry.buffer);
            _checkSupplyDepth(asset, curve, entry.buffer);
            entry.curve = curve;
            entry.updatedAt = block.timestamp;
        }
        emit FeesRecorded(asset, amount);
    }

    function quote(address asset, uint256 amount) public view returns (uint256 payment) {
        Auction storage entry = auctions[asset];
        if (entry.buffer == 0) revert InvalidAsset();
        if (amount > entry.inventory) revert InsufficientInventory();
        ContinuousAuction.State memory curve = _project(entry);
        payment = ContinuousAuction.buy(curve, amount);
        _checkSupplyDepth(asset, curve, entry.buffer);
    }

    function price(address asset) external view returns (uint256) {
        if (auctions[asset].buffer == 0) revert InvalidAsset();
        return ContinuousAuction.price(_project(auctions[asset]));
    }

    function take(address asset, uint256 amount, uint256 maximumPayment, uint256 deadline)
        external
        nonReentrant
        returns (uint256 payment)
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        uint256 opening = core.auctionsOpenAt();
        if (opening == 0) revert AuctionNotOpen();
        if (block.timestamp < opening) revert AuctionNotOpen();
        Auction storage entry = auctions[asset];
        if (entry.buffer == 0) revert InvalidAsset();
        if (amount > entry.inventory) revert InsufficientInventory();
        ContinuousAuction.State memory curve = _project(entry);
        payment = ContinuousAuction.buy(curve, amount);
        _checkSupplyDepth(asset, curve, entry.buffer);
        if (payment > maximumPayment) revert AboveMaximum();
        entry.inventory -= amount;
        entry.curve = curve;
        entry.updatedAt = block.timestamp;
        uint256 beforeBacking = SafeTransferLib.balanceOf(backingAsset, address(core));
        SafeTransferLib.safeTransferFrom(backingAsset, msg.sender, address(core), payment);
        if (SafeTransferLib.balanceOf(backingAsset, address(core)) != beforeBacking + payment) {
            revert TransferAmountMismatch();
        }
        core.recognizeFees(payment);
        uint256 beforeAsset = SafeTransferLib.balanceOf(asset, msg.sender);
        SafeTransferLib.safeTransfer(asset, msg.sender, amount);
        if (SafeTransferLib.balanceOf(asset, msg.sender) != beforeAsset + amount) {
            revert TransferAmountMismatch();
        }
        emit AuctionTaken(asset, msg.sender, amount, payment);
    }

    /// @dev Preserve representability if any currently existing fee tokens later return.
    /// Assets whose supply grows must remain within the documented numeric domain on receipt.
    function _checkSupplyDepth(
        address asset,
        ContinuousAuction.State memory curve,
        uint256 buffer
    ) internal view {
        ContinuousAuction.State memory projected =
            ContinuousAuction.State(
                curve.depth, curve.floorWad, curve.excessTime, curve.decayMass
            );
        ContinuousAuction.project(projected, 0, ERC20(asset).totalSupply() + buffer);
    }

    function _project(Auction storage entry)
        internal
        view
        returns (ContinuousAuction.State memory curve)
    {
        curve = entry.curve;
        uint256 elapsed;
        uint256 opening = core.auctionsOpenAt();
        if (opening != 0) {
            if (entry.inventory != 0) {
                uint256 start = entry.updatedAt > opening ? entry.updatedAt : opening;
                if (block.timestamp > start) elapsed = block.timestamp - start;
            }
        }
        ContinuousAuction.project(curve, elapsed, entry.inventory + entry.buffer);
    }
}
