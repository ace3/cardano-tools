# Cardano Stake Pool Retirement Context

This repository is for planning and executing a clean Cardano stake-pool decommissioning flow.

## High-Level Order

1. Choose a future retirement epoch.
2. Create a pool deregistration certificate for that epoch.
3. Build, sign, and submit a transaction containing the certificate.
4. Keep the pool infrastructure and pledge running until the retirement epoch starts.
5. Wait for the 500 ADA pool deposit and final rewards to appear on the stake/rewards address.
6. Withdraw the returned deposit and rewards.
7. Deregister the stake/rewards key only after withdrawal is complete.
8. Move pledge ADA and shut down infrastructure.

## Critical Safety Rule

Do not deregister the stake/rewards address before the 500 ADA pool deposit has been returned and withdrawn. If the stake key is deregistered too early, the pool deposit can be sent to the treasury instead of being recovered.

## Retirement Epoch

Use the current mainnet epoch and protocol parameters to choose the retirement epoch:

```bash
cardano-cli query tip --mainnet

cardano-cli query protocol-parameters \
  --mainnet \
  --out-file protocol.json
```

The retirement epoch must be strictly in the future and no later than `poolRetireMaxEpoch` epochs after the current epoch.

Recommended form:

```text
retire_epoch = current_epoch + k
1 <= k <= poolRetireMaxEpoch
```

Prefer at least a few epochs ahead so delegators have time to move.

## Pool Retirement Certificate

Create the pool deregistration certificate with the cold verification key:

```bash
cardano-cli stake-pool deregistration-certificate \
  --cold-verification-key-file cold.vkey \
  --epoch <RETIRE_EPOCH> \
  --out-file pool.dereg
```

The pool retires at the first block of `<RETIRE_EPOCH>`.

## Retirement Transaction

Query payment-address UTxOs:

```bash
cardano-cli query utxo \
  --address "$(cat payment.addr)" \
  --mainnet
```

Build the transaction:

```bash
cardano-cli transaction build \
  --mainnet \
  --tx-in <TXHASH>#<TXIX> \
  --change-address "$(cat payment.addr)" \
  --witness-override 2 \
  --certificate-file pool.dereg \
  --out-file tx.raw
```

Sign with the payment signing key and cold signing key:

```bash
cardano-cli transaction sign \
  --mainnet \
  --tx-body-file tx.raw \
  --signing-key-file payment.skey \
  --signing-key-file cold.skey \
  --out-file tx.signed
```

Submit:

```bash
cardano-cli transaction submit \
  --mainnet \
  --tx-file tx.signed
```

## After Submission

After the retirement transaction is confirmed, the pool is scheduled for retirement but remains active until the selected epoch starts.

Keep running:

- Block producer
- Relays
- Pledge in the owner payment address

If the operator changes their mind before the retirement epoch, a fresh pool registration certificate can override the retirement.

## Deposit And Rewards Recovery

After the pool retires, monitor the stake/rewards address:

```bash
cardano-cli query stake-address-info \
  --mainnet \
  --address "$(cat stake.addr)"
```

Wait until the reward balance includes the returned 500 ADA pool deposit and any final rewards.

Withdraw rewards and deposit:

```bash
cardano-cli transaction build \
  --mainnet \
  --tx-in <TXHASH>#<TXIX> \
  --change-address "$(cat payment.addr)" \
  --withdrawal "$(cat stake.addr)+<REWARD_BALANCE>" \
  --witness-override 2 \
  --out-file withdraw.raw

cardano-cli transaction sign \
  --mainnet \
  --tx-body-file withdraw.raw \
  --signing-key-file payment.skey \
  --signing-key-file stake.skey \
  --out-file withdraw.signed

cardano-cli transaction submit \
  --mainnet \
  --tx-file withdraw.signed
```

Repeat withdrawal in later epochs if residual rewards continue to appear.

## Stake Key Deregistration

Only after the pool deposit and rewards are withdrawn, create the stake deregistration certificate:

```bash
cardano-cli stake-address deregistration-certificate \
  --stake-verification-key-file stake.vkey \
  --out-file stake-dereg.cert
```

Build a transaction that includes the deregistration certificate, optionally withdraws final tiny rewards, and returns the stake key deposit. Sign with the payment signing key and stake signing key.

## Pledge And Infrastructure Shutdown

Pledge ADA is not protocol-locked; it is normal ADA held in the owner payment address and counted as pledge while the pool is active.

Do not move pledge below the declared pledge while the pool is active. After retirement, deposit recovery, reward withdrawal, and stake-key deregistration are complete, move the pledge ADA to the desired wallet and shut down Cardano infrastructure.

## Sources To Recheck Before Execution

- `cardano-cli` version and current command syntax
- Current mainnet protocol parameters
- Current epoch
- Pool owner/stake/payment key paths
- Live reward balance
- Confirmation that the retirement transaction is on-chain
