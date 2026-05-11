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
touch "$KEY_DIR/payment.skey" "$KEY_DIR/stake.vkey" "$KEY_DIR/stake.skey" "$KEY_DIR/cold.vkey" "$KEY_DIR/cold.skey"

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
OUT_DIR=$OUT_DIR
EOF

cat > "$BIN_DIR/cardano-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${MOCK_CARDANO_LOG:?}"
printf '%q ' "$@" >> "$log_file"
printf '\n' >> "$log_file"

if [[ "$1 $2" == "query tip" ]]; then
  printf '{"epoch":100,"slot":1}\n'
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
