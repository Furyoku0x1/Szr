# Sazare / SZR

A fixed-supply, WETH-backed token with one continuous sale auction and native Uniswap v4 liquidity
management. Auction proceeds fund backing first. Two thirds of any premium goes to protocol
custody, primarily for pool liquidity; one third stays in reserves and raises NAV. There are no
adapters, factories, per-pool rewards, or weights.

## Contracts

| Contract | Responsibility |
| --- | --- |
| `Szr` | Fixed 1B-supply ERC-20. No external mint function or implicit Permit2 allowance. Refuses transfers to the zero address, to itself and to Core. |
| `SzrCore` | Single SZR/WETH auction, reserved migration inventory, WETH reserves, redemption, and loans. |
| `SzrMigration` | Atomic 1:1 legacy SZR exchange through its canonical v4 hook, funded by recovered WETH. |
| `SzrEconomics` | Earned liquidity-revenue claims for the team beneficiary, who can hand the claim on by nomination and acceptance. |
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
4. The remaining premium is split: two thirds go to `Liquidity`, where they are recorded as held
   acquisition principal, and one third stays in Core reserves, raising NAV for every holder.
5. Core releases the purchased SZR to the buyer.

Prices react to purchases through the continuous constant-product curve and decay over two days
of eligible sale time. The price is bounded below by one and a half times current token backing, so
every sale carries a premium of at least half its NAV value. When that floor overtakes virtual
pricing, fills start from the floor so demand still raises the curve.

The decay is one straight line: each purchase lifts it and makes it steeper, and when it reaches
the floor everything resets. A consequence worth knowing is that steady buying does not hold the
price up indefinitely. With the same purchase every hour the price climbs to about 1.8x the floor
over roughly 60 hours, then falls back to the floor by about hour 98 and starts again. The 1.5x
NAV minimum always holds; this only affects how much premium the sale earns.

The curve can represent a price up to about 115,000 WETH per SZR at full-supply depth, so the floor
can follow NAV to roughly 77,000 WETH per SZR; past that only new sales stop. The pricing library
keeps its decaying term in two words to reach that range. `test/ContinuousAuctionEquivalence.t.sol`
holds the evidence that this changes no result: a step-by-step fuzz against the original library
(frozen in `test/utils/ContinuousAuctionV1.sol`) and exact vectors from an unbounded-integer
reference (`test/fixtures/continuous_auction_reference.py`) above the original's range.
Quotes include total payment, the reserve share (NAV backing plus a third of the premium), and
treasury funding separately; the last two always sum to the payment.

Sale funding is not LP revenue: receiving it does not pay the team. If the manager later swaps
that WETH through a pool where the protocol itself holds a position, the swap pays that pool's
ordinary fee, and the protocol's share of it is split like any other trading fee (about 0.33% of
the amount swapped reaches the team at a 1% pool fee). The former per-program allocation and
buyer-funded LP reward mechanism, including its separate 5% backing premium, has been removed.

## Smoothed release schedule

