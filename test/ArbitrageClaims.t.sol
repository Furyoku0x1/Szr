// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Vm } from "forge-std/Vm.sol";
import { MarketsWorld } from "./ArbitrageMarkets.t.sol";
import { TestAsset } from "./utils/TestAsset.sol";
import { ArbitrageProbe } from "./utils/ArbitrageProbe.sol";
import { ArbitrageLogic } from "../src/arbitrage/ArbitrageLogic.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";

/// @dev A token with a blocklist: it refuses to send to a blocked address.
contract BlockableAsset is TestAsset {
    mapping(address => bool) public blocked;

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function _beforeTokenTransfer(address, address to, uint256) internal view override {
        require(!blocked[to], "blocked");
    }
}

/// @dev Redeems a claim for the token, and measures a payout that falls back to a claim.
contract ClaimHelper is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager poolManager) {
        manager = poolManager;
    }

    /// `owner` must have made this contract an operator.
    function redeem(address owner, address asset, uint256 amount) external {
        manager.unlock(abi.encode(uint8(0), owner, asset, amount, address(0), uint256(0)));
    }

    /// Owes the probe `profit` of `asset` inside an unlock, then pays it out.
    function measure(ArbitrageProbe probe, uint256 market, address asset, uint256 profit)
        external
        returns (uint256 used, uint256 reserved)
    {
        bytes memory result = manager.unlock(
            abi.encode(uint8(1), address(0), asset, profit, address(probe), market)
        );
        return abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (
            uint8 kind,
            address owner,
            address asset,
            uint256 amount,
            address probe,
            uint256 market
        ) = abi.decode(data, (uint8, address, address, uint256, address, uint256));
        Currency currency = Currency.wrap(asset);
        if (kind == 0) {
            manager.burn(owner, uint256(uint160(asset)), amount);
            manager.take(currency, owner, amount);
            return "";
        }
        manager.sync(currency);
        TestAsset(asset).transfer(address(manager), amount);
        manager.settleFor(probe);
        (uint256 used, uint256 reserved) =
            ArbitrageProbe(payable(probe)).tokenPayoutCost(market, asset, amount);
        return abi.encode(used, reserved);
    }
}

