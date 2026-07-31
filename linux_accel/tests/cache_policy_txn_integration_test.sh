#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
transaction="${1:-${root_dir}/build/cache_policy_txn}"
pin_root=
lock_root=
exec_root=
pin_parent_created=false
policy_root_created=false
lock_holder_pid=
lock_holder_release=
lock_waiter_pid=

cleanup() {
  local exit_status=$?
  trap - EXIT
  set +e

  if [[ -n "${lock_holder_pid}" ]]; then
    if [[ -n "${lock_holder_release}" ]]; then
      touch -- "${lock_holder_release}" 2>/dev/null
    fi
    wait "${lock_holder_pid}" 2>/dev/null
  fi
  if [[ -n "${lock_waiter_pid}" ]]; then
    kill "${lock_waiter_pid}" 2>/dev/null
    wait "${lock_waiter_pid}" 2>/dev/null
  fi

  if [[ -n "${pin_root}" ]]; then
    if [[ "${pin_root}" =~ ^/sys/fs/bpf/vnet-dataplane-agent/cache-policy-txn-test-[[:alnum:]]{10}$ ]]; then
      rm -rf -- "${pin_root}" || exit_status=1
    else
      echo "cache_policy_txn_integration_test: unsafe pin cleanup path" >&2
      exit_status=1
    fi
  fi
  if [[ -n "${lock_root}" ]]; then
    if [[ "${lock_root}" =~ ^/run/vnet-dataplane-policy/cache-policy-txn-test\.[[:alnum:]]{10}$ ]]; then
      rm -rf -- "${lock_root}" || exit_status=1
    else
      echo "cache_policy_txn_integration_test: unsafe lock cleanup path" >&2
      exit_status=1
    fi
  fi
  if [[ -n "${exec_root}" ]]; then
    if [[ "${exec_root}" =~ ^/tmp/vnet-cache-policy-txn-test\.[[:alnum:]]{10}$ ]]; then
      rm -rf -- "${exec_root}" || exit_status=1
    else
      echo "cache_policy_txn_integration_test: unsafe executable cleanup path" >&2
      exit_status=1
    fi
  fi
  if [[ "${pin_parent_created}" == true ]]; then
    rmdir -- /sys/fs/bpf/vnet-dataplane-agent 2>/dev/null || true
  fi
  if [[ "${policy_root_created}" == true ]]; then
    rmdir -- /run/vnet-dataplane-policy 2>/dev/null || true
  fi
  exit "${exit_status}"
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "cache_policy_txn_integration_test: must run as root" >&2
  exit 1
fi

command -v bpftool >/dev/null
command -v c++ >/dev/null
command -v flock >/dev/null
command -v mktemp >/dev/null
command -v python3 >/dev/null
test -x "${transaction}"

if [[ ! -d /run/vnet-dataplane-policy ]]; then
  mkdir -m 0700 -- /run/vnet-dataplane-policy
  policy_root_created=true
fi
lock_root="$(mktemp -d /run/vnet-dataplane-policy/cache-policy-txn-test.XXXXXXXXXX)"
trap cleanup EXIT
exec_root="$(mktemp -d /tmp/vnet-cache-policy-txn-test.XXXXXXXXXX)"
if [[ ! -d /sys/fs/bpf/vnet-dataplane-agent ]]; then
  mkdir -m 0700 -- /sys/fs/bpf/vnet-dataplane-agent
  pin_parent_created=true
fi
pin_root="$(mktemp -d /sys/fs/bpf/vnet-dataplane-agent/cache-policy-txn-test-XXXXXXXXXX)"

c++ -std=c++17 -Wall -Wextra -Werror \
  -I"${root_dir}/src/include" \
  "${root_dir}/tests/cache_policy_txn_path_test.cpp" \
  -o "${exec_root}/cache_policy_txn_path_test"
"${exec_root}/cache_policy_txn_path_test"

map_a="${pin_root}/endpoint_a"
map_b="${pin_root}/endpoint_b"
lock_file="${lock_root}/transaction.lock"
quiesce_file="${lock_root}/transaction.quiesce"
lock_ready="${lock_root}/holder.ready"
lock_target="${lock_root}/hostile.target"
symlink_lock="${lock_root}/hostile.symlink"
permissive_lock="${lock_root}/permissive.lock"
secure_lock="${lock_root}/secure.lock"

create_map() {
  local path="$1"
  local name="$2"
  bpftool map create "${path}" type array key 4 value 16 entries 1 \
    name "${name}"
}

map_json() {
  bpftool -j map lookup pinned "$1" key hex 00 00 00 00 |
    tr -d '[:space:]"' |
    sed 's/0x//g'
}

expect_value() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(map_json "${path}")"
  case "${actual}" in
    *"value:[${expected}]"*)
      ;;
    *)
      echo "cache_policy_txn_integration_test: unexpected ${path} value" >&2
      echo "${actual}" >&2
      exit 1
      ;;
  esac
}

