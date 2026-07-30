# PEN Contracts

PEN is a minimal on-chain core for a seat-based membership treasury: members buy non-transferable seats at a tranche-based price, the treasury deploys principal into an ERC-4626 vault, and yield is paid out to recipients selected off-chain via Snapshot ranked-choice voting and ratified on-chain via Snapshot X / EVM (YES/NO).

## Table of Contents

- [Concept](#concept)
- [Architecture](#architecture)
- [Setup & Deployment](#setup--deployment)
  - [Prerequisites](#prerequisites)
  - [Local setup](#local-setup)
  - [Environment configuration](#environment-configuration)
  - [Deployment](#deployment)
  - [Publishing the Deployment](#publishing-the-deployment)
- [Usage Flows](#usage-flows)
  - [Purchase](#purchase)
  - [Refund](#refund)
  - [Reclaim](#reclaim)
  - [Yield Funding](#yield-funding)
- [Operations](#operations)
- [Limitations](#limitations)

## Concept

PEN splits governance into two layers:

- **Off-chain (Snapshot, ranked-choice):** members propose candidate slates (recipients + amounts, plus "none of the above") and select a single *winning slate* via ranked-choice voting.
- **On-chain (Snapshot X / EVM, YES/NO):** a member submits a proposal encoding the winning slate as executable transactions via the Space's whitelisted authenticator (stock `EthTxAuthenticator` at deploy; the DAO may enable additional stock authenticators such as `EthSigAuthenticator` later via a governance-owned `Space.updateSettings` call); seat holders vote using the stock `OZVotesVotingStrategy` (backed by `SeatToken.getPastVotes`); after the optional timelock, the proposal executes through `AvatarExecutionStrategy` → Safe.

For PEN treasury batch payouts, the canonical execution call is `PrincipalManager.executeFunding(recipients, amounts)` — a single batched primitive that is materially cheaper under Snapshot X execution than `withdraw + N transfers`.

Further reading: [`docs/flows.md`](docs/flows.md), [`docs/pen-operator-guide.md`](docs/pen-operator-guide.md).

## Architecture

| Contract | Role |
| --- | --- |
| `SeatToken` | Non-transferable `ERC20Votes` seat token, `decimals = 0`. Governance participation is refreshed via `refreshActivity` (see below). |
| `BondingTranche` | Seat sale (tranche-based pricing), fixed-price refund, inactivity reclaim. |
| `PrincipalManager` | Principal treasury controller: refund liquidity, principal accounting, ERC-4626 vault integration. |

**Roles**

| Contract | Role | Holder / Purpose |
| --- | --- | --- |
| `SeatToken` | `DEFAULT_ADMIN_ROLE` | **Unheld** — renounced at deploy. No party can reroute the roles below. |
| `SeatToken` | `MINTER_ROLE` | `BondingTranche` (mint on purchase) — frozen at deploy |
| `SeatToken` | `BURNER_ROLE` | `BondingTranche` (burn on refund/reclaim) — frozen at deploy |
| `BondingTranche` | `DEFAULT_ADMIN_ROLE` | Governance Safe |
| `BondingTranche` | `RECLAIMER_ROLE` | Authorized reclaimer |
| `PrincipalManager` | `DEFAULT_ADMIN_ROLE` | Governance Safe |
| `PrincipalManager` | `BONDING_ROLE` | `BondingTranche` (record purchases, trigger refunds) |

**Seat activity**

Seat activity is refreshed via the permissionless `SeatToken.refreshActivity(voter, proposalId)` (and the proposer-side companion `refreshActivityForProposal(author, proposalId)`). Each call verifies the vote or proposal against the Space's on-chain `voteRegistry` / `proposals` mapping — no role, no trusted contract, no admin surface. Any vote through any whitelisted authenticator (`EthTx`, `EthSig`, or a future one) is refreshable. See `docs/flows.md` §Activity refresh flow for who typically calls these and the batching primitives.

**Treasury accounting**

- Purchase proceeds land in `PrincipalManager`; excess over the configured liquid reserve is auto-deposited into `principalVault` (ERC-4626).
- `accountedPrincipal` tracks the protocol's principal obligation (created by seat sales, reduced by refunds).
- `availableYield = max(totalManagedAssets − accountedPrincipal, 0)`.

## PEN → PEN migration

PEN's core parameters — payment asset, refund price, tranche schedule, supply cap, inactivity period — are immutable in the deployed contracts. When governance needs to change any of them, the path is to **deploy a new PEN and migrate the treasury into it**.

Two admin primitives on `PrincipalManager` support this, both gated by the Safe's `DEFAULT_ADMIN_ROLE`:

- `pause()` / `unpause()` — freezes user-state-changing flows (`purchase`, `refund`, `reclaim`) on the old deployment without disturbing admin operations.
- `withdraw(token, to, amount)` — moves any ERC-20 balance out of `PrincipalManager` to a chosen receiver. Callable any time; does not adjust `accountedPrincipal`.

A migration ceremony typically looks like: deploy the new PEN → pause the old `PrincipalManager` → drain its principal vault to liquid → `withdraw` the treasury to the Safe → (if migrating to a different asset, swap externally) → seed the new `PrincipalManager` → governance on the new PEN reissues seats to original holders.

The most common reason to migrate is **payment-asset migration** (e.g. USDC → USDT), but the same procedure applies to any change that requires fresh contracts. See `docs/pen-migration.md` for the step-by-step runbook and risks.

## Setup & Deployment

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- Git
- For deployment: an RPC endpoint for the target chain and a funded deployer account

### Local setup

1. Clone the repository and enter the directory.
2. Initialize submodules:
   ```sh
   git submodule update --init --recursive
   ```
3. Build:
   ```sh
   forge build
   ```

### Environment configuration

Copy the example file and fill in values:

```sh
cp .env.example .env
```

All deployment variables and their meanings are documented inline in [`.env.example`](.env.example) — refer to that file as the source of truth.

The variables above the **Core config** divider (`RPC_URL`, `DEPLOYMENT_SALT`, `PRIVATE_KEY` / `DEPLOYER`) are deployer-specific and must always be filled in.

The **Core config** and **Governance config** sections are pre-populated with the canonical values for deploying **Shutter PEN**. Leave these unchanged if you are deploying PEN for Shutter. Only modify them if you are deploying a different PEN instance.

### Deployment

The repo provides two scripts:

- [`script/PreviewPENSystem.s.sol`](script/PreviewPENSystem.s.sol) — predicts the full address plan from the deployer, its current nonce, and `DEPLOYMENT_SALT` without broadcasting.
- [`script/DeployPENSystem.s.sol`](script/DeployPENSystem.s.sol) — deploys the Safe singleton, Safe proxy factory, Safe bootstrap helper, governance stack, and core treasury contracts in a single run, then hands all admin / executor / reclaimer roles to the new Safe.

The deploy script internally:

1. derives the deployer address and current nonce,
2. deterministically predicts every contract address from that sequence + `DEPLOYMENT_SALT`,
3. deploys all contracts in the predicted order,
4. creates the Safe with the Snapshot X `AvatarExecutionStrategy` module enabled during `Safe.setup`,
5. initializes the Snapshot X Space and transfers all admin / executor / reclaimer control to the Safe.

#### Step 1 — Load the environment

After completing [Environment configuration](#environment-configuration), load the file into your shell:

```sh
set -a; source .env; set +a
```

#### Step 2 — Preview the deployment

Run the preview against the **exact deployer address** you intend to broadcast from:

```sh
forge script script/PreviewPENSystem.s.sol:PreviewPENSystem --rpc-url "$RPC_URL"
```

The preview prints the deployer, starting nonce, and every predicted contract address (Safe singleton, Safe proxy factory, Safe bootstrap helper, Safe, `SeatToken`, `PrincipalManager`, `BondingTranche`, governance stack).

#### Step 3 — Verify the predicted addresses

Confirm:

- the deployer address matches the account you will broadcast from,
- the starting nonce matches the deployer's current on-chain nonce,
- the predicted Safe address is what you expect (it is bound to `DEPLOYMENT_SALT`).

#### Step 4 — Broadcast

Deploy in a single run:

```sh
forge script script/DeployPENSystem.s.sol:DeployPENSystem \
  --rpc-url "$RPC_URL" \
  --broadcast
```

On success, the script logs every deployed address. Broadcast artifacts are written under `broadcast/DeployPENSystem.s.sol/<chainId>/`.

#### Step 5 — (Optional) Verify on a block explorer

Append `--verify --etherscan-api-key "$ETHERSCAN_API_KEY"` to the broadcast command (or run `forge verify-contract` per address afterwards).

#### Operational caveat — nonce binding

Address prediction is bound to the deployer's nonce. **Any other transaction from the deployer between preview and broadcast invalidates every predicted address**, including the Safe address. Use a dedicated, otherwise-idle account for deployment, and broadcast immediately after previewing.

### Publishing the Deployment

After successfully deploying Shutter PEN, you can propose the deployment to the community by creating a PR in [shutter-pen-deployment-artifacts](https://github.com/shutter-network/shutter-pen-deployment-artifacts).

After `--broadcast`, Foundry writes per-deployment JSON artifacts (`run-latest.json`, `run-<timestamp>.json`) under `broadcast/DeployPENSystem.s.sol/<chainId>/`.

Fork the artifacts repository, then run the following commands (outside of this repository):

```sh
git clone git@github.com:<<YOUR_FORK_OF_SHUTTER_PEN_DEPLOYMENT_ARTIFACTS>>.git
cd shutter-pen-deployment-artifacts
mkdir -p deployments
cp -a <<PATH_TO_PEN_REPOSITORY>>/broadcast/DeployPENSystem.s.sol/. deployments/
git add deployments
git commit -m "Shutter PEN deployment by <<YOUR_NAME>>"
git push -u origin main
```

This copies every chain subfolder (named by chain id) that Foundry produced, so you do not need to know or look up the chain id yourself.

This will create a new commit in your fork of the `shutter-pen-deployment-artifacts` repository and push the deployment artifacts to it. Please open a PR with this branch against the `main` branch of the `shutter-pen-deployment-artifacts` repository.

## Usage Flows

### Purchase

1. User `approve`s the payment asset to `BondingTranche` for `assetAmount`.
2. User calls `BondingTranche.purchase(recipient, seats, maxCost)`.
3. `BondingTranche` computes the tranche-based price from current seat supply and pulls the asset directly into `PrincipalManager`.
4. `BondingTranche` calls `PrincipalManager.recordPurchase(totalCost)`, which increases `accountedPrincipal` and auto-deposits any excess over the liquid reserve into `principalVault`.
5. `BondingTranche` mints seats to `recipient` via `SeatToken`.

If no vault is configured, proceeds remain liquid in `PrincipalManager`.

### Refund

1. Holder calls `BondingTranche.refund(seats, receiver)`.
2. Refund amount is fixed: `seats * refundPrice`.
3. `BondingTranche` burns the holder's seats.
4. `PrincipalManager.payRefund(receiver, refundAmount)` pays from liquid funds first, then withdraws any shortfall from `principalVault`.
5. `accountedPrincipal` decreases by `refundAmount`.

Refunds reduce total supply, so the tranche cursor moves backward.

### Reclaim

1. An authorized reclaimer verifies inactivity via `SeatToken.isInactive(holder)`.
2. `BondingTranche.reclaim(holder)` burns all seats held by that account.
3. No refund is paid.

Reclaims also reduce total supply, moving pricing backward.

### Yield Funding

1. Off-chain (Snapshot, ranked-choice): community selects a winning slate (recipients + amounts).
2. On-chain (Snapshot X / EVM): a member creates a proposal encoding `PrincipalManager.executeFunding(recipients, amounts)` via the Space's whitelisted authenticator (stock `EthTxAuthenticator` by default).
3. Seat holders vote YES/NO. Simple majority (For > Against) with quorum met makes the proposal executable.
4. After the optional timelock, the proposal executes via `AvatarExecutionStrategy` → Safe: `PrincipalManager` pays from liquid assets first, withdrawing the shortfall from `principalVault` as needed.
5. `accountedPrincipal` is unchanged — funding pays from yield, not from the principal obligation.

## Operations

For day-to-day governance — vault rotation, funding payouts, tranche extensions, and refund solvency remediation — see the [PEN Operator Guide](docs/pen-operator-guide.md).

## Limitations

- The ERC-4626 integration is generic; tests use demo vaults, while production is expected to point at Octant v2-compatible vaults.
