// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20 } from "solady/tokens/ERC20.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BaseTestHooks } from "v4-core/test/BaseTestHooks.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { BeforeSwapDelta, toBeforeSwapDelta } from "v4-core/types/BeforeSwapDelta.sol";
import { ILegacySzrHook, SzrMigration } from "../../src/SzrMigration.sol";

/// @dev Test-only token with optional transfer taxation for negative accounting tests.
contract LegacyMigrationToken is ERC20 {
    address public immutable hook;
    bool public taxed;

    constructor(address hook_) {
        hook = hook_;
    }

    function name() public pure override returns (string memory) {
        return "Legacy SZR";
    }

    function symbol() public pure override returns (string memory) {
        return "SZR";
    }

    function mint(address owner, uint256 amount) external {
        _mint(owner, amount);
    }

    function burn(uint256 amount) external {
        require(msg.sender == hook);
        _burn(msg.sender, amount);
    }

    function setTaxed(bool enabled) external {
        taxed = enabled;
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!taxed) return;
        if (from == address(0)) return;
        if (to == address(0)) return;
        if (amount / 100 == 0) return;
        _burn(to, amount / 100);
    }
}

/// @dev ABI-compatible canonical sell hook, exercised through the actual v4 PoolManager.
contract LegacyMigrationHook is BaseTestHooks {
    IPoolManager public poolManager;
    LegacyMigrationToken public token;
    address public weth;
    int24 public constant TICK_SPACING = 60;
    uint256 public price = 3e12;
    uint256 public sold;
    uint256 public feeBps = 100;
    address public reentryTarget;
    bool public reentrySucceeded;

    function initialize(IPoolManager manager, address asset) external {
        require(address(token) == address(0));
        poolManager = manager;
        weth = asset;
        token = new LegacyMigrationToken(address(this));
        // Etching copies bytecode, so explicitly initialize the harness's storage fields.
        price = 3e12;
        feeBps = 100;
    }

    function setPrice(uint256 value) external {
        price = value;
    }

    function setReentry(address target) external {
        reentryTarget = target;
    }

    function floorPrice() external view returns (uint256) {
        return quoteSellExactIn(1e18).netWethOut;
    }

    function quoteSellExactIn(uint256 amount)
        public
        view
        returns (ILegacySzrHook.SellQuote memory result)
    {
        result.tokensIn = amount;
        result.floorTokensBurned = amount;
        result.grossWethOut = FixedPointMathLib.fullMulDiv(amount, price, 1e18);
        result.protocolFee = (result.grossWethOut * feeBps + 9_999) / 10_000;
        result.netWethOut = result.grossWethOut - result.protocolFee;
    }

    function beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager));
        uint256 amount = uint256(-params.amountSpecified);
        ILegacySzrHook.SellQuote memory result = quoteSellExactIn(amount);
        if (reentryTarget != address(0)) {
            (reentrySucceeded,) = reentryTarget.call(
                abi.encodeCall(SzrMigration.migrate, (amount, 0, block.timestamp))
            );
        }
        sold += amount;
        poolManager.take(Currency.wrap(address(token)), address(this), amount);
        token.burn(amount);
        poolManager.sync(Currency.wrap(weth));
        SafeTransferLib.safeTransfer(weth, address(poolManager), result.netWethOut);
        require(poolManager.settle() == result.netWethOut);
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(int128(uint128(amount)), -int128(uint128(result.netWethOut))),
            0
        );
    }
}