The reference is [Heesho's Rig.sol](https://github.com/Heesho/miner-launchpad-hardhat/blob/main/contracts/Rig.sol),
which uses configurable stepwise halvings and a minimum emission rate. SZR uses this continuous rate:

`rate(t) = max(1,000,000 * 2^(-t / 365 days), 100,000) SZR/day`

- Starts **the moment migration closes**, with zero accumulated allowance. Until then the sale
  and the fee auctions are closed; redemption stays open.
- Initial allowance rate: **1,000,000 SZR/day**.
- Continuous half-life: **365 days**; there is no sudden halving boundary.
- Minimum rate: **100,000 SZR/day**, reached after approximately 3.32 years.
- **All scheduled, unsold allowance accumulates**, with no carry cap.
- Actual sales are additionally limited by unreleased public inventory.

The first year's integrated allowance is about **263.29M SZR**. Every unsold scheduled token remains
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
These are the launch values, confirmed on 2026-11-13. The sale buffer is 200,000 SZR: in
90-day simulations it raised 0.2-4.3% more WETH than 20,000 because more tokens sold close to
the market price, while a much larger buffer (5,000,000) sold well below market when demand
was strong.

## Legacy SZR migration

The migration cap is **350M SZR**, and every redeemable holder receives **1 new SZR per old SZR**.
The whole cap is for holders; migration does not deduct a liquidity percentage. Genesis liquidity
is a separate **25M SZR taken from Core's public inventory**, leaving **625M SZR** as inactive
public auction inventory.

`fundInitialLiquidity(minimumUnits, deadline)` can be called once by anyone while migration is
open. Core releases the fixed 25M to Liquidity, which places all of it in the configured one-sided
POL position; any rounding remainder returns to Core's inventory. The caller supplies and receives
nothing. The release is not a scheduled sale and consumes no sale allowance.

**These 25M tokens are active claims with no backing, so they dilute migrators.** NAV is the
recovered WETH divided by migrated tokens plus the 25M. It is zero until the first migration, rises
as holders migrate, and ends below what each migrator brought in (about 9% below if all of the
roughly 246M sellable old SZR migrates). Because the release lowers NAV it is refused once
migration has closed, when loans and sales can exist.

Borrowing, the sale and the fee auctions are closed during migration. They open only when the
Liquidity manager permanently closes migration with `SzrCore.closeMigration()`. **Migration never
ends by filling up**: the last unit of the allowance is never released, so nobody can end it for
everyone by using the allowance up. Old SZR sold through the old hook can be bought back from it,
so the allowance is not limited by the old supply; if it is ever used up, the manager can reserve
more public inventory with `extendMigration(amount)` (once genesis is funded). Closure returns every unused reservation to
scheduled public inventory without changing active supply or creating release credit. Migration
cannot be closed until the genesis position has been funded; it could not be funded afterwards.
There is no automatic timeout. Final migration eligibility must be checked before deployment;
these figures are configuration defaults.

Legacy SZR is `0xbeD7c1660a01dbEEe225bd893ac31727a91A5773` on Robinhood. Deployment discovers its
canonical hook using the old token's `hook()` getter and validates both directions of that binding,
18 decimals, matching WETH, PoolManager code, and the initialized canonical zero-fee v4 pool. The
legacy pool key and hook/PoolManager code hashes are pinned; callers cannot supply another route.

The old hook's source is published and matches its bytecode exactly (Sourcify, chain 4663: the
proxy `0x02973Ca0…a888`, its implementation `0x1d07f75d…bc3f` and the pricing module
`0x21438fb2…5372`). Read for the final audit: the proxy has no admin or upgrade path; the hook has
no owner; its pricing module, settings and fee recipient are set once at initialisation; the hook
rejects any quote that would lower the floor price; selling to the floor carries no fee, while
selling into WETH that buyers left in its band pays a 1% band fee; and its quote structure and
zero-fee, tick-spacing-60 pool key are exactly what `SzrMigration` expects.

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
auction pricing. While migration is open, redeemed, donated or recycled SZR frees its migration
slot again (never beyond the original allowance), so migrating and redeeming in a loop cannot use
the allowance up; after closure it enters ordinary public inventory. New SZR has the same
redemption and borrowing rights as other active tokens. All net recovered WETH joins reserves and is shared with the 25M
genesis tokens, which are active from the moment the genesis position is funded. A 1:1 token payout
therefore does not preserve the old hook's per-token floor.
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
rollback, dust, loan interactions, and auction-inventory isolation.

`test/fork/SzrFork.t.sol` rehearses the launch against the live legacy hook on Robinhood Chain
(chain ID 4663). It runs the deploy script with the real WETH and PoolManager, migrates through
the real hook, redeems, trades the genesis pool, closes migration and buys from the auction. It
is skipped unless `FORK_RPC_URL` is set:

```sh
FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*" -vv
```

It runs at the latest block (the public RPC stops serving older state within hours; `FORK_BLOCK`
pins a block on an archive RPC). It impersonates real holders of the old token and stops on its
own guard if they have since moved their tokens; update the addresses in the test when that
happens. It also replays the attack an independent review found, buying old SZR from the old
hook, migrating and redeeming in a loop, and checks that it can no longer use up the allowance.

