# Sazare / SZR

A fixed-supply, WETH-backed token with one continuous sale auction and native Uniswap v4 liquidity
management. Auction proceeds fund backing first. Remaining WETH buys productive pool assets held
permanently under protocol custody. There are no adapters, factories, per-pool rewards, or weights.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `Szr` | Fixed 1B-supply ERC-20. No external mint function or implicit Permit2 allowance. |
| `SzrCore` | Single SZR/WETH auction, reserved migration inventory, WETH reserves, redemption, and loans. |
| `SzrMigration` | Atomic 1:1 legacy SZR exchange through its canonical v4 hook, funded by recovered WETH. |
| `SzrEconomics` | Earned liquidity-revenue claims for the immutable team beneficiary. |
| `Liquidity` | Direct PoolManager calls, all v4 positions, idle acquisition assets, swaps and reallocation. |
| `FeeCollector` | Converts non-WETH trading fees through per-asset partial-fill auctions paid in WETH. |
| `ContinuousAuction` | Existing constant-product pricing, fill pressure, and eligible-time price decay. |
| `ReleaseSchedule` | Smooth time-based auction allowance, a minimum rate, and full accumulation of unsold allowance. |

Only the main SZR distribution is consolidated into one auction. FeeCollector still converts each
foreign fee asset separately; those auctions do not allocate or distribute SZR.

## One sale, backing first

1. A buyer calls `SzrCore.quote(amount)` and `SzrCore.buy(amount, maximumPayment, deadline)`.
2. The buyer supplies **WETH only**, approving Core. There is no requirement to bring pool SZR,
   partner tokens, or a liquidity position.
3. Core receives the payment and retains the exact, rounded-up current NAV backing for the sold SZR.
4. The remaining WETH goes to `Liquidity`, where it is recorded as held acquisition principal.
5. Core releases the purchased SZR to the buyer.

Prices react to purchases through the continuous constant-product curve and decay over two days
of eligible sale time. The price is bounded below by current token backing. When backing overtakes
virtual pricing, fills start from that backing floor so demand still raises the curve. The integrated
purchase premium can fund liquidity even when the starting marginal price has reached backing.
Quotes include total payment, reserve backing, and treasury funding separately.

Sale funding is not LP revenue: it does not pay the team. The former per-program allocation and
buyer-funded LP reward mechanism, including its separate 5% backing premium, has been removed.

## Smoothed release schedule

