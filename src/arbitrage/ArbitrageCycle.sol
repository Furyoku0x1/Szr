// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./ArbitrageLogic.sol";

/// @dev The code of `execute`, one whole cycle.
abstract contract CyclePart is ArbitrageLogic {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @notice One whole cycle. It either nets at least `minimumProfit` SZR with no other
    /// token left owing, or reverts. The SZR stays as a credit until the search retires it.
    function execute(bytes32 poolId, Plan calldata plan)
        external
        onlySelf
        returns (uint256 profit)
    {
        (uint256 open, int256 held) = _tally();
        profit = plan.buying ? _buyCycle(poolId, plan) : _sellCycle(poolId, plan);
        if (profit == 0) revert Unprofitable();
        if (profit < minimumProfit[active][home]) revert Unprofitable();
        if (asking != 0) _requireTidy(open, held, profit);
        emit Arbitraged(poolId, plan.venue, plan.buying, profit);
    }

    /// @notice Pays out what a search earned. It is a call of its own, instead of code in the
    /// search modules, to keep those under the size limit; its reverts reach the search
    /// unchanged.
    function retire(uint256 profit) external virtual onlySelf {
        _retire(profit);
    }

    /// @dev SZR's market retires its profit at Core. Every other market's is paid out.
    function _retire(uint256 profit) internal {
        if (active != SZR_MARKET) return _payOut(profit);
        _take(Currency.wrap(token), address(this), profit);
        _requireSettled(token);
        core.donateSzr(profit);
    }

    /// @dev Splits a market's profit between the protocol and the market, in the token it
    /// was counted in. If the protocol's recipient cannot receive the token (a blocklist, for
    /// instance), its share is minted as a pool-manager claim instead, so one recipient cannot
    /// stop every market counting in that token. The recipient redeems a claim by calling
    /// `unlock` on the pool manager and, inside it, `burn` then `take`, or by transferring
    /// the claim to something that can. The market's own share has no such fallback, and
    /// neither does a share owed to Core, which could never redeem the claim.
    function _payOut(uint256 profit) internal {
        // Rounded up, so that no profit is too small for the protocol to share in.
        uint256 share = (profit * PROTOCOL_SHARE + 99) / 100;
        if (home == address(0)) {
            _payNative(profit, share);
        } else {
            Currency asset = Currency.wrap(home);
            address protocol = shareRecipient[home];
            // Checked for the whole profit before the try below, so that a drain is never
            // turned into a claim.
            _funded(asset, profit, true);
            if (protocol == address(core)) {
                // Core cannot redeem a claim, so one minted to it would be stuck.
                poolManager.take(asset, protocol, share);
            } else {
                try poolManager.take(asset, protocol, share) { }
                catch {
                    poolManager.mint(protocol, asset.toId(), share);
                    emit ShareHeld(home, protocol, share);
                }
            }
            // Some tokens refuse a transfer of nothing.
            if (profit != share) {
                poolManager.take(asset, markets[active].recipient, profit - share);
            }
        }
        _requireSettled(home);
        emit ProfitPaid(active, home, profit, share);
    }

    /// @dev Native ETH profit leaves only as WETH, so no recipient's code runs in the middle
    /// of a search. Unlike `_payOut` it has no claim fallback: the ETH is already taken by the
    /// hook, so none can be minted. WETH has no blocklist in its current implementation, but
    /// it is an upgradeable proxy, so that is not a promise.
    function _payNative(uint256 profit, uint256 share) internal {
        _take(Currency.wrap(address(0)), address(this), profit);
        // A failed wrap is a named error: an empty revert would be read as too little gas.
        try IWrapped(backingAsset).deposit{ value: profit }() { }
        catch {
            revert Unsettled();
        }
        SafeTransferLib.safeTransfer(backingAsset, shareRecipient[address(0)], share);
        if (profit != share) {
            SafeTransferLib.safeTransfer(
                backingAsset, markets[active].recipient, profit - share
            );
        }
    }
}

/// @notice The deployed Cycle module. The hook reaches it by delegatecall, so it runs on
/// the hook's storage; called directly it runs on storage of its own and changes nothing.
contract ArbitrageCycle is CyclePart {
    constructor(Liquidity treasury) ArbitrageLogic(treasury) { }
}
