## PEN fund flows (end-to-end)

This document captures **how seats and assets move through PEN**, including the off-chain (Snapshot) and on-chain (Azorius) governance steps used for funding distributions.

Legend: solid arrows are token transfers (the underlying ERC20 `asset` or `SeatToken` seats), dashed arrows are non-transfer triggers/calls.

---

## Purchase (asset in, seats out)

```mermaid
flowchart LR
  Buyer["Buyer"]
  BT["BondingTranche"]
  PM["PrincipalManager"]
  PV["Principal ERC4626 vault<br/>principalVault"]
  ST["SeatToken"]

  Buyer -- "asset" --> PM
  PM -- "excess asset" --> PV
  ST -- "seats (mint)" --> Buyer

  Buyer -. "purchase()" .-> BT
  BT -. "mint" .-> ST
  BT -. "pull asset" .-> PM
```

---

## Refund and reclaim (seats burned, asset out on refund)

```mermaid
flowchart LR
  Holder["Seat holder"]
  Reclaimer["Authorized reclaimer"]
  BT["BondingTranche"]
  PM["PrincipalManager"]
  PV["Principal ERC4626 vault<br/>principalVault"]
  ST["SeatToken"]
  Receiver["Refund receiver"]

  %% Refund: seats burned, asset paid out
  Holder -- "seats (burn)" --> ST
  PV -- "asset (if needed)" --> PM
  PM -- "asset" --> Receiver

  Holder -. "refund()" .-> BT
  BT -. "burn" .-> ST
  BT -. "payRefund" .-> PM

  %% Reclaim: seats burned, no asset transfer
  Reclaimer -. "reclaim()" .-> BT
  BT == "seats (burn, no refund)" ==> ST
```

---

## Funding distribution (Snapshot → Azorius → payout)

Ranked-choice slate selection happens **off-chain** on Snapshot. On-chain governance is a simple **YES/NO** Azorius vote that, on execution, calls `PrincipalManager.executeFunding(recipients, amounts)`.

```mermaid
flowchart LR
  SNAP["Snapshot vote<br/>(ranked-choice)"]
  WIN["Winning slate<br/>recipients + amounts"]
  AZ["Azorius proposal<br/>YES / NO"]
  PM["PrincipalManager"]
  PV["Principal ERC4626 vault<br/>principalVault"]
  R1["Recipient 1"]
  Rn["Recipient N"]

  SNAP --> WIN --> AZ
  AZ -. "executeFunding" .-> PM

  PV -- "asset (if needed)" --> PM
  PM -- "asset" --> R1
  PM -- "asset" --> Rn
```
