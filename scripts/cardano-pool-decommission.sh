#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
CARDANO_CLI="${CARDANO_CLI:-cardano-cli}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$ENV_FILE"
  set +a
fi

NETWORK="${NETWORK:-mainnet}"
OUT_DIR="${OUT_DIR:-artifacts}"

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/cardano-pool-decommission.sh <command>

Commands:
  check-env
  status
  make-retirement-cert       RETIRE_EPOCH=<epoch>
  build-retirement           RETIRE_EPOCH=<epoch> TX_IN=<hash#index>
  sign-retirement
  submit-retirement          SUBMIT=1 CONFIRM=RETIRE_POOL
  build-withdraw             REWARD_BALANCE=<lovelace> TX_IN=<hash#index>
  sign-withdraw
  submit-withdraw            SUBMIT=1 CONFIRM=WITHDRAW_REWARDS
  make-stake-dereg-cert
  build-stake-dereg          TX_IN=<hash#index> [REWARD_BALANCE=<lovelace>]
  sign-stake-dereg
  submit-stake-dereg         SUBMIT=1 CONFIRM=DEREGISTER_STAKE ALLOW_STAKE_DEREG=1
EOF
}

network_args() {
  case "$NETWORK" in
    mainnet)
      printf '%s\n' "--mainnet"
      ;;
    *)
      die "Unsupported NETWORK=$NETWORK. This toolkit currently supports NETWORK=mainnet."
      ;;
  esac
}

resolve_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$ROOT_DIR/$path"
  fi
}

out_dir() {
  resolve_path "$OUT_DIR"
}

artifact() {
  printf '%s/%s\n' "$(out_dir)" "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Missing required env var: $name"
}

require_file_var() {
  local name="$1"
  require_var "$name"
  local path
  path="$(resolve_path "${!name}")"
  [[ -f "$path" ]] || die "$name does not exist: $path"
}

require_socket() {
  require_var CARDANO_NODE_SOCKET_PATH
  [[ -S "$CARDANO_NODE_SOCKET_PATH" || -e "$CARDANO_NODE_SOCKET_PATH" ]] || die "CARDANO_NODE_SOCKET_PATH does not exist: $CARDANO_NODE_SOCKET_PATH"
}

require_base_env() {
  require_command jq
  command -v "$CARDANO_CLI" >/dev/null 2>&1 || die "Missing required command: $CARDANO_CLI"
  network_args >/dev/null
  require_socket
}

require_addresses() {
  require_file_var PAYMENT_ADDR_FILE
  require_file_var STAKE_ADDR_FILE
}

require_payment_key() {
  require_file_var PAYMENT_SKEY_FILE
}

require_cold_keys() {
  require_file_var COLD_VKEY_FILE
  require_file_var COLD_SKEY_FILE
}

require_stake_keys() {
  require_file_var STAKE_VKEY_FILE
  require_file_var STAKE_SKEY_FILE
}

payment_addr() {
  local file
  file="$(resolve_path "$PAYMENT_ADDR_FILE")"
  tr -d '[:space:]' < "$file"
}

stake_addr() {
  local file
  file="$(resolve_path "$STAKE_ADDR_FILE")"
  tr -d '[:space:]' < "$file"
}

ensure_out_dir() {
  mkdir -p "$(out_dir)"
}

query_tip() {
  "$CARDANO_CLI" query tip $(network_args)
}

write_protocol_params() {
  ensure_out_dir
  "$CARDANO_CLI" query protocol-parameters \
    $(network_args) \
    --out-file "$(artifact protocol.json)"
}

current_epoch() {
  query_tip | jq -r '.epoch'
}

pool_retire_max_epoch() {
  write_protocol_params >/dev/null
  jq -r '.poolRetireMaxEpoch' "$(artifact protocol.json)"
}

require_integer() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer, got: $value"
}

validate_retirement_epoch() {
  local retire_epoch="$1"
  require_integer RETIRE_EPOCH "$retire_epoch"

  local current max min allowed_max
  current="$(current_epoch)"
  max="$(pool_retire_max_epoch)"
  require_integer current_epoch "$current"
  require_integer poolRetireMaxEpoch "$max"

  min=$((current + 1))
  allowed_max=$((current + max))

  if (( retire_epoch < min || retire_epoch > allowed_max )); then
    die "RETIRE_EPOCH=$retire_epoch is invalid. Allowed range: $min..$allowed_max (current=$current, poolRetireMaxEpoch=$max)."
  fi

  log "RETIRE_EPOCH=$retire_epoch is valid. Allowed range: $min..$allowed_max."
}

