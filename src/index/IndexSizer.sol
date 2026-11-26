// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { SwapMath } from "v4-core/libraries/SwapMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { SizingWalk } from "../arbitrage/lib/SizingWalk.sol";

/// Everything one try of the index balancer needs, read once before the tries. `pay` is the
/// token that is dear in the pool, which the balancer pays in, and `take` the cheap one it
/// takes out. `spend` is the `take` the cycle sells first. `sell` trades `take` for units and
/// `buy` units for `pay`; each is unused when its token is the unit. `rate` is the pool's
/// square-root price of `take` per `pay` (Q96), `edge` the cycle's square-root gap (WAD), and
/// `worth` the square-root mid price of `take` in units on `sell` (Q96). A leg on Metric has
/// its pool in `sellPool` or `buyPool` (zero for v4), whether its input is that pool's token0,
/// and its reading as one v4 range (`IndexMetric.read`: price, fee, liquidity, lower, upper,
/// in the order of a v4 pool of the same tokens). `askRate` is `buy`'s square-root price of
/// `pay` per unit after fees.
struct Cycle {
    address pool;
    address pay;
    address take;
    address unit;
    PoolKey sell;
    PoolKey buy;
    uint256 spend;
    uint256 edge;
    uint256 worth;
    uint256 rate;
    uint256 minimumProfit;
    uint256 balancePay;
    uint256 balanceTake;
    uint256 weightPay;
    uint256 weightTake;
    address sellPool;
    address buyPool;
    bool sellZero;
    bool buyZero;
    uint256 askRate;
    uint256[5] sellBook;
    uint256[5] buyBook;
}

/// @notice What the balancer and its sizer share about a cycle's limits.
library IndexCycle {
    uint256 internal constant WAD = 1e18;
    /// Of a balance, in one cycle: under the pool's 30% limits on both sides of a swap.
    uint256 internal constant MAX_SHARE = 25e16;

    /// @dev The most one cycle pays in: `MAX_SHARE` of the balance paid in, or what takes
    /// out that share of the balance taken out if less. At 99/1 the second is far smaller.
    function _most(Cycle memory cycle) internal pure returns (uint256 most) {
        most = FixedPointMathLib.fullMulDiv(cycle.balancePay, MAX_SHARE, WAD);
        uint256 kept = WAD - MAX_SHARE;
        uint256 exponent = FixedPointMathLib.fullMulDiv(cycle.weightTake, WAD, cycle.weightPay);
        uint256 grown = uint256(
            FixedPointMathLib.powWad(
                int256(FixedPointMathLib.fullMulDiv(WAD, WAD, kept)), int256(exponent)
            )
        );
        uint256 outward = FixedPointMathLib.fullMulDiv(cycle.balancePay, grown - WAD, WAD);
        if (outward < most) most = outward;
    }
}

