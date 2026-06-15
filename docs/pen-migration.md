## PEN → PEN Migration Runbook

This document is a practical guide for **PEN operators / governors** executing a migration from one PEN deployment to another. The on-chain primitives that support this — `pause()`/`unpause()` and `withdraw(token, to, amount)` on `PrincipalManager` — are documented for the deploy-time admin, the Safe.

The migration model is intentionally generic. A "new PEN" can differ from the old one along any axis: different payment asset, different seat token parameters, different bonding-tranche schedule, different governance configuration. **Asset migration** (e.g. USDC → USDT) is the canonical and most likely use case, but the same procedure applies whenever you need to roll the system forward into a fresh deployment.

> The original deployment's `SeatToken`, `BondingTranche`, and `PrincipalManager` are **immutable in their core configuration** — the payment asset, refund price, and tranche schedule are all fixed at deploy time. Changing any of these means deploying a new PEN. This doc describes how to do that cleanly.

---

## When to use this

Use this runbook when governance has decided to:

- Replace the payment asset (most common reason — e.g. one stablecoin is being deprecated or has gained regulatory issues).
- Change the bonding tranche schedule or refund price beyond what `extendTranches` can do.
- Restructure the seat token (e.g. different inactivity period, different supply cap).
- Adopt a new governance configuration that requires fresh contract addresses.

Each of these requires deploying new contracts; the migration is the process of winding the old deployment down and handing the treasury over.

---

## Primitives

Two admin functions on `PrincipalManager`, both gated by `DEFAULT_ADMIN_ROLE` (held by the Safe):

- **`pause()` / `unpause()`** — freezes user-state-changing flows: `BondingTranche.purchase`, `BondingTranche.refund`, and `BondingTranche.reclaim` all revert while paused. Admin operations (`executeFunding`, `withdraw`, vault management, role administration) continue to work.
- **`withdraw(IERC20 token, address to, uint256 amount)`** — sends any ERC-20 balance held by `PrincipalManager` to a chosen receiver. Callable at any time, not gated by pause. Does **not** decrement `accountedPrincipal` — the refund obligation remains on book.

That's the entire on-chain surface. There is no in-place asset migration, no "pending state," no two-vote ceremony. The old PEN is wound down by pausing and withdrawing; the new PEN is a separate deployment.

---

## Procedure

### Step 0 — Deploy the new PEN

Use `script/DeployPENSystem.s.sol` against a new `.env` that captures the new configuration (new payment asset, refund price, tranche schedule, etc.). The new Safe, `SeatToken`, `BondingTranche`, and `PrincipalManager` will have new addresses.

Acceptance: the new system passes the same handoff checks as the original deploy (see `_finalizeAccess` and the `test_deploySystem_handsOffAccessToSafe` assertions).

### Step 1 — Announce

Communicate to seatholders that the old PEN is being wound down. Establish:

- When `pause()` will be called on the old `PrincipalManager`.
- When (and how) seatholders will be issued seats on the new PEN — this is a governance/social decision, not an on-chain primitive. Typical options:
  - **Snapshot-based reissue:** snapshot old-PEN seat balances at the pause block; new-PEN governance mints equivalent seats to the same holders.
  - **Voluntary re-bonding:** holders refund on the old PEN (before pause) and buy fresh seats on the new PEN with the refund proceeds.
  - **Hybrid:** dust holders snapshot-reissued; active holders re-bond.
- Whether activity timestamps will be preserved (they cannot be transferred automatically — the new SeatToken starts everyone fresh).

### Step 2 — Pause the old PrincipalManager

```solidity
oldPrincipalManager.pause()
```

After execution:

- `BondingTranche.purchase` reverts (cascade via `PrincipalManager.recordPurchase`).
- `BondingTranche.refund` reverts (cascade via `PrincipalManager.payRefund`).
- `BondingTranche.reclaim` reverts (checks `principalManager.paused()` directly).
- `PrincipalManager.executeFunding`, vault management, and `withdraw` all continue to work.

### Step 3 — Wind down vault positions (if any)

If the old `PrincipalManager` has a configured `principalVault`, drain it back to liquid:

```solidity
shares = oldPrincipalVault.balanceOf(oldPrincipalManager)
oldPrincipalManager.withdrawFromPrincipalVault(oldPrincipalVault.maxWithdraw(oldPrincipalManager), oldSafe)
```

(Or use `withdrawFromVault` for entries in `previousPrincipalVaults` if applicable.)

### Step 4 — Withdraw treasury

```solidity
oldPrincipalManager.withdraw(asset, recipient, amount)
```

`recipient` can be:

- The Safe (recommended) — for governance to hold and then route however appropriate (swap to a different asset, deposit into the new PrincipalManager, etc.).
- The new `PrincipalManager` directly, if the new PEN uses the same asset.
- An OTC counterparty, swap router, etc.

