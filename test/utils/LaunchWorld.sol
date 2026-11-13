// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { DeploySzr } from "../../script/DeploySzr.s.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { SzrMigration } from "../../src/SzrMigration.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { FeeCollector } from "../../src/FeeCollector.sol";
import { TestAsset } from "./TestAsset.sol";
import { LegacyMigrationHook, LegacyMigrationToken } from "./LegacyMigrationHook.sol";

/// @dev The system exactly as the deploy script leaves it: genesis funded from Core's
/// inventory, migration open, a separate team manager. `asset` fixes which side of the pool
/// SZR is on.
abstract contract LaunchWorld is Test {
    TestAsset internal backing;
    SzrCore internal core;
    FeeCollector internal jar;
    Liquidity internal locker;
    SzrMigration internal migrator;
    IPoolManager internal manager;
    PoolSwapTest internal router;
    LegacyMigrationHook internal oldHook;
    LegacyMigrationToken internal oldToken;
    TestAsset internal szr;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal team = address(0x7EA);
    uint256 internal constant GENESIS = 25_000_000e18;
    uint256 internal constant PRICE = 3e12; // genesis start, just above what old SZR recovers

    function _world(address asset) internal {
        _world(asset, true);
    }

    function _world(address asset, bool fundGenesis) internal {
        deployCodeTo("TestAsset.sol:TestAsset", asset);
        backing = TestAsset(asset);
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        router = new PoolSwapTest(manager);
        _legacy();
        DeploySzr.Config memory config;
        config.chainId = block.chainid;
        config.asset = asset;
        config.poolManager = address(manager);
        config.teamBeneficiary = address(0xBEEF);
        config.manager = team;
        config.legacyToken = address(oldToken);
        config.marketPrice = PRICE;
        config.bootstrapNAV = 1e12;
        config.launchAllocation = 350_000_000e18;
        config.initialLiquidityTokens = GENESIS;
        config.auction = SzrCore.AuctionConfig(PRICE * 2, 1, 20_000e18);
        config.fundInitialLiquidity = fundGenesis;
        DeploySzr deployment = DeploySzr(deployCode("DeploySzr.s.sol:DeploySzr"));
        (core, jar, locker) = deployment.run(config);
        migrator = SzrMigration(core.migration());
        szr = TestAsset(address(core.token()));
        vm.prank(team);
        locker.acceptManager();
        address[3] memory users = [alice, bob, carol];
        for (uint256 index; index < 3; index++) {
            oldToken.mint(users[index], 120_000_000e18);
            backing.mint(users[index], 1_000_000e18);
            vm.startPrank(users[index]);
            oldToken.approve(address(migrator), type(uint256).max);
            backing.approve(address(core), type(uint256).max);
            backing.approve(address(router), type(uint256).max);
            szr.approve(address(core), type(uint256).max);
            szr.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _legacy() internal {
        LegacyMigrationHook implementation = new LegacyMigrationHook();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        oldHook = LegacyMigrationHook(address(flags));
        vm.etch(address(oldHook), address(implementation).code);
        oldHook.initialize(manager, address(backing));
        oldToken = oldHook.token();
        bool first = address(oldToken) < address(backing);
        manager.initialize(
            PoolKey(
                Currency.wrap(first ? address(oldToken) : address(backing)),
                Currency.wrap(first ? address(backing) : address(oldToken)),
                0,
                60,
                IHooks(address(oldHook))
            ),
            uint160(1 << 96)
        );
        backing.mint(address(oldHook), 100_000e18);
    }

    function _poolSwap(address who, bool wethIn, uint256 amount) internal {
        PoolKey memory pool = locker.key(0);
        bool zeroForOne = (Currency.unwrap(pool.currency0) == address(backing)) == wethIn;
        PoolSwapTest.TestSettings memory settings;
        vm.prank(who);
        router.swap(
            pool,
            IPoolManager.SwapParams(
                zeroForOne,
                -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
    }

    function _books() internal view {
        assertEq(backing.balanceOf(address(core)), core.reserveCash(), "reserve cash");
        assertGe(
            szr.balanceOf(address(core)),
            core.unreleasedSupply() + core.pledgedSupply() + core.totalReclaimable(),
            "core tokens"
        );
        assertEq(
            core.publicInventory() + core.migrationRemaining(),
            core.unreleasedSupply(),
            "inventory"
        );
        assertEq(szr.balanceOf(address(locker)), locker.heldPrincipal(address(szr)), "held szr");
        assertEq(
            backing.balanceOf(address(locker)),
            locker.heldPrincipal(address(backing)),
            "held weth"
        );
        assertLe(locker.unallocatedFunding(), locker.heldPrincipal(address(backing)), "funding");
        uint256 unlocked = core.activeSupply() - core.pledgedSupply();
        assertGe(
            core.reserveCash() * core.activeSupply(),
            core.backingAmount() * unlocked,
            "solvency"
        );
    }
}