On 2026-11-12 the hook paid one flat price while its band held no WETH, about 0.000000532 WETH
per old SZR with no sell fee, at every size. It accepts only tokens outside its own inventory:
about 246M of the 330M supply, worth about 131 WETH in total. With the 25M genesis tokens sharing
those reserves, NAV would be about 0.000000483 WETH if every sellable old SZR migrated, and lower
while fewer have. **The price is not flat once someone has bought old SZR from the hook**: that
WETH sits in its band and the next sellers are paid from it at a higher price, so a migrator's
quote can move between quoting and migrating. Front-ends should leave a margin in
`minimumBacking`, and recovery above the floor price lifts NAV above the figures here.
**Re-run the rehearsal immediately before deployment**; it simulates on a fork and does not replace
checking the deployer's own settings.

## Native v4 liquidity management

`Liquidity` pins one PoolManager. It owns every position directly; pool keys, ticks, salts, and
liquidity balances are stored internally. No per-pool contract is deployed. Wide-range pools can be
registered with reviewed hooks. A separate one-sided `INITIAL_POSITION()` holds the genesis
liquidity that Core releases from its own inventory.

- `addPool(config, feeConfig)`: register a wide-range SZR/partner position and its fee asset.
  Do not end a range on the extreme usable ticks; see "Range ends" below.
- `registerRoute(poolKey)`: put an existing pool, such as WETH/partner, on the list of pools the
  manager may swap through.
- `swapPrincipal(poolKey, zeroForOne, amount, minimumOut, priceLimit, deadline)`: acquire SZR or
  partner assets from held treasury funds through a registered pool, including WETH/partner pools.
- `deployPrincipal(id, units, bounds)`: add held assets to a registered position.
- `withdrawPrincipal(id, units, minimumSzr, minimumPartner, deadline)`: return principal to custody.
- `moveLiquidity(request)`: remove and redeploy atomically when the held assets cover the destination.
- `moveLiquidityWithSwap(request, swap)`: the same move with one swap in the middle, so liquidity
  can go between pools with different partner tokens in one transaction. The swap can convert only
  what that move withdrew.
- `collect(id)`: permissionless collection and fixed routing of trading fees.
- `multicall(calls)`: run several of these in one atomic transaction, for example two swaps and a
  deployment to turn idle WETH into SZR/partner liquidity. Each inner call keeps its own access
  check, and a failure in any step undoes the whole batch.

Use ordinary pool IDs for wide-range positions and `INITIAL_POSITION()` for the launch position.
`fundInitialLiquidity(minimumUnits, deadline)` funds the configured target once, entirely from
Core's public inventory through `SzrCore.releaseInitialLiquidity()`, which only Liquidity can call.
Fees are collected through `collect(id)` for either position. The initial position is permanent:
`withdrawPrincipal` and both moves reject it, so its SZR leaves only to pool buyers. Unspent assets
remain held.

Every removal separates principal from fees. Internal moves cannot issue SZR, consume sale allowance,
or turn liquidity principal into revenue. There is no external allowance setter or arbitrary
execution function. Pool assets and held WETH do not count as floor reserves and cannot be borrowed
through Core.

**Untouched sale funding can fund other protocol uses.** The manager may send WETH to a
destination with `sendFunding`, for example staking rewards or another product, but only out of
`unallocatedFunding`: sale funding that has never been deployed or swapped. Once WETH has been
liquidity it stays for liquidity; WETH withdrawn from a position or received from a swap can only
be redeployed or swapped. SZR and positions can never be sent. A destination must first be
announced with `announceDestination` and becomes usable only after `DESTINATION_DELAY` (7 days);
`revokeDestination` takes effect immediately.

