// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { MarketsWorld } from "../ArbitrageMarkets.t.sol";
import { TestAsset } from "./TestAsset.sol";
import { ArbitrageApi } from "../../src/arbitrage/ArbitrageApi.sol";
import { ArbitrageVault } from "../../src/vaults/ArbitrageVault.sol";
import { IMarketController } from "../../src/interfaces/IMarketController.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";

/// @dev The vault with a way to hold idle principal, which only the curator's moves will
/// make once they exist, so the pro-rata rule can be tried on it now.
contract VaultHarness is ArbitrageVault {
    constructor(
        ArbitrageApi arbitrageHook,
        uint256 marketId,
        PoolKey memory home_,
        address curator_,
        IMarketController controller_,
        uint16 feeBps_
    ) ArbitrageVault(arbitrageHook, marketId, home_, curator_, controller_, feeBps_) { }

    /// The curator's price check on its own, so its bounds can be probed.
    function checkPrice(uint160 expectedPrice) external view {
        _checkMove(expectedPrice);
    }

    /// A position as the vault keeps it, so a test can follow it through moves.
    function positionAt(uint256 index) external view returns (Position memory) {
        return positions[index];
    }

    function addIdle(uint256 amount0, uint256 amount1) external {
        _pull(token0, amount0);
        _pull(token1, amount1);
        idle0 += amount0;
        idle1 += amount1;
    }
}

/// @dev Stands in for the market's controller: it pushes everything it holds in the listed
/// tokens to its caller, which is the vault, and can be told to fail.
contract MockController {
    uint256 public calls;
    bool public broken;

    function setBroken(bool value) external {
        broken = value;
    }

    function distribute(address[] calldata tokens) external {
        require(!broken, "broken");
        calls++;
        for (uint256 index; index < tokens.length; index++) {
            uint256 held = SafeTransferLib.balanceOf(tokens[index], address(this));
            if (held != 0) SafeTransferLib.safeTransfer(tokens[index], msg.sender, held);
        }
    }
}

/// @dev The market's WETH/coin pools, `first` and `second`, with a vault whose home pool is
/// `first`.
abstract contract VaultWorld is MarketsWorld {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaultHarness internal vault;
    MockController internal mock;
    uint16 internal constant FEE_BPS = 1_000;
    address internal curator = address(0xC0A7);
    address internal token0;
    address internal token1;
    uint256 internal constant SEED_UNITS = 1_000_000e18;

    function setUp() public virtual override {
        super.setUp();
        token0 = address(backing) < address(coin) ? address(backing) : address(coin);
        token1 = address(backing) < address(coin) ? address(coin) : address(backing);
        mock = new MockController();
        vault = _makeVault(first);
        _fundVault(curator);
        _fundVault(alice);
        _fundVault(bob);
    }

    /// A vault around `home`, built from its artifact so the test contract does not carry
    /// the vault's code.
    function _makeVault(PoolKey memory home) internal returns (VaultHarness) {
        return VaultHarness(
            deployCode(
                "VaultWorld.sol:VaultHarness",
                abi.encode(hook, id, home, curator, address(mock), FEE_BPS)
            )
        );
    }

    function _fundVault(address who) internal {
        backing.mint(who, 1_000_000_000e18);
        coin.mint(who, 1_000_000_000e18);
        vm.startPrank(who);
        backing.approve(address(vault), type(uint256).max);
        coin.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// What the vault holds of an asset beyond idle principal: rewards, booked or not.
    function _surplus(address asset) internal view returns (uint256) {
        (uint256 idle0, uint256 idle1) = vault.principal();
        uint256 held = TestAsset(asset).balanceOf(address(vault));
        return held - (asset == token0 ? idle0 : idle1);
    }

    function _ranges(uint256 count) internal view returns (ArbitrageVault.Range[] memory list) {
        list = new ArbitrageVault.Range[](count);
        for (uint256 index; index < count; index++) {
            int24 reach = int24(int256(60 * (index + 1)));
            list[index] = ArbitrageVault.Range(-reach, reach);
        }
        if (count == 0) return list;
        // The first is the widest the pool allows.
        list[0].tickLower = TickMath.minUsableTick(60);
        list[0].tickUpper = TickMath.maxUsableTick(60);
    }

    function _units(uint256 count, uint256 each) internal pure returns (uint256[] memory list) {
        list = new uint256[](count);
        for (uint256 index; index < count; index++) {
            list[index] = each + index * 1e18;
        }
    }

    function _seed(uint256 count) internal {
        vm.prank(curator);
        vault.seed(
            _ranges(count),
            _units(count, SEED_UNITS),
            type(uint256).max,
            type(uint256).max,
            block.timestamp
        );
    }

    /// The liquidity the pool manager holds for one of the vault's positions.
    function _held(uint256 index) internal view returns (uint128 liquidity) {
        ArbitrageVault.Range memory range = _ranges(index + 1)[index];
        (liquidity,,) = manager.getPositionInfo(
            first.toId(), address(vault), range.tickLower, range.tickUpper, bytes32(index + 1)
        );
    }
}
