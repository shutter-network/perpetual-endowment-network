# PEN Contracts

This repository contains the current PEN core contracts implemented in Foundry:

- `SeatToken`: non-transferable `ERC20Votes` seat token with `decimals = 0`
- `BondingTranche`: seat sale, fixed refund, and inactivity reclaim logic
- `PrincipalManager`: principal treasury controller with refund liquidity management, principal accounting, and external ERC-4626 vault integrations

## Setup

After cloning the repo, initialize submodules before building or testing:

```sh
git submodule update --init --recursive
```

## PEN Blueprint + governance flow (end-to-end)

PEN is designed as a minimal on-chain core with off-chain slate selection:

- **On-chain (PEN blueprint)**:
  - `SeatToken` + `BondingTranche` + `PrincipalManager`
  - a **Decent Azorius** governance instance with a **YES/NO strategy** (`PENStrategyV1` wrapping Decent `StrategyV1`)
- **Off-chain**:
  - Ranked-choice slate formation and selection on **Snapshot**

### Funding flow (Snapshot ranked-choice → Azorius execution)

1. **Forum / discussion (optional)**: community proposes candidate slates off-chain (each slate = recipients + amounts, plus a “none of the above” option).
2. **Snapshot (ranked-choice)**: members vote off-chain; the outcome is a *single winning slate* (recipients + amounts).
3. **Azorius proposal creation (on-chain)**: a member creates a proposal that encodes the *winning slate* as executable transactions.
4. **Azorius vote (on-chain, YES/NO)**: seat holders vote YES/NO under the Decent strategy.
5. **Execute (on-chain)**: once timelock elapses, the proposal becomes executable and the encoded transactions can be executed.

For PEN treasury batch payouts, the canonical execution transaction is:

- `PrincipalManager.executeFunding(recipients, amounts)`

This single-call “batch payout” primitive is materially cheaper (under Azorius execution) than executing 1 + N transactions (withdraw to Safe + N ERC20 transfers).
Take a look at the [PEN Operator Guide](docs/pen-operator-guide.md).

## Contract Roles

- `SeatToken`
  - `MINTER_ROLE`: bonding contract mints seats on purchase
  - `BURNER_ROLE`: bonding contract burns seats on refund or reclaim
  - `ACTIVITY_ROLE`: governance voting refreshes seat activity (via `PENStrategyV1`)
- `BondingTranche`
  - `DEFAULT_ADMIN_ROLE`: config/admin role
  - `RECLAIMER_ROLE`: allowed to reclaim inactive seats
- `PrincipalManager`
  - `DEFAULT_ADMIN_ROLE`: treasury admin
  - `BONDING_ROLE`: bonding contract can record purchases and trigger refunds

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
- Purchase proceeds land in `PrincipalManager` first for accounting and refund liquidity handling.
- Excess liquidity is then deposited into the vault automatically on purchase or manually by the treasury admin.
- `accountedPrincipal` tracks the protocol's principal obligation.
- `availableYield = max(totalManagedAssets - accountedPrincipal, 0)`.

## Yield Flow

1. Principal remains associated with `PrincipalManager` and the configured ERC-4626 principal vault (`principalVault`).
2. Yield is defined as any raw-asset value above `accountedPrincipal`:
   - `availableYield = max(totalManagedAssets - accountedPrincipal, 0)`
3. Off-chain, the community selects a *winning slate* (recipients + amounts) via Snapshot ranked-choice voting.
4. On-chain, a member creates a Decent Azorius proposal encoding the winning slate as a batch payout:
   - `PrincipalManager.executeFunding(recipients, amounts)`
5. On execution, `PrincipalManager` pays from liquid assets first, and if needed withdraws the shortfall from the ERC-4626 principal vault to reach the required liquidity.
6. `accountedPrincipal` is not changed by funding execution; it remains the refund obligation created when seats were sold.


## Current Limitations

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

## Scripted Deployment

The repository includes two deployment-facing scripts:

- `PreviewPENSystem.s.sol`: previews the full address plan from a deployer address, current nonce, and `DEPLOYMENT_SALT`
- `DeployPENSystem.s.sol`: deploys the Safe singleton, Safe proxy factory, Safe bootstrap helper, governance stack, and core treasury contracts in one script run

The deployment flow is:
1. derive the deployer address and starting nonce
2. deterministically predict every contract address from that deployment sequence plus `DEPLOYMENT_SALT`
3. deploy all contracts in the predicted order
4. create the Safe with Azorius enabled during `Safe.setup`
5. initialize governance and hand all admin/executor/reclaimer control to the Safe

Deployment steps:

1. set `.env` from `.env.example`
2. run preview against the exact deployer address you will broadcast from
3. verify the predicted addresses
4. broadcast without sending any other transaction from that deployer in between

Required environment variables:

- `DEPLOYMENT_SALT`
- `PRIVATE_KEY` or `DEPLOYER`
- `SEAT_TOKEN_NAME`
- `SEAT_TOKEN_SYMBOL`
- `SEAT_TOKEN_SUPPLY_CAP`
- `SEAT_TOKEN_INACTIVITY_PERIOD`
- `REFUND_PRICE`
- `LIQUID_RESERVE_TARGET`
- `PAYMENT_ASSET`
- `TRANCHE_UPPER_BOUNDS`
- `TRANCHE_PRICES`
- `VOTING_PERIOD`
- `TIMELOCK_PERIOD`
- `EXECUTION_PERIOD`
- `QUORUM_THRESHOLD`
- `BASIS_NUMERATOR`
- `PROPOSER_THRESHOLD`
- `VOTING_WEIGHT_PER_TOKEN`

Optional environment variables:

- `DEPLOYER_NONCE`: preview against a specific nonce instead of the current on-chain nonce
- `PRINCIPAL_VAULT`
- `LIGHT_ACCOUNT_FACTORY`

Preview example:

```sh
forge script script/PreviewPENSystem.s.sol:PreviewPENSystem
```

Deploy example:

```sh
forge script script/DeployPENSystem.s.sol:DeployPENSystem --rpc-url $RPC_URL --broadcast
```

Operational caveat:

The prediction is bound to the deployer nonce. If the deployer sends any other transaction between preview and broadcast, every predicted address changes.