/// @dev When the protocol's recipient cannot receive a profit token, its share becomes a
/// claim with the pool manager and the search goes on.
contract ArbitrageClaimsTest is MarketsWorld {
    BlockableAsset internal ink;
    PoolKey internal inkPool;
    PoolKey internal inkCheap;

    function setUp() public override {
        super.setUp();
        ink = new BlockableAsset();
        _approve(ink);
        hook.setProfitToken(address(ink), desk);
        // Three tokens let a swap open three books, which needs a larger allowance first.
        uint128 profit = hook.minimumProfit(id, address(backing));
        vm.prank(team);
        hook.setLimits(id, address(backing), 30_000_000, profit, 1.0001e18);
        _choose(id, address(ink));
        inkPool = _create(address(ink), address(coin), 3_000);
        inkCheap = _create(address(ink), address(coin), 500);
        _lead(address(ink), address(coin), _list(_id(inkPool), _id(inkCheap)));
        _limits(address(ink), 1e15);
    }

    function _choose(uint256 market, address token) internal {
        address[] memory list = new address[](3);
        list[0] = token;
        list[1] = address(backing);
        list[2] = address(usd);
        vm.startPrank(team);
        hook.setMinimumProfit(market, token, 1e15);
        hook.setMinimumProfit(market, address(backing), 1e15);
        hook.setMinimumProfit(market, address(usd), 1e15);
        hook.setTokens(market, list);
        vm.stopPrank();
    }

    function _claim(address who) internal view returns (uint256) {
        return manager.balanceOf(who, uint256(uint160(address(ink))));
    }

    /// Counts the payouts and held shares in the recorded logs.
    function _logged()
        internal
        returns (uint256 paid, uint256 shares, uint256 held, uint256 undone)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 index; index < logs.length; index++) {
            bytes32 topic = logs[index].topics[0];
            if (topic == ArbitrageLogic.SearchUndone.selector) undone++;
            if (topic == ArbitrageLogic.ShareHeld.selector) {
                held += abi.decode(logs[index].data, (uint256));
                assertEq(logs[index].topics[1], bytes32(uint256(uint160(address(ink)))));
                assertEq(logs[index].topics[2], bytes32(uint256(uint160(desk))));
            }
            if (topic != ArbitrageLogic.ProfitPaid.selector) continue;
            (uint256 amount, uint256 share) = abi.decode(logs[index].data, (uint256, uint256));
            paid += amount;
            shares += share;
        }
    }

    function _assertEmpty() internal view {
        assertEq(ink.balanceOf(address(hook)), 0, "hook ink");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(ink)))), 0, "claims");
        _assertHookEmpty();
    }

    function testBlockedProtocolRecipientIsCreditedAClaim() public {
        ink.setBlocked(desk, true);
        vm.recordLogs();
        _trade(inkPool, address(coin), 50_000e18);
        (uint256 paid, uint256 shares, uint256 held, uint256 undone) = _logged();
        assertGt(paid, 0, "gap closed");
        assertEq(undone, 0, "nothing undone");
        assertEq(held, shares, "ShareHeld and ProfitPaid agree");
        assertEq(_claim(desk), shares, "claim is the protocol's share");
        assertEq(ink.balanceOf(desk), 0, "nothing sent");
        assertEq(ink.balanceOf(treasury), paid - shares, "market paid in full");
        _assertThirty(shares, paid);
        _assertEmpty();
    }

    function testClaimIsRedeemedOnceUnblocked() public {
        ink.setBlocked(desk, true);
        _trade(inkPool, address(coin), 50_000e18);
        uint256 amount = _claim(desk);
        assertGt(amount, 0, "claim held");
        ClaimHelper helper = new ClaimHelper(manager);
        vm.prank(desk);
        manager.setOperator(address(helper), true);
        ink.setBlocked(desk, false);
        helper.redeem(desk, address(ink), amount);
        assertEq(ink.balanceOf(desk), amount, "token received");
        assertEq(_claim(desk), 0, "claim spent");
    }

    function testUnblockedRecipientIsPaidAsBefore() public {
        vm.recordLogs();
        _trade(inkPool, address(coin), 50_000e18);
        (uint256 paid, uint256 shares, uint256 held,) = _logged();
        assertGt(paid, 0, "gap closed");
        assertEq(held, 0, "nothing held");
        assertEq(_claim(desk), 0, "no claim");
        assertEq(ink.balanceOf(desk), shares, "paid in the token");
        _assertEmpty();
    }

    /// Core cannot redeem a claim, so a failing send to it undoes the search instead.
    /// `setProfitToken` now refuses Core for a token that is not ETH or WETH, which Core could
    /// never use, so the recipient is stored directly (`shareRecipient` is slot 0) to keep
    /// the payout's Core branch covered.
    function testBlockedCoreRecipientUndoesTheSearch() public {
        vm.expectRevert(ArbitrageLogic.InvalidPool.selector);
        hook.setProfitToken(address(ink), address(core));
        vm.store(
            address(hook),
            keccak256(abi.encode(address(ink), uint256(0))),
            bytes32(uint256(uint160(address(core))))
        );
        ink.setBlocked(address(core), true);
        vm.recordLogs();
        _trade(inkPool, address(coin), 50_000e18);
        (uint256 paid,, uint256 held, uint256 undone) = _logged();
        assertGt(undone, 0, "search undone");
        assertEq(paid, 0, "nothing paid");
        assertEq(held, 0, "nothing held");
        assertEq(_claim(address(core)), 0, "no claim for Core");
        assertEq(ink.balanceOf(treasury), 0, "market not paid");
        _assertEmpty();
    }

    function testBlockedMarketRecipientUndoesTheSearch() public {
        ink.setBlocked(treasury, true);
        vm.recordLogs();
        _trade(inkPool, address(coin), 50_000e18);
        (uint256 paid,, uint256 held, uint256 undone) = _logged();
        assertGt(undone, 0, "search undone");
        assertEq(paid, 0, "nothing paid");
        assertEq(held, 0, "nothing held");
        assertEq(_claim(desk), 0, "no claim");
        assertEq(ink.balanceOf(desk), 0, "protocol not paid");
        assertEq(ink.balanceOf(treasury), 0, "market not paid");
        _assertEmpty();
    }

    /// The fallback's failing `take` and its `mint` fit in the gas a search holds back.
    function testFallbackFitsInTheRetireReserve() public {
        address probeAt = address(uint160(0xA4B2 << 24 | 1 << 7 | 1 << 6));
        deployCodeTo("ArbitrageProbe.sol:ArbitrageProbe", abi.encode(locker), probeAt);
        ArbitrageProbe probe = ArbitrageProbe(payable(probeAt));
        address owner = address(0xC01D2);
        probe.setProfitToken(address(ink), desk);
        vm.prank(team);
        uint256 market = probe.openMarket(owner);
        ink.setBlocked(desk, true);
        uint256 profit = 1e18;
        ClaimHelper helper = new ClaimHelper(manager);
        ink.mint(address(helper), profit);
        vm.cool(desk);
        vm.cool(owner);
        vm.cool(address(ink));
        (uint256 used, uint256 reserved) = helper.measure(probe, market, address(ink), profit);
        emit log_named_uint("fallback payout gas", used);
        emit log_named_uint("RETIRE_GAS", reserved);
        assertLt(used, reserved, "fits");
        assertEq(_claim(desk), (profit * 30 + 99) / 100, "claim");
        assertEq(ink.balanceOf(owner), profit - (profit * 30 + 99) / 100, "market paid");
    }

    function testOtherMarketsCountingInTheTokenAreUnaffected() public {
        address other = address(0xA11CE);
        vm.prank(team);
        uint256 rival = hook.openMarket(other);
        _choose(rival, address(ink));
        uint256 original = id;
        id = rival;
        PoolKey memory mine = _create(address(ink), address(coin), 3_060);
        PoolKey memory mineToo = _create(address(ink), address(coin), 510);
        _lead(address(ink), address(coin), _list(_id(mine), _id(mineToo)));
        _limits(address(ink), 1e15);
        id = original;
        ink.setBlocked(desk, true);
        vm.recordLogs();
        _trade(mine, address(coin), 50_000e18);
        (uint256 paid, uint256 shares, uint256 held, uint256 undone) = _logged();
        assertGt(paid, 0, "second market closed its gap");
        assertEq(undone, 0, "nothing undone");
        assertEq(ink.balanceOf(other), paid - shares, "its owner paid in the token");
        assertEq(_claim(desk), held, "protocol holds a claim");
        assertEq(held, shares);
        _assertEmpty();
    }
}
