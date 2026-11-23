// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Test, console } from "forge-std/Test.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { MetricVault } from "../../src/vaults/MetricVault.sol";
import { IHookVault, IMarketController } from "../../src/interfaces/IHookVault.sol";
import { IMetricFactory } from "../../src/interfaces/metric/IMetricFactory.sol";
import {
    IMetricLiquidityPool,
    IMetricPool,
    IMetricSwapCallback,
    MetricPoolImmutables
} from "../../src/interfaces/metric/IMetricPool.sol";

/// @dev Sells and buys through a Metric pool, paying in the callback.
contract MetricSwapper is IMetricSwapCallback {
    address internal immutable weth;
    address internal immutable usdg;

    constructor(address weth_, address usdg_) {
        weth = weth_;
        usdg = usdg_;
    }

    function swap(IMetricPool pool, bool zeroForOne, int128 amount, uint128 limit)
        external
        returns (int128 amount0, int128 amount1)
    {
        return pool.swap(address(this), zeroForOne, amount, limit, "", "");
    }

    function metricOmmSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata)
        external
    {
        if (amount0Delta > 0) {
            SafeTransferLib.safeTransfer(weth, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            SafeTransferLib.safeTransfer(usdg, msg.sender, uint256(amount1Delta));
        }
    }
}

