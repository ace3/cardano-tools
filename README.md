# Cardano Pool Decommission Toolkit

Portable scripts for retiring a Cardano stake pool from the node/server that has `cardano-cli`, node socket access, and the required key/address files.

This toolkit does not move pledge ADA or shut down services automatically. It only builds, signs, and submits the retirement, withdrawal, and stake-key deregistration transactions when explicitly gated.

## Server Setup

Clone this repo on the Cardano node/server:

```bash
git clone <repo-url>
cd cardano-decommision
cp .env.example .env
```

Edit `.env` so paths point to files on the server:

```bash
NETWORK=mainnet
CARDANO_NODE_SOCKET_PATH=/path/to/node.socket
PAYMENT_ADDR_FILE=/path/to/payment.addr
STAKE_ADDR_FILE=/path/to/stake.addr
PAYMENT_SKEY_FILE=/secure/path/payment.skey
STAKE_VKEY_FILE=/secure/path/stake.vkey
STAKE_SKEY_FILE=/secure/path/stake.skey
COLD_VKEY_FILE=/secure/path/cold.vkey
COLD_SKEY_FILE=/secure/path/cold.skey
OUT_DIR=artifacts
```

Validate the server environment:

```bash
make check
make status
```

`make status` prints the current epoch, `poolRetireMaxEpoch`, payment UTxOs, and stake address info.

## Phase 1: Create The Retirement Certificate

Choose a retirement epoch in this range:

```text
current_epoch + 1 <= RETIRE_EPOCH <= current_epoch + poolRetireMaxEpoch
```

Create the certificate:

```bash
make retirement-cert RETIRE_EPOCH=<epoch>
```

The script writes `artifacts/pool.dereg`.

## Phase 2: Build, Sign, And Submit Retirement

Pick a payment UTxO from `make status`, then build:

```bash
make retirement-build RETIRE_EPOCH=<epoch> TX_IN=<txhash#txix>
```

Sign with payment and cold signing keys:

```bash
make retirement-sign
```

Submit only after reviewing the generated files:

```bash
make retirement-submit SUBMIT=1 CONFIRM=RETIRE_POOL
```

After submission, keep the block producer, relays, and pledge running until the selected retirement epoch starts.

## Phase 3: Monitor Deposit And Rewards

After the pool retires, keep checking:

```bash
make status
```

Wait until the stake/rewards address includes the returned 500 ADA pool deposit and remaining rewards.

## Phase 4: Withdraw Deposit And Rewards

Build the withdrawal transaction:

```bash
make withdraw-build TX_IN=<txhash#txix> REWARD_BALANCE=<lovelace>
```

Sign with payment and stake signing keys:

```bash
make withdraw-sign
```

Submit:

```bash
make withdraw-submit SUBMIT=1 CONFIRM=WITHDRAW_REWARDS
```

Repeat in later epochs if residual rewards continue to appear.

## Phase 5: Deregister Stake Key

Only run this after the 500 ADA pool deposit and rewards have been withdrawn.

Create the stake deregistration certificate:

```bash
make stake-dereg-cert
```

Build the deregistration transaction:

```bash
make stake-dereg-build TX_IN=<txhash#txix> ALLOW_STAKE_DEREG=1
```

If a final tiny reward balance remains, include it:

```bash
make stake-dereg-build TX_IN=<txhash#txix> REWARD_BALANCE=<lovelace> ALLOW_STAKE_DEREG=1
```

Sign:

```bash
make stake-dereg-sign
```

Submit:

```bash
make stake-dereg-submit SUBMIT=1 CONFIRM=DEREGISTER_STAKE ALLOW_STAKE_DEREG=1
```

## Phase 6: Move Pledge And Shut Down Infrastructure

After retirement, deposit recovery, reward withdrawal, and stake-key deregistration are complete, move the pledge ADA manually and shut down Cardano infrastructure manually.

Do not move pledge below the declared pledge while the pool is still active.

## Validation

Local checks:

```bash
make test
```

On the real node/server, final acceptance is:

```bash
make check
make status
```

Review all generated artifacts before running any submit command.
