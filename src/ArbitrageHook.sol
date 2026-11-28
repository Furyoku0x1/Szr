// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { Liquidity } from "./Liquidity.sol";
import { ArbitrageLogic } from "./arbitrage/ArbitrageLogic.sol";
import { EntryPart } from "./arbitrage/ArbitrageEntry.sol";
import { SearchPart } from "./arbitrage/ArbitrageSearch.sol";
import { SearchManyPart } from "./arbitrage/ArbitrageSearchMany.sol";
import { CyclePart } from "./arbitrage/ArbitrageCycle.sol";
import { SizerPart } from "./arbitrage/ArbitrageSizer.sol";

/// @notice One hook shared by every pool created with it. Around each swap it closes
/// price gaps between that pool and the other pools of its market. SZR's market retires
/// the SZR it earns. Anyone can open a market for their own token; it counts profit in
/// tokens its owner chose from the ones Liquidity's manager approved (native ETH included,
/// which is paid out as WETH), `PROTOCOL_SHARE` percent to the protocol and the rest to the
/// market.
/// @dev "SZR" below stands for the profit token of the search being run: SZR in SZR's
/// market, one of the market's chosen tokens in every other.
/// @dev A pool on a hook that Liquidity's manager has given a pricer (a wrapped pool, one
/// that fills trades somewhere other than the pool manager) can be a venue or connecting
/// pool. Markets that use one reserve more gas, and each cycle is checked for leaving
/// nothing owed.
/// @dev `arb` searches one pool without a swap and `sweep` searches the head of every group
/// of a market, which reaches the hookless pools `arb` cannot name in outside markets.
/// @dev Pools are grouped by partner token, and each group has a few leaders. A swap's pool
/// is compared with the leaders of its own group, the first leader of every other group,
/// and Core, so the cost of a search does not grow with the number of pools tracked.
/// @dev It searches twice per swap. Before the swap trades it closes any gap already open,
/// so the swap executes at the aligned price and cannot collect that gap. After the swap it
/// closes the gap the swap itself opened.
/// @dev A cycle starts and ends in SZR: sell SZR at one venue, cross up to two connecting
/// pools, buy SZR back at another. One of the two venues is always the pool being searched.
/// Core's `redeem` is a sell-only venue paying NAV in WETH, in SZR's market only. v4 flash
/// accounting funds every cycle, so the hook holds no balance between transactions; profit
/// goes to `donateSzr` in SZR's market and is paid out in the other markets.
/// @dev In a market that counts in ETH or WETH, a cycle can also cross between the two
/// through the wrap link, a one-for-one deposit or withdraw of WETH, and a venue can be a
/// pool on the other ether token. The search reads the groups under both tokens, and a
/// cycle that ends on a venue holding the twin converts at the end so it still ends in the
/// token counted.
/// @dev A failed or unprofitable attempt reverts inside a caught self-call and does not fail
/// the swap that triggered it. Running out of gas is the exception: a swap sent with too
/// little gas for any cycle reverts as a whole, so gas estimates include the cycles. Once a
/// cycle has succeeded the search holds gas back and stops early instead. The other
/// exception is a pool manager short of a token the hook must take before a swap: whoever
/// controls the current unlock can borrow its whole balance, so the swap reverts with
/// `Drained` rather than letting that skip a gap. After a swap a shortage is not proof of a
/// drain (the swapper's own input may be owed and not yet paid), so that search is undone
/// and the swap goes on. The drain rule has a known limit. Any debit left unpaid earlier in
/// the same unlock (a multi-hop route, two swaps settled together at the end, an
/// exact-output route, adding liquidity and then swapping) can make the pool manager look
/// short before a later swap. Such a swap must pay first or be split. In that state more
/// gas can fail a swap that less gas passes, because a search with more gas reaches a
/// further cycle that meets the shortage. So "more gas never makes a swap fail" holds when
/// nothing earlier in the unlock is unpaid. It holds for each hooked swap, not for a whole
/// transaction: a transaction with several hooked swaps spends its gas across their searches,
/// and the rule is promised only for ordinary pools.
/// v4 skips hook callbacks for the hook's own swaps.
/// @dev The code is split over this contract and four modules, so that each fits the
/// 24,576 bytes many chains allow. This contract holds all the state and the address the pool
/// manager knows. What it does not carry itself it reaches by delegatecall, so the modules'
/// code runs on this contract's storage, with its address, balances and logs. The module
/// addresses are immutable: nothing can change them. See `docs/specs/hook-split.md`.
contract ArbitrageHook is EntryPart {
    /// @notice The modules, one per group of entry points. `searchMany` has its own to keep
    /// every module under the 24,576-byte limit.
    address public immutable searchModule;
    address public immutable manyModule;
    address public immutable cycleModule;
    address public immutable sizerModule;
    address public immutable adminModule;

    error ModuleMismatch();

    constructor(
        Liquidity treasury,
        address search,
        address many,
        address cycle,
        address sizer,
        address admin
    ) ArbitrageLogic(treasury) {
        if (uint160(address(this)) & PERMISSION_MASK != SWAP_HOOKS) {
            revert InvalidHookAddress();
        }
        // A module built on another Liquidity would read other immutables than this hook.
        if (address(ArbitrageLogic(search).liquidity()) != address(treasury)) {
            revert ModuleMismatch();
        }
        if (address(ArbitrageLogic(many).liquidity()) != address(treasury)) {
            revert ModuleMismatch();
        }
        if (address(ArbitrageLogic(cycle).liquidity()) != address(treasury)) {
            revert ModuleMismatch();
        }
        if (address(ArbitrageLogic(sizer).liquidity()) != address(treasury)) {
            revert ModuleMismatch();
        }
        if (address(ArbitrageLogic(admin).liquidity()) != address(treasury)) {
            revert ModuleMismatch();
        }
        searchModule = search;
        manyModule = many;
        cycleModule = cycle;
        sizerModule = sizer;
        adminModule = admin;
        _initialise();
    }

    /// @dev Sends every call that is not one of this contract's own to the module that has
    /// its code, with all the gas left, and hands back what it returned or why it reverted.
    /// `msg.sender` is unchanged, so `onlySelf` still means this contract calling itself.
    fallback() external {
        address module = _moduleFor(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), module, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    function _moduleFor(bytes4 sig) internal view returns (address) {
        if (sig == SearchPart.search.selector) return searchModule;
        if (sig == SearchManyPart.searchMany.selector) return manyModule;
        if (sig == SearchPart.unlockCallback.selector) return searchModule;
        if (sig == CyclePart.execute.selector) return cycleModule;
        if (sig == CyclePart.retire.selector) return cycleModule;
        if (sig == SizerPart.size.selector) return sizerModule;
        if (sig == SizerPart.ahead.selector) return sizerModule;
        return adminModule;
    }
}
