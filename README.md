# Cardano Pool Operations Toolkit

Portable scripts for Cardano stake-pool retirement and offline-first KES renewal from servers that have `cardano-cli`, node socket access, and the required key/address files.

This toolkit does not move pledge ADA, transfer files between servers, stop services, start services, or shut down infrastructure automatically. It only performs local file generation, local file installation, local validation, and explicitly gated transaction submission.

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
COLD_COUNTER_FILE=/secure/path/cold.counter
SHELLEY_GENESIS_FILE=/path/to/mainnet-shelley-genesis.json
NODE_CERT_FILE=/secure/path/node.cert
KES_VKEY_FILE=/secure/path/kes.vkey
KES_SKEY_FILE=/secure/path/kes.skey
BACKUP_ROOT=/root/backup
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

## KES Renewal

KES renewal rotates the pool's hot KES key and issues a fresh operational certificate. This keeps the block producer authorized to sign blocks without exposing the cold key on the block producer.

Use this workflow before the current KES period expires. Cardano documentation describes the KES key as a hot operational key that must be updated periodically, while the operational certificate links that hot key to the offline cold key.

References:

- Cardano Docs: [Creating keys and operational certificates](https://docs.cardano.org/stake-pool-operators/creating-keys-and-certificates)
- Cardano Developer Portal: [Generating Cardano block producer keys](https://developers.cardano.org/docs/operate-a-stake-pool/block-producer-keys/)
- Current `cardano-cli` help: [`node key-gen-KES`](https://raw.githubusercontent.com/IntersectMBO/cardano-cli/master/cardano-cli/test/cardano-cli-golden/files/golden/help/node_key-gen-KES.cli), [`node issue-op-cert`](https://raw.githubusercontent.com/IntersectMBO/cardano-cli/master/cardano-cli/test/cardano-cli-golden/files/golden/help/node_issue-op-cert.cli), [`query kes-period-info`](https://raw.githubusercontent.com/IntersectMBO/cardano-cli/master/cardano-cli/test/cardano-cli-golden/files/golden/help/query_kes-period-info.cli)

### KES Concepts

Files involved:

- `kes.vkey`: hot KES verification key. Used to issue the operational certificate.
- `kes.skey`: hot KES signing key. Installed on the block producer.
- `node.cert`: operational certificate. Installed on the block producer with `kes.skey`.
- `cold.skey`: offline cold signing key. Used only to issue `node.cert`.
- `cold.counter`: operational certificate issue counter. It is incremented by `cardano-cli node issue-op-cert`.
- `mainnet-shelley-genesis.json`: source for `slotsPerKESPeriod`.

Important rules:

- Generate the new operational certificate in the cold/offline environment.
- Do not copy `cold.skey` to the block producer.
- Do not overwrite live `kes.skey` or `node.cert` before taking a backup.
- `kes.skey` and `node.cert` must be generated together and installed together.
- If `cold.counter` has advanced but the new files are not usable, restore the previous live files from backup before trying again.

### Server Roles

Typical topology:

- 2 relay nodes connect to the Cardano network.
- 1 block producer connects to the relays and produces blocks.

KES renewal affects the block producer key material. Relays are restarted before the block producer only as an operational safety sequence; this toolkit does not automate service control.

Server-specific operator map:

| Server | Purpose | Commands |
| --- | --- | --- |
| `cardano-relay1` | Online status source, optional staging host | `make kes-plan`, `make kes-status` |
| `cardano-relay2` | Relay restart/check only | Manual service restart/check |
| `cardano-blockproducer` / validator | Live KES backup, install, and verification | `make kes-backup`, `make kes-verify-source`, `make kes-install`, `make kes-verify` |
| Cold/offline key location | Holds `cold.skey` and `cold.counter` | `make kes-generate` |

Do not copy `cold.skey` to relays or to the block producer. Transfer only the generated `kes.vkey`, `kes.skey`, and `node.cert` to the block producer staging directory.

### Operator Flow By Server

On `cardano-relay1` or `cardano-blockproducer`, create the operator plan and record the current KES period:

```bash
make kes-plan
make kes-status
cat artifacts/kes-renewal/start-kes-period.txt
```

On the cold/offline key location, generate the new KES files:

```bash
make kes-generate START_KES_PERIOD=<period>
```

Copy only these generated files to the block producer staging directory:

```text
artifacts/kes-renewal/kes.vkey
artifacts/kes-renewal/kes.skey
artifacts/kes-renewal/node.cert
```

Example manual copy flow:

```bash
ssh <bastion-or-access-command> cardano-blockproducer
mkdir -p /root/kes-renewal-<yyyymmdd>
scp artifacts/kes-renewal/kes.vkey root@<blockproducer-ip>:/root/kes-renewal-<yyyymmdd>/
scp artifacts/kes-renewal/kes.skey root@<blockproducer-ip>:/root/kes-renewal-<yyyymmdd>/
scp artifacts/kes-renewal/node.cert root@<blockproducer-ip>:/root/kes-renewal-<yyyymmdd>/
```

On `cardano-blockproducer`, back up current live files, verify the staged files, then install:

```bash
make kes-backup BACKUP_LABEL=<yyyymmdd>
make kes-verify-source SOURCE_DIR=/root/kes-renewal-<yyyymmdd>
make kes-install SOURCE_DIR=/root/kes-renewal-<yyyymmdd> INSTALL=1 CONFIRM=INSTALL_KES
```

Restart manually:

```text
stop cardano-blockproducer
restart cardano-relay1
restart cardano-relay2
start cardano-blockproducer
```

Use the existing operational method on each server: `ps -aux | grep cardano`, `kill -s SIGINT <pid>`, then `bash startcardano.sh`.

On `cardano-blockproducer` after restart:

```bash
make kes-verify
cardano-cli query tip --mainnet
./gLiveView.sh
tail -f relay-node.log
```

### Step 1: Inspect Current KES Status

Run this on an online relay or block producer that has a synced node socket, `cardano-cli`, `jq`, `SHELLEY_GENESIS_FILE`, and `NODE_CERT_FILE` configured:

```bash
make kes-plan
make kes-status
```

What this does:

- `make kes-plan` writes `artifacts/kes-renewal/operator-plan.txt` with the server-specific command sequence, configured paths, current KES expiry, op-cert counters, and computed `START_KES_PERIOD`.
- Queries the current chain tip.
- Reads `slotsPerKESPeriod` from the Shelley genesis file.
- Computes `START_KES_PERIOD = slot / slotsPerKESPeriod`.
- Queries `cardano-cli query kes-period-info` for the installed `node.cert`.
- Writes:
  - `artifacts/tip.json`
  - `artifacts/kes-renewal/operator-plan.txt`
  - `artifacts/kes-renewal/kes-period-info.json`
  - `artifacts/kes-renewal/start-kes-period.txt`

Record the printed value:

```text
START_KES_PERIOD=<period>
```

Use the same value when generating the new certificate. If a long time passes before generation, run `make kes-status` again and use the latest value.

### Step 2: Generate New KES Files Offline

Run this in the cold/offline environment where `cold.skey` and `cold.counter` are available:

```bash
make kes-generate START_KES_PERIOD=<period>
```

What this does:

- Runs `cardano-cli node key-gen-KES`.
- Runs `cardano-cli node issue-op-cert`.
- Uses the current CLI flag `--operational-certificate-issue-counter-file`.
- Writes the new files under `artifacts/kes-renewal/`.
- Validates `START_KES_PERIOD` against the latest computed period when an online node socket and genesis file are available. If generation is fully offline, this live check is skipped.
- Writes `artifacts/kes-renewal/manifest.json`.

Generated files:

```text
artifacts/kes-renewal/kes.vkey
artifacts/kes-renewal/kes.skey
artifacts/kes-renewal/node.cert
artifacts/kes-renewal/manifest.json
```

These files do not overwrite live block producer files. Transfer only these generated files to the block producer. Do not transfer `cold.skey`.

### Step 3: Back Up Live Block Producer Files

Run this on the block producer before installing the new files:

```bash
make kes-backup BACKUP_LABEL=<yyyymmdd>
```

Example:

```bash
make kes-backup BACKUP_LABEL=20260511
```

What this does:

- Copies the current live `kes.vkey`, `kes.skey`, and `node.cert`.
- Writes them to `BACKUP_ROOT/<BACKUP_LABEL>/`.
- Writes `artifacts/kes-renewal/last-backup-dir.txt`.
- Refuses to overwrite an existing backup directory.

Expected backup files:

```text
<BACKUP_ROOT>/<BACKUP_LABEL>/kes.vkey
<BACKUP_ROOT>/<BACKUP_LABEL>/kes.skey
<BACKUP_ROOT>/<BACKUP_LABEL>/node.cert
```

### Step 4: Install The New Files On The Block Producer

After manually transferring the generated renewal directory to the block producer, verify it first:

```bash
make kes-verify-source SOURCE_DIR=<renewal-dir>
```

Then install it with an explicit confirmation gate:

```bash
make kes-install SOURCE_DIR=<renewal-dir> INSTALL=1 CONFIRM=INSTALL_KES
```

Example:

```bash
make kes-install SOURCE_DIR=/root/kes-renewal-20260511 INSTALL=1 CONFIRM=INSTALL_KES
```

What this does:

- Requires `INSTALL=1 CONFIRM=INSTALL_KES`.
- Requires a previous `make kes-backup` marker.
- Requires `SOURCE_DIR/kes.vkey`, `SOURCE_DIR/kes.skey`, and `SOURCE_DIR/node.cert`.
- Copies those files to the configured live paths:
  - `KES_VKEY_FILE`
  - `KES_SKEY_FILE`
  - `NODE_CERT_FILE`
- Runs installed-certificate verification after copying.
- Prints the manual restart checklist.

It does not restart Cardano services.

### Step 5: Restart Services Manually

Restart sequence:

1. Stop the block producer.
2. Restart relay 1.
3. Restart relay 2.
4. Start the block producer.

Use your server's existing operational commands. For the environment described in the original runbook, service control was manual through process inspection, `SIGINT`, and `startcardano.sh`; this toolkit intentionally does not automate that.

### Step 6: Verify After Restart

Run this on the block producer after the node is back online:

```bash
make kes-verify
```

What this does:

- Runs `cardano-cli query kes-period-info`.
- Writes `artifacts/kes-renewal/kes-verify.json`.
- Fails if the operational certificate starts in the future.
- Fails if the operational certificate is expired.
- Fails if the node state operational certificate counter and on-disk counter disagree when both are available.

Expected success output:

```text
OK: installed operational certificate is valid for the current KES period
```

Also check the node logs and gLiveView manually. The block producer should be synced, connected to relays, and not reporting invalid KES or operational certificate errors.

### Rollback

If the block producer logs show an invalid KES signature, an operational certificate counter mismatch, or the node cannot produce blocks after renewal:

1. Stop the block producer.
2. Restore `kes.vkey`, `kes.skey`, and `node.cert` from the backup created by `make kes-backup`.
3. Start the block producer.
4. Run `make kes-verify`.
5. Re-run `make kes-status` before attempting another renewal.

Do not decrement or hand-edit `cold.counter`. Treat it as managed by `cardano-cli node issue-op-cert`.

### KES Command Reference

```text
make kes-status
  Online check. Computes START_KES_PERIOD and writes current KES status artifacts.

make kes-plan
  Online operator plan. Writes current KES status, configured paths, and server-specific next commands.

make kes-generate START_KES_PERIOD=<period>
  Cold/offline generation. Creates kes.vkey, kes.skey, node.cert, and manifest.json under artifacts/kes-renewal/.

make kes-backup BACKUP_LABEL=<label>
  Block producer backup. Refuses to overwrite BACKUP_ROOT/<label> and records the latest backup marker.

make kes-verify-source SOURCE_DIR=<dir>
  Block producer staging check. Verifies SOURCE_DIR/kes.vkey, SOURCE_DIR/kes.skey, and SOURCE_DIR/node.cert before install.

make kes-install SOURCE_DIR=<dir> INSTALL=1 CONFIRM=INSTALL_KES
  Block producer install. Requires a backup marker, copies generated KES files into configured live paths, then verifies the installed cert.

make kes-verify
  Online verification. Checks installed node.cert against current KES period and counters.
```

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
