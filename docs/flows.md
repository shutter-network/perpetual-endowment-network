## PEN fund flows (end-to-end)

This document captures **how principal and yield move through PEN**, including the off-chain (Snapshot) and on-chain (Azorius) governance steps used for funding distributions.

---

## Principal + yield flow (core accounting)

```mermaid
flowchart TD
  A[User buys seats\nBondingTranche.purchase] -->|asset transfer| PM[PrincipalManager]
  A -->|recordPurchase(amount)| PM
  PM -->|accountedPrincipal += amount| AP[accountedPrincipal\n(refund obligation)]
  PM -->|keep liquidReserveTarget liquid| L[Liquid assets in\nPrincipalManager]
  PM -->|excessLiquidAssets() deposit| PV[Principal ERC4626 vault\nprincipalVault]
  PV -->|shares owned by PM| PVSH[PM vault shares]

  %% Yield definition
  PV -->|strategy earns\n(share price ↑)| YGEN[Yield accrues\ninside principal vault]
  PM -->|availableYield() =\ntotalManagedAssets - accountedPrincipal| AY[availableYield > 0\n(accounting view)]
```

---

## Refunds + reclaim (principal obligation exits)

```mermaid
flowchart TD
  %% Principal comes in
  A[User buys seats\nBondingTranche.purchase] -->|asset transfer| PM[PrincipalManager]
  A -->|recordPurchase(amount)| PM
  PM -->|accountedPrincipal += amount| AP[accountedPrincipal]
  PM -->|keep liquidReserveTarget liquid| L[Liquid assets in PrincipalManager]
  PM -->|excessLiquidAssets() deposit| PV[Principal ERC4626 vault\nprincipalVault]

  %% Only exit path for principal obligation: refunds
  R[Seat holder refunds\nBondingTranche.refund] -->|burn seats| ST[SeatToken burn]
  R -->|payRefund(receiver, refundAmount)| PR[PrincipalManager.payRefund]
  PR -->|checks:\namount <= accountedPrincipal\nand totalManagedAssets >= accountedPrincipal| CHK[Solvency checks]
  PR -->|_ensureLiquidity(amount)\nwithdraw from principalVault if needed| LIQ[Liquidity secured]
  PR -->|accountedPrincipal -= amount| AP
  PR -->|ERC20 transfer| REFREC[Refund receiver gets assets]

  %% Reclaim path (no refund)
  C[Authorized reclaimer\nBondingTranche.reclaim] -->|requires:\nSeatToken.isInactive(holder)| INACT[Inactive seat holder]
  C -->|burn all seats| ST
```

---

## Funding distribution (Snapshot → Azorius → payout)

Ranked-choice slate selection is **off-chain** (Snapshot). On-chain governance is a simple **YES/NO** vote to execute the winning slate as transactions.

```mermaid
flowchart TD
  F[Funding round] --> SNAP[Snapshot vote\nranked-choice over slates]
  SNAP --> WIN[Winning slate\nrecipients + amounts]
  WIN --> PROP[Azorius proposal\nYES/NO]
  PROP -->|passes + timelock| EXEC[Azorius.executeProposal]
  EXEC -->|calls| EF[PrincipalManager.executeFunding\n(recipients, amounts)]
  EF -->|_ensureLiquidity(total)\nwithdraw from principalVault if needed| PM[PrincipalManager]
  EF -->|ERC20 transfers| RECIPS[Recipients receive assets]
```

Notes:

- `PrincipalManager.executeFunding(...)` **does not decrement** `accountedPrincipal` (refund obligation).
- Operationally, governance should keep distributions within what the community considers “yield” (often approximated by `availableYield()`), since `availableYield()` is a view helper and not enforced as a spend limit.

---