**Range ends.** Uniswap v4 caps how much liquidity may reference a single tick. Whoever fills
that cap at a tick locks everyone else out of any range ending there, and at the extreme usable
ticks filling it costs about 0.00002 of one token. A range ending there could be locked by
anyone: the position could still be withdrawn, but nothing more could be added. `Liquidity`
therefore accepts any aligned range, and the manager must choose ends that cannot be filled
cheaply. The script's two positions end about 163,000 WETH per SZR on the side where SZR is
expensive (above the sale's own price ceiling) and about 1e-13 WETH per SZR on the side where
it is cheap. Filling the cap at any of their ends takes more than ten times all SZR in
existence and more than a million WETH, at tick spacing 200 and at 60. The cost falls with the
square of the tick spacing and depends on token decimals, so work it out again for every new
pool: for a one-spacing range next to the end tick, compute both token amounts for
`Pool.tickSpacingToMaxLiquidityPerTick(spacing)` of liquidity, as
`testFix_ScriptRangeEndsCannotBeFilledToTheTickCap` does. The genesis range can still never be
registered a second time as an ordinary position. If a range is ever locked, the way out
is to register a new range and move the liquidity into it; registering in a live pool needs
its exact current price, so send that transaction straight after reading it.

**Principal only goes into, or trades through, registered pools.** Deployments and moves can
only target positions added with `addPool`, and every swap must go through a pool in
`poolRegistered`: one added with `addPool` or put there with `registerRoute`. There is no waiting
period, so a newly added pool can be funded straight away.

**The manager is still a trusted role.** It chooses which pools, hooks and price ranges to
register, how to allocate, and the minimum output of each trade, so a malicious manager could register a hostile
pool and transfer that value away. It also sets each partner token's fee-auction
floor, so it could price that token's fee income cheaply. Registration leaves a public record (`PoolAdded`,
`RouteRegistered`); it is not a safeguard by itself. Floor reserves in Core and the permanent
genesis position are out of its reach. Use a multisig.

The manager controls asset/hook selection, allocation, and trade execution prices. It is trusted
not to choose harmful hooks or assets, manipulated markets, or inappropriate slippage settings.
Protocol custody does not prevent economic trading losses. Hooks requiring custom callback payloads
are unsupported; v4 hook data is empty. Native ETH pools are unsupported; WETH is used instead.

## Fees

1. **SZR trading fees:** returned to Core's unreleased public sale inventory.
2. **WETH trading fees:** **33% team / 67% reserves**, with integer rounding dust kept in reserves.
3. **Other trading fees:** auctioned for WETH, then allocated using the same 67/33 split. The
   auction works like the SZR sale: arriving fees add stock without moving the price, the price
   falls over two days while stock is waiting, each purchase lifts it, and it freezes while the
   auction is empty. The sale's floor is 1.5x NAV; a partner token has no such number on-chain,
   so each asset has a floor (WETH per unit) that the Liquidity manager keeps just under the
   token's market rate. Fees never sell below it. `FeeCollector.updateAsset(asset, config)`
   restarts an asset's auction with a new rate, buffer and floor, as its first registration
   did: at twice the given rate, falling to the new floor.
4. Anyone can call `SzrEconomics.claimFees()` to pay the team beneficiary. It pays the
   contract's whole WETH balance, so WETH sent there by mistake goes to the beneficiary too.
   The beneficiary can hand the claim to another address with `nominateBeneficiary`; nothing
   changes until that address calls `acceptBeneficiary`, and fees not yet claimed at that
   point go to the new beneficiary. Nobody else can change it.

Only realized liquidity revenue is split. Principal, primary-sale funding, loan repayments, and
returned SZR are excluded. Loan opening fees and backing donations go entirely to reserves. If WETH
fees are recognised while nobody holds SZR, the whole amount goes to the team: a reserve share with
no holders would only belong to whoever bought the next unit.

## Supply, backing and loans

Total supply is **1,000,000,000 SZR**, with no team token allocation, token vesting, or privileged
team token claim. Up to **350M SZR** migrates 1:1. A fixed **25M SZR** is released once from
public inventory as permanent, protocol-owned genesis liquidity; it is unbacked and dilutes
migrators as described above. The remaining **625M SZR** and recycled inventory fund
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

Tokens sent to the contracts by mistake:

- **SZR** cannot be transferred to the zero address, to the SZR token contract, or to Core; the
  transfer reverts with `InvalidRecipient` and the sender keeps the tokens. Core takes SZR in
  only by pulling it (`redeem`, `donateSzr`, loan collateral, recycled fees).
- **WETH sent straight to Core** is counted by nothing until anyone calls
  `SzrCore.absorbBacking()`, which adds it to reserves as a donation to whoever holds SZR at
  that moment. It cannot be returned to the sender. While nobody holds SZR the call reverts
  and the WETH waits for the next holders.
