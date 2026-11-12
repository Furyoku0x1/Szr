// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { console2 } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SzrCore } from "../src/SzrCore.sol";
import { FeeCollector } from "../src/FeeCollector.sol";
import { SzrMigration, ILegacySzrToken, ILegacySzrHook } from "../src/SzrMigration.sol";
import { Liquidity } from "../src/Liquidity.sol";

/// @notice Ordinary Foundry deployment transactions; signing is supplied by the caller.
contract DeploySzr is Script {
    struct Config {
        uint256 chainId;
        address asset;
        address poolManager;
        address teamBeneficiary;
        address manager;
        address legacyToken;
        uint256 marketPrice;
        uint256 bootstrapNAV;
        uint256 launchAllocation;
        uint256 initialLiquidityTokens;
        SzrCore.AuctionConfig auction;
        bool fundInitialLiquidity;
    }

    error WrongChain();
    error MissingAsset();
    error MissingPoolManager();
    error InvalidMarketPrice();
    error ManagerIsDeployer();
    error InitialPriceBelowNav();

    function run() external returns (SzrCore core, FeeCollector jar, Liquidity locker) {
        return run(_readConfig());
    }

    /// @notice Typed inputs let rehearsals execute without shared environment-variable state.
    function run(Config memory config)
        public
        returns (SzrCore core, FeeCollector jar, Liquidity locker)
    {
        if (block.chainid != config.chainId) revert WrongChain();
        if (config.asset.code.length == 0) revert MissingAsset();
        if (config.poolManager.code.length == 0) revert MissingPoolManager();
        if (config.marketPrice < 1e6) revert InvalidMarketPrice();
        if (config.marketPrice > 1e30) revert InvalidMarketPrice();
        vm.startBroadcast();
        core = new SzrCore(
            config.asset, config.bootstrapNAV, config.teamBeneficiary, config.auction
        );
        jar = new FeeCollector(core);
        address setupManager = core.initializer();
        locker = new Liquidity(core, jar, IPoolManager(config.poolManager), setupManager);
        core.initialize(address(locker), address(jar));
        _setupMigration(core, config);
        _setupPools(core, locker, config.marketPrice);
        core.launch();
        // Genesis liquidity comes straight from Core's inventory; the deployer supplies nothing.
        if (config.fundInitialLiquidity) {
            if (core.initialLiquidityTarget() != 0) {
                locker.fundInitialLiquidity(0, type(uint256).max);
            }
        }
        // The deployer only sets up; a separate manager takes over once it accepts.
        if (config.manager != address(0)) {
            if (config.manager == setupManager) revert ManagerIsDeployer();
            locker.nominateManager(config.manager);
        }
        vm.stopBroadcast();
        console2.log("ECONOMICS", address(core.economics()));
        console2.log("TEAM_BENEFICIARY", core.economics().beneficiary());
        console2.log("SZR", address(core.token()));
        console2.log("CORE", address(core));
        console2.log("FEE_JAR", address(jar));
        console2.log("LIQUIDITY", address(locker));
    }

    function _readConfig() internal view returns (Config memory config) {
        config.chainId = vm.envUint("EXPECTED_CHAIN_ID");
        config.asset = vm.envAddress("WETH");
        config.poolManager = vm.envAddress("POOL_MANAGER");
        config.teamBeneficiary = vm.envAddress("TEAM_BENEFICIARY");
        config.manager = vm.envAddress("MANAGER");
        config.legacyToken =
            vm.envOr("LEGACY_SZR", address(0xbeD7c1660a01dbEEe225bd893ac31727a91A5773));
        config.marketPrice = vm.envOr("INITIAL_MARKET_PRICE", uint256(507e9));
        if (config.marketPrice < 1e6) revert InvalidMarketPrice();
        if (config.marketPrice > 1e30) revert InvalidMarketPrice();
        config.bootstrapNAV = vm.envOr("BOOTSTRAP_NAV", uint256(1e12));
        config.launchAllocation = vm.envOr("MIGRATION_ALLOCATION", uint256(350_000_000e18));
        config.initialLiquidityTokens =
            vm.envOr("INITIAL_LIQUIDITY_ALLOCATION", uint256(25_000_000e18));
        config.auction = SzrCore.AuctionConfig(
            vm.envOr("AUCTION_OPENING_WAD", config.marketPrice * 2),
            vm.envOr("AUCTION_FLOOR_WAD", uint256(1)),
            vm.envOr("AUCTION_BUFFER", uint256(20_000e18))
        );
        config.fundInitialLiquidity = vm.envOr("FUND_INITIAL_LIQUIDITY", true);
    }

    function _setupMigration(SzrCore core, Config memory config) internal {
        if (config.launchAllocation == 0) return;
        ILegacySzrHook hook = ILegacySzrHook(ILegacySzrToken(config.legacyToken).hook());
        // Genesis liquidity must not start below the highest NAV migration can reach, or it
        // would be bought and redeemed against reserves at a profit. That NAV is what one old
        // SZR recovers now, diluted by the genesis tokens, with the whole allocation migrated.
        uint256 recovered = hook.quoteSellExactIn(1e18).netWethOut * config.launchAllocation;
        uint256 claims = config.launchAllocation + config.initialLiquidityTokens;
        if (config.marketPrice * claims < recovered) revert InitialPriceBelowNav();
        SzrMigration migrator = new SzrMigration(core, config.legacyToken, hook);
        core.configureMigration(
            address(migrator), config.launchAllocation, config.initialLiquidityTokens
        );
        console2.log("MIGRATION", address(migrator));
        console2.log("LAUNCH_ALLOCATION", config.launchAllocation);
        console2.log("MIGRATION_ALLOCATION", core.migrationAllocation());
        console2.log("INITIAL_LIQUIDITY_TARGET", config.initialLiquidityTokens);
    }

    function _setupPools(SzrCore core, Liquidity locker, uint256 marketPrice) internal {
        Liquidity.PoolConfig memory config = _config(core, marketPrice);
        FeeCollector.AssetConfig memory unused;
        locker.addPool(config, unused);
        if (core.initialLiquidityTarget() == 0) return;
        _initialRange(core, config);
        locker.setInitialPool(config, unused);
    }

    function _config(SzrCore core, uint256 price)
        internal
        view
        returns (Liquidity.PoolConfig memory config)
    {
        bool first = address(core.token()) < core.backingAsset();
        uint256 ratio = first
            ? FixedPointMathLib.fullMulDiv(price, 1 << 192, 1e18)
            : FixedPointMathLib.fullMulDiv(1e18, 1 << 192, price);
        config = Liquidity.PoolConfig({
            partner: core.backingAsset(),
            feePips: 10_000,
            tickSpacing: 200,
            tickLower: TickMath.minUsableTick(200),
            tickUpper: TickMath.maxUsableTick(200),
            initialSqrtPriceX96: SafeCastLib.toUint160(FixedPointMathLib.sqrt(ratio)),
            hooks: IHooks(address(0))
        });
    }

    function _initialRange(SzrCore core, Liquidity.PoolConfig memory config) internal view {
        int24 tick = TickMath.getTickAtSqrtPrice(config.initialSqrtPriceX96);
        int24 floorTick = tick / config.tickSpacing * config.tickSpacing;
        if (tick < floorTick) floorTick -= config.tickSpacing;
        if (address(core.token()) < config.partner) {
            config.tickLower = floorTick;
            if (TickMath.getSqrtPriceAtTick(floorTick) < config.initialSqrtPriceX96) {
                config.tickLower += config.tickSpacing;
            }
        } else {
            config.tickUpper = floorTick;
        }
    }
}
