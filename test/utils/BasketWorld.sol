// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { Basket } from "../../src/basket/Basket.sol";
import { BasketFactory } from "../../src/basket/BasketFactory.sol";

/// @dev A stock token stand-in that its issuer can pause, as Robinhood's can.
contract PausableAsset is ERC20 {
    bool public paused;

    function name() public pure override returns (string memory) {
        return "Test Stock";
    }

    function symbol() public pure override returns (string memory) {
        return "TSTK";
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function _beforeTokenTransfer(address, address, uint256) internal view override {
        if (paused) revert("paused");
    }
}

/// @dev Stands in for Liquidity: only `manager()` is read.
contract ManagerStub {
    address public manager;

    constructor(address manager_) {
        manager = manager_;
    }
}

/// @dev Stands in for the v4 liquidity extension: only `liquidity()` is read.
contract ProtocolStub {
    address public liquidity;

    constructor(address liquidity_) {
        liquidity = liquidity_;
    }
}

/// @dev Gives a basket pool-manager claims, paid from its own balance, the way anyone could.
contract ClaimDonor is IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function donate(address basket, address token, uint256 amount) external {
        manager.unlock(abi.encode(basket, token, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address basket, address token, uint256 amount) =
            abi.decode(data, (address, address, uint256));
        Currency currency = Currency.wrap(token);
        manager.sync(currency);
        ERC20(token).transfer(address(manager), amount);
        manager.settle();
        manager.mint(basket, currency.toId(), amount);
        return "";
    }
}

/// @dev The real pool manager with a unit token and up to ten pausable stocks, each in a
/// hookless pool at price one with deep full-range liquidity from the test contract, which
/// is also Liquidity's manager. Baskets are made through the real factory.
abstract contract BasketWorld is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    int24 internal constant SPACING = 60;
    // About 1/16 to 16 times the price at creation.
    int24 internal constant LOWER = -27_720;
    int24 internal constant UPPER = 27_720;
    uint256 internal constant DEPTH = 1_000_000e18;
    uint128 internal constant SEED = 1_000e18;
    uint256 internal constant SHARES = 1_000e18;
    uint160 internal constant FLOOR = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant CEILING = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal provider;
    PoolSwapTest internal swapper;
    BasketFactory internal factory;
    ProtocolStub internal protocol;
    PausableAsset internal usd;
    PausableAsset[] internal stocks;
    PoolKey[] internal pools;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        manager =
            IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        provider = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        protocol = new ProtocolStub(address(new ManagerStub(address(this))));
        factory = new BasketFactory(
            manager, address(0), address(protocol), type(Basket).creationCode
        );
        usd = _asset();
        for (uint256 index; index < 10; index++) {
            PausableAsset stock = _asset();
            stocks.push(stock);
            pools.push(_pool(stock));
        }
    }

    function _asset() internal returns (PausableAsset asset) {
        asset = new PausableAsset();
        asset.mint(address(this), 1e40);
        asset.approve(address(provider), type(uint256).max);
        asset.approve(address(swapper), type(uint256).max);
    }

    function _key(address stock) internal view returns (PoolKey memory) {
        (address zero, address one) =
            address(usd) < stock ? (address(usd), stock) : (stock, address(usd));
        return
            PoolKey(Currency.wrap(zero), Currency.wrap(one), 3000, SPACING, IHooks(address(0)));
    }

    function _pool(PausableAsset stock) internal returns (PoolKey memory pool) {
        pool = _key(address(stock));
        manager.initialize(pool, uint160(1 << 96));
        _provide(pool, TickMath.minUsableTick(SPACING), TickMath.maxUsableTick(SPACING), DEPTH);
    }

    function _provide(PoolKey memory pool, int24 lower, int24 upper, uint256 liquidity)
        internal
    {
        provider.modifyLiquidity(
            pool, IPoolManager.ModifyLiquidityParams(lower, upper, int256(liquidity), 0), ""
        );
    }

    function _legs(uint256 count) internal view returns (Basket.Leg[] memory legs) {
        legs = new Basket.Leg[](count);
        for (uint256 index; index < count; index++) {
            legs[index] = Basket.Leg(pools[index], LOWER, UPPER);
        }
    }

    /// A started basket over the first `count` pools, seeded by this contract.
    function _basket(uint256 count) internal returns (Basket basket) {
        return _basket(count, 0);
    }

    /// The same, with fee mode `mode`.
    function _basket(uint256 count, uint8 mode) internal returns (Basket basket) {
        basket = Basket(factory.create("Basket", "BSKT", address(usd), mode, _legs(count)));
        uint128[] memory seed = new uint128[](count);
        for (uint256 index; index < count; index++) {
            seed[index] = SEED;
        }
        _approveAll(basket, address(this));
        basket.start(seed, SHARES, _unbounded(count + 1), block.timestamp);
    }

    function _make(Basket.Leg[] memory legs) internal returns (Basket) {
        return Basket(factory.create("Basket", "BSKT", address(usd), 0, legs));
    }

    /// Funds `who` with every token and approves the basket for all of them.
    function _fund(Basket basket, address who, uint256 amount) internal {
        address[] memory list = basket.tokens();
        for (uint256 index; index < list.length; index++) {
            PausableAsset(list[index]).mint(who, amount);
        }
        _approveAll(basket, who);
    }

    function _approveAll(Basket basket, address who) internal {
        address[] memory list = basket.tokens();
        for (uint256 index; index < list.length; index++) {
            vm.prank(who);
            PausableAsset(list[index]).approve(address(basket), type(uint256).max);
        }
    }

    function _unbounded(uint256 count) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = type(uint256).max;
        }
    }

    function _zeros(uint256 count) internal pure returns (uint256[] memory) {
        return new uint256[](count);
    }

    /// An exact-input swap by this contract with no price limit.
    function _trade(PoolKey memory pool, address input, uint256 amount) internal {
        bool zeroForOne = Currency.unwrap(pool.currency0) == input;
        swapper.swap(
            pool,
            IPoolManager.SwapParams(zeroForOne, -int256(amount), zeroForOne ? FLOOR : CEILING),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    /// Trades both ways through every leg, so each earns fees and ends near where it began.
    function _churn(uint256 count, uint256 amount) internal {
        for (uint256 index; index < count; index++) {
            _trade(pools[index], address(usd), amount);
            _trade(pools[index], address(stocks[index]), amount);
        }
    }

    function _balances(Basket basket, address who) internal view returns (uint256[] memory) {
        address[] memory list = basket.tokens();
        uint256[] memory amounts = new uint256[](list.length);
        for (uint256 index; index < list.length; index++) {
            amounts[index] = PausableAsset(list[index]).balanceOf(who);
        }
        return amounts;
    }

    /// The pool manager's ERC20 balance of every stock: unchanged means no stock moved.
    function _stocksHeld(Basket basket) internal view returns (uint256 total) {
        address[] memory list = basket.tokens();
        for (uint256 index = 1; index < list.length; index++) {
            total += PausableAsset(list[index]).balanceOf(address(manager));
        }
    }

    function _claims(Basket basket, address token) internal view returns (uint256) {
        return manager.balanceOf(address(basket), Currency.wrap(token).toId());
    }

    function _idle(Basket basket, address token) internal view returns (uint256) {
        return _claims(basket, token) - basket.owed(token);
    }
}
