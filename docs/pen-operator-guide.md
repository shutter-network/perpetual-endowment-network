## PEN Operator Guide (Governance + Operations)

This document is a practical guide for **PEN operators / governors** (Safe signers and community members creating proposals).

---

## Change or set the `PrincipalManager` principal vault (governance proposal recipes)

PEN uses **Azorius proposals (YES/NO voting)** to execute on-chain transactions from the Safe.

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

### Notes / operational checklist

- **First-time set vs migration are different templates**: if the vault is unset, do not include withdraw.
- **Deposit step**: `depositExcessToPrincipalVault()` avoids having to compute a precise deposit amount and leaves the manager’s liquid reserve target intact.

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
2. **On-chain (Azorius, YES/NO)**: a member submits a proposal that encodes that winning slate as executable transactions, and seat holders vote YES/NO.

### On-chain execution patterns

When governance wants to pay out funds to multiple recipients (e.g. after an off-chain Snapshot vote decides the winning slate), there are two on-chain execution patterns.

### Option 1 (recommended): single transaction batch payout

**Proposal transactions (in order):**

1. `PrincipalManager.executeFunding(recipients, amounts)`

This is kept as a first-class primitive because it is **more gas efficient under Azorius execution** than executing many per-recipient transfers.

### Option 2: withdraw to the Safe, then do N transfers

**Proposal transactions (in order):**

1. `PrincipalManager.withdrawFromPrincipalVault(totalAmount, safe)`
2. \(N times\) `ERC20(asset).transfer(recipient, amount)`

This is operationally flexible, but it is generally **more expensive in governance execution** because Azorius/Safe pays overhead per transaction.

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

- `price != 0`
- `upperBound` must be **strictly greater** than the previous final upper bound
- `upperBound` must be **strictly greater** than the current `SeatToken.totalSupply()` (extensions must actually extend sales)
- `upperBound` must be **<= `SeatToken.supplyCap()`**