`amount` is typically the full balance (`asset.balanceOf(oldPrincipalManager)`).

### Step 5 — Seed the new PrincipalManager

How the new PrincipalManager gets funded depends on the migration scenario:

- **Same asset:** transfer the withdrawn balance directly into the new `PrincipalManager`. Then governance on the new PEN mints seats to the original holders (Step 1 plan).
- **Different asset (e.g. USDC → USDT):** the Safe swaps externally (CowSwap, Curve, OTC) and then transfers the new-asset balance into the new `PrincipalManager`. Note that the swap may incur slippage; the principal-coverage delta is a governance decision (top up from yield, accept a small refund-obligation reduction, etc.).
- **Different parameters but same asset:** identical to the same-asset case.

### Step 6 — Wind down or leave the old contracts dormant

The old contracts remain on-chain. Options:

- **Leave dormant:** the most common path. Old contracts are paused; no further state changes possible. Holders who didn't re-bond keep their (now-frozen) old seats indefinitely.
- **Unpause if needed:** governance can call `unpause()` later if there's a reason to reactivate the old system (e.g. allowing late refunds). The asset remains the original one, since `PrincipalManager.asset` is immutable.

---

## Risks

### 1. Refund obligation continuity

When `withdraw()` moves the old asset to the Safe, `accountedPrincipal` stays at its pre-withdrawal value. If governance later unpaused the old system to allow late refunds, the old `PrincipalManager` would not have the assets to honor those refunds unless they're returned.

In practice this isn't a problem because the migration plan replaces the old seats with new seats — refunds happen on the new PEN, not the old one. But governance must be explicit about this. Document the plan before pausing.

### 2. Asset swap slippage (asset-migration scenario)

A USDC → USDT swap on mainnet at PEN-sized notional will bleed somewhere between 0.05% (CowSwap, OTC) and 0.5% (DEX, no protection). For a $50M treasury that's $25K–$250K of realised principal loss. Governance must decide who absorbs the loss:

- Top up from accumulated yield (`availableYield()` on the old PrincipalManager).
- Top up from external funding.
- Reduce the new refund price proportionally (changes the seat economics — usually undesirable).

### 3. Activity-timestamp loss

`SeatToken.lastActivityAt` cannot be transferred to a new seat token. Whatever seatholders accrued in the old PEN resets to zero (or to the new mint timestamp) on the new PEN. If preserving activity matters (e.g. inactive seatholders should still count as inactive in the new system), governance must replay the relevant state — there is no on-chain primitive for this.

### 4. Old PEN's offchain integrations

Frontends, indexers, oracles that point at the old `Space`, `SeatToken`, `BondingTranche`, etc. must be updated to the new addresses. The old contracts continue to function (in paused mode) so stale integrations won't break catastrophically, but they'll be reading dead state.

### 5. Holder coordination

The migration's success depends on seatholders actively engaging — refunding from the old PEN, accepting reissue on the new PEN, updating their interaction tooling. A migration that's announced too quietly will leave a long tail of stale old-PEN seats and underutilised new-PEN seats.

---

## Worked example — asset migration (USDC → USDT)

Assume the old PEN holds 5,000,000 USDC of principal across 1,234 seats with refund price 0.5 USDC. Target: a new PEN deployed against USDT with the same parameters.

```
# Step 0 — deploy
PAYMENT_ASSET=<USDT_ADDR> forge script DeployPENSystem ...

# Step 1 — announce: snapshot-based reissue at pause block

# Step 2 — pause
cast send $OLD_PM "pause()" --private-key $SAFE_PROPOSAL  # via Snapshot X

# Step 3 — drain vault (if set)
cast send $OLD_PM "withdrawFromPrincipalVault(uint256,address)" \
  $(cast call $OLD_PRINCIPAL_VAULT "maxWithdraw(address)(uint256)" $OLD_PM) \
  $OLD_SAFE

# Step 4 — withdraw USDC to Safe
USDC_BAL=$(cast call $USDC "balanceOf(address)(uint256)" $OLD_PM)
cast send $OLD_PM "withdraw(address,address,uint256)" $USDC $OLD_SAFE $USDC_BAL

# Step 5a — swap USDC → USDT (CowSwap, OTC, etc.) on Safe

# Step 5b — seed new PrincipalManager with USDT
cast send $USDT "transfer(address,uint256)" $NEW_PM <amount>

# Step 5c — new-PEN governance proposal mints seats to original holders
# (off-chain script reads old SeatToken.balanceOf() at pause block; submits mint proposals on new PEN)
```

After Step 5c, the new PEN is live and the old PEN sits paused with stale state.

---

## Related docs

- `docs/pen-operator-guide.md` — general governance proposal recipes
- `docs/flows.md` — purchase, refund, and reclaim flow diagrams
