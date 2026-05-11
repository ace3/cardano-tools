#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/cardano-pool-decommission.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -F -- "$needle" "$file" >/dev/null || fail "Expected '$needle' in $file"
}

assert_command_logged() {
  local needle="$1"
  grep -F -- "$needle" "$MOCK_CARDANO_LOG" >/dev/null || fail "Expected command '$needle' in $MOCK_CARDANO_LOG"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
KEY_DIR="$TMP_DIR/keys"
OUT_DIR="$TMP_DIR/artifacts"
mkdir -p "$BIN_DIR" "$KEY_DIR" "$OUT_DIR"

touch "$TMP_DIR/node.socket"
printf 'addr_test1payment\n' > "$KEY_DIR/payment.addr"
printf 'stake_test1stake\n' > "$KEY_DIR/stake.addr"
printf '{"slotsPerKESPeriod":129600}\n' > "$TMP_DIR/mainnet-shelley-genesis.json"
touch "$KEY_DIR/payment.skey" "$KEY_DIR/stake.vkey" "$KEY_DIR/stake.skey" "$KEY_DIR/cold.vkey" "$KEY_DIR/cold.skey" "$KEY_DIR/cold.counter"
touch "$KEY_DIR/kes.vkey" "$KEY_DIR/kes.skey" "$KEY_DIR/node.cert"

cat > "$TMP_DIR/test.env" <<EOF
NETWORK=mainnet
CARDANO_NODE_SOCKET_PATH=$TMP_DIR/node.socket
PAYMENT_ADDR_FILE=$KEY_DIR/payment.addr
STAKE_ADDR_FILE=$KEY_DIR/stake.addr
PAYMENT_SKEY_FILE=$KEY_DIR/payment.skey
STAKE_VKEY_FILE=$KEY_DIR/stake.vkey
STAKE_SKEY_FILE=$KEY_DIR/stake.skey
COLD_VKEY_FILE=$KEY_DIR/cold.vkey
COLD_SKEY_FILE=$KEY_DIR/cold.skey
COLD_COUNTER_FILE=$KEY_DIR/cold.counter
SHELLEY_GENESIS_FILE=$TMP_DIR/mainnet-shelley-genesis.json
NODE_CERT_FILE=$KEY_DIR/node.cert
KES_VKEY_FILE=$KEY_DIR/kes.vkey
KES_SKEY_FILE=$KEY_DIR/kes.skey
BACKUP_ROOT=$TMP_DIR/backup
OUT_DIR=$OUT_DIR
EOF

cat > "$BIN_DIR/cardano-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_CARDANO_LOG:?}"
printf '%q ' "$@" >> "$log_file"
printf '\n' >> "$log_file"

if [[ "$1 $2" == "query tip" ]]; then
  printf '{"epoch":100,"slot":179712000}\n'
  exit 0
fi

if [[ "$1 $2" == "query protocol-parameters" ]]; then
  out=""
  while (($#)); do
    if [[ "$1" == "--out-file" ]]; then
      shift
      out="$1"
    fi
    shift || true
  done
  [[ -n "$out" ]] || exit 1
  printf '{"poolRetireMaxEpoch":18}\n' > "$out"
  exit 0
fi

if [[ "$1 $2" == "query utxo" ]]; then
  printf 'TxHash TxIx Amount\nabc 0 10000000 lovelace\n'
  exit 0
fi

if [[ "$1 $2" == "query stake-address-info" ]]; then
  printf '[{"rewardAccountBalance":500000000}]\n'
  exit 0
fi

if [[ "$1 $2" == "query kes-period-info" ]]; then
  printf '{"qKesCurrentKesPeriod":1386,"qKesEndKesInterval":1448,"qKesKesKeyExpiry":"2026-11-01T00:00:00Z","qKesMaxKESEvolutions":62,"qKesNodeStateOperationalCertificateNumber":50,"qKesOnDiskOperationalCertificateNumber":50,"qKesRemainingSlotsInKesPeriod":1000,"qKesSlotsPerKesPeriod":129600,"qKesStartKesInterval":1386}\n'
  exit 0
fi

if [[ "$1 $2" == "node key-gen-KES" ]]; then
  vkey=""
  skey=""
  while (($#)); do
    case "$1" in
      --verification-key-file)
        shift
        vkey="$1"
        ;;
      --signing-key-file)
        shift
        skey="$1"
        ;;
    esac
    shift || true
  done
  [[ -n "$vkey" && -n "$skey" ]] || exit 1
  printf '{}\n' > "$vkey"
  printf '{}\n' > "$skey"
  exit 0
fi

out=""
while (($#)); do
  if [[ "$1" == "--out-file" ]]; then
    shift
    out="$1"
  fi
  shift || true
done

if [[ -n "$out" ]]; then
  printf '{}\n' > "$out"
fi
EOF
chmod +x "$BIN_DIR/cardano-cli"

export PATH="$BIN_DIR:$PATH"
export MOCK_CARDANO_LOG="$TMP_DIR/cardano-cli.log"
export ENV_FILE="$TMP_DIR/test.env"

: > "$MOCK_CARDANO_LOG"
"$SCRIPT" check-env > "$TMP_DIR/check.out"
assert_contains "OK: environment is ready" "$TMP_DIR/check.out"

"$SCRIPT" kes-status > "$TMP_DIR/kes-status.out"
assert_contains "START_KES_PERIOD=1386" "$TMP_DIR/kes-status.out"
test "$(cat "$OUT_DIR/kes-renewal/start-kes-period.txt")" = "1386" || fail "start KES period was not written"
test -f "$OUT_DIR/kes-renewal/kes-period-info.json" || fail "KES period info was not written"

"$SCRIPT" kes-plan > "$TMP_DIR/kes-plan.out"
assert_contains "START_KES_PERIOD=1386" "$TMP_DIR/kes-plan.out"
assert_contains "cardano-blockproducer" "$TMP_DIR/kes-plan.out"
test -f "$OUT_DIR/kes-renewal/operator-plan.txt" || fail "operator plan was not written"

if START_KES_PERIOD=1385 "$SCRIPT" kes-generate > "$TMP_DIR/kes-generate-stale.out" 2>&1; then
  fail "stale KES period should fail"
fi
assert_contains "does not match latest computed period 1386" "$TMP_DIR/kes-generate-stale.out"

START_KES_PERIOD=1386 "$SCRIPT" kes-generate > "$TMP_DIR/kes-generate.out"
test -f "$OUT_DIR/kes-renewal/kes.vkey" || fail "generated kes.vkey was not created"
test -f "$OUT_DIR/kes-renewal/kes.skey" || fail "generated kes.skey was not created"
test -f "$OUT_DIR/kes-renewal/node.cert" || fail "generated node.cert was not created"
test -f "$OUT_DIR/kes-renewal/manifest.json" || fail "KES manifest was not created"
assert_command_logged "node key-gen-KES"
assert_command_logged "node issue-op-cert"
assert_command_logged "--operational-certificate-issue-counter-file $KEY_DIR/cold.counter"

SOURCE_DIR="$OUT_DIR/kes-renewal" "$SCRIPT" kes-verify-source > "$TMP_DIR/kes-verify-source.out"
assert_contains "OK: source operational certificate is valid" "$TMP_DIR/kes-verify-source.out"

mkdir -p "$TMP_DIR/incomplete-kes-source"
if SOURCE_DIR="$TMP_DIR/incomplete-kes-source" "$SCRIPT" kes-verify-source > "$TMP_DIR/kes-verify-source-missing.out" 2>&1; then
  fail "source verification should fail when files are missing"
fi
assert_contains "Missing source KES verification key" "$TMP_DIR/kes-verify-source-missing.out"

if SOURCE_DIR="$OUT_DIR/kes-renewal" INSTALL=1 CONFIRM=INSTALL_KES "$SCRIPT" kes-install > "$TMP_DIR/kes-install-no-backup.out" 2>&1; then
  fail "KES install should require a backup marker"
fi
assert_contains "Missing KES backup marker" "$TMP_DIR/kes-install-no-backup.out"

BACKUP_LABEL=20260511 "$SCRIPT" kes-backup > "$TMP_DIR/kes-backup.out"
test -f "$TMP_DIR/backup/20260511/kes.vkey" || fail "backup kes.vkey was not created"
test -f "$TMP_DIR/backup/20260511/kes.skey" || fail "backup kes.skey was not created"
test -f "$TMP_DIR/backup/20260511/node.cert" || fail "backup node.cert was not created"
test "$(cat "$OUT_DIR/kes-renewal/last-backup-dir.txt")" = "$TMP_DIR/backup/20260511" || fail "backup marker was not written"

if BACKUP_LABEL=20260511 "$SCRIPT" kes-backup > "$TMP_DIR/kes-backup-denied.out" 2>&1; then
  fail "KES backup should refuse to overwrite an existing backup"
fi
assert_contains "Backup destination already exists" "$TMP_DIR/kes-backup-denied.out"

if SOURCE_DIR="$OUT_DIR/kes-renewal" "$SCRIPT" kes-install > "$TMP_DIR/kes-install-denied.out" 2>&1; then
  fail "KES install should require gate"
fi
assert_contains "INSTALL=1 CONFIRM=INSTALL_KES" "$TMP_DIR/kes-install-denied.out"

SOURCE_DIR="$OUT_DIR/kes-renewal" INSTALL=1 CONFIRM=INSTALL_KES "$SCRIPT" kes-install > "$TMP_DIR/kes-install.out"
assert_contains "Installed KES files" "$TMP_DIR/kes-install.out"
assert_contains "Manual restart checklist" "$TMP_DIR/kes-install.out"

"$SCRIPT" kes-verify > "$TMP_DIR/kes-verify.out"
assert_contains "OK: installed operational certificate is valid" "$TMP_DIR/kes-verify.out"

RETIRE_EPOCH=101 "$SCRIPT" make-retirement-cert > "$TMP_DIR/retire-cert.out"
test -f "$OUT_DIR/pool.dereg" || fail "pool.dereg was not created"
assert_contains "RETIRE_EPOCH=101 is valid" "$TMP_DIR/retire-cert.out"

if RETIRE_EPOCH=100 "$SCRIPT" make-retirement-cert > "$TMP_DIR/bad-epoch.out" 2>&1; then
  fail "current epoch retirement should fail"
fi
assert_contains "Allowed range: 101..118" "$TMP_DIR/bad-epoch.out"

if RETIRE_EPOCH=119 "$SCRIPT" make-retirement-cert > "$TMP_DIR/far-epoch.out" 2>&1; then
  fail "too-far retirement epoch should fail"
fi
assert_contains "Allowed range: 101..118" "$TMP_DIR/far-epoch.out"

RETIRE_EPOCH=101 TX_IN=abc#0 "$SCRIPT" build-retirement > "$TMP_DIR/build-retirement.out"
test -f "$OUT_DIR/retirement.raw" || fail "retirement.raw was not created"
assert_command_logged "latest transaction build"
assert_command_logged "--certificate-file $OUT_DIR/pool.dereg"

"$SCRIPT" sign-retirement > "$TMP_DIR/sign-retirement.out"
test -f "$OUT_DIR/retirement.signed" || fail "retirement.signed was not created"
assert_command_logged "latest transaction sign"

if "$SCRIPT" submit-retirement > "$TMP_DIR/submit-denied.out" 2>&1; then
  fail "submit should require gate"
fi
assert_contains "Refusing to submit" "$TMP_DIR/submit-denied.out"

SUBMIT=1 CONFIRM=RETIRE_POOL "$SCRIPT" submit-retirement > "$TMP_DIR/submit-retirement.out"
assert_command_logged "latest transaction submit"

TX_IN=abc#0 REWARD_BALANCE=500000000 "$SCRIPT" build-withdraw > "$TMP_DIR/build-withdraw.out"
test -f "$OUT_DIR/withdraw.raw" || fail "withdraw.raw was not created"
assert_command_logged "--withdrawal stake_test1stake+500000000"

"$SCRIPT" make-stake-dereg-cert > "$TMP_DIR/stake-dereg-cert.out"
test -f "$OUT_DIR/stake-dereg.cert" || fail "stake-dereg.cert was not created"
assert_command_logged "latest stake-address deregistration-certificate"

if TX_IN=abc#0 "$SCRIPT" build-stake-dereg > "$TMP_DIR/stake-dereg-denied.out" 2>&1; then
  fail "stake dereg build should require ALLOW_STAKE_DEREG=1"
fi
assert_contains "ALLOW_STAKE_DEREG=1" "$TMP_DIR/stake-dereg-denied.out"

ALLOW_STAKE_DEREG=1 TX_IN=abc#0 "$SCRIPT" build-stake-dereg > "$TMP_DIR/stake-dereg-build.out"
test -f "$OUT_DIR/stake-dereg.raw" || fail "stake-dereg.raw was not created"

make -C "$ROOT_DIR" retirement-cert ENV_FILE="$TMP_DIR/test.env" RETIRE_EPOCH=101 > "$TMP_DIR/make-retirement-cert.out"
assert_contains "Wrote $OUT_DIR/pool.dereg" "$TMP_DIR/make-retirement-cert.out"

printf 'All tests passed\n'
