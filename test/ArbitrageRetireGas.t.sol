// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { BlockableAsset } from "./ArbitrageClaims.t.sol";
import { WrappingAsset } from "./utils/ArbitrageNative.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageHook } from "../src/ArbitrageHook.sol";
import { Liquidity } from "../src/Liquidity.sol";
import { CyclePart } from "../src/arbitrage/ArbitrageCycle.sol";
import { ArbitrageApi } from "../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev The Cycle module with a `retire` that first picks the market and token to pay in,
/// from two slots of the hook's storage, since both are transient and a test cannot set them.
/// Everything after that is the module's own `_retire`.
contract MeterCycle is CyclePart {
    uint256 internal constant SLOT = 0xC0FFEE;

    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }

    function retire(uint256 profit) external override onlySelf {
        uint256 market;
        uint256 base;
        assembly {
            market := sload(SLOT)
            base := sload(add(SLOT, 1))
        }
        active = market;
        home = address(uint160(base));
        _retire(profit);
        active = 0;
        home = address(0);
    }

    function reserve() external pure returns (uint256) {
        return RETIRE_GAS;
    }
}

/// @dev Owes the hook `profit` of `asset` inside an unlock, makes the accounts cold, then
/// has the hook retire it by calling itself, which is the path a search takes.
contract RetireMeter is IUnlockCallback {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    IPoolManager internal immutable manager;
    ArbitrageHook internal immutable hook;

    constructor(IPoolManager poolManager, ArbitrageHook target) payable {
        manager = poolManager;
        hook = target;
    }

    function measure(address asset, uint256 profit, address[] calldata cold)
        external
        returns (uint256)
    {
        return abi.decode(manager.unlock(abi.encode(asset, profit, cold)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address asset, uint256 profit, address[] memory cold) =
            abi.decode(data, (address, uint256, address[]));
        if (asset == address(0)) {
            manager.settleFor{ value: profit }(address(hook));
        } else {
            manager.sync(Currency.wrap(asset));
            TestAsset(asset).transfer(address(manager), profit);
            manager.settleFor(address(hook));
        }
        for (uint256 index; index < cold.length; index++) {
            VM.cool(cold[index]);
        }
        VM.cool(address(hook));
        VM.cool(hook.cycleModule());
        VM.prank(address(hook));
        uint256 start = gasleft();
        ArbitrageApi(payable(address(hook))).retire(profit);
        return abi.encode(start - gasleft());
    }
}

/// @dev What retiring a profit costs through the real split hook, cold and with the hop,
/// against the gas a search holds back for it (`RETIRE_GAS`). Each call to the hook's own
/// module keeps back a 64th, twice over, so the cost is scaled by (64/63)^2 before it is
/// compared with the reserve.
contract ArbitrageRetireGasTest is MarketsWorld {
    uint256 internal constant SLOT = 0xC0FFEE;

    function _fits(uint256 used, string memory what) internal {
        uint256 reserve =
            MeterCycle(ArbitrageHook(payable(address(hook))).cycleModule()).reserve();
        uint256 scaled = used * 64 * 64 / (63 * 63);
        emit log_named_uint(what, used);
        emit log_named_uint("  with the holdbacks", scaled);
        emit log_named_uint("  RETIRE_GAS", reserve);
        assertLt(scaled, reserve, "fits");
    }

    function _meter(uint256 market, address base, address asset, uint256 profit)
        internal
        returns (uint256)
    {
        address cycle = ArbitrageHook(payable(address(hook))).cycleModule();
        vm.etch(cycle, address(new MeterCycle(hook.liquidity())).code);
        vm.store(address(hook), bytes32(SLOT), bytes32(market));
        vm.store(address(hook), bytes32(SLOT + 1), bytes32(uint256(uint160(base))));
        RetireMeter meter = new RetireMeter{ value: asset == address(0) ? profit : 0 }(
            manager, ArbitrageHook(payable(address(hook)))
        );
        if (asset != address(0)) TestAsset(asset).transfer(address(meter), profit);
        address[] memory cold = new address[](5);
        cold[0] = asset;
        cold[1] = hook.shareRecipient(base);
        cold[2] = hook.market(market).recipient;
        cold[3] = address(backing);
        cold[4] = address(core);
        return meter.measure(asset, profit, cold);
    }

    function testEthPayoutFitsTheReserveThroughTheHook() public {
        // The world's WETH has no `deposit()`; the real one does.
        vm.etch(address(backing), address(new WrappingAsset()).code);
        hook.setProfitToken(address(0), desk);
        _fits(_meter(id, address(0), address(0), 1e18), "ETH payout gas");
        assertGt(backing.balanceOf(desk), 0, "paid");
    }

    function testClaimsFallbackFitsTheReserveThroughTheHook() public {
        BlockableAsset ink = new BlockableAsset();
        _approve(ink);
        hook.setProfitToken(address(ink), desk);
        ink.setBlocked(desk, true);
        ink.mint(address(this), 1e18);
        _fits(_meter(id, address(ink), address(ink), 1e18), "claims fallback gas");
        assertGt(manager.balanceOf(desk, uint256(uint160(address(ink)))), 0, "claim held");
    }

    function testSzrRetireFitsTheReserveThroughTheHook() public {
        uint256 inventory = core.unreleasedSupply();
        _fits(_meter(1, hook.token(), hook.token(), 1e18), "SZR take and donate gas");
        assertGt(core.unreleasedSupply(), inventory, "retired");
    }
}
