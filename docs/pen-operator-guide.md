## PEN Operator Guide (Governance + Operations)

This document is a practical guide for **PEN operators / governors** (Safe signers and community members creating proposals).

---

## Change or set the `PrincipalManager` principal vault (governance proposal recipes)

PEN uses **Snapshot X (EVM) proposals (YES/NO voting)** to execute on-chain transactions from the Safe.

The principal vault is the ERC-4626 vault at `PrincipalManager.principalVault()`. The vault may be unset at deployment time (`address(0)`), and can be set later via governance.

If you need to check whether the vault is currently configured, `PrincipalManager` exposes:

- `PrincipalManager.isPrincipalVaultSet()` (returns `true` iff `principalVault != address(0)`)

### Recipe A — Set the principal vault for the first time (when no vault is configured yet)

Use this recipe if:

- `PrincipalManager.isPrincipalVaultSet()` is `false` (unset), **or**
- you are deploying PEN with no vault configured and want to set it later via governance.

**Do NOT include a withdraw step**.

**Proposal transactions (in order):**

1. `PrincipalManager.setPrincipalVault(newVault)`
2. EITHER:
   - `PrincipalManager.depositExcessToPrincipalVault()` (recommended “safe default”), OR
   - `PrincipalManager.depositToPrincipalVault(assets)` if you intentionally want to deposit a specific amount.

**Why no withdraw transaction?**

`PrincipalManager.withdrawFromPrincipalVault(...)` is designed to revert if `principalVault` is unset. That’s intentional: it prevents “silent no-op” proposals and forces governors to choose the correct proposal template.

### Recipe B — Migrate from an existing vault to a new vault (vault rotation)

Use this recipe if:

- `PrincipalManager.principalVault()` is already a real vault address, and
- you want to rotate/migrate to a different vault.

**Proposal transactions (in order):**

1. Withdraw from the current vault into the `PrincipalManager`:
   - First, determine a safe withdrawal amount using the vault’s ERC-4626 view functions (vault implementations can vary):
     - **Pattern A (uses `maxWithdraw`)**: `withdrawable = vault.maxWithdraw(address(PrincipalManager))`
     - **Pattern B (uses `maxRedeem`)**: `withdrawable = vault.convertToAssets(vault.maxRedeem(address(PrincipalManager)))`
       - This is sometimes preferred when vault shares are routed/staked through another contract; in that case you may need to query `maxRedeem` for the actual share holder.
       - Some vault integrations expose a helper like `vaultsMaxWithdraw()` that internally implements this “`maxRedeem` + `convertToAssets`” pattern.
     - **Other patterns may exist** depending on the vault’s strategy/design (withdraw limits, cooldowns, staking wrappers, etc.). Always follow the vault’s recommended method for determining a safe withdrawable amount.
   - Then withdraw that amount:
     - `PrincipalManager.withdrawFromPrincipalVault(withdrawable, address(0))` (withdraws to `PrincipalManager`)
2. `PrincipalManager.setPrincipalVault(newVault)`
3. `PrincipalManager.depositExcessToPrincipalVault()` or `PrincipalManager.depositToPrincipalVault(assets)`

Note:
- **Why `withdrawFromVault(...)` was added**: when governance sets a new `principalVault`, it first withdraws from the current one using `withdrawFromPrincipalVault(...)`, but some vaults may not allow full-balance withdrawal at that time (e.g. temporary illiquidity, limits, cooldown/strategy constraints). In that case, funds can remain in the older vault. `withdrawFromVault(...)` exists so governance can still withdraw from those older vaults later, even after the active vault pointer has moved, subject to each vault's own constraints.
- **Drain the old vault promptly.** `PrincipalManager._ensureLiquidity(...)` (invoked by every refund and every `executeFunding` call) can only withdraw from the *current* `principalVault`. Funds still held in a previous vault count toward `totalManagedAssets()` (they satisfy the refund solvency precheck), but they cannot be pulled automatically to satisfy a refund. If liquid reserves and the current vault together cannot cover a refund, the refund will revert even though the system is nominally solvent. Governance must therefore treat any nonzero balance in a previous vault as a live operational task and follow up with `withdrawFromVault(oldVault, amount, address(0))` proposals until the previous vault is empty. See also §"Managing previous principal vaults" below.

### Notes / operational checklist

- **First-time set vs migration are different templates**: if the vault is unset, do not include withdraw.
- **Deposit step**: `depositExcessToPrincipalVault()` avoids having to compute a precise deposit amount and leaves the manager’s liquid reserve target intact.

---

## Managing previous principal vaults

Every time `setPrincipalVault(newVault)` rotates to a different vault, the outgoing vault is appended to `PrincipalManager.previousPrincipalVaults[]` (deduplicated). Entries in that array are read by `deployedAssets()` / `totalManagedAssets()` and never removed automatically.

The operator has two reasons to actively curate this array:

