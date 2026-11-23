// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev Every other external function: the setters and the views.
abstract contract AdminPart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice Approves `asset` as a token profit may be counted in, with the address the
    /// protocol's share of it is sent to, or changes that address. A zero `recipient` takes
    /// it off: it stops being paid out at once, and pools counting in it are not
    /// arbitraged until it is approved (and chosen) again; nothing needs re-tracking.
    /// @dev Core can only count WETH, so any other token needs a recipient of its own.
    /// Native ETH (`address(0)`) is the exception: its share is paid out as WETH, so Core
    /// can be its recipient. ETH and WETH are approved separately, and taking WETH off does
    /// not stop ETH profit, which is still paid as WETH.
    /// @dev Never approve a token that calls its receiver on transfer: paying it out would
    /// run that receiver's code in the middle of a search. Never approve a token whose
    /// balances can fall on their own (rebasing, fee on transfer): the pool manager would
    /// look drained, and swaps that close a gap in it would fail.
    function setProfitToken(address asset, address recipient) external onlyOwner(SZR_MARKET) {
        // SZR is counted only in its own market.
        if (asset == token) revert InvalidPool();
        if (recipient == address(this)) revert InvalidPool();
        // Credits to the pool manager itself would be surplus nobody can claim.
        if (recipient == address(poolManager)) revert InvalidPool();
        // Core can only count WETH, so any other token sent to it would be locked there.
        if (recipient == address(core)) {
            if (asset != address(0)) {
                if (asset != backingAsset) revert InvalidPool();
            }
        }
        shareRecipient[asset] = recipient;
        emit ProfitTokenSet(asset, recipient);
    }

    /// @notice Replaces the tokens a market counts profit in, most preferred first. Each
    /// must be approved now. A pool keeps the token picked when it was tracked; a token
    /// dropped here idles its pools until it is chosen again.
    function setTokens(uint256 id, address[] calldata assets) external onlyOwner(id) {
        if (id == SZR_MARKET) revert InvalidPool();
        if (assets.length > MAX_PROFIT_TOKENS) revert InvalidLimit();
        address[] storage old = chosen[id];
        for (uint256 index; index < old.length; index++) {
            delete rankIn[id][old[index]];
        }
        delete chosen[id];
        for (uint256 index; index < assets.length; index++) {
            address asset = assets[index];
            if (shareRecipient[asset] == address(0)) revert InvalidPool();
            if (rankIn[id][asset] != 0) revert InvalidPool();
            rankIn[id][asset] = uint8(index + 1);
            chosen[id].push(asset);
        }
        _requireWorkable(id, markets[id].gasLimit);
        _requireMinimums(id);
        emit TokensSet(id, assets);
    }

    function tokensOf(uint256 id) external view returns (address[] memory) {
        return chosen[id];
    }

    /// @notice Opens a market owned by the caller. Anyone can. It starts switched off;
    /// create its pools, name leaders, then call `setLimits`.
    /// @dev Every cycle in it starts and ends in a token it has chosen (WETH to begin with),
    /// so its profit is counted on balances in a token its owner cannot price, and the hook
    /// holds nothing between transactions.
    function openMarket(address recipient) external returns (uint256 id) {
        _requireRecipient(recipient);
        id = ++marketCount;
        // A pool records its market in 32 bits.
        if (id > type(uint32).max) revert TooManyMarkets();
        Settings storage own = markets[id];
        own.owner = msg.sender;
        own.recipient = recipient;
        own.edge = uint56(1.0001e18 / EDGE_UNIT);
        // Chosen whether or not WETH is approved at this moment.
        chosen[id].push(backingAsset);
        rankIn[id][backingAsset] = 1;
        emit MarketOpened(id, msg.sender);
    }

    function setRecipient(uint256 id, address recipient) external onlyOwner(id) {
        _requireRecipient(recipient);
        markets[id].recipient = recipient;
        emit RecipientSet(id, recipient);
    }

    /// @notice Names the address that may take a market over. SZR's market always belongs
    /// to Liquidity's manager.
    function nominateOwner(uint256 id, address nominee) external onlyOwner(id) {
        if (id == SZR_MARKET) revert InvalidPool();
        Settings storage own = markets[id];
        own.nominee = nominee;
        own.nominatedAt = nominee == address(0) ? 0 : uint40(block.timestamp);
        emit OwnerNominated(id, nominee);
    }

    function acceptOwnership(uint256 id) external {
        if (active != 0) revert Busy();
        Settings storage own = markets[id];
        if (own.nominee == address(0)) revert NotManager();
        if (msg.sender != own.nominee) revert NotManager();
        if (block.timestamp > own.nominatedAt + NOMINATION_WINDOW) revert NominationExpired();
        own.owner = msg.sender;
        own.nominee = address(0);
        own.nominatedAt = 0;
        emit OwnerSet(id, msg.sender);
    }

    /// @notice Creates a pool on this hook and adds it to the caller's market. This is the
    /// only way a pool on this hook joins a market other than SZR's, so nobody can claim a
    /// pool someone else created.
    function createPool(uint256 id, PoolKey calldata pool, uint160 sqrtPriceX96)
        external
        onlyOwner(id)
    {
        if (id == SZR_MARKET) revert InvalidPool();
        if (address(pool.hooks) != address(this)) revert InvalidPool();
        // A dynamic-fee pool takes its fee from its hook, and this hook never sets one, so
        // such a pool on this hook would trade for nothing for ever.
        if (pool.fee >= 1e6) revert InvalidPool();
        _requireOutside(pool);
        poolManager.initialize(pool, sqrtPriceX96);
        bytes32 poolId = PoolId.unwrap(pool.toId());
        (address pick, bool picked) = _pick(id, pool);
        pools[poolId] = Pool(uint32(id), uint32(id), pick, picked);
        _track(id, pool, poolId);
    }

    /// @notice Adds a pool to trade against to the caller's market: one that runs no hook,
    /// or one on a hook that has a pricer. Any market can add the same one; it is never
    /// searched on its own swaps.
    /// @dev SZR's own pools come from Liquidity. The one kind added here is a pool holding
    /// SZR on a hook with a pricer, for SZR that trades on another exchange.
    function addVenue(uint256 id, PoolKey calldata pool) external onlyOwner(id) {
        bool priced = pricers[address(pool.hooks)] != address(0);
        if (id == SZR_MARKET) {
            if (!priced) revert InvalidPool();
            if (_other(pool, token) == Currency.unwrap(pool.currency0)) {
                if (Currency.unwrap(pool.currency1) != token) revert InvalidPool();
            }
        }
        if (id != SZR_MARKET) {
            _requireOutside(pool);
            if (address(pool.hooks) != address(0)) {
                if (!priced) revert NotTrusted();
            }
        }
        bytes32 poolId = PoolId.unwrap(pool.toId());
        _track(id, pool, poolId);
        if (priced) _wrap(id, address(pool.hooks), poolId);
    }

    /// @notice Tracks again a pool that was created in a market and then untracked.
    function retrack(bytes32 poolId) external {
        if (active != 0) revert Busy();
        uint256 id = pools[poolId].origin;
        if (id <= SZR_MARKET) revert UnknownPool();
        if (msg.sender != _owner(id)) revert NotManager();
        PoolKey memory pool = keys[poolId];
        (address pick, bool picked) = _pick(id, pool);
        pools[poolId] = Pool(uint32(id), uint32(id), pick, picked);
        _track(id, pool, poolId);
    }

    /// @notice A market's settings.
    function market(uint256 id) external view returns (Market memory) {
        Settings memory own = markets[id];
        return Market(
            own.owner,
            own.gasLimit,
            uint64(own.edge * EDGE_UNIT),
            own.recipient,
            own.poolCount,
            own.nominee,
            uint32(own.ask * ASK_UNIT)
        );
    }

    /// @notice Pairs a hook that fills trades somewhere other than the pool manager with
    /// the contract that prices its pools, or takes the pairing away with a zero pricer.
    /// Taking it away stops every pool on that hook being traded at once.
    /// @dev Like a profit token, a token a wrapped pool trades must not rebase or take a fee
    /// on transfer: the hook asks the pool manager's balance of the input of each wrapped leg
    /// (see `_legLimit`), and a token that reports less than it holds fails swaps before a
    /// search in any market that routes through it.
    /// A pool whose hook's pricer is taken away later stays listed, which keeps the market's
    /// `ask` above zero and its guards on, until the market's owner clears the pool with
    /// `setConnector`. It reads "no price" and is never planned until a pricer is set for the
    /// hook again.
    function setPricer(address wrapper, address pricer) external onlyOwner(SZR_MARKET) {
        if (wrapper == address(0)) revert InvalidPool();
        if (wrapper == address(this)) revert InvalidPool();
        pricers[wrapper] = pricer;
        emit PricerSet(wrapper, pricer);
    }

    /// @notice The wrapped pools a market's searches ask the pricers about, once each.
    function wrappedPools(uint256 id) external view returns (bytes32[] memory) {
        return wrappedIn[id];
    }

    /// @notice Sets the gas a pricer gets for one answer in a market that uses pools
    /// priced by one. More lets a pricer do more work, and has more reserved for every
    /// search, so the gas allowance is checked again.
    function setPricerGas(uint256 id, uint32 gas) external onlyOwner(id) {
        if (markets[id].ask == 0) revert InvalidLimit();
        uint256 units = (uint256(gas) + ASK_UNIT - 1) / ASK_UNIT;
        if (units == 0) revert InvalidLimit();
        if (units > type(uint8).max) revert InvalidLimit();
        markets[id].ask = uint8(units);
        _requireWorkable(id, markets[id].gasLimit);
        emit PricerGasSet(id, uint32(units * ASK_UNIT));
    }

    /// @notice Starts pricing the pool behind one of Liquidity's positions, in SZR's market.
    function track(uint256 id) external onlyOwner(SZR_MARKET) {
        Liquidity.Position memory entry = liquidity.position(id);
        bytes32 poolId = PoolId.unwrap(entry.key.toId());
        address wrapper = address(entry.key.hooks);
        // Another hook could do anything in the middle of a cycle, so a pool on one is only
        // priced once Liquidity's manager has given that hook a pricer.
        if (wrapper != address(0)) {
            if (wrapper != address(this)) {
                if (pricers[wrapper] == address(0)) revert NotTrusted();
            }
        }
        if (wrapper == address(this)) {
            if (entry.key.fee >= 1e6) revert InvalidPool();
            pools[poolId] = Pool(uint32(SZR_MARKET), uint32(SZR_MARKET), token, true);
        }
        _track(SZR_MARKET, entry.key, poolId);
        if (pricers[wrapper] != address(0)) _wrap(SZR_MARKET, wrapper, poolId);
    }

    /// @notice Stops a market pricing a pool. A leader has to be replaced first.
    function untrack(uint256 id, bytes32 poolId) external onlyOwner(id) {
        if (!tracked[id][poolId]) revert UnknownPool();
        PoolKey memory pool = keys[poolId];
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        // It can lead with either of its tokens as the one profit is counted in.
        if (_leads(id, lower, higher, poolId)) revert StillLeader();
        if (_leads(id, higher, lower, poolId)) revert StillLeader();
        tracked[id][poolId] = false;
        markets[id].poolCount--;
        if (pools[poolId].market == id) pools[poolId].market = 0;
        _unlist(id, poolId);
        emit PoolUntracked(id, poolId);
    }

    /// @notice Names the leaders among a market's pools that pair `base`, a token profit is
    /// counted in, with `partner`: its deepest such pools, deepest first. The first is what
    /// every other group is compared against, so it should be the pool hardest to move. An
    /// empty list removes the group.
    function setLeaders(uint256 id, address base, address partner, bytes32[] calldata poolIds)
        external
        onlyOwner(id)
    {
        if (poolIds.length > MAX_LEADERS) revert TooManyLeaders();
        // The gas allowance is checked against the tokens on the list, so leaders can only
        // be named for one of those. A group can always be emptied.
        if (poolIds.length != 0) {
            if (!_countable(id, base)) revert InvalidPool();
            if (_isEther(base)) {
                if (_isEther(partner)) revert InvalidPool();
            }
        }
        address lower = base < partner ? base : partner;
        address higher = base < partner ? partner : base;
        for (uint256 index; index < poolIds.length; index++) {
            if (!tracked[id][poolIds[index]]) revert InvalidPool();
            PoolKey storage pool = keys[poolIds[index]];
            if (Currency.unwrap(pool.currency0) != lower) revert InvalidPool();
            if (Currency.unwrap(pool.currency1) != higher) revert InvalidPool();
            for (uint256 earlier; earlier < index; earlier++) {
                if (poolIds[earlier] == poolIds[index]) revert InvalidPool();
            }
        }
        _setGroup(groups[id][base], partner, poolIds.length != 0);
        leaders[id][base][partner] = poolIds;
        heads[id][base][partner] = poolIds.length == 0 ? bytes32(0) : poolIds[0];
        _requireWorkable(id, markets[id].gasLimit);
        emit LeadersSet(id, base, partner, poolIds);
    }

    function leadersOf(uint256 id, address base, address partner)
        external
        view
        returns (bytes32[] memory)
    {
        return leaders[id][base][partner];
    }

    function groupsOf(uint256 id, address base) external view returns (address[] memory) {
        return groups[id][base];
    }

    /// @notice Sets or clears the pool a market uses to convert between its two tokens.
    /// It must not contain SZR. In SZR's market it must be on Liquidity's list of
    /// registered pools.
    /// @dev Anyone can open a market, so its connecting pools may run no hook but this one
    /// (and then only as a pool of that same market) or one that has a pricer. Another hook
    /// could do anything in the middle of a cycle, and this hook's own swaps skip its
    /// searches, so trading through another market's pool would move it without that
    /// market's search.
    function setConnector(uint256 id, PoolKey calldata pool, bool enabled)
        external
        onlyOwner(id)
    {
        bytes32 poolId = PoolId.unwrap(pool.toId());
        address lower = Currency.unwrap(pool.currency0);
        address higher = Currency.unwrap(pool.currency1);
        if (lower == token) revert InvalidPool();
        if (higher == token) revert InvalidPool();
        // Clearing skips the trust and link checks: a pool whose hook lost its pricer must
        // still be removable by its owner.
        if (enabled) {
            if (id == SZR_MARKET) _requireSzrConnector(pool, poolId);
            else _requireLink(id, pool, poolId);
        }
        // Clearing has to name the pool that is set, not just any pool on the same pair.
        if (!enabled) {
            if (connector[id][lower][higher] != poolId) revert InvalidPool();
        }
        keys[poolId] = pool;
        traded[id][lower] = true;
        traded[id][higher] = true;
        bytes32 replaced = connector[id][lower][higher];
        connector[id][lower][higher] = enabled ? poolId : bytes32(0);
        emit ConnectorSet(id, lower, higher, connector[id][lower][higher]);
        // The pool this one replaced, or this one cleared, may be wrapped and now unused.
        if (replaced != bytes32(0)) _unlist(id, replaced);
        if (enabled) {
            if (pricers[address(pool.hooks)] != address(0)) {
                _wrap(id, address(pool.hooks), poolId);
            }
        }
    }

    /// @notice Sets a market's gas allowance and smallest gap, and the smallest profit for
    /// cycles counted in `base`. `gas` zero switches the market off; otherwise it must
    /// cover at least one cycle. `edge` below 1.0 would chase losing cycles.
    function setLimits(uint256 id, address base, uint32 gas, uint128 profit, uint64 edge)
        external
        onlyOwner(id)
    {
        if (edge < WAD) revert InvalidLimit();
        if (edge > MAX_EDGE) revert InvalidLimit();
        _requireWorkable(id, gas);
        Settings storage own = markets[id];
        own.gasLimit = gas;
        own.edge = uint56(edge / EDGE_UNIT);
        minimumProfit[id][base] = profit;
        _requireMinimums(id);
        emit LimitsSet(id, base, gas, profit, uint64(own.edge * EDGE_UNIT));
    }

    /// @notice Sets the smallest profit for cycles counted in `base`, and nothing else.
    function setMinimumProfit(uint256 id, address base, uint128 profit) external onlyOwner(id) {
        Settings storage own = markets[id];
        minimumProfit[id][base] = profit;
        _requireMinimums(id);
        emit LimitsSet(id, base, own.gasLimit, profit, uint64(own.edge * EDGE_UNIT));
    }

    /// @notice The smallest gas allowance with which a search can always start its first
    /// cycle, for the groups and leaders set now. It does not depend on how many pools are
    /// tracked, only on how many venues one search can price.
    function minimumGasLimit(uint256 id) external view returns (uint256) {
        return _minimumGasLimit(id);
    }

    /// @notice The gas the pool manager must still have when it calls this hook before a
    /// swap in this market, for the swap never to fail with `InsufficientGas`, whatever
    /// gaps are open. Set a swap's gas limit from this, not from an estimate: an estimate
    /// made while no gap was open is far too low for a swap that meets one.
    /// @dev Add what the router and the pool manager use before that point, and allow for
    /// each call on the way down keeping back one 64th of the gas it is given. The two
    /// factors here are for the two calls from the pool manager to the search; the search's
    /// own cap is raised for its hop to the module (`_hopped`) so that it gets what it needs.
    /// @dev A swap that itself costs more than `SWAP_GAS` (800k) needs that much more.
    /// @dev This holds as long as the gas reserved per step in this contract is no less
    /// than those steps really cost.
    function gasForSwap(uint256 id) external view returns (uint256) {
        return _gasForSwap(id);
    }

    /// @notice Sets the most `gasForSwap` a market may have when it is switched on or
    /// changed. Lowering it switches nothing off; a market above it is refused at its next
    /// change. Zero would stop every market being switched on.
    function setSwapGasCeiling(uint256 ceiling) external onlyOwner(SZR_MARKET) {
        if (ceiling == 0) revert InvalidLimit();
        swapGasCeiling = ceiling;
        emit SwapGasCeilingSet(ceiling);
    }

    /// @notice The other token of a pool a market is searching, beside the one its profit
    /// is counted in. Zero means either that the pool is not tracked or is never searched,
    /// or that the other token is native ETH.
    function partnerOf(bytes32 poolId) external view returns (address) {
        Pool memory entry = pools[poolId];
        if (entry.market != 0) {
            if (!entry.picked) return address(0);
            return _other(keys[poolId], entry.home);
        }
        if (tracked[SZR_MARKET][poolId]) return _other(keys[poolId], token);
        return address(0);
    }

    /// @notice Until when the cycle between `poolId` (the pool searched) and `venue` (zero
    /// for Core redemption) is set aside after failing, in market `id` with profit counted
    /// in `base`. `buying` is its direction: whether the hook buys `base` in `poolId`.
    function benchedUntil(uint256 id, address base, bytes32 poolId, bytes32 venue, bool buying)
        external
        view
        returns (uint256)
    {
        return benched[_pair(id, base, poolId, venue, buying)].until;
    }

    /// @notice Registers, or removes, a search of market `id` for profit counted in `base`
    /// to run around swaps in the venue `poolId`. Only the venue's own hook may call it, and
    /// only while it has a pricer, so a market's owner cannot take a venue's places or make
    /// its swaps pay for searches: the hook's owner chooses which markets a swap searches.
    /// A venue has at most `MAX_TRIGGERS`, across all markets. The market must track the
    /// pool, and `base` must be countable there, which means chosen by the market and
    /// approved. `gasCap`, at most `MAX_TRIGGER_GAS`, bounds what the trigger's searches may
    /// use in all; setting a trigger again changes its cap.
    function setVenueTrigger(uint256 id, bytes32 poolId, address base, uint32 gasCap, bool on)
        external
    {
        if (active != 0) revert Busy();
        if (msg.sender != address(keys[poolId].hooks)) revert NotTrusted();
        if (pricers[msg.sender] == address(0)) revert NotTrusted();
        Trigger[] storage list = triggers[poolId];
        uint256 count = list.length;
        uint256 index;
        while (index < count) {
            if (list[index].market == id) {
                if (list[index].base == base) break;
            }
            index++;
        }
        if (on) {
            if (!tracked[id][poolId]) revert UnknownPool();
            if (!_countable(id, base)) revert InvalidPool();
            if (gasCap == 0) revert InvalidLimit();
            if (gasCap > MAX_TRIGGER_GAS) revert InvalidLimit();
            if (index == count) {
                if (count == MAX_TRIGGERS) revert TooManyTriggers();
                list.push(Trigger(uint32(id), gasCap, base));
            } else {
                list[index].gasCap = gasCap;
            }
        } else if (index != count) {
            list[index] = list[count - 1];
            list.pop();
        }
        emit VenueTriggerSet(id, poolId, base, gasCap, on);
    }

    function triggersOf(bytes32 poolId) external view returns (Trigger[] memory) {
        return triggers[poolId];
    }
}

/// @notice The deployed Admin module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageAdmin is AdminPart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
