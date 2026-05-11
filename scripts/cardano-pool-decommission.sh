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
  kes-plan
  kes-status
  kes-backup                 BACKUP_LABEL=<label>
  kes-generate               START_KES_PERIOD=<period>
  kes-verify-source          SOURCE_DIR=<dir>
  kes-install                SOURCE_DIR=<dir> INSTALL=1 CONFIRM=INSTALL_KES
  kes-verify
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

env_path_or_unset() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    resolve_path "${!name}"
  else
    printf '<unset>\n'
  fi
}

out_dir() {
  resolve_path "$OUT_DIR"
}

artifact() {
  printf '%s/%s\n' "$(out_dir)" "$1"
}

kes_out_dir() {
  printf '%s/kes-renewal\n' "$(out_dir)"
}

kes_artifact() {
  printf '%s/%s\n' "$(kes_out_dir)" "$1"
}

last_kes_backup_marker() {
  kes_artifact last-backup-dir.txt
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

require_kes_files() {
  require_file_var NODE_CERT_FILE
  require_file_var KES_VKEY_FILE
  require_file_var KES_SKEY_FILE
}

require_cold_counter() {
  require_file_var COLD_COUNTER_FILE
}

require_genesis_file() {
  require_file_var SHELLEY_GENESIS_FILE
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

ensure_kes_out_dir() {
  mkdir -p "$(kes_out_dir)"
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

start_kes_period() {
  require_base_env
  require_genesis_file

  local slot slots_per_kes_period
  slot="$(query_tip | jq -r '.slot')"
  slots_per_kes_period="$(jq -r '.slotsPerKESPeriod' "$(resolve_path "$SHELLEY_GENESIS_FILE")")"
  require_integer slot "$slot"
  require_integer slotsPerKESPeriod "$slots_per_kes_period"
  (( slots_per_kes_period > 0 )) || die "slotsPerKESPeriod must be greater than zero"

  printf '%s\n' "$((slot / slots_per_kes_period))"
}

query_kes_period_info() {
  local op_cert_file="$1"
  "$CARDANO_CLI" query kes-period-info \
    $(network_args) \
    --socket-path "$CARDANO_NODE_SOCKET_PATH" \
    --op-cert-file "$op_cert_file" \
    --output-json
}

assert_valid_kes_info() {
  local file="$1"
  local current start end node_counter on_disk_counter
  current="$(jq -r '.qKesCurrentKesPeriod' "$file")"
  start="$(jq -r '.qKesStartKesInterval' "$file")"
  end="$(jq -r '.qKesEndKesInterval' "$file")"
  node_counter="$(jq -r '.qKesNodeStateOperationalCertificateNumber // empty' "$file")"
  on_disk_counter="$(jq -r '.qKesOnDiskOperationalCertificateNumber' "$file")"

  require_integer qKesCurrentKesPeriod "$current"
  require_integer qKesStartKesInterval "$start"
  require_integer qKesEndKesInterval "$end"
  require_integer qKesOnDiskOperationalCertificateNumber "$on_disk_counter"

  if (( current < start )); then
    die "Operational certificate KES period starts in the future (current=$current, start=$start)."
  fi

  if (( current > end )); then
    die "Operational certificate KES period is expired (current=$current, end=$end)."
  fi

  if [[ -n "$node_counter" ]]; then
    require_integer qKesNodeStateOperationalCertificateNumber "$node_counter"
    if [[ "$node_counter" != "$on_disk_counter" ]]; then
      die "Operational certificate counter mismatch (node=$node_counter, on_disk=$on_disk_counter)."
    fi
  fi
}

require_kes_source_dir() {
  require_var SOURCE_DIR

  local source_dir="$1"
  [[ -d "$source_dir" ]] || die "SOURCE_DIR does not exist: $source_dir"
  [[ -f "$source_dir/kes.vkey" ]] || die "Missing source KES verification key: $source_dir/kes.vkey"
  [[ -f "$source_dir/kes.skey" ]] || die "Missing source KES signing key: $source_dir/kes.skey"
  [[ -f "$source_dir/node.cert" ]] || die "Missing source operational certificate: $source_dir/node.cert"
}

require_recent_kes_backup() {
  local marker backup_dir
  marker="$(last_kes_backup_marker)"
  [[ -f "$marker" ]] || die "Missing KES backup marker: $marker. Run make kes-backup BACKUP_LABEL=<label> before install."
  backup_dir="$(< "$marker")"
  [[ -d "$backup_dir" ]] || die "KES backup directory from marker does not exist: $backup_dir"
  [[ -f "$backup_dir/kes.vkey" ]] || die "Backup is missing kes.vkey: $backup_dir"
  [[ -f "$backup_dir/kes.skey" ]] || die "Backup is missing kes.skey: $backup_dir"
  [[ -f "$backup_dir/node.cert" ]] || die "Backup is missing node.cert: $backup_dir"
}

can_check_latest_kes_period() {
  command -v jq >/dev/null 2>&1 || return 1
  command -v "$CARDANO_CLI" >/dev/null 2>&1 || return 1
  network_args >/dev/null
  [[ -n "${CARDANO_NODE_SOCKET_PATH:-}" ]] || return 1
  [[ -S "$CARDANO_NODE_SOCKET_PATH" || -e "$CARDANO_NODE_SOCKET_PATH" ]] || return 1
  [[ -n "${SHELLEY_GENESIS_FILE:-}" ]] || return 1
  [[ -f "$(resolve_path "$SHELLEY_GENESIS_FILE")" ]] || return 1
}

validate_start_kes_period_for_generate() {
  if ! can_check_latest_kes_period; then
    log "Skipping latest KES period check; online node socket/genesis context is not available."
    return
  fi

  local latest_period
  latest_period="$(start_kes_period)"
  if [[ "$START_KES_PERIOD" != "$latest_period" && "${CONFIRM:-}" != "STALE_KES_PERIOD" ]]; then
    die "START_KES_PERIOD=$START_KES_PERIOD does not match latest computed period $latest_period. Re-run with START_KES_PERIOD=$latest_period or set CONFIRM=STALE_KES_PERIOD."
  fi
}

write_kes_manifest() {
  local manifest_file
  manifest_file="$(kes_artifact manifest.json)"
  cat > "$manifest_file" <<EOF
{
  "generatedAt": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "network": "$NETWORK",
  "startKesPeriod": $START_KES_PERIOD,
  "coldCounterFile": "$(resolve_path "$COLD_COUNTER_FILE")",
  "kesVkeyFile": "$(kes_artifact kes.vkey)",
  "kesSkeyFile": "$(kes_artifact kes.skey)",
  "nodeCertFile": "$(kes_artifact node.cert)"
}
EOF
  log "Wrote $manifest_file"
}

print_kes_restart_checklist() {
  cat <<'EOF'
Manual restart checklist:
  1. Stop cardano-blockproducer.
  2. Restart cardano-relay1.
  3. Restart cardano-relay2.
  4. Start cardano-blockproducer.
  5. Run make kes-verify on cardano-blockproducer.
EOF
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

kes_plan() {
  require_base_env
  require_genesis_file
  require_file_var NODE_CERT_FILE
  require_var BACKUP_ROOT
  ensure_kes_out_dir

  local tip_file info_file plan_file start_period expiry node_counter on_disk_counter
  tip_file="$(artifact tip.json)"
  info_file="$(kes_artifact kes-period-info.json)"
  plan_file="$(kes_artifact operator-plan.txt)"
  start_period="$(start_kes_period)"

  query_tip > "$tip_file"
  query_kes_period_info "$(resolve_path "$NODE_CERT_FILE")" > "$info_file"

  expiry="$(jq -r '.qKesKesKeyExpiry // "unknown"' "$info_file")"
  node_counter="$(jq -r '.qKesNodeStateOperationalCertificateNumber // "unknown"' "$info_file")"
  on_disk_counter="$(jq -r '.qKesOnDiskOperationalCertificateNumber // "unknown"' "$info_file")"

  cat > "$plan_file" <<EOF
KES renewal operator plan

Run online status on: cardano-relay1 or cardano-blockproducer
Run cold generation on: cold/offline key location with cold.skey and cold.counter
Install on: cardano-blockproducer
Restart manually: cardano-blockproducer, cardano-relay1, cardano-relay2

NETWORK=$NETWORK
START_KES_PERIOD=$start_period
KES_EXPIRY=$expiry
NODE_STATE_OP_CERT_COUNTER=$node_counter
ON_DISK_OP_CERT_COUNTER=$on_disk_counter

Configured files:
  NODE_CERT_FILE=$(resolve_path "$NODE_CERT_FILE")
  KES_VKEY_FILE=$(env_path_or_unset KES_VKEY_FILE)
  KES_SKEY_FILE=$(env_path_or_unset KES_SKEY_FILE)
  COLD_COUNTER_FILE=$(env_path_or_unset COLD_COUNTER_FILE)
  BACKUP_ROOT=$(resolve_path "$BACKUP_ROOT")
  GENERATED_DIR=$(kes_out_dir)

Operator commands:
  cardano-relay1 or cardano-blockproducer:
    make kes-status
    cat artifacts/kes-renewal/start-kes-period.txt

  cold/offline key location:
    make kes-generate START_KES_PERIOD=$start_period

  copy only these generated files to cardano-blockproducer staging directory:
    artifacts/kes-renewal/kes.vkey
    artifacts/kes-renewal/kes.skey
    artifacts/kes-renewal/node.cert

  cardano-blockproducer:
    make kes-backup BACKUP_LABEL=<yyyymmdd>
    make kes-verify-source SOURCE_DIR=/root/kes-renewal-<yyyymmdd>
    make kes-install SOURCE_DIR=/root/kes-renewal-<yyyymmdd> INSTALL=1 CONFIRM=INSTALL_KES
    make kes-verify
EOF

  cat "$plan_file"
  log "Wrote $plan_file"
}

kes_status() {
  require_base_env
  require_genesis_file
  require_file_var NODE_CERT_FILE
  ensure_kes_out_dir

  local tip_file info_file start_period
  tip_file="$(artifact tip.json)"
  info_file="$(kes_artifact kes-period-info.json)"
  start_period="$(start_kes_period)"

  query_tip | tee "$tip_file"
  query_kes_period_info "$(resolve_path "$NODE_CERT_FILE")" | tee "$info_file"

  log "START_KES_PERIOD=$start_period"
  printf '%s\n' "$start_period" > "$(kes_artifact start-kes-period.txt)"
  log "Wrote $(kes_artifact start-kes-period.txt)"
  log "Wrote $info_file"
}

kes_backup() {
  require_var BACKUP_LABEL
  require_var BACKUP_ROOT
  require_kes_files

  local backup_dir
  backup_dir="$(resolve_path "$BACKUP_ROOT")/$BACKUP_LABEL"
  [[ ! -e "$backup_dir" ]] || die "Backup destination already exists: $backup_dir"
  mkdir -p "$backup_dir"

  cp "$(resolve_path "$KES_VKEY_FILE")" "$backup_dir/kes.vkey"
  cp "$(resolve_path "$KES_SKEY_FILE")" "$backup_dir/kes.skey"
  cp "$(resolve_path "$NODE_CERT_FILE")" "$backup_dir/node.cert"
  printf '%s\n' "$backup_dir" > "$(last_kes_backup_marker)"

  log "Wrote KES backup: $backup_dir"
  log "Wrote $(last_kes_backup_marker)"
}

kes_generate() {
  command -v "$CARDANO_CLI" >/dev/null 2>&1 || die "Missing required command: $CARDANO_CLI"
  network_args >/dev/null
  require_var START_KES_PERIOD
  require_integer START_KES_PERIOD "$START_KES_PERIOD"
  require_cold_keys
  require_cold_counter
  ensure_kes_out_dir
  validate_start_kes_period_for_generate

  "$CARDANO_CLI" node key-gen-KES \
    --verification-key-file "$(kes_artifact kes.vkey)" \
    --signing-key-file "$(kes_artifact kes.skey)"

  "$CARDANO_CLI" node issue-op-cert \
    --kes-verification-key-file "$(kes_artifact kes.vkey)" \
    --cold-signing-key-file "$(resolve_path "$COLD_SKEY_FILE")" \
    --operational-certificate-issue-counter-file "$(resolve_path "$COLD_COUNTER_FILE")" \
    --kes-period "$START_KES_PERIOD" \
    --out-file "$(kes_artifact node.cert)"

  log "Wrote $(kes_artifact kes.vkey)"
  log "Wrote $(kes_artifact kes.skey)"
  log "Wrote $(kes_artifact node.cert)"
  write_kes_manifest
}

kes_verify_source() {
  require_base_env
  ensure_kes_out_dir

  local source_dir info_file
  source_dir="$(resolve_path "$SOURCE_DIR")"
  require_kes_source_dir "$source_dir"
  info_file="$(kes_artifact source-kes-verify.json)"

  query_kes_period_info "$source_dir/node.cert" | tee "$info_file"
  assert_valid_kes_info "$info_file"
  log "OK: source operational certificate is valid for the current KES period"
}

kes_install() {
  require_var SOURCE_DIR
  [[ "${INSTALL:-}" == "1" ]] || die "Refusing to install KES files. Re-run with INSTALL=1 CONFIRM=INSTALL_KES."
  [[ "${CONFIRM:-}" == "INSTALL_KES" ]] || die "Refusing to install KES files. Expected CONFIRM=INSTALL_KES."
  require_base_env
  require_kes_files
  require_recent_kes_backup

  local source_dir source_vkey source_skey source_cert
  source_dir="$(resolve_path "$SOURCE_DIR")"
  require_kes_source_dir "$source_dir"
  source_vkey="$source_dir/kes.vkey"
  source_skey="$source_dir/kes.skey"
  source_cert="$source_dir/node.cert"

  cp "$source_vkey" "$(resolve_path "$KES_VKEY_FILE")"
  cp "$source_skey" "$(resolve_path "$KES_SKEY_FILE")"
  cp "$source_cert" "$(resolve_path "$NODE_CERT_FILE")"

  log "Installed KES files from $source_dir"
  kes_verify
  print_kes_restart_checklist
}

kes_verify() {
  require_base_env
  require_file_var NODE_CERT_FILE
  ensure_kes_out_dir

  local info_file
  info_file="$(kes_artifact kes-verify.json)"
  query_kes_period_info "$(resolve_path "$NODE_CERT_FILE")" | tee "$info_file"
  assert_valid_kes_info "$info_file"
  log "OK: installed operational certificate is valid for the current KES period"
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

  "$CARDANO_CLI" latest transaction build \
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

  "$CARDANO_CLI" latest transaction sign \
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

  "$CARDANO_CLI" latest transaction submit \
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

  "$CARDANO_CLI" latest transaction build \
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

  "$CARDANO_CLI" latest transaction sign \
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

  "$CARDANO_CLI" latest stake-address deregistration-certificate \
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
    latest transaction build
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

  "$CARDANO_CLI" latest transaction sign \
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
    kes-plan) kes_plan ;;
    kes-status) kes_status ;;
    kes-backup) kes_backup ;;
    kes-generate) kes_generate ;;
    kes-verify-source) kes_verify_source ;;
    kes-install) kes_install ;;
    kes-verify) kes_verify ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; die "Unknown command: $command" ;;
  esac
}

main "$@"