1. **Keep the auto-liquidation path clean** — `_ensureLiquidity(...)` only pulls from the current vault; balances left in previous vaults are "solvent on paper, unreachable in practice" (see the note in Recipe B above).
2. **Excise impaired or defunct integrations** — a vault that reverts on `balanceOf` / `convertToAssets` no longer breaks `totalManagedAssets()` (reverting reads are treated as zero), but it stays in the array forever unless governance removes it. A vault whose shares are permanently lost (hack, insolvency, unrecoverable freeze) is the same situation: its contribution should be excised so accounting reflects reality.

### Recipe C — Remove a drained previous vault (normal cleanup)

Use this recipe after Recipe B when the previous vault has been fully drained via `withdrawFromVault(...)`.

**Pre-flight check (off-chain):**

- Confirm `previousVault.balanceOf(address(PrincipalManager)) == 0`. If it's nonzero, follow Recipe B (drain first) — otherwise proceeding with removal will abandon the remaining shares.

**Proposal transactions (in order):**

1. `PrincipalManager.removePreviousVault(previousVault)`

`removePreviousVault(...)` swap-and-pops the entry from `previousPrincipalVaults[]` and clears the tracking mapping. It reverts on:

- `PreviousVaultNotTracked(vault)` — the address is not in the array (never was, or was already removed).
- `PreviousVaultIsCurrent(vault)` — the address is currently `principalVault()`. Rotate away with Recipe B first.

### Recipe D — Write off an impaired previous vault (loss / freeze)

Use this recipe only when the previous vault's shares are unrecoverable — the integration is hacked, the vault is permanently paused, upgraded to reverting code, or governance has otherwise decided to abandon those shares.

**`removePreviousVault(...)` does not check the remaining share balance.** Whatever balance the contract still holds at the moment of removal is *written off*: the contract keeps the shares (they cannot be reintroduced except by rotating that vault back in via `setPrincipalVault`) but they no longer contribute to `totalManagedAssets()`.

**Proposal transactions (in order):**

1. `PrincipalManager.removePreviousVault(impairedVault)`

The emitted `PreviousPrincipalVaultRemoved(vault, abandonedShares)` event records the last observed share balance (best-effort — a reverting `balanceOf` reports zero). This is the on-chain audit trail for the write-off; make sure the associated governance proposal justifies the loss.

### Recovery limitation after a write-off

`BondingTranche.refundPrice` is `immutable`. The refund solvency precheck is:

```
totalSupply(SeatToken) * refundPrice <= totalManagedAssets()
```

If a write-off (Recipe D) drops `totalManagedAssets()` below `totalSupply * refundPrice`, **all refunds are blocked** until one of:

- Enough fresh assets are injected into `PrincipalManager` (yield harvested, treasury top-up, insurance) to restore the ratio.
- `SeatToken.totalSupply()` shrinks (holders burning seats via reclaim of inactive holders, or through a subsequent successful refund cycle once solvency is restored).
- The PEN instance is migrated / redeployed with different parameters (see `docs/pen-migration.md`).

There is no on-chain "reduce the per-seat refund price" primitive. Operators considering Recipe D on a material portion of assets should have the recovery path decided beforehand.

---

## Refunds: solvency gating (intended behavior)

Refunds are paid via `BondingTranche.refund(...)`, which internally calls `PrincipalManager.payRefund(...)`.

`PrincipalManager` will **block refunds** if the system is insolvent from an accounting perspective:

- Refunds revert when `totalManagedAssets() < accountedPrincipal` (revert: `PrincipalInsolvent(accountedPrincipal, totalManagedAssets)`).

This is **intended behavior**: `accountedPrincipal` represents the protocol’s principal obligation created when seats are sold, and refunds should not proceed if the system no longer has enough managed assets to cover that obligation.

### Operational remediation

If refunds are blocked due to insolvency and governance wants refunds to be available again, governance must **restore solvency** by making `totalManagedAssets()` exceed `accountedPrincipal`, e.g.:

- Transfer additional `asset` tokens into the `PrincipalManager` (increasing `liquidAssets()`).

---

## Execute funding payouts (governance proposal recipes)

### Context (off-chain → on-chain)

PEN funding rounds are expected to run as:

1. **Off-chain (Snapshot, ranked-choice)**: The Ranked-Choice funding execution voting happens off-chain on Snapshot. Members submit slates and they vote and a *winning slate* (recipients + amounts) is selected.
2. **On-chain (Snapshot X / EVM, YES/NO)**: a member submits a proposal that encodes that winning slate as executable transactions, and seat holders vote YES/NO.

### On-chain execution patterns

When governance wants to pay out funds to multiple recipients (e.g. after an off-chain Snapshot vote decides the winning slate), there are two on-chain execution patterns.

### Option 1 (recommended): single transaction batch payout

**Proposal transactions (in order):**

1. `PrincipalManager.executeFunding(recipients, amounts)`

This is kept as a first-class primitive because it is **more gas efficient under Snapshot X execution** than executing many per-recipient transfers.

### Option 2: withdraw to the Safe, then do N transfers

**Proposal transactions (in order):**

1. `PrincipalManager.withdrawFromPrincipalVault(totalAmount, safe)`
2. \(N times\) `ERC20(asset).transfer(recipient, amount)`