The reference is [Heesho's Rig.sol](https://github.com/Heesho/miner-launchpad-hardhat/blob/main/contracts/Rig.sol),
which uses configurable stepwise halvings and a minimum emission rate. SZR uses this continuous rate:

`rate(t) = max(500,000 * 2^(-t / 365 days), 100,000) SZR/day`

- Starts **24 hours after launch**, with zero accumulated allowance.
- Initial allowance rate: **500,000 SZR/day**.
- Continuous half-life: **365 days**; there is no sudden halving boundary.
- Minimum rate: **100,000 SZR/day**, reached after approximately 2.32 years.
- **All scheduled, unsold allowance accumulates**, with no carry cap.
- Actual sales are additionally limited by unreleased public inventory.

The first year's integrated allowance is about **131.65M SZR**. Every unsold scheduled token remains
available, limited by actual unreleased inventory. The schedule permits sales; it does not guarantee
that purchases occur.
The rate continues aging while inventory is empty, but sale-price decay freezes until tokens return.
Recycled SZR re-enters the same auction at the then-current rate; returning tokens cannot create
extra release credit or reset the emission clock. The minimum rate cannot mint new supply.

Cumulative integration uses an absolute-time antiderivative. Frequent checkpoints cannot compound
rounding into extra release or discard unspent allowance. Credit retains sub-token fractions. The
release balance equals cumulative scheduled release minus total auction purchases. Pricing depth
uses the smaller of that balance and actual inventory, plus the virtual buffer; the buffer does not
limit the quantity of released tokens available to buy.
These numerical values are approved **testing defaults**, not final launch calibration.

## Legacy SZR migration

The migration cap is **350M SZR**, and every redeemable holder receives **1 new SZR per old SZR**.
A separate liquidity plan targets **100M of those already-migrated tokens**, contributed explicitly
by an existing holder. If that holder migrates and contributes 100M, the other 250M can migrate to
other holders. Normal migration does not deduct a liquidity percentage. The 100M funding target is
not a second reservation or release from Core; the remaining **650M SZR** starts as inactive public
auction inventory.

Launch starts with zero active supply and zero reserve cash. The migration contributor receives
their full 1:1 wallet balance first and then separately approves Liquidity and calls
`fundInitialLiquidity(minimumUnits, deadline)`. That call pulls only their own active tokens, funds
the configured one-sided POL position, and refunds unused rounding to that contributor. It cannot
spend Core inventory or take tokens from another wallet. Funding changes neither active supply nor
NAV and does not consume sale allowance. There is no automatic initial-token issuance.

Borrowing is disabled during migration. It becomes available when the migration cap is exhausted,
or when the deployment initializer permanently closes migration with `SzrCore.closeMigration()`.
Closure returns every unused migration reservation to scheduled public inventory without changing
active supply or creating release credit. Tokens already contributed to liquidity are not counted
again. Already-active holder tokens may fund liquidity after closure without diluting open loans.
There is no automatic timeout. Final migration eligibility and the contributor's available old
holdings must be checked before deployment; these figures are configuration defaults.

Legacy SZR is `0xbeD7c1660a01dbEEe225bd893ac31727a91A5773` on Robinhood. Deployment discovers its
canonical hook using the old token's `hook()` getter and validates both directions of that binding,
18 decimals, matching WETH, PoolManager code, and the initialized canonical zero-fee v4 pool. The
legacy pool key and hook/PoolManager code hashes are pinned; callers cannot supply another route.

1. A holder approves **SzrMigration**, then calls `migrate(amount, minimumBacking, deadline)`.
2. Migration pulls exactly that holder's old SZR and sells the complete amount through the canonical
   v4 hook, receiving **net WETH after legacy sell fees**. The hook can pay a combination of band
   proceeds and floor redemption; this is its normal sell path, not a bypass of its economics.
3. Migration accepts the hook's actual net WETH proceeds, with **no protocol NAV minimum**.
   The holder can still set `minimumBacking` for slippage protection, or use zero to accept any
   positive hook payout. Falling below that holder-selected minimum reverts the entire exchange.
4. Core receives **all** recovered WETH into reserves and releases exactly the same amount of new
   SZR directly to the holder. There is no additional WETH payment, public auction premium, opening
   loan fee, or team revenue split on migration proceeds. Only actual received WETH is recorded;
   the contract does not book an assumed NAV payment.

`publicInventory = unreleasedSupply - migrationRemaining`

A successful migration reduces both unreleased supply and the remaining migration reservation by
its token amount. It does not spend or create scheduled sale allowance, alter total supply, or reset
auction pricing. Returned/redeemed new SZR subsequently enters ordinary public inventory; it does
not replenish the original migration allocation. New SZR has the same redemption and borrowing
rights as other active tokens. All net recovered WETH joins reserves. With zero active supply at
launch, the first migration establishes actual backing for its delivered tokens. The liquidity
contributor's migrated tokens are included in active supply before they move from their wallet into
POL; this move introduces no new reserve claims. A 1:1 token payout does not guarantee preservation
of the old hook's per-token floor.
Migration can lower the new token's NAV when recovered WETH per token is below the current NAV.
The normal public auction still requires full current-NAV backing. Because borrowing starts only
after migration finishes permanently, migration cannot lower the backing of an outstanding loan.

`SzrMigration.quote(amount)` returns expected net recovered backing, required new backing, and
whether it currently covers NAV. That comparison is informational and does not gate migration.
Quotes can change before execution. This is a **live token swap**,
with no holder snapshot or per-wallet entitlement: later buyers of old SZR can also use the remaining
allocation, until migration finishes. Migration availability depends on the remaining reservation
and successful legacy settlement, not the new NAV. Closing migration cannot be reversed. The contract has no top-up pool, owner withdrawal, or arbitrary-call
entry point. Unsolicited transfers do not earn migration credit; use `migrate`.

Tests exercise the real local v4 PoolManager with an ABI-compatible legacy custom-accounting hook,
including exact input settlement, partial exchanges, full allocation, quote fees, callback attacks,
rollback, dust, loan interactions, and auction-inventory isolation. **A live Robinhood fork rehearsal
against the actual legacy hook remains required before deployment**: public explorer/RPC access was
blocked during implementation, so the local tests do not establish live-state compatibility.

## Native v4 liquidity management

`Liquidity` pins one PoolManager. It owns every position directly; pool keys, ticks, salts, and
liquidity balances are stored internally. No per-pool contract is deployed. Full-range pools can be
registered with reviewed hooks. A separate one-sided `INITIAL_POSITION()` accepts the configured
holder-funded initial liquidity contribution.

- `addPool(config, feeConfig)`: register a full-range SZR/partner position and its fee asset.
- `swapPrincipal(poolKey, zeroForOne, amount, minimumOut, priceLimit, deadline)`: acquire SZR or
  partner assets from held treasury funds through any existing v4 pool, including WETH/partner pools.
- `deployPrincipal(id, units, bounds)`: add held assets to a registered position.
- `withdrawPrincipal(id, units, minimumSzr, minimumPartner, deadline)`: return principal to custody.
- `moveLiquidity(request)`: remove and redeploy atomically when the held assets cover the destination.
- `collect(id)`: permissionless collection and fixed routing of trading fees.

Use ordinary pool IDs for full-range positions and `INITIAL_POSITION()` for the launch position.
`fundInitialLiquidity(minimumUnits, deadline)` funds the configured target once, entirely from its
caller's active SZR balance. Core has no special initial-liquidity release path. Fees are collected
through `collect(id)` for either position. The initial position is permanent: `withdrawPrincipal`
and `moveLiquidity` reject it, so its SZR leaves only to pool buyers. Different-partner moves can use withdrawal, bounded swaps,
and deployment in separate steps. Unspent assets remain held.

Every removal separates principal from fees. Internal moves cannot issue SZR, consume sale allowance,
or turn liquidity principal into revenue. There is no general withdrawal, arbitrary recipient,
external allowance setter, or arbitrary execution function. Pool assets and held WETH do not count
as floor reserves and cannot be borrowed through Core.

**The manager is a trusted role.** `addPool`, `deployPrincipal` and `swapPrincipal` can route held
treasury assets and non-genesis positions through any pool the manager chooses, with a
manager-set minimum output, so a malicious manager could transfer that value away. Floor reserves
in Core and the permanent genesis position are out of its reach. Use a multisig.

The manager controls asset/hook selection, allocation, and trade execution prices. It is trusted
not to choose harmful hooks or assets, manipulated markets, or inappropriate slippage settings.
Protocol custody does not prevent economic trading losses. Hooks requiring custom callback payloads
are unsupported; v4 hook data is empty. Native ETH pools are unsupported; WETH is used instead.

## Fees

1. **SZR trading fees:** returned to Core's unreleased public sale inventory.
2. **WETH trading fees:** **33% team / 67% reserves**, with integer rounding dust kept in reserves.
3. **Other trading fees:** auctioned for WETH, then allocated using the same 67/33 split.
4. Anyone can call `SzrEconomics.claimFees()` to pay the immutable team beneficiary.

Only realized liquidity revenue is split. Principal, primary-sale funding, loan repayments, and
returned SZR are excluded. Loan opening fees and backing donations go entirely to reserves.

## Supply, backing and loans

Total supply is **1,000,000,000 SZR**, with no team token allocation, token vesting, or privileged
team token claim. Up to **350M SZR** migrates 1:1, including the existing holder's planned **100M**
liquidity contribution. That contribution comes from the holder's delivered tokens, not an extra
Core allocation. There is no genesis release. The remaining **650M SZR** and recycled inventory fund
public sales, subject to the release schedule and backing requirement. The team's compensation
is its existing 33% share of realized liquidity revenue; its beneficiary has the same token-purchase
terms as every other buyer.

`activeSupply = totalSupply - unreleasedSupply`

`backing = reserveCash + loanPrincipal`

`NAV = backing / activeSupply` (displayed per-token value uses 1e18 scaling).

Loans open only after migration has finished (or immediately if migration was disabled at deployment).
They lock existing SZR and cannot exceed its exact proportional backing. Additional draws can use
existing collateral after NAV rises. The **1% opening fee** is rounded up and deducted from each
new draw. There is no running interest or price-based liquidation. Partial repayment frees proportional
collateral into a reclaimable ledger; `repay`, `reclaimCollateral`, and `repayAndReclaim` are preserved.

A borrower renews the **90-day inactivity deadline** with `poke`. Repayment remains possible after
expiry until settlement. Anyone can settle expiry: only the debt's current NAV-equivalent SZR is
recycled, debt is cancelled, and excess collateral returns to its owner. Previously reclaimable
collateral is excluded. Redemption pays exact NAV from available reserve cash; outstanding loans
are backing but cannot be transferred as cash.

Launch activates no tokens and books no reserve cash. Migration brings existing holders' actual
WETH backing into Core, with all net recovered WETH retained as reserves. A first public auction purchase instead funds its required bootstrap backing; the
bootstrap quote is not booked as cash by itself. Direct token transfers are not automatically recorded
as principal, fees, or backing; use the protocol's entry points.

## Build and verify

```sh
forge install
forge fmt --check
forge build --no-lint
python3 tools/check_style.py
forge test -vv
```

Tests use the pinned real v4 PoolManager, compiled separately with Solidity 0.8.26. First-party
contracts use Solidity 0.8.30 without IR. Tests cover sale/backing/treasury conservation, schedule
integrals and checkpoints, native pool custody, hook pools, external WETH/partner routes, rollback,
loans, expiry, redemption and stateful mixed-operation invariants. The style checker separately
enforces production runtime/initcode limits, short functions, one check per line, and no recursion.

## Deployment rehearsal

Copy `.env.example` to `.env` and set the required chain ID, WETH, PoolManager and beneficiary.
`LEGACY_SZR` defaults to the approved Robinhood legacy token; `MIGRATION_ALLOCATION` defaults to
`350000000000000000000000000` (the full 1:1 migration cap in wei).
`INITIAL_LIQUIDITY_ALLOCATION` defaults to `100000000000000000000000000`; it is only the funding
target exposed as `initialLiquidityTarget()`. It neither increases nor reduces `migrationAllocation()`.
The script registers full-range and empty one-sided positions, then launches without moving tokens.
The contributing holder separately migrates their old tokens, approves Liquidity for the 100M target,
and calls `fundInitialLiquidity(minimumUnits, deadline)` to fund POL from their delivered balance.
For a deliberately allocation-free local rehearsal, explicitly set `MIGRATION_ALLOCATION=0`.
For holder-migration-only tests, set `INITIAL_LIQUIDITY_ALLOCATION=0`. WETH
must be an ordinary 18-decimal ERC-20. The script checks chain ID and deployed asset/PoolManager code,
binds all modules, registers the full-range and initial one-sided v4 positions, and launches once. The signer
is initially manager; any nominated successor must explicitly accept.

```sh
set -a
source .env
set +a
forge script script/DeploySzr.s.sol:DeploySzr --rpc-url "$RPC_URL" --account YOUR_KEYSTORE -vvvv
```

Review the rehearsal and its inputs before intentionally adding `--broadcast`. Repository changes
do not deploy contracts. `AUCTION_OPENING_WAD` and `AUCTION_FLOOR_WAD` are WETH per SZR scaled by 1e18.

## Refactor complexity report

AST decision counts for the old adapter paths and their native replacements:

| Previous function | Before | Native replacement | After |
| --- | ---: | --- | ---: |
| `V4Position.constructor` | 29 | `Liquidity._registerPool` | 9 |
| `V4Position.unlockCallback` | 15 | `Liquidity.unlockCallback` | 5 |
| `SzrMigration.constructor` initial implementation | 15 | Constructor / `_legacyPool` | 9 / 7 |
| `SzrMigration.migrate` initial implementation | 16 | `migrate` / `_validateMigration` | 7 / 9 |

Registration delegates fixed fee/range/key validation to small helpers. The authenticated callback
routes liquidity settlement to `_modifyCallback` (10), keeping authentication separate from principal
and fee handling. The old weighted splitter and adapter dispatch were removed. All touched production
functions have complexity at most 10. Migration preflight validation and canonical pool validation
are separated from token settlement. Behavior verified with the migration suite, stateful invariants,
real-v4 integration, deployment rehearsal, formatting/style and production bytecode-size checks.