require_tx_in() {
  require_var TX_IN
  [[ "$TX_IN" == *"#"* ]] || die "TX_IN must use format <txhash>#<txix>, got: $TX_IN"
}

require_reward_balance() {
  require_var REWARD_BALANCE
  require_integer REWARD_BALANCE "$REWARD_BALANCE"
}

check_env() {
  require_base_env
  require_addresses
  require_payment_key
  require_cold_keys
  require_stake_keys
  ensure_out_dir

  log "OK: environment is ready"
  log "NETWORK=$NETWORK"
  log "CARDANO_NODE_SOCKET_PATH=$CARDANO_NODE_SOCKET_PATH"
  log "OUT_DIR=$(out_dir)"
}

status() {
  require_base_env
  require_addresses
  ensure_out_dir

  log "== Tip =="
  query_tip | tee "$(artifact tip.json)"

  log
  log "== Protocol parameters =="
  write_protocol_params
  log "poolRetireMaxEpoch=$(jq -r '.poolRetireMaxEpoch' "$(artifact protocol.json)")"

  log
  log "== Payment UTxOs =="
  "$CARDANO_CLI" query utxo \
    $(network_args) \
    --address "$(payment_addr)"

  log
  log "== Stake address info =="
  "$CARDANO_CLI" query stake-address-info \
    $(network_args) \
    --address "$(stake_addr)" | tee "$(artifact stake-address-info.json)"
}

make_retirement_cert() {
  require_base_env
  require_cold_keys
  require_var RETIRE_EPOCH
  validate_retirement_epoch "$RETIRE_EPOCH"
  ensure_out_dir

  "$CARDANO_CLI" stake-pool deregistration-certificate \
    --cold-verification-key-file "$(resolve_path "$COLD_VKEY_FILE")" \
    --epoch "$RETIRE_EPOCH" \
    --out-file "$(artifact pool.dereg)"

  log "Wrote $(artifact pool.dereg)"
}

build_retirement() {
  require_base_env
  require_addresses
  require_var RETIRE_EPOCH
  require_tx_in
  validate_retirement_epoch "$RETIRE_EPOCH"
  [[ -f "$(artifact pool.dereg)" ]] || die "Missing retirement certificate: $(artifact pool.dereg). Run make retirement-cert first."

  "$CARDANO_CLI" transaction build \
    $(network_args) \
    --tx-in "$TX_IN" \
    --change-address "$(payment_addr)" \
    --witness-override 2 \
    --certificate-file "$(artifact pool.dereg)" \
    --out-file "$(artifact retirement.raw)"

  log "Wrote $(artifact retirement.raw)"
}

sign_retirement() {
  require_base_env
  require_payment_key
  require_cold_keys
  [[ -f "$(artifact retirement.raw)" ]] || die "Missing tx body: $(artifact retirement.raw). Run make retirement-build first."

  "$CARDANO_CLI" transaction sign \
    $(network_args) \
    --tx-body-file "$(artifact retirement.raw)" \
    --signing-key-file "$(resolve_path "$PAYMENT_SKEY_FILE")" \
    --signing-key-file "$(resolve_path "$COLD_SKEY_FILE")" \
    --out-file "$(artifact retirement.signed)"

  log "Wrote $(artifact retirement.signed)"
}

require_submit_gate() {
  local expected="$1"
  [[ "${SUBMIT:-}" == "1" ]] || die "Refusing to submit. Re-run with SUBMIT=1 CONFIRM=$expected."
  [[ "${CONFIRM:-}" == "$expected" ]] || die "Refusing to submit. Expected CONFIRM=$expected."
}

submit_tx() {
  local gate="$1"
  local file="$2"
  require_base_env
  require_submit_gate "$gate"
  [[ -f "$file" ]] || die "Missing signed tx: $file"

  "$CARDANO_CLI" transaction submit \
    $(network_args) \
    --tx-file "$file"
}

submit_retirement() {
  submit_tx RETIRE_POOL "$(artifact retirement.signed)"
}