This is operationally flexible, but it is generally **more expensive in governance execution** because the Snapshot Safe pays overhead per transaction in the MultiSend batch.

---

## Seat reclaim (governance proposal recipes)

`BondingTranche.reclaim(holder)` burns a seat from a holder whose `SeatToken.lastActivityAt` is older than `SeatToken.inactivityPeriod` (365 days at current settings). It's the mechanism that keeps voting supply reflective of the active participant set.

### Why refresh matters before reclaim

Under the current design, **`lastActivityAt` is only updated by the permissionless `SeatToken.refreshActivity*` calls** — voting through the Space no longer refreshes activity as a side effect (see `docs/future-refresh-activity.md`). An active voter therefore looks "inactive" on-chain if nobody has called refresh for them since their last vote. Proposing reclaim against such a holder is technically valid but socially wrong: they participated, the record just hasn't caught up.

**Before submitting a reclaim proposal, the operator MUST close this gap.** Two paths are available and should be used together for defense-in-depth.

### Path A — Refresh before proposing (mandatory pre-flight)

Off-chain, for each holder being considered for reclaim:

1. Scan the Space's `VoteCast(proposalId, voter, ...)` and `ProposalCreated(proposalId, author, ...)` events for any activity by that holder since `now - inactivityPeriod`. Collect the matching `proposalId`s.
2. If any hit, refresh the on-chain record:
   - Single hit: `SeatToken.refreshActivity(holder, proposalId)` (or `refreshActivityForProposal(holder, proposalId)` if they authored, not voted).
   - Multiple hits or a batch of holders: `SeatToken.refreshActivityBatch(voters, proposalIds)` — non-matches are silently skipped, so a mixed batch is safe.
3. Re-read `SeatToken.isInactive(holder)`. If `false`, **do not propose reclaim**.
4. If still `true` after refresh, proceed to Path B.

Anyone can run this — the calls are permissionless. In practice this belongs to a keeper (see `docs/future-refresh-activity.md` §"Who calls refreshActivity" case 2), but until a keeper is deployed it's the operator's responsibility.

### Path B — Prepend a defensive refresh to the reclaim payload (recommended)

Even after a clean Path A, wrap the reclaim in a refresh guard so a late vote by the target during the reclaim's own voting window can't be silently ignored.

**Proposal transactions (in order):**

1. `SeatToken.refreshActivityForProposalVoters(recentProposalId, [holder])` — silently no-ops if the holder didn't vote on `recentProposalId`. Pick a proposal that just closed, or the reclaim proposal itself (see note below).
2. `BondingTranche.reclaim(holder)`.

If the holder actually voted on `recentProposalId`, transaction 1 sets `lastActivityAt`, `isInactive` flips to `false`, and transaction 2 reverts `HolderStillActive`. The whole batch fails and the seat is preserved. If the holder did nothing, transaction 1 is a no-op and the reclaim proceeds.

For a batch reclaim (multiple holders in one proposal), pass all of them into the same `refreshActivityForProposalVoters` call and follow with one `reclaim` per holder.

### The reclaim proposal's own voting window is a refresh opportunity for the target

Independently of the operator's choices, the reclaim proposal has a voting window during which the target can vote (any choice). After that vote lands, **anyone** can call `refreshActivity(target, reclaimProposalId)` before execution. That will make the reclaim revert at execution time.

This is intended behavior — see `docs/future-refresh-activity.md` §Design Decision #8 and `test/integration/EndToEndProposal.t.sol::test_reclaim_evadedByOnTimeVote`. An on-time vote by the target beats a reclaim by construction. Operators shouldn't be surprised when a reclaim proposal passes the vote but reverts at execution: the system is working as designed. If this is a repeated pattern, address it socially (why is the target coming back only to block reclaims?) rather than trying to engineer it away.

---

## Extend `BondingTranche` sale cap (add tranches)

`BondingTranche` sells seats according to a tranche schedule: each tranche defines an **upper bound** (cumulative seats sold) and a **price per seat**.

The **current sale cap** is the *final tranche upper bound*. When total supply reaches that bound, `BondingTranche.quotePurchase(...)` will revert `SoldOut()` until governance extends the schedule.

### Recipe — Append new tranche(s) via governance

**Proposal transactions (in order):**

1. `BondingTranche.extendTranches(newUpperBounds, newPrices)`

Where:

- `newUpperBounds`: strictly increasing cumulative upper bounds (e.g. `[700, 1000]`)
- `newPrices`: the corresponding seat prices for each new tranche (e.g. `[80e6, 120e6]` for a 6-decimal asset)

### Important constraints enforced on-chain

For each appended tranche:

- `upperBound` must be **strictly greater** than the previous final upper bound
- `price` must be **strictly greater** than the previous final price (a tranche that repeats the previous price is redundant — just widen the previous tranche instead)
- `upperBound` must be **strictly greater** than the current `SeatToken.totalSupply()` (extensions must actually extend sales)
- `upperBound` must be **<= `SeatToken.supplyCap()`**

