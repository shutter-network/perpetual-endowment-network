# PEN Contracts

This repository contains the current PEN core contracts implemented in Foundry:

- `SeatToken`: non-transferable `ERC20Votes` seat token with `decimals = 0`
- `BondingTranche`: seat sale, fixed refund, and inactivity reclaim logic
- `PrincipalManager`: principal treasury controller with refund liquidity management, principal accounting, and external ERC-4626 vault integrations
- `FundingSlateExecutor`: governance-owned yield-vault receiver that stores slate payloads and executes winning funding distributions

## Setup

After cloning the repo, initialize submodules before building or testing:

```sh
git submodule update --init --recursive
```

## Contract Roles

- `SeatToken`
  - `MINTER_ROLE`: bonding contract mints seats on purchase
  - `BURNER_ROLE`: bonding contract burns seats on refund or reclaim
  - `ACTIVITY_ROLE`: future governance integration records vote activity
- `BondingTranche`
  - `DEFAULT_ADMIN_ROLE`: config/admin role
  - `RECLAIMER_ROLE`: allowed to reclaim inactive seats
- `PrincipalManager`
  - `DEFAULT_ADMIN_ROLE`: treasury admin
  - `BONDING_ROLE`: bonding contract can record purchases and trigger refunds
  - `STRATEGIST_ROLE`: can manually deposit to or withdraw from the vault

## Purchase Flow

1. User calls `approve(assetAmount)` on the `BondingTranche` contract for the payment asset.
2. User calls `BondingTranche.purchase(recipient, seats, maxCost)`.
3. `BondingTranche` computes the tranche-based purchase price from current seat supply.
4. `BondingTranche` transfers the payment asset from the buyer directly into `PrincipalManager`.
5. `BondingTranche` calls `PrincipalManager.recordPurchase(totalCost)`.
6. `PrincipalManager` increases `accountedPrincipal` by the purchase amount.
7. `PrincipalManager` keeps the configured liquid reserve and auto-deposits any excess into the configured external ERC-4626 principal vault.
8. `BondingTranche` mints seats to the recipient through `SeatToken`.

If no vault is configured, purchase proceeds remain liquid inside `PrincipalManager`.

## Refund Flow

1. Seat holder calls `BondingTranche.refund(seats, receiver)`.
2. `BondingTranche` computes the fixed refund amount as `seats * refundPrice`.
3. `BondingTranche` burns the holder's seats through `SeatToken`.
4. `BondingTranche` calls `PrincipalManager.payRefund(receiver, refundAmount)`.
5. `PrincipalManager` pays from liquid funds first.
6. If liquid funds are insufficient and a vault is configured, `PrincipalManager` withdraws the shortfall from the ERC-4626 vault and completes the refund.
7. `PrincipalManager` decreases `accountedPrincipal` by the refund amount.

Refunds reduce total seat supply, so the current tranche cursor moves backward automatically.

## Reclaim Flow

1. An authorized reclaimer checks whether a holder is inactive using `SeatToken.isInactive(holder)`.
2. `BondingTranche.reclaim(holder)` burns all seats held by that account.
3. No refund is paid during reclaim.

Reclaims also reduce total seat supply, so they move pricing backward in the same way as refunds.

## Treasury Model

- `PrincipalManager` is the PEN principal treasury controller.
- The ERC-4626 vault is the principal deployment venue.
- The yield vault is also an external ERC-4626 vault.
- Purchase proceeds land in `PrincipalManager` first for accounting and refund liquidity handling.
- Excess liquidity is then deposited into the vault automatically on purchase or manually by a strategist.
- `accountedPrincipal` tracks the protocol's principal obligation.
- `availableYield = max(totalManagedAssets - accountedPrincipal, 0)`.
- Principal is never distributed as grants from these contracts.

## Yield Flow

1. Principal remains associated with `PrincipalManager` and the configured ERC-4626 vault.
2. Yield is defined as any raw-asset value above `accountedPrincipal`.
3. Governance sets the external yield-vault address and receiver on `PrincipalManager`.
4. The intended receiver is `FundingSlateExecutor`, which holds yield-vault shares on behalf of the governance system.
5. When governance wants to move yield, it calls `PrincipalManager.transferYieldToVault(amount)`.
6. `PrincipalManager` verifies that `amount <= availableYield()`.
7. If needed, `PrincipalManager` withdraws raw assets from the principal ERC-4626 vault.
8. `PrincipalManager` deposits those raw assets into the external yield ERC-4626 vault using the configured receiver address.
9. Seat holders register funding slates in `FundingSlateExecutor`, and a governance proposal can later call `FundingSlateExecutor.executeFunding(proposalId)` to distribute the winning slate.

Only yield can be moved to the external yield vault; principal accounting is unchanged by yield transfers.

## Quorum And Slate Voting

- `PENRankedChoiceStrategy` uses ranked-choice voting to determine which slate wins.
- Quorum is not part of the winner-selection algorithm. The winner is resolved from ballot rankings and voting weights alone.
- Quorum is checked separately when deciding whether the proposal has passed.
- In practice, each valid ranked ballot is cast as a `YES` vote with the holder's ERC-20 seat weight.
- Because of that, quorum is effectively: total ranked-ballot voting weight cast must be at least `quorumThreshold`.
- This means a winning slate can exist even when quorum is not met. In that case, the proposal does not pass and cannot be executed.

So the flow is:
1. ranked-choice picks the winning slate
2. quorum determines whether that result is actionable as a passed proposal

## Default Slate Behavior

- `PENRankedChoiceStrategy` always initializes each proposal with default slate `0`.
- Slate `0` is a fallback voting option, not a registered payout slate with recipients and amounts.
- If ranked-choice voting resolves to slate `0`, `FundingSlateExecutor.executeFunding(...)` performs no distribution and leaves the assets in the yield vault.
- This means the current system behavior for a default-slate win is "leave yield parked in the yield vault," not "automatically reinvest into principal."

This distinction is intentional in the current codebase. Reinvestment can be added later as an explicit execution path, but it is not encoded today.

## Current Limitations

- Default slate `0` currently behaves as a no-op in `FundingSlateExecutor`; explicit reinvest execution is still a separate step.
- The ERC-4626 integration is generic for now; tests use demo ERC-4626 vaults, while production is expected to point at Octant v2-compatible vaults.

## Commands

Build:

```sh
forge build
```

Test:

```sh
forge test --offline
```

Format:

```sh
forge fmt
```
