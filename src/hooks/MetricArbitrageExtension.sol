// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {
    IMetricOmmExtensions,
    IMetricSwapState
} from "../interfaces/metric/IMetricOmmExtensions.sol";

interface IArbitrageSweep {
    function sweep(uint256 id, address base) external returns (uint256 profit);
}

/// @title MetricArbitrageExtension
/// @notice A Metric pool extension that sweeps the arbitrage hook's market before and after
/// every real swap in the pool. It never reverts a swap: Metric reverts the trader's whole
/// swap when an extension reverts, so every failure of the sweep is caught here.
/// @dev Inside a v4 unlock (a swap routed through `MetricVenueHook`) the hook's own unlock
/// reverts and is caught, so that route gets no sweep from here. It is meant to be covered by
/// the hook's venue triggers, but those need an approved pricer and none may be set yet, so
/// today that route gets no search at all. The Metric pool is locked while it calls this, so
/// the sweep prices the v4 pools and other venues.
///
/// Known limit: a sweep only runs when more than `gasCap + reserve` gas is left, and it
/// leaves at least `reserve` for the rest of the swap. A swap whose remaining work (or a
/// router's later hops) needs more than `reserve` can therefore fail at gas levels just
/// above that threshold while succeeding just below it. Curators of pools with heavy routes
/// should set a larger `reserve`.
///
/// Cost: a real swap can spend up to 2 calls (before and after) times the number of tokens
/// (at most 2) times `gasCap` on sweeps. That is the curator's choice, and it is paid by
/// the pool's swappers.
contract MetricArbitrageExtension is IMetricOmmExtensions {
    struct Config {
        bool registered;
        uint8 count;
        uint32 gasCap;
        uint256 reserve;
        uint256 market;
        address token0;
        address token1;
    }

    /// `afterSwap(address,address,bool,int128,uint128,uint256,uint256,uint128,uint128,
    /// uint128,int128,int128,uint256,bytes)`
    bytes4 public constant AFTER_SWAP = 0xe6a7bba0;
    /// A search in a market with a pricer needs a floor above 3M gas before it starts, so
    /// a lower maximum would stop it ever running there. The floors are lower now, since
    /// the live-pricer reserve change, but the value is left alone.
    uint32 public constant MAX_GAS_CAP = 20_000_000;
    /// The least `reserve` a pool may choose: gas kept back for the rest of the swap.
    uint256 public constant MIN_RESERVE = 1_000_000;
    /// The most a pool may reserve: above this, `gasCap + reserve` could never be met (a
    /// transaction is capped at 32M gas) and a huge value would overflow the sum.
    uint256 public constant MAX_RESERVE = 30_000_000;
    bytes4 internal constant BEFORE_ADD = 0x0a2a56a6;
    bytes4 internal constant AFTER_ADD = 0x9a298305;
    bytes4 internal constant BEFORE_REMOVE = 0x90c26d99;
    bytes4 internal constant AFTER_REMOVE = 0x016c3252;

    address public immutable arbitrageHook;
    address public immutable metricFactory;
    mapping(address pool => Config) public configs;

    event Registered(
        address indexed pool, uint256 market, address[] tokens, uint32 gasCap, uint256 reserve
    );

    error NotFactory();
    error AlreadyRegistered();
    error BadTokens();
    error GasCapTooHigh();
    error UnknownCall();
    error ReserveTooLow();
    error ReserveTooHigh();
    error NoHook();
    error NoFactory();

    constructor(address hook_, address factory_) {
        // A hook without code would make every sweep call revert outside the `try`.
        if (hook_.code.length == 0) revert NoHook();
        if (factory_ == address(0)) revert NoFactory();
        arbitrageHook = hook_;
        metricFactory = factory_;
    }

    function initialize(address pool, bytes calldata data) external returns (bytes4) {
        if (msg.sender != metricFactory) revert NotFactory();
        if (configs[pool].registered) revert AlreadyRegistered();
        (uint256 market, address[] memory tokens, uint32 gasCap, uint256 reserve) =
            abi.decode(data, (uint256, address[], uint32, uint256));
        if (tokens.length == 0) revert BadTokens();
        if (tokens.length > 2) revert BadTokens();
        if (gasCap > MAX_GAS_CAP) revert GasCapTooHigh();
        if (reserve < MIN_RESERVE) revert ReserveTooLow();
        if (reserve > MAX_RESERVE) revert ReserveTooHigh();
        configs[pool] = Config(
            true,
            uint8(tokens.length),
            gasCap,
            reserve,
            market,
            tokens[0],
            tokens.length == 2 ? tokens[1] : address(0)
        );
        emit Registered(pool, market, tokens, gasCap, reserve);
        return this.initialize.selector;
    }

    function beforeSwap(
        address,
        address,
        bool,
        int128,
        uint128,
        uint256,
        uint128,
        uint128,
        uint128,
        bytes calldata
    ) external returns (bytes4) {
        _sweep();
        return this.beforeSwap.selector;
    }

    /// @dev Also answers Metric's liquidity points with their selector and nothing else, so
    /// that the extension can never block a deposit or a withdrawal.
    /// Metric's `afterSwap` has 14 arguments, more than this repo's compiler settings
    /// can decode, so it is answered here by its selector. The arguments are not read.
    fallback() external {
        bytes4 answer = msg.sig;
        if (answer == AFTER_SWAP) _sweep();
        else if (!_isLiquidityPoint(answer)) revert UnknownCall();
        assembly ("memory-safe") {
            mstore(0, answer)
            return(0, 32)
        }
    }

    function _isLiquidityPoint(bytes4 sig) internal pure returns (bool) {
        if (sig == BEFORE_ADD) return true;
        if (sig == AFTER_ADD) return true;
        if (sig == BEFORE_REMOVE) return true;
        return sig == AFTER_REMOVE;
    }

    /// @dev Skips unknown callers rather than reverting, and skips simulations and quotes,
    /// which Metric runs through the same extension calls.
    function _sweep() internal {
        Config memory config = configs[msg.sender];
        if (!config.registered) return;
        if (IMetricSwapState(msg.sender).inSwap() == address(0)) return;
        _try(config.market, config.token0, config.gasCap, config.reserve);
        if (config.count == 2) {
            _try(config.market, config.token1, config.gasCap, config.reserve);
        }
    }

    /// @dev With more than `gasCap + reserve` left, the sweep gets exactly `gasCap` (the lower
    /// of the cap and what is above the reserve), so at least `reserve` is left afterwards.
    function _try(uint256 market, address token, uint32 gasCap, uint256 reserve) internal {
        if (gasleft() <= uint256(gasCap) + reserve) return;
        try IArbitrageSweep(arbitrageHook).sweep{ gas: gasCap }(market, token) { } catch { }
    }
}
