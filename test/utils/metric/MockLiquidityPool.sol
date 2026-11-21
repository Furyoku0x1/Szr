// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import {
    IMetricLiquidityPool,
    IMetricModifyLiquidityCallback,
    MetricLiquidityDelta,
    MetricPoolImmutables
} from "../../../src/interfaces/metric/IMetricPool.sol";

/// @dev A Metric pool's liquidity side, with Metric's rules from `LiquidityLib` (ceil on
/// add, floor on remove, the minimum change and the minimum leftover, owner-only removal)
/// and its storage layout, so `extsload` reads what the real pool would give: bins at slot
/// 4 (token0 scaled in the low 104 bits, token1 scaled above), bin total shares at slot 5
/// and position shares at slot 6. A new bin below the current one (bin 0) takes token1
/// only, above it token0 only, and the current bin half of each.
contract MockLiquidityPool is IMetricLiquidityPool {
    uint256 internal pad0;
    uint256 internal pad1;
    uint256 internal pad2;
    uint256 internal pad3;
    mapping(int256 => uint256) internal binStates;
    mapping(int256 => uint256) internal binTotals;
    mapping(bytes32 => uint256) internal positionShares;

    address public immutable token0;
    address public immutable token1;
    uint256 public immutable scale0;
    uint256 public immutable scale1;
    uint256 public immutable minimum;
    uint256[4] public orders;
    // 1: reports one more unit of token0 removed than it sends.
    uint8 public mode;

    constructor(
        address t0,
        address t1,
        uint256 s0,
        uint256 s1,
        uint256 minimum_,
        uint256[4] memory orders_
    ) {
        token0 = t0;
        token1 = t1;
        scale0 = s0;
        scale1 = s1;
        minimum = minimum_;
        orders = orders_;
    }

    function setMode(uint8 newMode) external {
        mode = newMode;
    }

    function getImmutables() external view returns (MetricPoolImmutables memory imm) {
        imm.token0 = token0;
        imm.token1 = token1;
        imm.token0ScaleMultiplier = scale0;
        imm.token1ScaleMultiplier = scale1;
        imm.initialScaledToken0PerShareE18 = 1e18;
        imm.initialScaledToken1PerShareE18 = 1e18;
        imm.minimalOperationalLiquidity = minimum;
        imm.lowestBin = -10;
        imm.highestBin = 10;
        imm.beforeAddLiquidityOrder = orders[0];
        imm.afterAddLiquidityOrder = orders[1];
        imm.beforeRemoveLiquidityOrder = orders[2];
        imm.afterRemoveLiquidityOrder = orders[3];
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        assembly {
            value := sload(slot)
        }
    }

    function sharesOf(address owner, uint80 salt, int16 bin) external view returns (uint256) {
        return positionShares[keccak256(abi.encode(owner, salt, bin))];
    }

    function totalOf(int256 bin) external view returns (uint256) {
        return binTotals[bin];
    }

    function balancesOf(int256 bin) external view returns (uint256, uint256) {
        uint256 raw = binStates[bin];
        return (uint104(raw), uint104(raw >> 104));
    }

    /// Earnings: scaled balances added to a bin. The test sends the tokens itself.
    function earn(int256 bin, uint256 add0, uint256 add1) external {
        uint256 raw = binStates[bin];
        uint256 b0 = uint104(raw) + add0;
        uint256 b1 = uint104(raw >> 104) + add1;
        binStates[bin] = b0 | (b1 << 104);
    }

    function addLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata callbackData,
        bytes calldata
    ) public virtual returns (uint256 amount0Added, uint256 amount1Added) {
        require(deltas.binIdxs.length == deltas.shares.length, "length");
        uint256 total0;
        uint256 total1;
        for (uint256 i; i < deltas.binIdxs.length; i++) {
            if (deltas.shares[i] == 0) continue;
            require(deltas.shares[i] >= minimum, "below the minimum change");
            (uint256 a0, uint256 a1) = _addBin(owner, salt, deltas.binIdxs[i], deltas.shares[i]);
            total0 += a0;
            total1 += a1;
        }
        amount0Added = FixedPointMathLib.divUp(total0, scale0);
        amount1Added = FixedPointMathLib.divUp(total1, scale1);
        uint256 before0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(token1, address(this));
        IMetricModifyLiquidityCallback(msg.sender)
            .metricOmmModifyLiquidityCallback(amount0Added, amount1Added, callbackData);
        require(SafeTransferLib.balanceOf(token0, address(this)) >= before0 + amount0Added);
        require(SafeTransferLib.balanceOf(token1, address(this)) >= before1 + amount1Added);
    }

    function _addBin(address owner, uint80 salt, int256 bin, uint256 shares)
        internal
        returns (uint256 a0, uint256 a1)
    {
        require(bin >= -10, "bin range");
        require(bin <= 10, "bin range");
        uint256 total = binTotals[bin];
        uint256 raw = binStates[bin];
        if (total == 0) {
            a0 = bin > 0 ? shares : bin == 0 ? FixedPointMathLib.divUp(shares, 2) : 0;
            a1 = bin < 0 ? shares : bin == 0 ? FixedPointMathLib.divUp(shares, 2) : 0;
        } else {
            a0 = FixedPointMathLib.fullMulDivUp(uint104(raw), shares, total);
            a1 = FixedPointMathLib.fullMulDivUp(uint104(raw >> 104), shares, total);
        }
        binStates[bin] = (uint104(raw) + a0) | ((uint104(raw >> 104) + a1) << 104);
        binTotals[bin] = total + shares;
        bytes32 key = keccak256(abi.encode(owner, salt, int16(bin)));
        positionShares[key] += shares;
    }

    function removeLiquidity(
        address owner,
        uint80 salt,
        MetricLiquidityDelta calldata deltas,
        bytes calldata
    ) public virtual returns (uint256 amount0Removed, uint256 amount1Removed) {
        require(msg.sender == owner, "not the owner");
        uint256 total0;
        uint256 total1;
        for (uint256 i; i < deltas.binIdxs.length; i++) {
            if (deltas.shares[i] == 0) continue;
            (uint256 r0, uint256 r1) =
                _removeBin(owner, salt, deltas.binIdxs[i], deltas.shares[i]);
            total0 += r0;
            total1 += r1;
        }
        amount0Removed = total0 / scale0;
        amount1Removed = total1 / scale1;
        SafeTransferLib.safeTransfer(token0, owner, amount0Removed);
        SafeTransferLib.safeTransfer(token1, owner, amount1Removed);
        if (mode == 1) amount0Removed += 1;
    }

    function _removeBin(address owner, uint80 salt, int256 bin, uint256 shares)
        internal
        returns (uint256 r0, uint256 r1)
    {
        bytes32 key = keccak256(abi.encode(owner, salt, int16(bin)));
        uint256 held = positionShares[key];
        require(held >= shares, "insufficient liquidity");
        require(shares >= minimum, "below the minimum change");
        uint256 left = held - shares;
        if (left != 0) {
            require(left >= minimum, "leftover below the minimum");
        }
        uint256 total = binTotals[bin];
        uint256 raw = binStates[bin];
        r0 = FixedPointMathLib.fullMulDiv(uint104(raw), shares, total);
        r1 = FixedPointMathLib.fullMulDiv(uint104(raw >> 104), shares, total);
        binStates[bin] = (uint104(raw) - r0) | ((uint104(raw >> 104) - r1) << 104);
        binTotals[bin] = total - shares;
        positionShares[key] = left;
    }
}

/// @dev Someone who adds liquidity to the vault's position, which Metric allows for any
/// owner.
contract Donor is IMetricModifyLiquidityCallback {
    function donate(
        MockLiquidityPool pool,
        address owner,
        uint80 salt,
        int256 bin,
        uint256 shares
    ) external {
        int256[] memory bins = new int256[](1);
        uint256[] memory amounts = new uint256[](1);
        bins[0] = bin;
        amounts[0] = shares;
        pool.addLiquidity(
            owner, salt, MetricLiquidityDelta(bins, amounts), abi.encode(pool), ""
        );
    }

    function metricOmmModifyLiquidityCallback(uint256 a0, uint256 a1, bytes calldata data)
        external
    {
        MockLiquidityPool pool = abi.decode(data, (MockLiquidityPool));
        SafeTransferLib.safeTransfer(pool.token0(), msg.sender, a0);
        SafeTransferLib.safeTransfer(pool.token1(), msg.sender, a1);
    }
}