build_withdraw() {
  require_base_env
  require_addresses
  require_tx_in
  require_reward_balance

  "$CARDANO_CLI" transaction build \
    $(network_args) \
    --tx-in "$TX_IN" \
    --change-address "$(payment_addr)" \
    --withdrawal "$(stake_addr)+$REWARD_BALANCE" \
    --witness-override 2 \
    --out-file "$(artifact withdraw.raw)"

  log "Wrote $(artifact withdraw.raw)"
}

sign_withdraw() {
  require_base_env
  require_payment_key
  require_stake_keys
  [[ -f "$(artifact withdraw.raw)" ]] || die "Missing tx body: $(artifact withdraw.raw). Run make withdraw-build first."

  "$CARDANO_CLI" transaction sign \
    $(network_args) \
    --tx-body-file "$(artifact withdraw.raw)" \
    --signing-key-file "$(resolve_path "$PAYMENT_SKEY_FILE")" \
    --signing-key-file "$(resolve_path "$STAKE_SKEY_FILE")" \
    --out-file "$(artifact withdraw.signed)"

  log "Wrote $(artifact withdraw.signed)"
}

submit_withdraw() {
  submit_tx WITHDRAW_REWARDS "$(artifact withdraw.signed)"
}

make_stake_dereg_cert() {
  require_base_env
  require_stake_keys
  ensure_out_dir

  "$CARDANO_CLI" stake-address deregistration-certificate \
    --stake-verification-key-file "$(resolve_path "$STAKE_VKEY_FILE")" \
    --out-file "$(artifact stake-dereg.cert)"

  log "Wrote $(artifact stake-dereg.cert)"
}

build_stake_dereg() {
  require_base_env
  require_addresses
  require_tx_in
  [[ "${ALLOW_STAKE_DEREG:-}" == "1" ]] || die "Refusing to build stake deregistration. Set ALLOW_STAKE_DEREG=1 after confirming pool deposit and rewards are withdrawn."
  [[ -f "$(artifact stake-dereg.cert)" ]] || die "Missing stake deregistration cert: $(artifact stake-dereg.cert). Run make stake-dereg-cert first."

  local args=(
    transaction build
    $(network_args)
    --tx-in "$TX_IN"
    --change-address "$(payment_addr)"
    --certificate-file "$(artifact stake-dereg.cert)"
    --witness-override 2
    --out-file "$(artifact stake-dereg.raw)"
  )

  if [[ -n "${REWARD_BALANCE:-}" ]]; then
    require_integer REWARD_BALANCE "$REWARD_BALANCE"
    args+=(--withdrawal "$(stake_addr)+$REWARD_BALANCE")
  fi

  "$CARDANO_CLI" "${args[@]}"
  log "Wrote $(artifact stake-dereg.raw)"
}

sign_stake_dereg() {
  require_base_env
  require_payment_key
  require_stake_keys
  [[ -f "$(artifact stake-dereg.raw)" ]] || die "Missing tx body: $(artifact stake-dereg.raw). Run make stake-dereg-build first."

  "$CARDANO_CLI" transaction sign \
    $(network_args) \
    --tx-body-file "$(artifact stake-dereg.raw)" \
    --signing-key-file "$(resolve_path "$PAYMENT_SKEY_FILE")" \
    --signing-key-file "$(resolve_path "$STAKE_SKEY_FILE")" \
    --out-file "$(artifact stake-dereg.signed)"

  log "Wrote $(artifact stake-dereg.signed)"
}

submit_stake_dereg() {
  [[ "${ALLOW_STAKE_DEREG:-}" == "1" ]] || die "Refusing stake deregistration submit. Set ALLOW_STAKE_DEREG=1 after confirming pool deposit and rewards are withdrawn."
  submit_tx DEREGISTER_STAKE "$(artifact stake-dereg.signed)"
}

main() {
  local command="${1:-}"
  case "$command" in
    check-env) check_env ;;
    status) status ;;
    make-retirement-cert) make_retirement_cert ;;
    build-retirement) build_retirement ;;
    sign-retirement) sign_retirement ;;
    submit-retirement) submit_retirement ;;
    build-withdraw) build_withdraw ;;
    sign-withdraw) sign_withdraw ;;
    submit-withdraw) submit_withdraw ;;
    make-stake-dereg-cert) make_stake_dereg_cert ;;
    build-stake-dereg) build_stake_dereg ;;
    sign-stake-dereg) sign_stake_dereg ;;
    submit-stake-dereg) submit_stake_dereg ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "Unknown command: $command" ;;
  esac
}

main "$@"