/// @dev `MetricVault` on the live WETH/USDG Metric pool of Robinhood Chain. The suite runs
/// only with a `FORK_RPC_URL`, at the latest block, and spends nothing real:
///     FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
///         forge test --match-path "test/fork/MetricVaultFork.t.sol" -vv
contract MetricVaultForkTest is Test {
    uint256 internal constant MAX = type(uint256).max;
    IMetricLiquidityPool internal constant POOL =
        IMetricLiquidityPool(0x1E8Fc442AD3606719F7016DED6C17B56C3cA7386);
    address internal constant FACTORY = 0x2a53833cc95548cf52c7b159110e22D3a9018f32;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant EOA = address(0xE0A);

    bool internal live;
    MetricVault internal vault;
    MetricSwapper internal swapper;
    address internal curator = address(0xC0);
    address internal alice = address(0xA11CE);
    int16 internal cur;

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        vault = new MetricVault(
            IMetricFactory(FACTORY), address(POOL), IMarketController(address(0)), 1000, curator
        );
        swapper = new MetricSwapper(WETH, USDG);
        address[3] memory users = [curator, alice, address(swapper)];
        for (uint256 i; i < users.length; i++) {
            deal(WETH, users[i], 1_000e18);
            deal(USDG, users[i], 5_000_000e6);
            vm.prank(users[i]);
            IERC20(WETH).approve(address(vault), MAX);
            vm.prank(users[i]);
            IERC20(USDG).approve(address(vault), MAX);
        }
        // The current bin is word 0 of slot 0 above the pause level: bits 8..23.
        cur = int16(uint16(uint256(POOL.extsload(bytes32(uint256(0)))) >> 8));
    }

    modifier onlyFork() {
        if (!live) return;
        _;
    }

    function _bins(int16 a, int16 b) internal pure returns (int16[] memory list) {
        list = new int16[](2);
        list[0] = a;
        list[1] = b;
    }

    function _bins(int16 a) internal pure returns (int16[] memory list) {
        list = new int16[](1);
        list[0] = a;
    }

    /// The current bin and the one above it: about 7% of the first and 1.6% of the second.
    function _seed() internal {
        int16[][] memory ranges = new int16[][](1);
        ranges[0] = _bins(cur, cur + 1);
        uint256[][] memory shares = new uint256[][](1);
        shares[0] = new uint256[](2);
        shares[0][0] = 1e22;
        shares[0][1] = 1e21;
        vm.prank(curator);
        vault.seed(ranges, shares, MAX, MAX, block.timestamp);
    }

    function _deposit(uint256 shares) internal returns (uint256, uint256) {
        vm.prank(alice);
        return vault.deposit(shares, MAX, MAX, block.timestamp);
    }

    function _withdraw(uint256 shares) internal returns (uint256, uint256) {
        vm.prank(alice);
        return vault.withdraw(shares, 0, 0, block.timestamp);
    }

    function _held(int16 bin) internal view returns (uint256) {
        bytes32 key = keccak256(abi.encode(address(vault), uint80(1), bin));
        return uint256(POOL.extsload(keccak256(abi.encode(key, uint256(6)))));
    }

    function testSeedReadsTheShares() public onlyFork {
        _seed();
        assertEq(vault.totalSupply(), 1.1e22);
        assertEq(vault.unitsOf(0), 1.1e22, "the sum of the bins' shares");
        assertEq(_held(cur), 1e22, "read from the live pool's storage");
        assertEq(_held(cur + 1), 1e21);
        assertEq(vault.primaryHook(), FACTORY);
        assertEq(vault.balanceOf(vault.DEAD()), vault.MINIMUM_SHARES());
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertEq(idle0 + idle1, 0);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "all of it went to the pool");
        assertEq(IERC20(USDG).balanceOf(address(vault)), 0);
    }

    function testDepositAndWithdraw() public onlyFork {
        _seed();
        (uint256 need0, uint256 need1) = vault.quoteDeposit(1e21);
        uint256 gas = gasleft();
        (uint256 paid0, uint256 paid1) = _deposit(1e21);
        console.log("deposit gas (two bins)", gas - gasleft());
        assertEq(paid0, need0, "the quote is exact against the live pool, WETH");
        assertEq(paid1, need1, "and USDG");
        assertGt(paid0, 0);
        assertGt(paid1, 0);
        assertEq(vault.balanceOf(alice), 1e21);
        assertApproxEqRel(_held(cur), 1e22 + uint256(1e22) * 1e21 / 11e21, 1e9);
        gas = gasleft();
        (uint256 out0, uint256 out1) = _withdraw(1e21);
        console.log("withdraw gas (two bins)", gas - gasleft());
        assertLe(out0, paid0, "rounding is against the user");
        assertLe(out1, paid1);
        console.log("paid, got back WETH wei", paid0, out0);
        console.log("paid, got back USDG units", paid1, out1);
        assertLe(paid0 - out0, 100, "and costs a few wei");
        assertLe(paid1 - out1, 100);
        assertEq(IERC20(WETH).balanceOf(address(vault)), 0, "nothing stays in the vault");
    }

    function testQuoteWithdrawMatchesARealWithdrawal() public onlyFork {
        _seed();
        _deposit(1e21);
        (uint256 q0, uint256 q1) = vault.quoteWithdraw(1e21);
        (uint256 out0, uint256 out1) = _withdraw(1e21);
        assertGt(out0, 0);
        assertGt(out1, 0);
        // One unit per bin per token: the vault seeds two bins.
        assertApproxEqAbs(q0, out0, 2, "WETH");
        assertApproxEqAbs(q1, out1, 2, "USDG");
    }

    /// A sale and a buy back through the pool leave its fee in the bin, so a share costs and
    /// pays more WETH, and is worth more in all.
    function testASwapThroughMetricRaisesShareValue() public onlyFork {
        _seed();
        (uint256 paid0, uint256 paid1) = _deposit(1e21);
        (uint256 before0,) = vault.quoteDeposit(1e21);
        vm.prank(EOA, EOA);
        (, int128 got) = swapper.swap(IMetricPool(address(POOL)), true, 1e18, 0);
        assertLt(got, 0, "the sale paid out USDG");
        vm.prank(EOA, EOA);
        swapper.swap(IMetricPool(address(POOL)), false, -got, type(uint128).max);
        (uint256 after0, uint256 after1) = vault.quoteDeposit(1e21);
        console.log("quote WETH before, after", before0, after0);
        console.log("quote USDG before, after", paid1, after1);
        assertGt(after0, before0, "a share costs more WETH");
        (uint256 out0, uint256 out1) = _withdraw(1e21);
        assertGt(out0, paid0, "and pays more WETH");
        // The mix shifts a little with the trade, so value both sides at the sale's price.
        uint256 price = uint256(uint128(-got));
        assertGt(out0 * price / 1e18 + out1, paid0 * price / 1e18 + paid1, "worth more");
        assertEq(vault.earned(alice, WETH), 0, "earnings are in the bins, not rewards");
    }

    function testRefusesAPoolWithAnExtensionOnRemoval() public onlyFork {
        MetricPoolImmutables memory imm = POOL.getImmutables();
        assertEq(imm.beforeRemoveLiquidityOrder, 0, "the live pool runs none on removal");
        assertEq(imm.afterRemoveLiquidityOrder, 0);
        imm.beforeRemoveLiquidityOrder = 2;
        vm.mockCall(
            address(POOL),
            abi.encodeCall(IMetricLiquidityPool.getImmutables, ()),
            abi.encode(imm)
        );
        vm.expectRevert(MetricVault.BlockingExtension.selector);
        new MetricVault(
            IMetricFactory(FACTORY), address(POOL), IMarketController(address(0)), 1000, curator
        );
    }

    /// Part of the second bin moves up to a new bin, which takes WETH only, as the second
    /// does. The WETH not needed stays as idle principal.
    function testRebalanceOnTheLivePool() public onlyFork {
        _seed();
        vm.prank(curator);
        vault.addPosition(_bins(cur + 2));
        MetricVault.Change[] memory list = new MetricVault.Change[](2);
        list[0] = MetricVault.Change(0, 1, -1e21);
        list[1] = MetricVault.Change(1, 0, 0.9e21);
        uint256 total0 = IERC20(WETH).balanceOf(address(POOL));
        vm.prank(curator);
        vault.rebalance(list, 0, 0, block.timestamp);
        assertEq(_held(cur + 1), 0, "the second bin is empty");
        assertEq(vault.unitsOf(1), 0.9e21);
        (uint256 idle0, uint256 idle1) = vault.principal();
        assertGt(idle0, 0, "WETH left over is idle principal");
        assertEq(idle1, 0);
        assertEq(IERC20(WETH).balanceOf(address(vault)), idle0);
        assertLt(IERC20(WETH).balanceOf(address(POOL)), total0, "the pool holds less WETH");
        vm.prank(curator);
        vm.expectRevert(MetricVault.RebalanceTooSoon.selector);
        vault.rebalance(list, 0, 0, block.timestamp);
        // Everyone can still leave, with the idle part too.
        _deposit(1e21);
        (uint256 out0,) = _withdraw(1e21);
        assertGt(out0, 0);
    }

    function testPausingThePoolDoesNotBlockAWithdrawal() public onlyFork {
        _seed();
        _deposit(1e21);
        // Pause level 2 stops swaps; adding and removing are not gated by it (P5).
        uint256 raw = uint256(POOL.extsload(bytes32(uint256(0))));
        vm.store(address(POOL), bytes32(uint256(0)), bytes32((raw & ~uint256(0xff)) | 2));
        vm.prank(EOA, EOA);
        vm.expectRevert();
        swapper.swap(IMetricPool(address(POOL)), true, 1e18, 0);
        (uint256 out0, uint256 out1) = _withdraw(1e21);
        assertGt(out0 + out1, 0);
    }
}
