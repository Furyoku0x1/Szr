// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { SzrMigration, ILegacySzrHook } from "../../src/SzrMigration.sol";
import { LegacyMigrationHook } from "./LegacyMigrationHook.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { SzrCore } from "../../src/SzrCore.sol";
import { FeeCollector } from "../../src/FeeCollector.sol";
import { Liquidity } from "../../src/Liquidity.sol";
import { TestAsset } from "./TestAsset.sol";

abstract contract SzrWorld is Test {
    uint256 internal initialSupply = 20_000_000e18;
    TestAsset internal backing;
    SzrCore internal core;
    FeeCollector internal jar;
    Liquidity internal locker;
    IPoolManager internal manager;
    PoolSwapTest internal swapper;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal charlie = address(0xCA11);

    function setUp() public virtual {
        _deploy();
        _fund(alice);
        _fund(bob);
        _fund(charlie);
        vm.warp(core.auctionsOpenAt() + 1 days);
        backing.mint(address(this), 20e18);
        backing.approve(address(core), type(uint256).max);
        core.donateBacking(20e18);
        _acquire(charlie);
        _fundPosition();
    }

    function _deploy() internal {
        backing = new TestAsset();
        core = SzrCore(
            deployCode(
                "SzrCore.sol:SzrCore",
                abi.encode(
                    address(backing),
                    uint256(1e12),
                    address(this),
                    SzrCore.AuctionConfig(4e12, 1, 20_000e18)
                )
            )
        );
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        swapper = new PoolSwapTest(manager);
        jar = new FeeCollector(core);
        locker = new Liquidity(core, jar, manager, address(this));
        core.initialize(address(locker), address(jar));
        FeeCollector.AssetConfig memory unused;
        locker.addPool(_config(), unused);
        SzrMigration migrator = _legacyMigration();
        core.launch();
        migrator.migrate(initialSupply, 0, block.timestamp);
        _provideMarketLiquidity();
    }

    /// @dev Initial test holders migrate existing tokens; Core never seeds a new allocation.
    function _legacyMigration() internal returns (SzrMigration migrator) {
        LegacyMigrationHook implementation = new LegacyMigrationHook();
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        LegacyMigrationHook hook = LegacyMigrationHook(address(flags));
        vm.etch(address(hook), address(implementation).code);
        hook.initialize(manager, address(backing));
        hook.setPrice(1_000);
        address oldToken = address(hook.token());
        bool first = oldToken < address(backing);
        PoolKey memory key = PoolKey(
            Currency.wrap(first ? oldToken : address(backing)),
            Currency.wrap(first ? address(backing) : oldToken),
            0,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, uint160(1 << 96));
        backing.mint(address(hook), initialSupply * 1_000 / 1e18);
        migrator = new SzrMigration(core, oldToken, ILegacySzrHook(address(hook)));
        core.configureMigration(address(migrator), initialSupply, 0);
        hook.token().mint(address(this), initialSupply);
        hook.token().approve(address(migrator), initialSupply);
    }

    /// @dev An existing holder provides the market's first LP; this is not protocol issuance.
    function _provideMarketLiquidity() internal {
        PoolModifyLiquidityTest provider = new PoolModifyLiquidityTest(manager);
        backing.mint(address(this), 10_000_000e18);
        backing.approve(address(provider), type(uint256).max);
        core.token().approve(address(provider), type(uint256).max);
        provider.modifyLiquidity(
            locker.key(0),
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(60), TickMath.maxUsableTick(60), int256(10_000_000e18), 0
            ),
            ""
        );
    }

    function _config() internal view returns (Liquidity.PoolConfig memory config) {
        config = Liquidity.PoolConfig({
            partner: address(backing),
            feePips: 3_000,
            tickSpacing: 60,
            tickLower: TickMath.minUsableTick(60),
            tickUpper: TickMath.maxUsableTick(60),
            initialSqrtPriceX96: uint160(1 << 96),
            hooks: IHooks(address(0))
        });
    }

    function _fund(address account) internal {
        backing.mint(account, 1_000_000e18);
        vm.startPrank(account);
        backing.approve(address(core), type(uint256).max);
        backing.approve(address(jar), type(uint256).max);
        backing.approve(address(swapper), type(uint256).max);
        core.token().approve(address(core), type(uint256).max);
        core.token().approve(address(swapper), type(uint256).max);
        vm.stopPrank();
        _swap(account, address(backing), 10_000e18);
    }

    function _acquire(address account) internal returns (uint256) {
        (uint256 payment,,) = core.quote(1_000e18);
        vm.prank(account);
        return core.buy(1_000e18, payment, block.timestamp);
    }

    function _fundPosition() internal {
        PoolKey memory pool = locker.key(0);
        bool zeroForOne = Currency.unwrap(pool.currency0) == address(backing);
        locker.swapPrincipal(
            pool,
            zeroForOne,
            locker.heldPrincipal(address(backing)) / 2,
            1,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            block.timestamp
        );
        locker.deployPrincipal(
            0, 1e12, Liquidity.Bounds(type(uint256).max, type(uint256).max, block.timestamp)
        );
    }

    function _swap(address account, address input, uint256 amount) internal {
        PoolKey memory pool = locker.key(0);
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings;
        vm.prank(account);
        swapper.swap(pool, params, settings, "");
    }

    function _registerFeeAsset() internal returns (TestAsset asset) {
        asset = new TestAsset();
        Liquidity.PoolConfig memory config = _config();
        config.partner = address(asset);
        locker.addPool(config, FeeCollector.AssetConfig(1e18, 20_000e18, 1e12));
    }

    function _recordFee(TestAsset asset, uint256 amount) internal {
        asset.mint(address(jar), amount);
        vm.prank(address(locker));
        jar.recordFees(address(asset), amount);
    }

    function _assertCash() internal view {
        assertEq(backing.balanceOf(address(core)), core.reserveCash());
        uint256 held = core.token().balanceOf(address(core));
        assertGe(held, core.unreleasedSupply() + core.pledgedSupply() + core.totalReclaimable());
        assertLe(core.pledgedSupply(), core.activeSupply());
        assertLe(core.availableRelease(), core.publicInventory());
        assertLe(core.availableRelease(), core.releaseCredit());
        assertEq(
            core.token().balanceOf(address(locker)), locker.heldPrincipal(address(core.token()))
        );
        assertEq(backing.balanceOf(address(locker)), locker.heldPrincipal(address(backing)));
    }
}