run_txn() {
  local operation="$1"
  local mode="$2"
  local epoch="$3"
  shift 3
  local arguments=()
  local map
  for map in "$@"; do
    arguments+=(--control-map "${map}")
  done
  "${transaction}" --operation "${operation}" --mode "${mode}" \
    --epoch "${epoch}" --lock-file "${lock_file}" \
    --quiesce-file "${quiesce_file}" "${arguments[@]}"
}

expect_quiesce_rejected() {
  local description="$1"
  local output
  shift

  if output="$("$@" 2>&1 >/dev/null)"; then
    echo "cache_policy_txn_integration_test: quiesce allowed ${description}" >&2
    exit 1
  fi
  if [[ "${output}" != *"quiesce fence active:"* ]]; then
    echo "cache_policy_txn_integration_test: unexpected ${description} error" >&2
    echo "${output}" >&2
    exit 1
  fi
}

assert_current_json() {
  local actual="$1"
  local expected_present="$2"
  local expected_maps="$3"
  local expected_epoch="$4"
  local expected_mode="$5"
  local expected_flags="$6"

  CURRENT_JSON="$actual" EXPECTED_PRESENT="$expected_present" \
    EXPECTED_MAPS="$expected_maps" EXPECTED_EPOCH="$expected_epoch" \
    EXPECTED_MODE="$expected_mode" EXPECTED_FLAGS="$expected_flags" \
    python3 - <<'PY'
import json
import os
import sys

try:
    observed = json.loads(os.environ["CURRENT_JSON"])
except json.JSONDecodeError as error:
    raise SystemExit(f"cache_policy_txn_integration_test: invalid JSON: {error}")

expected = {
    "schema_version": 1,
    "present": os.environ["EXPECTED_PRESENT"] == "true",
    "maps": int(os.environ["EXPECTED_MAPS"]),
    "epoch": int(os.environ["EXPECTED_EPOCH"]),
    "mode": int(os.environ["EXPECTED_MODE"]),
    "flags": int(os.environ["EXPECTED_FLAGS"]),
}
if observed != expected:
    print("cache_policy_txn_integration_test: unexpected read-current value",
          file=sys.stderr)
    print(f"observed={observed!r}", file=sys.stderr)
    print(f"expected={expected!r}", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_current() {
  local expected_present="$1"
  local expected_maps="$2"
  local expected_epoch="$3"
  local expected_mode="$4"
  local expected_flags="$5"
  local actual
  shift 5

  actual="$(run_txn read-current bypass 1 "$@")"
  assert_current_json "$actual" "$expected_present" "$expected_maps" \
    "$expected_epoch" "$expected_mode" "$expected_flags"
}

run_all_missing_with_lock() {
  local candidate_lock="$1"

  "${transaction}" --operation force-bypass --mode bypass --epoch 1 \
    --lock-file "${candidate_lock}" \
    --quiesce-file "${quiesce_file}" \
    --allow-all-missing \
    --control-map "${pin_root}/missing_a" \
    --control-map "${pin_root}/missing_b"
}

assert_lock_unchanged() {
  local path="$1"
  local expected_content="$2"
  local expected_mode="$3"
  local description="$4"
  local actual_content
  local actual_mode

  actual_content="$(<"${path}")"
  actual_mode="$(stat -c '%a' -- "${path}")"
  if [[ "${actual_content}" != "${expected_content}" ||
        "${actual_mode}" != "${expected_mode}" ]]; then
    echo "cache_policy_txn_integration_test: ${description} was modified" >&2
    exit 1
  fi
}

start_lock_holder() {
  local candidate_lock="$1"
  local ready_file="$2"
  local release_file="$3"

  lock_holder_release="${release_file}"
  (
    exec 9<>"${candidate_lock}"
    flock -x 9
    touch -- "${ready_file}"
    for ((attempt = 0; attempt < 500; attempt++)); do
      [[ -e "${release_file}" ]] && exit 0
      sleep 0.01
    done
    echo "cache_policy_txn_integration_test: lock holder timed out" >&2
    exit 1
  ) &
  lock_holder_pid=$!

  for ((attempt = 0; attempt < 500; attempt++)); do
    [[ -e "${ready_file}" ]] && return 0
    if ! kill -0 "${lock_holder_pid}" 2>/dev/null; then
      break
    fi
    sleep 0.01
  done
  echo "cache_policy_txn_integration_test: lock holder did not become ready" >&2
  return 1
}

start_lock_waiter() {
  local candidate_lock="$1"
  local stdout_file="$2"
  local stderr_file="$3"

  (
    exec "${transaction}" --operation force-bypass --mode bypass --epoch 1 \
      --lock-file "${candidate_lock}" \
      --quiesce-file "${quiesce_file}" \
      --allow-all-missing \
      --control-map "${pin_root}/missing_a" \
      --control-map "${pin_root}/missing_b"
  ) >"${stdout_file}" 2>"${stderr_file}" &
  lock_waiter_pid=$!
}

wait_for_flock_waiter() {
  local pid="$1"
  local candidate_lock="$2"
  local description="$3"
  local fd
  local process_state
  local saw_lock_fd=false

  for ((attempt = 0; attempt < 500; attempt++)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      break
    fi
    saw_lock_fd=false
    for fd in "/proc/${pid}/fd/"*; do
      if [[ -e "${fd}" && "${fd}" -ef "${candidate_lock}" ]]; then
        saw_lock_fd=true
        break
      fi
    done
    if [[ "${saw_lock_fd}" == true ]]; then
      process_state="$(sed -n \
        's/^State:[[:space:]]*\([^[:space:]]\).*/\1/p' \
        "/proc/${pid}/status" 2>/dev/null || true)"
      if [[ "${process_state}" == S ]]; then
        return 0
      fi
    fi
    sleep 0.01
  done
  echo "cache_policy_txn_integration_test: ${description} did not wait on flock" >&2
  return 1
}

release_lock_holder() {
  touch -- "${lock_holder_release}"
  if ! wait "${lock_holder_pid}"; then
    lock_holder_pid=
    lock_holder_release=
    echo "cache_policy_txn_integration_test: lock holder failed" >&2
    return 1
  fi
  lock_holder_pid=
  lock_holder_release=
}

create_map "${map_a}" txn_test_a
create_map "${map_b}" txn_test_b

group_writable_parent="${lock_root}/group-writable-parent"
group_writable_lock="${group_writable_parent}/transaction.lock"
mkdir -m 0770 -- "${group_writable_parent}"
if group_parent_output="$(run_all_missing_with_lock \
  "${group_writable_lock}" 2>&1 >/dev/null)"; then
  echo "cache_policy_txn_integration_test: group-writable parent succeeded" >&2
  exit 1
fi
if [[ "${group_parent_output}" != \
      *"lock parent is writable by group or other users:"* ]]; then
  echo "cache_policy_txn_integration_test: unexpected group-writable parent error" >&2
  echo "${group_parent_output}" >&2
  exit 1
fi
if [[ -e "${group_writable_lock}" ]]; then
  echo "cache_policy_txn_integration_test: rejected parent created a lock" >&2
  exit 1
fi
chmod 0700 -- "${group_writable_parent}"

printf '%s\n' hostile-lock-target >"${lock_target}"
chmod 0600 "${lock_target}"
ln -s "${lock_target}" "${symlink_lock}"
if run_all_missing_with_lock "${symlink_lock}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: symlink lock succeeded" >&2
  exit 1
fi
assert_lock_unchanged "${lock_target}" hostile-lock-target 600 \
  "symlink lock target"
rm -f -- "${symlink_lock}" "${lock_target}"

printf '%s\n' permissive-lock >"${permissive_lock}"
chmod 0644 "${permissive_lock}"
if run_all_missing_with_lock "${permissive_lock}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: 0644 lock succeeded" >&2
  exit 1
fi
assert_lock_unchanged "${permissive_lock}" permissive-lock 644 \
  "0644 lock"
rm -f -- "${permissive_lock}"

printf '%s\n' secure-lock >"${secure_lock}"
chmod 0600 "${secure_lock}"
run_all_missing_with_lock "${secure_lock}" >/dev/null
assert_lock_unchanged "${secure_lock}" secure-lock 600 "0600 lock"
rm -f -- "${secure_lock}"

if "${transaction}" --operation read-current --mode bypass --epoch 1 \
  --lock-file "${lock_file}" --control-map "${map_a}" \
  --control-map "${map_b}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: missing quiesce file succeeded" >&2
  exit 1
fi
if "${transaction}" --operation read-current --mode bypass --epoch 1 \
  --lock-file "${lock_file}" --quiesce-file relative-quiesce \
  --control-map "${map_a}" --control-map "${map_b}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: relative quiesce file succeeded" >&2
  exit 1
fi
if "${transaction}" --operation read-current --mode bypass --epoch 1 \
  --lock-file "${lock_file}" --quiesce-file / \
  --control-map "${map_a}" --control-map "${map_b}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: unsafe quiesce file succeeded" >&2
  exit 1
fi
if "${transaction}" --operation read-current --mode bypass --epoch 1 \
  --lock-file "${lock_file}" --quiesce-file "${pin_root}/" \
  --control-map "${map_a}" --control-map "${map_b}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: directory quiesce file succeeded" >&2
  exit 1
fi

"${transaction}" --operation force-bypass --mode bypass --epoch 1 \
  --lock-file "${lock_file}" \
  --quiesce-file "${quiesce_file}" \
  --allow-all-missing \
  --control-map "${pin_root}/missing_a" \
  --control-map "${pin_root}/missing_b" >/dev/null
if "${transaction}" --operation force-bypass --mode bypass --epoch 1 \
  --lock-file "${lock_file}" \
  --quiesce-file "${quiesce_file}" \
  --allow-all-missing \
  --control-map "${map_a}" \
  --control-map "${pin_root}/missing_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: partial missing set succeeded" >&2
  exit 1
fi

if "$transaction" --operation read-current --mode bypass --epoch 1 \
  --lock-file "$lock_file" --quiesce-file "$quiesce_file" \
  --control-map "$pin_root/missing_a" \
  --control-map "$pin_root/missing_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: all-missing read succeeded without opt-in" >&2
  exit 1
fi
if "$transaction" --operation read-current --mode bypass --epoch 1 \
  --lock-file "$lock_file" --quiesce-file "$quiesce_file" \
  --allow-all-missing --control-map "$map_a" \
  --control-map "$pin_root/missing_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: partial-missing read succeeded" >&2
  exit 1
fi

all_missing_current="$("$transaction" --operation read-current --mode bypass \
  --epoch 1 --lock-file "$lock_file" --quiesce-file "$quiesce_file" \
  --allow-all-missing \
  --control-map "$pin_root/missing_a" \
  --control-map "$pin_root/missing_b")"
assert_current_json "$all_missing_current" false 0 0 0 0

run_txn stage server 7 "${map_a}" "${map_b}" >/dev/null
staged_server='07,00,00,00,00,00,00,00,02,00,00,00,00,00,00,00'
expect_value "${map_a}" "${staged_server}"
expect_value "${map_b}" "${staged_server}"
run_txn verify-staged server 7 "${map_a}" "${map_b}" >/dev/null
run_txn commit server 7 "${map_a}" "${map_b}" >/dev/null
run_txn verify-committed server 7 "${map_a}" "${map_b}" >/dev/null

committed_server='07,00,00,00,00,00,00,00,02,00,00,00,01,00,00,00'
expect_value "${map_a}" "${committed_server}"
expect_value "${map_b}" "${committed_server}"
assert_current true 2 7 2 1 "$map_a" "$map_b"

committed_server_bytes=(
  07 00 00 00 00 00 00 00
  02 00 00 00
  01 00 00 00
)
client_epoch_seven=(
  07 00 00 00 00 00 00 00
  03 00 00 00
  01 00 00 00
)
bpftool map update pinned "$map_b" key hex 00 00 00 00 \
  value hex "${client_epoch_seven[@]}"
if run_txn read-current bypass 1 "$map_a" "$map_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: read-current accepted map disagreement" >&2
  exit 1
fi
bpftool map update pinned "$map_b" key hex 00 00 00 00 \
  value hex "${committed_server_bytes[@]}"

if run_txn stage dual 7 "$map_a" "$map_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: same-epoch mode mismatch succeeded" >&2
  exit 1
fi
committed_bypass_seven='07,00,00,00,00,00,00,00,01,00,00,00,01,00,00,00'
expect_value "$map_a" "$committed_bypass_seven"
expect_value "$map_b" "$committed_bypass_seven"
assert_current true 2 7 1 1 "$map_a" "$map_b"

if run_txn stage client 6 "$map_a" "$map_b" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: epoch rollback succeeded" >&2
  exit 1
fi
expect_value "$map_a" "$committed_bypass_seven"
expect_value "$map_b" "$committed_bypass_seven"

run_txn stage server 8 "$map_a" "$map_b" >/dev/null
staged_server_eight='08,00,00,00,00,00,00,00,02,00,00,00,00,00,00,00'
touch "${quiesce_file}"
for quiesced_operation in stage verify-staged commit verify-committed; do
  "${transaction}" --operation "${quiesced_operation}" --mode server \
    --epoch 9 --lock-file "${lock_file}" --quiesce-file "${quiesce_file}" \
    --allow-all-missing --control-map "${pin_root}/missing_a" \
    --control-map "${pin_root}/missing_b" >/dev/null
done
expect_quiesce_rejected "stage while quiesced" \
  run_txn stage dual 9 "$map_a" "$map_b"
expect_value "$map_a" "$staged_server_eight"
expect_value "$map_b" "$staged_server_eight"
expect_quiesce_rejected "verify-staged while quiesced" \
  run_txn verify-staged server 8 "$map_a" "$map_b"
expect_quiesce_rejected "commit while quiesced" \
  run_txn commit server 8 "$map_a" "$map_b"
expect_value "$map_a" "$staged_server_eight"
expect_value "$map_b" "$staged_server_eight"
assert_current true 2 8 2 0 "$map_a" "$map_b"
run_txn force-bypass bypass 8 "$map_a" "$map_b" >/dev/null
committed_bypass_eight='08,00,00,00,00,00,00,00,01,00,00,00,01,00,00,00'
expect_value "$map_a" "$committed_bypass_eight"
expect_value "$map_b" "$committed_bypass_eight"
expect_quiesce_rejected "verify-committed while quiesced" \
  run_txn verify-committed bypass 8 "$map_a" "$map_b"
expect_quiesce_rejected "delayed commit while quiesced" \
  run_txn commit server 8 "$map_a" "$map_b"
expect_value "$map_a" "$committed_bypass_eight"
expect_value "$map_b" "$committed_bypass_eight"
assert_current true 2 8 1 1 "$map_a" "$map_b"
rm -f -- "${quiesce_file}"

run_txn stage server 9 "$map_a" "$map_b" >/dev/null
run_txn verify-staged server 9 "$map_a" "$map_b" >/dev/null
run_txn commit server 9 "$map_a" "$map_b" >/dev/null
run_txn verify-committed server 9 "$map_a" "$map_b" >/dev/null
committed_server_nine='09,00,00,00,00,00,00,00,02,00,00,00,01,00,00,00'
expect_value "$map_a" "$committed_server_nine"
expect_value "$map_b" "$committed_server_nine"
assert_current true 2 9 2 1 "$map_a" "$map_b"

if "$transaction" --operation force-bypass --mode server --epoch 8 \
  --lock-file "$lock_file" --quiesce-file "$quiesce_file" \
  --control-map "$map_a" --control-map "$map_b" \
  >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: force-bypass accepted a non-bypass mode" >&2
  exit 1
fi

flock "$lock_file" bash -c 'touch "$1"; sleep 1' _ "$lock_ready" &
lock_holder_pid=$!
for _ in $(seq 1 100); do
  [[ -e "$lock_ready" ]] && break
  sleep 0.01
done
if [[ ! -e "$lock_ready" ]]; then
  echo "cache_policy_txn_integration_test: lock holder did not become ready" >&2
  exit 1
fi
lock_started_ns=$(date +%s%N)
run_txn verify-committed server 9 "$map_a" "$map_b" >/dev/null
lock_finished_ns=$(date +%s%N)
wait "$lock_holder_pid"
lock_holder_pid=
if (( lock_finished_ns - lock_started_ns < 500000000 )); then
  echo "cache_policy_txn_integration_test: transaction did not wait for endpoint lock" >&2
  exit 1
fi

permission_drift_lock="${lock_root}/permission-drift.lock"
permission_drift_ready="${lock_root}/permission-drift.ready"
permission_drift_release="${lock_root}/permission-drift.release"
permission_drift_stdout="${lock_root}/permission-drift.stdout"
permission_drift_stderr="${lock_root}/permission-drift.stderr"
printf '%s\n' permission-drift >"${permission_drift_lock}"
chmod 0600 -- "${permission_drift_lock}"
start_lock_holder "${permission_drift_lock}" \
  "${permission_drift_ready}" "${permission_drift_release}"
start_lock_waiter "${permission_drift_lock}" \
  "${permission_drift_stdout}" "${permission_drift_stderr}"
wait_for_flock_waiter "${lock_waiter_pid}" "${permission_drift_lock}" \
  "permission-drift transaction"
chmod 0644 -- "${permission_drift_lock}"
release_lock_holder
if wait "${lock_waiter_pid}"; then
  lock_waiter_pid=
  echo "cache_policy_txn_integration_test: post-flock permission drift succeeded" >&2
  exit 1
fi
lock_waiter_pid=
permission_drift_error="$(<"${permission_drift_stderr}")"
if [[ "${permission_drift_error}" != \
      *"acquired lock permissions must be 0600:"* ]]; then
  echo "cache_policy_txn_integration_test: unexpected permission drift error" >&2
  echo "${permission_drift_error}" >&2
  exit 1
fi

inode_drift_lock="${lock_root}/inode-drift.lock"
inode_drift_moved="${lock_root}/inode-drift.original"
inode_drift_ready="${lock_root}/inode-drift.ready"
inode_drift_release="${lock_root}/inode-drift.release"
inode_drift_stdout="${lock_root}/inode-drift.stdout"
inode_drift_stderr="${lock_root}/inode-drift.stderr"
printf '%s\n' inode-drift >"${inode_drift_lock}"
chmod 0600 -- "${inode_drift_lock}"
start_lock_holder "${inode_drift_lock}" \
  "${inode_drift_ready}" "${inode_drift_release}"
start_lock_waiter "${inode_drift_lock}" \
  "${inode_drift_stdout}" "${inode_drift_stderr}"
wait_for_flock_waiter "${lock_waiter_pid}" "${inode_drift_lock}" \
  "inode-drift transaction"
mv -- "${inode_drift_lock}" "${inode_drift_moved}"
printf '%s\n' inode-replacement >"${inode_drift_lock}"
chmod 0600 -- "${inode_drift_lock}"
release_lock_holder
if wait "${lock_waiter_pid}"; then
  lock_waiter_pid=
  echo "cache_policy_txn_integration_test: post-flock inode drift succeeded" >&2
  exit 1
fi
lock_waiter_pid=
inode_drift_error="$(<"${inode_drift_stderr}")"
if [[ "${inode_drift_error}" != *"lock path changed during acquisition:"* ]]; then
  echo "cache_policy_txn_integration_test: unexpected inode drift error" >&2
  echo "${inode_drift_error}" >&2
  exit 1
fi

parent_permission_dir="${lock_root}/parent-permission-drift"
parent_permission_lock="${parent_permission_dir}/transaction.lock"
parent_permission_ready="${lock_root}/parent-permission.ready"
parent_permission_release="${lock_root}/parent-permission.release"
parent_permission_stdout="${lock_root}/parent-permission.stdout"
parent_permission_stderr="${lock_root}/parent-permission.stderr"
mkdir -m 0700 -- "${parent_permission_dir}"
printf '%s\n' parent-permission-drift >"${parent_permission_lock}"
chmod 0600 -- "${parent_permission_lock}"
start_lock_holder "${parent_permission_lock}" \
  "${parent_permission_ready}" "${parent_permission_release}"
start_lock_waiter "${parent_permission_lock}" \
  "${parent_permission_stdout}" "${parent_permission_stderr}"
wait_for_flock_waiter "${lock_waiter_pid}" "${parent_permission_lock}" \
  "parent-permission transaction"
chmod 0770 -- "${parent_permission_dir}"
release_lock_holder
if wait "${lock_waiter_pid}"; then
  lock_waiter_pid=
  echo "cache_policy_txn_integration_test: parent permission drift succeeded" >&2
  exit 1
fi
lock_waiter_pid=
parent_permission_error="$(<"${parent_permission_stderr}")"
if [[ "${parent_permission_error}" != \
      *"acquired lock parent is writable by group or other users:"* ]]; then
  echo "cache_policy_txn_integration_test: unexpected parent permission error" >&2
  echo "${parent_permission_error}" >&2
  exit 1
fi
chmod 0700 -- "${parent_permission_dir}"

parent_inode_dir="${lock_root}/parent-inode-drift"
parent_inode_moved="${lock_root}/parent-inode-drift.original"
parent_inode_lock="${parent_inode_dir}/transaction.lock"
parent_inode_ready="${lock_root}/parent-inode.ready"
parent_inode_release="${lock_root}/parent-inode.release"
parent_inode_stdout="${lock_root}/parent-inode.stdout"
parent_inode_stderr="${lock_root}/parent-inode.stderr"
mkdir -m 0700 -- "${parent_inode_dir}"
printf '%s\n' parent-inode-drift >"${parent_inode_lock}"
chmod 0600 -- "${parent_inode_lock}"
start_lock_holder "${parent_inode_lock}" \
  "${parent_inode_ready}" "${parent_inode_release}"
start_lock_waiter "${parent_inode_lock}" \
  "${parent_inode_stdout}" "${parent_inode_stderr}"
wait_for_flock_waiter "${lock_waiter_pid}" "${parent_inode_lock}" \
  "parent-inode transaction"
mv -- "${parent_inode_dir}" "${parent_inode_moved}"
mkdir -m 0700 -- "${parent_inode_dir}"
printf '%s\n' parent-inode-replacement >"${parent_inode_lock}"
chmod 0600 -- "${parent_inode_lock}"
release_lock_holder
if wait "${lock_waiter_pid}"; then
  lock_waiter_pid=
  echo "cache_policy_txn_integration_test: parent inode drift succeeded" >&2
  exit 1
fi
lock_waiter_pid=
parent_inode_error="$(<"${parent_inode_stderr}")"
if [[ "${parent_inode_error}" != *"lock parent changed during acquisition:"* ]]; then
  echo "cache_policy_txn_integration_test: unexpected parent inode error" >&2
  echo "${parent_inode_error}" >&2
  exit 1
fi

dual_epoch_nine=(
  09 00 00 00 00 00 00 00
  04 00 00 00
  01 00 00 00
)
bpftool map update pinned "${map_a}" key hex 00 00 00 00 \
  value hex "${dual_epoch_nine[@]}"
bpftool map update pinned "${map_b}" key hex 00 00 00 00 \
  value hex "${dual_epoch_nine[@]}"
bpftool map freeze pinned "${map_b}"

if run_txn stage client 10 "${map_a}" "${map_b}" >/dev/null 2>&1; then
  echo "cache_policy_txn_integration_test: injected stage failure succeeded" >&2
  exit 1
fi

committed_bypass_ten='0a,00,00,00,00,00,00,00,01,00,00,00,01,00,00,00'
committed_dual_nine='09,00,00,00,00,00,00,00,04,00,00,00,01,00,00,00'
expect_value "${map_a}" "${committed_bypass_ten}"
expect_value "${map_b}" "${committed_dual_nine}"

echo "cache_policy_txn_integration_test: PASS"
