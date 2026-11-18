// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { IMetricPool } from "./IMetric.sol";

/// @dev Reads a Metric pool's mutable storage with `extsload`, using the layout in
/// Metricxyz/pool-contracts `PoolStateLibrary`: slot 0 packs the swap state, slot 4 is the
/// bin states, slot 5 the bins' total shares and slot 6 the positions' bin shares.
library MetricState {
    struct Slot0 {
        uint8 pauseLevel;
        int16 curBinIdx;
        uint104 curPosInBin;
        int24 curBinDistE6;
        uint24 spreadFeeE6;
        uint24 notionalFeeE8;
        uint16 asymmetryX8;
    }

    struct Bin {
        uint104 token0Scaled;
        uint104 token1Scaled;
        uint16 lengthE6;
        uint16 addFeeBuyE6;
        uint16 addFeeSellE6;
    }

    function slot0(IMetricPool pool) internal view returns (Slot0 memory s) {
        uint256 raw = uint256(pool.extsload(bytes32(uint256(0))));
        s.pauseLevel = uint8(raw);
        s.curBinIdx = int16(uint16(raw >> 8));
        s.curPosInBin = uint104(raw >> 24);
        s.curBinDistE6 = int24(uint24(raw >> 128));
        s.spreadFeeE6 = uint24(raw >> 152);
        s.notionalFeeE8 = uint24(raw >> 176);
        s.asymmetryX8 = uint16(raw >> 200);
    }

    function mapSlot(int256 key, uint256 base) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, base));
    }

    function bin(IMetricPool pool, int16 idx) internal view returns (Bin memory b) {
        uint256 raw = uint256(pool.extsload(mapSlot(idx, 4)));
        b.token0Scaled = uint104(raw);
        b.token1Scaled = uint104(raw >> 104);
        b.lengthE6 = uint16(raw >> 208);
        b.addFeeBuyE6 = uint16(raw >> 224);
        b.addFeeSellE6 = uint16(raw >> 240);
    }

    function totalShares(IMetricPool pool, int16 idx) internal view returns (uint256) {
        return uint256(pool.extsload(mapSlot(idx, 5)));
    }

    /// The key is `keccak256(abi.encode(owner, salt, bin))`, as in `LiquidityLib`.
    function positionShares(IMetricPool pool, address owner, uint80 salt, int16 idx)
        internal
        view
        returns (uint256)
    {
        bytes32 key = keccak256(abi.encode(owner, salt, idx));
        return uint256(pool.extsload(keccak256(abi.encode(key, uint256(6)))));
    }
}