- Tokens sent to `Liquidity`, `FeeCollector` or `SzrMigration` (including old SZR sent to the
  migration contract instead of calling `migrate`), and SZR sent to `SzrEconomics`, stay
  there and cannot be recovered.

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
`INITIAL_LIQUIDITY_ALLOCATION` defaults to `25000000000000000000000000`; it is only the funding
target exposed as `initialLiquidityTarget()`. It neither increases nor reduces `migrationAllocation()`.
The script registers wide-range and empty one-sided positions in one hook-less SZR/WETH pool with
a 1% swap fee and tick spacing 200, and launches. By default
(`FUND_INITIAL_LIQUIDITY=true`) the script then calls `fundInitialLiquidity`, so the 25M genesis
tokens from Core's inventory are the only active supply when migration opens. The deployer needs
no old SZR. With `FUND_INITIAL_LIQUIDITY=false` anyone can make that call later, while migration
is still open.
For a deliberately allocation-free local rehearsal, explicitly set `MIGRATION_ALLOCATION=0`.
For holder-migration-only tests, set `INITIAL_LIQUIDITY_ALLOCATION=0`. WETH
must be an ordinary 18-decimal ERC-20. The script checks chain ID and deployed asset/PoolManager code,
binds all modules, registers the wide-range and initial one-sided v4 positions, and launches once. The signer
is manager only for setup: `MANAGER` is required, must be a different address, and takes over
when it calls `acceptManager()`. After that the deployer has no authority anywhere.

```sh
set -a
source .env
set +a
forge script script/DeploySzr.s.sol:DeploySzr --sig "run()" --rpc-url "$RPC_URL" --account YOUR_KEYSTORE --slow -vvvv
```

Review the rehearsal and its inputs before intentionally adding `--broadcast`. Repository changes
do not deploy contracts. `AUCTION_OPENING_WAD` and `AUCTION_FLOOR_WAD` are WETH per SZR scaled by 1e18.
`AUCTION_FLOOR_WAD` defaults to `INITIAL_MARKET_PRICE`, so the sale never sells below where the
pool starts, even if migration is closed while reserves are still small.

### Launch checklist

These are accepted operating rules, not enforced in code.

- Rehearse the full script on a fork against the real legacy hook before any broadcast.
- Deploy from an address that has not been published. It needs no old SZR and is the interim
  manager only until the `MANAGER` address accepts.
- Have the `MANAGER` address (a multisig) call `Liquidity.acceptManager()` straight after deploy.
  From then on only it can close migration, manage pools and send untouched sale funding; there
  is no time limit on when it closes migration.
- `INITIAL_MARKET_PRICE` is where the genesis liquidity starts. It defaults to 0.000000507 WETH,
  about 1.05x the NAV reached if every sellable old SZR migrates at the floor price (0.000000483
  on 2026-11-12), and below the auction minimum of 1.5x NAV. The script refuses a value below
  that NAV, computed from the old hook's `floorPrice()` diluted by the genesis tokens with the
  whole allowance migrated; check it again before deploying. Migrators who recover above the
  floor (see the rehearsal notes) can lift NAV past this price, in which case the lowest genesis
  tokens are bought and redeemed: a bounded loss to the pool position, not to holders.
- The genesis position is finite: it runs from `INITIAL_MARKET_PRICE` up to about 163,000 WETH
  per SZR, and its first selling price is one tick-spacing step above `INITIAL_MARKET_PRICE`
  (about 0.000000515 WETH for the default), so the sale's absolute floor sits about 1.5% under it.
- Anyone can raise the old hook's floor price by gifting it WETH. If that happens before
  deployment the script stops with `InitialPriceBelowNav`; raise `INITIAL_MARKET_PRICE` and
  run it again. After deployment it only makes the lowest genesis tokens worth buying and
  redeeming, a loss to the pool position far smaller than the gift.
- The genesis position must be registered before launch and funded before migration can close;
  the contracts enforce both. The script registers the pool and the genesis range in one
  transaction and funds it right after launch. If `FUND_INITIAL_LIQUIDITY=false`, or that funding
  transaction fails because someone moved the empty pool's price into the genesis range, the
  manager restores the price and funds in one `multicall`: a `swapPrincipal` to a price below the
  range (it spends nothing in an empty pool, so nothing needs to be held) followed by
  `fundInitialLiquidity`.
