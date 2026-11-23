// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMarketController, IVaultLink } from "../interfaces/IMarketController.sol";
import { IMetricFactory } from "../interfaces/metric/IMetricFactory.sol";
import {
    IMetricLiquidityPool,
    IMetricModifyLiquidityCallback,
    MetricLiquidityDelta,
    MetricPoolImmutables
} from "../interfaces/metric/IMetricPool.sol";
import { HookVault } from "./HookVault.sol";

/// @notice A market vault whose positions are bins of one Metric pool, its home pool, fixed
/// when the vault is made. Its pair is the pool's tokens. A position is a salt the vault
/// picks and a set of bins; its units are the vault's own shares in those bins, read from the
/// pool's storage with `extsload`. The curator can move shares between bins and can never
/// move them to another pool.
/// @dev Disclosure: the home pool's price provider decides the pool's prices, and the vault
/// accepts any Metric pool. A depositor must check that provider before depositing. A curator
/// who controls it can move the price and take the vault's funds.
/// @dev Metric's earnings compound inside the bins and raise what a share is worth, so
/// unlike v4 fees they never become claimable rewards. Profit the controller routes here is
/// still a reward. A pool is refused if an extension runs around `removeLiquidity`, since
/// the pool's order words are immutable and an extension that reverts there would hold every
/// withdrawal back. Pausing a pool or tripping its stop-loss does not touch removal.
/// @dev Nobody but the owner can remove liquidity, and anybody can add it for any owner, so
/// shares sent to the vault by others raise its units and become the holders'. The pool
/// also needs each change to be at least `minimalOperationalLiquidity` and a position to
/// keep that much or nothing, so a withdrawal skips a bin whose share is too small and
/// leaves the minimum behind where it must: rounding always goes against whoever acts.
contract MetricVault is HookVault, IMetricModifyLiquidityCallback {
    uint256 public constant MAX_POSITIONS = 4;
    uint256 public constant MAX_BINS = 16;
    // Metric's storage layout (`PoolStateLibrary`): bin balances, bin total shares, and
    // position shares keyed by `keccak(owner, salt, bin)`.
    uint256 internal constant BINS_SLOT = 4;
    uint256 internal constant TOTALS_SLOT = 5;
    uint256 internal constant SHARES_SLOT = 6;

    error BlockingExtension();
    error InvalidBins();
    error TooManyBins();
    error RebalanceTooSoon();
    error InsufficientIdle();
    error NotPool();

    event PositionAdded(uint256 indexed index, address indexed pool, uint80 salt);
    event PositionDropped(uint256 indexed index);
    event Rebalanced(uint256 changes, uint256 removed0, uint256 removed1);

    struct Position {
        uint80 salt;
        int16[] bins;
    }

    /// @dev A change of `shares` in the position's bin at `slot` (an index into its bins):
    /// negative removes, positive adds.
    struct Change {
        uint256 position;
        uint256 slot;
        int256 shares;
    }

    IMetricFactory public immutable factory;
    IMetricLiquidityPool public immutable pool;
    // The pool's own limits, read once: they are immutable in the pool.
    uint256 internal immutable minimum;
    uint256 internal immutable scale0;
    uint256 internal immutable scale1;
    int256 internal immutable lowestBin;
    int256 internal immutable highestBin;
    Position[] internal positions;
    uint80 public lastSalt;
    uint256 public binCount;
    uint256 public lastRebalance;
    address internal transient active;

    constructor(
        IMetricFactory metricFactory,
        address pool_,
        IMarketController controller_,
        uint16 feeBps_,
        address curator_
    )
        HookVault(
            curator_,
            IMetricLiquidityPool(pool_).getImmutables().token0,
            IMetricLiquidityPool(pool_).getImmutables().token1,
            controller_,
            feeBps_
        )
    {
        if (address(metricFactory) == address(0)) revert InvalidPair();
        if (!metricFactory.isPool(pool_)) revert InvalidPool();
        MetricPoolImmutables memory imm = IMetricLiquidityPool(pool_).getImmutables();
        if (imm.beforeRemoveLiquidityOrder != 0) revert BlockingExtension();
        if (imm.afterRemoveLiquidityOrder != 0) revert BlockingExtension();
        factory = metricFactory;
        pool = IMetricLiquidityPool(pool_);
        minimum = imm.minimalOperationalLiquidity;
        scale0 = imm.token0ScaleMultiplier;
        scale1 = imm.token1ScaleMultiplier;
        lowestBin = imm.lowestBin;
        highestBin = imm.highestBin;
    }

    /// @notice The market this vault's controller runs, or zero when it has no controller.
    function market() external view returns (uint256) {
        if (address(controller) == address(0)) return 0;
        return IVaultLink(address(controller)).market();
    }

    /// @dev There is no arbitrage-hook pool to name: the vault's primary hook is Metric's
    /// own factory, which says which pools are real.
    function primaryHook() external view returns (address) {
        return address(factory);
    }

    function positionInfo(uint256 index)
        external
        view
        returns (address, uint80 salt, int16[] memory bins)
    {
        Position storage entry = positions[index];
        return (address(pool), entry.salt, entry.bins);
    }

    /// @notice The first deposit, which only the curator makes. It fixes the positions and
    /// mints their total bin shares as vault shares, `MINIMUM_SHARES` of which are locked.
    function seed(
        int16[][] calldata ranges,
        uint256[][] calldata shares,
        uint256 max0,
        uint256 max1,
        uint256 deadline
    ) external onlyCurator nonReentrant {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (totalSupply() != 0) revert AlreadySeeded();
        if (ranges.length == 0) revert InvalidPosition();
        if (shares.length != ranges.length) revert InvalidPosition();
        uint256 total;
        uint256 paid0;
        uint256 paid1;
        for (uint256 index; index < ranges.length; index++) {
            _register(ranges[index]);
            (uint256 amount, uint256 in0, uint256 in1) = _seedOne(index, shares[index]);
            total += amount;
            paid0 += in0;
            paid1 += in1;
        }
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
        _open(total);
    }

    function _seedOne(uint256 index, uint256[] calldata shares)
        internal
        returns (uint256 total, uint256 paid0, uint256 paid1)
    {
        Position storage entry = positions[index];
        if (shares.length != entry.bins.length) revert InvalidPosition();
        for (uint256 slot; slot < shares.length; slot++) {
            if (shares[slot] == 0) revert ZeroShares();
            total += shares[slot];
        }
        (paid0, paid1) = _callAdd(entry, shares, msg.sender);
    }

    /// @notice Adds an empty position: shares reach it only through `rebalance`.
    function addPosition(int16[] calldata bins) external onlyCurator nonReentrant {
        if (totalSupply() == 0) revert NotSeeded();
        _register(bins);
    }

    /// @notice Removes a position. Any shares still in its bins, which a third party can
    /// add for the vault, go to idle principal first, so nobody can block a drop with a
    /// donation. The last position takes the freed index.
    function dropPosition(uint256 index) external onlyCurator nonReentrant {
        if (index >= positions.length) revert InvalidPosition();
        Position storage entry = positions[index];
        _sweep(entry);
        binCount -= entry.bins.length;
        uint256 last = positions.length - 1;
        if (index != last) positions[index] = positions[last];
        positions.pop();
        emit PositionDropped(index);
    }

    /// @notice Shifts shares between bins: every removal runs first, into idle principal,
    /// then every addition is paid out of idle principal. The removals must return at least
    /// `min0` and `min1` in all. No price is checked, so the curator can sandwich their own
    /// rebalance, bounded only by `min0` and `min1`. A pool is touched at most once a
    /// block. Funds go only between bins and idle principal.
    function rebalance(Change[] calldata changes, uint256 min0, uint256 min1, uint256 deadline)
        external
        onlyCurator
        nonReentrant
    {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (totalSupply() == 0) revert NotSeeded();
        _claimBlock(changes);
        uint256 out0;
        uint256 out1;
        for (uint256 index; index < changes.length; index++) {
            if (changes[index].shares >= 0) continue;
            (uint256 got0, uint256 got1) = _take(changes[index]);
            out0 += got0;
            out1 += got1;
        }
        if (out0 < min0) revert BelowMinimum();
        if (out1 < min1) revert BelowMinimum();
        for (uint256 index; index < changes.length; index++) {
            if (changes[index].shares > 0) _place(changes[index]);
        }
        emit Rebalanced(changes.length, out0, out1);
    }

    /// @dev Moves everything the vault holds in a position into idle principal.
    function _sweep(Position storage entry) internal {
        uint256[] memory amounts = new uint256[](entry.bins.length);
        for (uint256 slot; slot < amounts.length; slot++) {
            amounts[slot] = _held(entry, slot);
        }
        if (_sum(amounts) == 0) return;
        (uint256 out0, uint256 out1) = _callRemove(entry, amounts);
        idle0 += out0;
        idle1 += out1;
    }

    /// @dev Pool call guards: the pool must not have been rebalanced in this block, and the
    /// change must name a real position and bin. The block is recorded afterwards, so one
    /// rebalance may change a pool as often as it needs to.
    function _claimBlock(Change[] calldata changes) internal {
        for (uint256 index; index < changes.length; index++) {
            if (changes[index].position >= positions.length) revert InvalidPosition();
            Position storage entry = positions[changes[index].position];
            if (changes[index].slot >= entry.bins.length) revert InvalidPosition();
        }
        if (lastRebalance == block.number) revert RebalanceTooSoon();
        lastRebalance = block.number;
    }

    function _take(Change calldata change) internal returns (uint256 out0, uint256 out1) {
        Position storage entry = positions[change.position];
        uint256[] memory amounts = new uint256[](entry.bins.length);
        amounts[change.slot] = uint256(-change.shares);
        (out0, out1) = _callRemove(entry, amounts);
        idle0 += out0;
        idle1 += out1;
    }

    function _place(Change calldata change) internal {
        Position storage entry = positions[change.position];
        uint256[] memory amounts = new uint256[](entry.bins.length);
        amounts[change.slot] = uint256(change.shares);
        (uint256 in0, uint256 in1) = _callAdd(entry, amounts, address(this));
        if (in0 > idle0) revert InsufficientIdle();
        if (in1 > idle1) revert InsufficientIdle();
        idle0 -= in0;
        idle1 -= in1;
    }

    /// @dev A position's bins must be listed once each, in rising order, within the pool's
    /// range, and fit the vault's limits.
    function _register(int16[] calldata bins) internal {
        if (positions.length >= MAX_POSITIONS) revert TooManyPositions();
        _checkBins(bins);
        Position storage entry = positions.push();
        entry.salt = ++lastSalt;
        entry.bins = bins;
        binCount += bins.length;
        emit PositionAdded(positions.length - 1, address(pool), entry.salt);
    }

    function _checkBins(int16[] calldata bins) internal view {
        if (bins.length == 0) revert InvalidBins();
        if (binCount + bins.length > MAX_BINS) revert TooManyBins();
        for (uint256 index; index < bins.length; index++) {
            if (int256(bins[index]) < lowestBin) revert InvalidBins();
            if (int256(bins[index]) > highestBin) revert InvalidBins();
            if (index == 0) continue;
            if (bins[index] <= bins[index - 1]) revert InvalidBins();
        }
    }

    function _positionCount() internal view override returns (uint256) {
        return positions.length;
    }

    function _unitsOf(uint256 index) internal view override returns (uint256) {
        return _unitsOfPosition(positions[index]);
    }

    /// @dev The sum of the vault's shares across the position's bins.
    function _unitsOfPosition(Position storage entry) internal view returns (uint256 sum) {
        for (uint256 slot; slot < entry.bins.length; slot++) {
            sum += _held(entry, slot);
        }
    }

    function _held(Position storage entry, uint256 slot) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encode(address(this), entry.salt, entry.bins[slot]));
        return uint256(pool.extsload(keccak256(abi.encode(key, SHARES_SLOT))));
    }

    /// @dev What adding `shares / supply` of each bin takes, in bin shares. It rounds up,
    /// and a change below the pool's minimum is lifted to it, so a depositor pays more and
    /// never less. A bin the vault holds nothing in stays empty.
    function _addAmounts(Position storage entry, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](entry.bins.length);
        for (uint256 slot; slot < amounts.length; slot++) {
            uint256 held = _held(entry, slot);
            if (held == 0) continue;
            uint256 units = FixedPointMathLib.fullMulDivUp(held, shares, supply);
            amounts[slot] = FixedPointMathLib.max(units, minimum);
        }
    }

    /// @dev What removing `shares / supply` of each bin takes. It rounds down. A change
    /// below the pool's minimum is skipped, and one that would leave less than the minimum
    /// leaves the minimum, so a withdrawal is never refused for dust. What is skipped stays
    /// in the vault for the holders that remain.
    function _removeAmounts(Position storage entry, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](entry.bins.length);
        for (uint256 slot; slot < amounts.length; slot++) {
            uint256 held = _held(entry, slot);
            uint256 units = FixedPointMathLib.fullMulDiv(held, shares, supply);
            if (units < minimum) continue;
            uint256 left = held - units;
            if (left != 0) {
                if (left < minimum) {
                    if (held < 2 * minimum) continue;
                    units = held - minimum;
                }
            }
            amounts[slot] = units;
        }
    }

    function _addFraction(uint256 shares, uint256 supply, uint256 max0, uint256 max1)
        internal
        override
        returns (uint256 paid0, uint256 paid1)
    {
        for (uint256 index; index < positions.length; index++) {
            Position storage entry = positions[index];
            uint256[] memory amounts = _addAmounts(entry, shares, supply);
            if (_sum(amounts) == 0) continue;
            (uint256 in0, uint256 in1) = _callAdd(entry, amounts, msg.sender);
            paid0 += in0;
            paid1 += in1;
        }
        if (paid0 > max0) revert AboveMaximum();
        if (paid1 > max1) revert AboveMaximum();
    }

    /// @dev The pool pays the vault, which owns the position, and the vault passes it on.
    function _removeFraction(uint256 shares, uint256 supply)
        internal
        override
        returns (uint256 out0, uint256 out1)
    {
        for (uint256 index; index < positions.length; index++) {
            Position storage entry = positions[index];
            uint256[] memory amounts = _removeAmounts(entry, shares, supply);
            if (_sum(amounts) == 0) continue;
            (uint256 got0, uint256 got1) = _callRemove(entry, amounts);
            out0 += got0;
            out1 += got1;
        }
        if (out0 != 0) SafeTransferLib.safeTransfer(token0, msg.sender, out0);
        if (out1 != 0) SafeTransferLib.safeTransfer(token1, msg.sender, out1);
    }

    /// @dev Metric has no fee to collect: earnings are already in the bins.
    function _harvest() internal override { }

    /// @dev The pool's own rule, per position: each bin's cost is its balance times the
    /// shares added over the bin's total, rounded up, then the sum is converted to raw
    /// token units, rounded up.
    function _quoteAdd(uint256 shares, uint256 supply)
        internal
        view
        override
        returns (uint256 need0, uint256 need1)
    {
        for (uint256 index; index < positions.length; index++) {
            Position storage entry = positions[index];
            uint256[] memory amounts = _addAmounts(entry, shares, supply);
            uint256 scaled0;
            uint256 scaled1;
            for (uint256 slot; slot < amounts.length; slot++) {
                if (amounts[slot] == 0) continue;
                (uint256 cost0, uint256 cost1) = _cost(entry, slot, amounts[slot]);
                scaled0 += cost0;
                scaled1 += cost1;
            }
            need0 += (scaled0 + scale0 - 1) / scale0;
            need1 += (scaled1 + scale1 - 1) / scale1;
        }
    }

    function _cost(Position storage entry, uint256 slot, uint256 units)
        internal
        view
        returns (uint256 cost0, uint256 cost1)
    {
        (uint256 bal0, uint256 bal1, uint256 total) = _binState(entry, slot);
        cost0 = FixedPointMathLib.fullMulDivUp(bal0, units, total);
        cost1 = FixedPointMathLib.fullMulDivUp(bal1, units, total);
    }

    /// @dev A bin's scaled balances and its total shares, as the pool stores them.
    function _binState(Position storage entry, uint256 slot)
        internal
        view
        returns (uint256 bal0, uint256 bal1, uint256 total)
    {
        int256 bin = entry.bins[slot];
        uint256 raw = uint256(pool.extsload(keccak256(abi.encode(bin, BINS_SLOT))));
        total = uint256(pool.extsload(keccak256(abi.encode(bin, TOTALS_SLOT))));
        bal0 = uint256(uint104(raw));
        bal1 = uint256(uint104(raw >> 104));
    }

    /// @notice What `withdraw(shares, ...)` would pay now. A bin too small to remove is
    /// skipped: it returns nothing and its value stays with the other holders. A caller
    /// should pass this as `min0` and `min1`, less any slippage they accept. It equals the
    /// payment when no bin is shared between positions; otherwise it is a lower bound, up to
    /// one scaled unit per shared bin per token below the payment, so a minimum taken from
    /// it never reverts.
    function quoteWithdraw(uint256 shares) external view returns (uint256 out0, uint256 out1) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotSeeded();
        if (shares == 0) revert ZeroShares();
        out0 = FixedPointMathLib.fullMulDiv(idle0, shares, supply);
        out1 = FixedPointMathLib.fullMulDiv(idle1, shares, supply);
        for (uint256 index; index < positions.length; index++) {
            (uint256 got0, uint256 got1) = _quoteRemove(positions[index], shares, supply);
            out0 += got0;
            out1 += got1;
        }
    }

    /// @dev The pool's rule for one removal call: each bin's value rounded down, summed
    /// scaled, then converted to raw token units, rounded down.
    function _quoteRemove(Position storage entry, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256 got0, uint256 got1)
    {
        uint256[] memory amounts = _removeAmounts(entry, shares, supply);
        uint256 scaled0;
        uint256 scaled1;
        for (uint256 slot; slot < amounts.length; slot++) {
            if (amounts[slot] == 0) continue;
            (uint256 bal0, uint256 bal1, uint256 total) = _binState(entry, slot);
            scaled0 += FixedPointMathLib.fullMulDiv(bal0, amounts[slot], total);
            scaled1 += FixedPointMathLib.fullMulDiv(bal1, amounts[slot], total);
        }
        got0 = scaled0 / scale0;
        got1 = scaled1 / scale1;
    }

    function _sum(uint256[] memory amounts) internal pure returns (uint256 total) {
        for (uint256 index; index < amounts.length; index++) {
            total += amounts[index];
        }
    }

    function _delta(Position storage entry, uint256[] memory amounts)
        internal
        view
        returns (MetricLiquidityDelta memory)
    {
        int256[] memory bins = new int256[](entry.bins.length);
        for (uint256 slot; slot < bins.length; slot++) {
            bins[slot] = entry.bins[slot];
        }
        return MetricLiquidityDelta(bins, amounts);
    }

    /// @dev Adds as the owner. The pool asks for the tokens in the callback, which pays
    /// them from `from`; what the pool reports is what was paid.
    function _callAdd(Position storage entry, uint256[] memory amounts, address from)
        internal
        returns (uint256 paid0, uint256 paid1)
    {
        active = address(pool);
        (paid0, paid1) = pool.addLiquidity(
            address(this), entry.salt, _delta(entry, amounts), abi.encode(from), ""
        );
        active = address(0);
    }

    /// @dev Removes as the owner, so the tokens arrive here. Idle principal is booked from
    /// what the pool reports, after checking that the balance rose by exactly that.
    function _callRemove(Position storage entry, uint256[] memory amounts)
        internal
        returns (uint256 out0, uint256 out1)
    {
        uint256 before0 = SafeTransferLib.balanceOf(token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(token1, address(this));
        (out0, out1) =
            pool.removeLiquidity(address(this), entry.salt, _delta(entry, amounts), "");
        if (SafeTransferLib.balanceOf(token0, address(this)) != before0 + out0) {
            revert TransferAmountMismatch();
        }
        if (SafeTransferLib.balanceOf(token1, address(this)) != before1 + out1) {
            revert TransferAmountMismatch();
        }
    }

    /// @dev Only the pool the vault is calling may ask for tokens, and only while it does.
    function metricOmmModifyLiquidityCallback(
        uint256 amount0Delta,
        uint256 amount1Delta,
        bytes calldata data
    ) external {
        if (msg.sender != active) revert NotPool();
        address from = abi.decode(data, (address));
        _send(token0, from, amount0Delta);
        _send(token1, from, amount1Delta);
    }

    function _send(address asset, address from, uint256 amount) internal {
        if (amount == 0) return;
        if (from == address(this)) {
            SafeTransferLib.safeTransfer(asset, msg.sender, amount);
        } else {
            SafeTransferLib.safeTransferFrom(asset, from, msg.sender, amount);
        }
    }
}
