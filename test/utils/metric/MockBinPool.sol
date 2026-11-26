// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { SwapMath } from "v4-core/libraries/SwapMath.sol";
import {
    IMetricPool,
    IMetricSwapCallback,
    MetricImmutables
} from "../../../src/interfaces/metric/IMetricPool.sol";
import { IndexMetric } from "../../../src/index/IndexMetric.sol";
import { Cycle } from "../../../src/index/IndexSizer.sol";
import { IMetricFactory } from "../../../src/interfaces/metric/IMetricFactory.sol";

/// @dev A Metric pool with one bin, laid out in storage as `PoolStateLibrary` lays it out
/// (slot 0 and the bin's word at slot 4), and prices a spread either side of its midpoint.
/// It fills a swap, exact input or exact output, as the v4 range `MetricBook` reads it as,
/// in its own token order, up to
/// the bin's edge: a swap that would leave the bin is filled only to the edge. It keeps
/// Metric's order of work: pay the output first, ask for the input in the callback, then
/// check its balance rose. After a swap its midpoint is the range's new price and the bin
/// holds what moved. Switches: paused, feed down, a guard that refuses, a cap on the input it
/// takes, and too little of the output to pay.
contract MockBinPool is IMetricPool {
    uint256 internal constant MAX_POS = type(uint104).max;
    uint256 internal constant PIPS = 1_000_000;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint256 public immutable scale0;
    uint256 public immutable scale1;
    /// The reader the pool reads itself with, as the balancer would, in its own order.
    IndexMetric public immutable reader;

    uint256 public mid;
    uint256 public spread;
    int16 public idx = 3;
    uint104 public pos = uint104(MAX_POS / 2);
    int24 public dist = -25_000;
    uint16 public length = 50_000;
    uint104 public held0;
    uint104 public held1;
    uint8 public paused;
    bool public feedDown;
    bool public guarded;
    bool public short;
    uint256 public maxFill = type(uint256).max;
    /// Set while a swap is under way, as Metric's reentrancy guard is: a price read then
    /// fails with `ReentrancyGuardReentrantCall()`.
    bool public inSwap;
    /// When set, the cycle the balancer passes through a swap is handed back with its pool
    /// changed to this one, as a hostile pool might.
    address public tamperPool;
    /// An extension: called during every swap, before the callback, with its result kept.
    address public extension;
    bytes public extensionCall;
    bool public extensionOk;
    bytes public extensionResult;

    error ReentrancyGuardReentrantCall();
    error PriceProviderFailed(bytes reason);
    error FeedStalled();

    constructor(
        address factory_,
        address t0,
        address t1,
        uint256 s0,
        uint256 s1,
        uint256 midX64,
        uint256 spreadPips,
        uint104 scaled0,
        uint104 scaled1
    ) {
        factory = factory_;
        token0 = t0;
        token1 = t1;
        scale0 = s0;
        scale1 = s1;
        mid = midX64;
        spread = spreadPips;
        held0 = scaled0;
        held1 = scaled1;
        reader = new IndexMetric(IMetricFactory(factory_));
    }

    function setMid(uint256 midX64) external {
        mid = midX64;
    }

    function setSwitches(uint8 paused_, bool feedDown_, bool guarded_, bool short_) external {
        (paused, feedDown, guarded, short) = (paused_, feedDown_, guarded_, short_);
    }

    function setLength(uint16 length_) external {
        length = length_;
    }

    /// Set, the callback asks to be paid nothing, though the swap reports the full input
    /// and the pool does not check it was paid: a hostile pool handing out its tokens.
    bool public askNothing;

    function setAskNothing(bool on) external {
        askNothing = on;
    }

    /// Set, `swap` reverts with exactly these bytes, as a hostile pool or extension might.
    bytes public revertData;

    function setRevertData(bytes calldata data) external {
        revertData = data;
    }

    function setTamper(address pool) external {
        tamperPool = pool;
    }

    function setMaxFill(uint256 cap) external {
        maxFill = cap;
    }

    function getImmutables() external view returns (MetricImmutables memory) {
        return MetricImmutables(factory, token0, token1, scale0, scale1);
    }

    function setExtension(address target, bytes calldata call) external {
        (extension, extensionCall) = (target, call);
    }

    function getSellAndBuyPrices() public view returns (uint128, uint128) {
        if (inSwap) revert ReentrancyGuardReentrantCall();
        // As Metric wraps a stalled feed.
        if (feedDown) revert PriceProviderFailed(abi.encodeWithSelector(FeedStalled.selector));
        return (uint128(mid * (PIPS - spread) / PIPS), uint128(mid * (PIPS + spread) / PIPS));
    }

    function extsload(bytes32 slot) external view returns (bytes32) {
        if (slot == bytes32(0)) {
            return bytes32(
                uint256(paused) | uint256(uint16(idx)) << 8 | uint256(pos) << 24
                    | uint256(uint24(dist)) << 128
            );
        }
        if (slot == keccak256(abi.encode(int256(idx), uint256(4)))) {
            return bytes32(uint256(held0) | uint256(held1) << 104 | uint256(length) << 208);
        }
        return bytes32(0);
    }

    /// What `swap` would pay for exactly `amountIn`, and the input it would take.
    function quote(bool zeroForOne, uint256 amountIn)
        public
        returns (uint256 taken, uint256 paid, uint160 next)
    {
        uint256[5] memory book = reader.read(address(this), token0);
        uint160 target = uint160(zeroForOne ? book[3] : book[4]);
        uint256 amount = amountIn < maxFill ? amountIn : maxFill;
        uint256 used;
        uint256 levy;
        (next, used, paid, levy) = SwapMath.computeSwapStep(
            uint160(book[0]), target, uint128(book[2]), -int256(amount), uint24(book[1])
        );
        taken = used + levy;
    }

    /// What `swap` would take for exactly `amountOut`, and what it would pay: less, if that
    /// leaves the bin.
    function quoteOut(bool zeroForOne, uint256 amountOut)
        public
        returns (uint256 taken, uint256 paid, uint160 next)
    {
        uint256[5] memory book = reader.read(address(this), token0);
        uint160 target = uint160(zeroForOne ? book[3] : book[4]);
        uint256 used;
        uint256 levy;
        (next, used, paid, levy) = SwapMath.computeSwapStep(
            uint160(book[0]), target, uint128(book[2]), int256(amountOut), uint24(book[1])
        );
        taken = used + levy;
        if (taken > maxFill) (taken, paid, next) = quote(zeroForOne, maxFill);
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int128 amountSpecified,
        uint128,
        bytes calldata callbackData,
        bytes calldata
    ) external returns (int128 amount0, int128 amount1) {
        bytes memory refusal = revertData;
        if (refusal.length != 0) {
            assembly {
                revert(add(refusal, 32), mload(refusal))
            }
        }
        require(!guarded, "guard");
        require(paused == 0, "paused");
        (uint256 taken, uint256 paid, uint160 next) = amountSpecified > 0
            ? quote(zeroForOne, uint256(uint128(amountSpecified)))
            : quoteOut(zeroForOne, uint256(uint128(-amountSpecified)));
        inSwap = true;
        require(!short, "short");
        (amount0, amount1) = zeroForOne
            ? (int128(int256(taken)), -int128(int256(paid)))
            : (-int128(int256(paid)), int128(int256(taken)));
        _exchange(recipient, zeroForOne, taken, paid, callbackData);
        inSwap = false;
        _moved(zeroForOne, taken, paid, next);
    }

    function _exchange(
        address recipient,
        bool zeroForOne,
        uint256 taken,
        uint256 paid,
        bytes calldata callbackData
    ) internal {
        address input = zeroForOne ? token0 : token1;
        uint256 before = SafeTransferLib.balanceOf(input, address(this));
        SafeTransferLib.safeTransfer(zeroForOne ? token1 : token0, recipient, paid);
        if (extension != address(0)) {
            address target = extension;
            extension = address(0);
            (extensionOk, extensionResult) = target.call(extensionCall);
        }
        (int256 delta0, int256 delta1) =
            zeroForOne ? (int256(taken), -int256(paid)) : (-int256(paid), int256(taken));
        bytes memory data = callbackData;
        if (tamperPool != address(0)) {
            if (data.length != 0) {
                Cycle memory cycle = abi.decode(data, (Cycle));
                cycle.pool = tamperPool;
                data = abi.encode(cycle);
            }
        }
        if (askNothing) {
            if (zeroForOne) delta0 = 0;
            else delta1 = 0;
        }
        IMetricSwapCallback(msg.sender).metricOmmSwapCallback(delta0, delta1, data);
        if (askNothing) return;
        require(SafeTransferLib.balanceOf(input, address(this)) >= before + taken, "not paid");
    }

    /// Calls a contract's callback as this pool, outside any swap of its own.
    function poke(address target) external {
        IMetricSwapCallback(target).metricOmmSwapCallback(int256(1), -int256(1), "");
    }

    function _moved(bool zeroForOne, uint256 taken, uint256 paid, uint160 next) internal {
        if (zeroForOne) {
            held0 += uint104(taken * scale0);
            held1 -= uint104(paid * scale1);
        } else {
            held1 += uint104(taken * scale1);
            held0 -= uint104(paid * scale0);
        }
        // The v4 price is raw token1 per raw token0 times 2^192; Metric's is whole token1
        // per whole token0 times 2^64.
        mid = FullMath.mulDiv(FullMath.mulDiv(next, next, 1 << 64), scale1, scale0 << 64);
    }
}