- Broadcast with `--slow`, so each transaction is sent only after the previous one has
  succeeded, and check `pendingManager`, `initialLiquidityFunded` and `launched` afterwards.
- If someone creates the SZR/WETH pool first at another price, the registration reverts and
  nothing is left half-launched. Set `POOL_FEE` (default 10000) to deploy against a different
  pool instead of racing them, and keep `POOL_TICK_SPACING` at 200: the script refuses a
  spacing under 60, because narrow spacings make range ends cheap to fill (see "Range ends").
- If a griefer both moves the empty genesis pool's price and leaves a little liquidity of their
  own there, restoring it needs someone to sell real SZR into that liquidity (above the genesis
  price, so at a profit). Have a migrated wallet ready to do that and call
  `fundInitialLiquidity` in the same transaction. The script's own funding, right after launch,
  normally leaves no window for this.
- Do not deploy with real funds using `INITIAL_LIQUIDITY_ALLOCATION=0`. Without the permanent
  genesis tokens, active supply can shrink to dust, where a few wei can set NAV to any value and
  price the sale out for good.
- Closing migration opens the sale, the release schedule and the fee auctions. Nothing else does.
- Watch `DestinationAnnounced` events: each one starts a 7-day notice before held WETH can be
  sent to that address.
- Watch `PoolAdded` and `RouteRegistered` events: they list every pool the manager can use, with
  no notice period.
- Partner tokens: no rebasing, unbounded-mint, fee-on-transfer or transfer-restricted tokens.
  The mint rule matters most: in tests, once a token's supply had been multiplied 10,000 to
  100,000 times, that token's fees could no longer be recorded or its auction updated, which
  also blocks withdrawing that pool's liquidity.
  A pool whose partner is WETH has no fee auction, so the rest of this applies only once a
  pool with another partner is added.
- Fee-auction floor: this is what stops fees selling cheaply. Register each partner token with
  `initialPoolRateWad` at its market rate in WETH and `floorWad` just under it (90-95%), never
  at the minimum: with a floor of `1`, a batch that arrives after the price has run down sells
  for dust. Fees never sell below the floor. A floor above the market only makes fees wait; a
  floor far below it lets a quiet auction sell down to it.
- Updating a fee auction: each `updateAsset` restarts the price at twice the given rate, so
  nothing sells for up to about two days afterwards. Do not update on a schedule: in a 30-day
  run, updating every day or more often sold nothing, every two days about half, and weekly
  96% of the fees received. Update in two cases only: the market has fallen below the floor
  (fees have stopped selling), or the floor has slipped under about 80% of the market. Watch
  `AssetUpdated` events for every change.
- What to expect, from simulations with one buyer who takes whatever is cheaper than market
  (buffer 20,000). Market held still, floor at 95%: fees arriving every minute sold at 99.7%
  of market. Market moving 3% or 6% a day for 60 days, updating only when it fell below the
  floor: 0 to 4 updates, 95-99.9% of fees sold within the period, at 96-99% of market, for
  floors set at 80-95%. In a rising market with no updates the floor slipped to as little as
  64% of market, which is why the 80% rule above exists.
- Fee-auction units: rates and floors are WETH wei per smallest token unit, scaled by 1e18.
  For an 18-decimal token worth 0.0004 WETH that is `4e14`; for a 6-decimal token worth the
  same it is `4e26` (checked: one whole 6-decimal token then quotes 0.0008 WETH at the
  restart price). A rate and floor both set far too low sell the waiting fees at once, and
  the only check is that the floor sits below twice the rate, so review these numbers as
  carefully as a transfer.
- Fee-auction buffer: how much stock a purchase is measured against. Size it around the most
  fees expected to wait at once, and never a dust amount: a dust buffer lets one cheap purchase
  push the frozen price out of range, after which recording that token's fees (and so
  withdrawing that pool's liquidity) reverts until the manager calls `updateAsset`.
- A new, empty pool's price can be moved by anyone for free. Before the first deposit, check it;
  the manager can move it back with a `swapPrincipal` (it spends nothing in an empty pool) and
  deposit in the same `multicall`.

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