/// @notice The index balancer's sizing walk, kept apart so the balancer fits in 24,576
/// bytes. Stateless: it reads the pool manager and nothing else.
/// @dev It builds the cycle's legs itself, the index pool first, and runs the arbitrage
/// hook's `SizingWalk` over them unchanged.
contract IndexSizer {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant Q96 = 1 << 96;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice The `take` the walk finds best to sell first, held back a millionth and a
    /// few wei, or zero if it finds none. It reports failure by reverting (`Unsizable`).
    function size(Cycle calldata cycle) external view returns (uint256) {
        SizingWalk.Leg[] memory legs = _legs(cycle);
        SizingWalk.Walk memory walk;
        for (uint256 round; round <= SizingWalk.SIZING_STEPS; round++) {
            if (!SizingWalk._round(poolManager, legs, walk, 0, round)) break;
        }
        if (walk.total == 0) return 0;
        if (walk.predicted <= 0) return 0;
        return SizingWalk._shaved(walk.total);
    }

    /// @notice What a Metric venue's reading says `amountIn` buys, `zeroForOne` in the order
    /// of a v4 pool of its tokens, within its current bin.
    function metricOut(uint256[5] calldata book, bool zeroForOne, uint256 amountIn)
        external
        pure
        returns (uint256 out)
    {
        uint160 target = uint160(zeroForOne ? book[3] : book[4]);
        (,, out,) = SwapMath.computeSwapStep(
            uint160(book[0]), target, uint128(book[2]), -int256(amountIn), uint24(book[1])
        );
    }

    /// @dev The cycle's legs in the order value flows: the venue that sells `take` for
    /// units, then the one that sells units for `pay`, then the index pool, which turns the
    /// `pay` back into `take`.
    function _legs(Cycle calldata cycle) internal view returns (SizingWalk.Leg[] memory legs) {
        uint256 count = 1;
        if (cycle.take != cycle.unit) count++;
        if (cycle.pay != cycle.unit) count++;
        legs = new SizingWalk.Leg[](count);
        uint256 next;
        address low = cycle.take < cycle.unit ? cycle.take : cycle.unit;
        if (cycle.take != cycle.unit) {
            legs[next++] = cycle.sellPool == address(0)
                ? _venueLeg(cycle.sell, cycle.take, cycle.edge)
                : _metricLeg(cycle.sellPool, cycle.sellBook, cycle.take == low, cycle.edge);
        }
        low = cycle.pay < cycle.unit ? cycle.pay : cycle.unit;
        if (cycle.pay != cycle.unit) {
            legs[next++] = cycle.buyPool == address(0)
                ? _venueLeg(cycle.buy, cycle.unit, cycle.edge)
                : _metricLeg(cycle.buyPool, cycle.buyBook, cycle.unit == low, cycle.edge);
        }
        legs[next] = _indexLeg(cycle);
    }

    /// @dev The index pool as one range in the tokens' own units, `pay` as token0: priced at
    /// the pool's price, ending at `_most`, with virtual reserves chosen so that the leg's
    /// price moves with size as the pool's does at its current balances. Matching the slope
    /// of the log price at size zero gives a reserve of `pay` of
    /// `2 × balancePay × weightTake / (weightTake + weightPay)`, which at equal weights is the
    /// balance itself, and there the leg is exact. It has no ticks and ends at its target, so
    /// the walk never reads the pool manager for it.
    function _indexLeg(Cycle calldata cycle) internal pure returns (SizingWalk.Leg memory leg) {
        leg.id = bytes32(uint256(uint160(cycle.pool)));
        leg.zeroForOne = true;
        uint256 reserve = FixedPointMathLib.fullMulDiv(
            2 * cycle.balancePay, cycle.weightTake, cycle.weightTake + cycle.weightPay
        );
        uint256 units = FixedPointMathLib.fullMulDiv(reserve, cycle.rate, Q96);
        if (units > type(uint128).max) revert SizingWalk.Unsizable();
        SizingWalk._read(leg, cycle.rate, units, cycle.edge);
        leg.target = SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp(
            leg.price, leg.liquidity, IndexCycle._most(cycle), true
        );
        leg.edge = true;
        if (leg.target == leg.price) revert SizingWalk.Unsizable();
    }

    /// @dev A Metric venue as a leg, as the arbitrage hook's `_loadWrapped` builds one from a
    /// pricer's answer: no ticks, and the end of the current bin is the end of the leg.
    function _metricLeg(address pool, uint256[5] calldata book, bool zeroForOne, uint256 edge)
        internal
        pure
        returns (SizingWalk.Leg memory leg)
    {
        leg.id = bytes32(uint256(uint160(pool)));
        leg.zeroForOne = zeroForOne;
        SizingWalk._read(leg, book[0] | book[1] << 208, book[2], edge);
        leg.target = uint160(zeroForOne ? book[3] : book[4]);
        leg.edge = true;
        leg.wrapped = true;
        if (leg.target == leg.price) revert SizingWalk.Unsizable();
    }

    /// @dev A plain v4 venue as a leg, read as the arbitrage hook's `_load` reads one.
    function _venueLeg(PoolKey calldata venue, address input, uint256 edge)
        internal
        view
        returns (SizingWalk.Leg memory leg)
    {
        PoolId id = venue.toId();
        leg.id = PoolId.unwrap(id);
        leg.zeroForOne = Currency.unwrap(venue.currency0) == input;
        leg.spacing = venue.tickSpacing;
        bytes32 slot = StateLibrary._getPoolStateSlot(id);
        bytes32[] memory slots = new bytes32[](2);
        slots[0] = slot;
        slots[1] = bytes32(uint256(slot) + 3);
        bytes32[] memory words = poolManager.extsload(slots);
        SizingWalk._read(leg, uint256(words[0]), uint256(words[1]), edge);
        SizingWalk._bound(poolManager, leg);
        if (leg.broken) revert SizingWalk.Unsizable();
    }
}
