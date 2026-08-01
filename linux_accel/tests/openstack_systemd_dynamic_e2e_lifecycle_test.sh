#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runner="${root_dir}/bench/openstack_systemd_dynamic_e2e.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT

test_python="${PYTHON_BIN:-python3}"
if ! "${test_python}" -c 'import json' >/dev/null 2>&1; then
  test_python=python
fi
"${test_python}" -c 'import json' >/dev/null

test -x "${runner}"
bash -n "${runner}"
grep -q "wait-committed" "${runner}"
grep -q -- '--require-shutdown' "${runner}"
grep -Fq 'value.get("schema_version") != 2' "${runner}"
grep -Fq 'client endpoint port allowlist does not match CLIENT_PORT_ID' "${runner}"
grep -Eq 'client[[:space:]]+"127\.0\.0\.1"[[:space:]]+50053' "${runner}"
if grep -nE '(^|[;&|[:space:]])sleep[[:space:]]+[1-9][0-9]*(\.[0-9]+)?([;&|[:space:]]|$)' "${runner}"; then
  echo "fixed multi-second publication sleep is forbidden" >&2
  exit 1
fi

driver="${tmp_dir}/fake-action-driver.sh"
action_log="${tmp_dir}/actions.log"

cat >"${driver}" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${VNET_E2E_ACTION_LOG:?}"
action="${1:?}"
shift
full_action="${action}${*:+ $*}"

if [[ -n "${VNET_E2E_FAIL_ACTION:-}" &&
      "${full_action}" == "${VNET_E2E_FAIL_ACTION}" ]]; then
  exit 42
fi

case "${action}" in
  preflight|deploy|service|audit-running)
    ;;
  audit-cleanup)
    if [[ "${VNET_E2E_SKIP_CLEANUP_EVIDENCE:-0}" == 0 ]]; then
      mkdir -p "${OUT_DIR:?}/cleanup/raw"
      printf '%s\n' 'fake cleanup observation' \
        >"${OUT_DIR}/cleanup/raw/fake-observation.txt"
      printf '%s\n' \
        '{"schema":1,"passed":true,"checks":{"units_inactive":true,"pins_removed":true,"quiesce_removed":true,"processes_absent":true,"xdp_detached":true,"listeners_absent":true,"tc_cleanup":true,"continuity_absent":true},"netmig_baseline_scope":"test_driver","raw_files":["cleanup/raw/fake-observation.txt"]}' \
        >"${OUT_DIR}/cleanup-evidence.json"
    fi
    ;;
  read-epoch)
    printf '%s\n' 72
    ;;
  wait-committed)
    case "${1:?target mode}" in
      bypass)
        after_epoch="${2:?after epoch}"
        printf '{"ready":true,"mode":"bypass","epoch":%s,"present_readbacks":4}\n' \
          "$((after_epoch + 1))"
        ;;
      server)
        [[ "${VNET_E2E_NEVER_COMMIT:-0}" == 0 ]] || exit 1
        convergence_count="$(cat "${VNET_E2E_DRIVER_STATE:?}" 2>/dev/null || printf 0)"
        (( convergence_count >= 3 )) || exit 1
        committed_epoch="$((${2:?after epoch} + 1))"
        printf '%s\n' "${committed_epoch}" \
          >"${VNET_E2E_DRIVER_STATE}.epoch"
        printf '{"ready":true,"mode":"server","epoch":%s,"present_readbacks":4}\n' \
          "${committed_epoch}"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  migration-baseline)
    printf '{"schema":1,"phase":"%s","source_host":"%s","target_host":"%s","after_epoch":%s,"coordinator":{"device":1,"inode":2,"offset":100},"source_agent":{"device":3,"inode":4,"offset":200},"target_agent":{"device":5,"inode":6,"offset":300}}\n' \
      "${1:?phase}" "${2:?source}" "${3:?target}" "${4:?after epoch}"
    ;;
  wait-transition)
    printf '{"ready":true,"outcome":"migration_forced_bypass","epoch":%s,"matched_byte_start":100,"matched_byte_end":200}\n' \
      "$((${4:?after epoch} + 1))"
    ;;
  wait-attachment)
    printf '{"ready":true,"phase":"%s","source_host":"%s","target_host":"%s","source_detached":true,"target_attached":true}\n' \
      "${1:?phase}" "${2:?source}" "${3:?target}"
    ;;
  continuity)
    printf '{"schema":1,"operation":"%s","phase":"%s","passed":true}\n' \
      "${1:?operation}" "${2:?phase}"
    ;;
  migration)
    phase="${1:?migration phase}"
    server_id="${2:?server id}"
    source_host="${3:?source host}"
    target_host="${4:?target host}"
    port_id="${BACKEND_PORT_ID:?backend port id}"
    host_file="${VNET_E2E_DRIVER_STATE:?}.host"
    current_host="$(cat "${host_file}" 2>/dev/null || printf master)"
    if [[ "${phase}" == restore && "${current_host}" == "${target_host}" ]]; then
      outcome=already_on_target
      migration_id=null
    else
      [[ "${current_host}" == "${source_host}" ]] || exit 43
      printf '%s\n' "${target_host}" >"${host_file}"
      outcome=completed
      migration_id="\"fake-${phase}\""
    fi
    printf '{"schema":1,"phase":"%s","status":"completed","outcome":"%s","server_id":"%s","port_id":"%s","source_host":"%s","requested_source_host":"%s","target_host":"%s","final_host":"%s","migration_id":%s}\n' \
      "${phase}" "${outcome}" "${server_id}" "${port_id}" \
      "${source_host}" "${source_host}" "${target_host}" "${target_host}" \
      "${migration_id}"
    ;;
  snapshot)
    runtime_epoch="$(cat "${VNET_E2E_DRIVER_STATE:?}.epoch" 2>/dev/null || printf 74)"
    case "${1:?snapshot phase}" in
      before)
        printf '{"dns_backend_count":50,"dns_cache_hit":100,"dns_cache_tx":100,"dns_cache_miss":50,"dns_policy_bypass":50,"grpc_accepted":200,"grpc_cache_hit":100,"grpc_serving_cache_hit":100,"grpc_fallback":100,"grpc_fallback_error":0,"grpc_parse_error":0,"grpc_policy_bypass":100,"grpc_tx_error":0,"grpc_runtime_epoch":%s}\n' \
          "${runtime_epoch}"
        ;;
      after)
        if [[ "${VNET_E2E_NEVER_CONVERGE:-0}" == 1 ]]; then
          printf '{"dns_backend_count":100,"dns_cache_hit":100,"dns_cache_tx":100,"dns_cache_miss":100,"dns_policy_bypass":50,"grpc_accepted":250,"grpc_cache_hit":150,"grpc_serving_cache_hit":150,"grpc_fallback":100,"grpc_fallback_error":0,"grpc_parse_error":0,"grpc_policy_bypass":100,"grpc_tx_error":0,"grpc_runtime_epoch":%s}\n' \
            "${runtime_epoch}"
          exit 0
        fi
        if [[ "${VNET_E2E_DELAY_METRICS:-0}" == 1 ]]; then
          after_count_file="${VNET_E2E_DRIVER_STATE:?}.after-count"
          after_count="$(cat "${after_count_file}" 2>/dev/null || printf 0)"
          printf '%s\n' "$((after_count + 1))" >"${after_count_file}"
          if (( after_count == 0 )); then
            printf '{"dns_backend_count":100,"dns_cache_hit":100,"dns_cache_tx":100,"dns_cache_miss":100,"dns_policy_bypass":50,"grpc_accepted":250,"grpc_cache_hit":150,"grpc_serving_cache_hit":150,"grpc_fallback":100,"grpc_fallback_error":0,"grpc_parse_error":0,"grpc_policy_bypass":100,"grpc_tx_error":0,"grpc_runtime_epoch":%s}\n' \
              "${runtime_epoch}"
            exit 0
          fi
        fi
        printf '{"dns_backend_count":50,"dns_cache_hit":150,"dns_cache_tx":150,"dns_cache_miss":50,"dns_policy_bypass":50,"grpc_accepted":250,"grpc_cache_hit":150,"grpc_serving_cache_hit":150,"grpc_fallback":100,"grpc_fallback_error":0,"grpc_parse_error":0,"grpc_policy_bypass":100,"grpc_tx_error":0,"grpc_runtime_epoch":%s}\n' \
          "${runtime_epoch}"
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  workload)
    if [[ "${1:?protocol}" == dns && "${2:?phase}" == convergence ]]; then
      convergence_count="$(cat "${VNET_E2E_DRIVER_STATE:?}" 2>/dev/null || printf 0)"
      printf '%s\n' "$((convergence_count + 1))" >"${VNET_E2E_DRIVER_STATE}"
    fi
    case "${1:?protocol}" in
      dns)
        printf '%s\n' 'requests=40 success=40 failed=0 qps=1500.00 avg_us=660.00 p95_us=1300.00'
        ;;
      grpc)
        printf '%s\n' 'requests=40 serving=40 not_serving=0 failed=0 qps=570.00 avg_us=1380.00 p95_us=3080.00'
        ;;
      *)
        exit 2
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
DRIVER
chmod 700 "${driver}"

run_smoke() {
  local out_dir="$1"
  shift
  env \
    OUT_DIR="${out_dir}" \
    VNET_E2E_ACTION_DRIVER="${driver}" \
    VNET_E2E_ACTION_LOG="${action_log}" \
    VNET_E2E_DRIVER_STATE="${out_dir}/driver-state" \
    PYTHON_BIN="${test_python}" \
    CLIENT_SERVER_ID=5d983776-e49c-4320-b038-f720df01ace6 \
    CLIENT_PORT_ID=2200c160-c07d-43ea-9cda-5aabd4e54d37 \
    BACKEND_SERVER_ID=383d55a1-2d78-4ec2-927e-0575312ccc0d \
    BACKEND_PORT_ID=8ddb7d32-92ab-41e2-b5b9-94596bef3952 \
    CLIENT_IP=10.0.0.43 \
    BACKEND_IP=10.0.0.55 \
    "$@" \
    bash "${runner}"
}

assert_ordered_subsequence() {
  local file="$1"
  shift
  local cursor=0 pattern line
  for pattern in "$@"; do
    line="$(awk -v start="$((cursor + 1))" -v pattern="${pattern}" \
      'NR >= start && index($0, pattern) { print NR; exit }' "${file}")"
    if [[ -z "${line}" ]]; then
      echo "missing ordered action after line ${cursor}: ${pattern}" >&2
      sed -n '1,240p' "${file}" >&2
      exit 1
    fi
    cursor="${line}"
  done
}

assert_manifest_valid() {
  local directory="$1"
  (
    cd "${directory}"
    sha256sum -c sha256sums.txt >/dev/null
  )
}

success_out="${tmp_dir}/success"
: >"${action_log}"
run_smoke "${success_out}"

assert_ordered_subsequence "${action_log}" \
  "preflight" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-metrics-controller.service" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "service local master stop vnet-dataplane-agent.service" \
  "service remote client-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-dataplane-guest-endpoint.service" \
  "deploy" \
  "service remote backend-guest start vnet-lab-dns-backend.service" \
  "service remote backend-guest start vnet-lab-grpc-backend.service" \
  "service remote backend-guest start vnet-dataplane-guest-endpoint.service" \
  "service remote client-guest start vnet-dataplane-guest-endpoint.service" \
  "service remote compute2 start vnet-dataplane-agent.service" \
  "service local master start vnet-dataplane-agent.service" \
  "service local master start vnet-dataplane-metrics-controller.service" \
  "service local master start vnet-dataplane-epoch-coordinator.service" \
  "wait-committed bypass 72" \
  "workload dns convergence" \
  "workload grpc convergence" \
  "wait-committed server 73" \
  "snapshot before" \
  "workload dns measured" \
  "workload grpc measured" \
  "snapshot after" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-metrics-controller.service" \
  "wait-committed bypass 74 shutdown" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "service local master stop vnet-dataplane-agent.service" \
  "service remote client-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-lab-grpc-backend.service" \
  "service remote backend-guest stop vnet-lab-dns-backend.service" \
  "audit-cleanup"

grep -q '"status":"passed"' "${success_out}/result-summary.json"
grep -q '"execution_mode":"test_driver"' "${success_out}/result-summary.json"
grep -q '"experiment_executed":true' "${success_out}/result-summary.json"
grep -q '"formal_rounds":0' "${success_out}/result-summary.json"
grep -q '"mode":"server"' "${success_out}/committed-server.json"
grep -q '"dns_backend_suppressed":true' "${success_out}/result-summary.json"
grep -q '"grpc_kernel_response":false' "${success_out}/result-summary.json"
grep -q '"passed":true' "${success_out}/cleanup-evidence.json"
assert_manifest_valid "${success_out}"
test "$(grep -c '^workload dns convergence$' "${action_log}")" -eq 3
test "$(grep -c '^workload grpc convergence$' "${action_log}")" -eq 3
test "$(grep -c '^wait-committed server 73$' "${action_log}")" -eq 3

third_wait_line="$(grep -n '^wait-committed server 73$' "${action_log}" | tail -n 1 | cut -d: -f1)"
measured_line="$(grep -n '^workload dns measured$' "${action_log}" | cut -d: -f1)"
(( measured_line > third_wait_line ))

remote_source_out="${tmp_dir}/remote-source"
: >"${action_log}"
run_smoke "${remote_source_out}" \
  SOURCE_COMPUTE_REMOTE=1 \
  EXPECTED_COMPUTE_HOST=compute2 \
  COMPUTE2_HOST=compute3 \
  SOURCE_COMPUTE_SSH_TARGET=ubuntu@172.25.6.13 \
  TARGET_COMPUTE_SSH_TARGET=ubuntu@172.25.6.14 \
  CLIENT_HOST_INTERFACE=tap2200c160-c0 \
  BACKEND_HOST_INTERFACE=tap8ddb7d32-92 \
  DEPLOY_PROFILE=shared-yoga \
  VNET_KNOWN_HOSTS=/etc/vnet-dataplane-shared/known_hosts \
  REQUIRE_NETMIG_TC=0 \
  SHARED_CLUSTER_INVENTORY=/etc/vnet-dataplane-shared/inventory.json \
  SHARED_SSH_IDENTITY_FILE=/etc/vnet-dataplane-shared/id_ed25519 \
  VNET_E2E_SKIP_SHARED_PREFLIGHT=1 \
  DEPLOY_ARTIFACTS=0
assert_ordered_subsequence "${action_log}" \
  "service remote compute3 stop vnet-dataplane-agent.service" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "deploy" \
  "service remote compute3 start vnet-dataplane-agent.service" \
  "service remote compute2 start vnet-dataplane-agent.service" \
  "service local master start vnet-dataplane-metrics-controller.service" \
  "service local master start vnet-dataplane-epoch-coordinator.service" \
  "service remote compute3 stop vnet-dataplane-agent.service" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "audit-cleanup"
if grep -q '^service local compute2 .*vnet-dataplane-agent.service$' "${action_log}"; then
  echo "remote source compute was incorrectly managed as a local service" >&2
  exit 1
fi
if grep -q '^service local master .*vnet-dataplane-agent.service$' "${action_log}"; then
  echo "controller incorrectly managed a Compute Agent in remote-source mode" >&2
  exit 1
fi
grep -q '"status":"passed"' "${remote_source_out}/result-summary.json"
assert_manifest_valid "${remote_source_out}"

unsafe_remote_out="${tmp_dir}/unsafe-remote-source"
: >"${action_log}"
if run_smoke "${unsafe_remote_out}" \
    SOURCE_COMPUTE_REMOTE=1 \
    EXPECTED_COMPUTE_HOST=compute2 \
    COMPUTE2_HOST=compute3 \
    VNET_E2E_SKIP_SHARED_PREFLIGHT=1 \
    >"${unsafe_remote_out}.log" 2>&1; then
  echo "remote source run without explicit transport/interface scope was accepted" >&2
  exit 1
fi
grep -q 'requires explicit SOURCE_COMPUTE_SSH_TARGET' "${unsafe_remote_out}.log"
test ! -s "${action_log}"

unsafe_deploy_out="${tmp_dir}/unsafe-remote-deploy"
: >"${action_log}"
if run_smoke "${unsafe_deploy_out}" \
    SOURCE_COMPUTE_REMOTE=1 \
    EXPECTED_COMPUTE_HOST=compute2 \
    COMPUTE2_HOST=compute3 \
    SOURCE_COMPUTE_SSH_TARGET=ubuntu@172.25.6.13 \
    TARGET_COMPUTE_SSH_TARGET=ubuntu@172.25.6.14 \
    CLIENT_HOST_INTERFACE=tap2200c160-c0 \
    BACKEND_HOST_INTERFACE=tap8ddb7d32-92 \
    DEPLOY_PROFILE=shared-yoga \
    VNET_KNOWN_HOSTS=/etc/vnet-dataplane-shared/known_hosts \
    REQUIRE_NETMIG_TC=0 \
    SHARED_CLUSTER_INVENTORY=/etc/vnet-dataplane-shared/inventory.json \
    SHARED_SSH_IDENTITY_FILE=/etc/vnet-dataplane-shared/id_ed25519 \
    VNET_E2E_SKIP_SHARED_PREFLIGHT=1 \
    DEPLOY_ARTIFACTS=1 \
    >"${unsafe_deploy_out}.log" 2>&1; then
  echo "remote source run was allowed to overwrite deployment artifacts" >&2
  exit 1
fi
grep -q 'requires pre-staged artifacts' "${unsafe_deploy_out}.log"
test ! -s "${action_log}"

roundtrip_out="${tmp_dir}/roundtrip"
: >"${action_log}"
run_smoke "${roundtrip_out}" MIGRATION_MODE=roundtrip

assert_ordered_subsequence "${action_log}" \
  "wait-committed server 73" \
  "migration-baseline forward master compute2 74" \
  "continuity start forward" \
  "migration forward 383d55a1-2d78-4ec2-927e-0575312ccc0d master compute2" \
  "wait-transition forward master compute2 74" \
  "wait-attachment forward master compute2" \
  "wait-committed server 75" \
  "continuity stop forward" \
  "migration-baseline reverse compute2 master 76" \
  "continuity start reverse" \
  "migration reverse 383d55a1-2d78-4ec2-927e-0575312ccc0d compute2 master" \
  "wait-transition reverse compute2 master 76" \
  "wait-attachment reverse compute2 master" \
  "wait-committed server 77" \
  "continuity stop reverse" \
  "snapshot before" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "audit-cleanup"
if grep -q '^migration restore ' "${action_log}"; then
  echo "successful roundtrip unexpectedly ran recovery migration" >&2
  exit 1
fi
"${test_python}" - \
  "${roundtrip_out}/migration/forward.json" \
  "${roundtrip_out}/migration/reverse.json" \
  "${roundtrip_out}/migration/roundtrip.json" \
  "${roundtrip_out}/result-summary.json" <<'PY'
import json
import sys
from pathlib import Path

forward, reverse, roundtrip, summary = (
    json.loads(Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
)
assert forward["schema"] == 1
assert forward["phase"] == "forward"
assert forward["status"] == "completed"
assert forward["final_host"] == "compute2"
assert reverse["schema"] == 1
assert reverse["phase"] == "reverse"
assert reverse["status"] == "completed"
assert reverse["final_host"] == "master"
assert roundtrip["schema"] == 1
assert roundtrip["completed"] is True
assert roundtrip["final_host"] == "master"
assert roundtrip["recovery_attempted"] is False
assert summary["status"] == "passed"
assert summary["migration_mode"] == "roundtrip"
assert summary["migration_roundtrip_completed"] is True
assert summary["formal_rounds"] == 0
PY
assert_manifest_valid "${roundtrip_out}"

reverse_failure_out="${tmp_dir}/roundtrip-reverse-failure"
: >"${action_log}"
if run_smoke "${reverse_failure_out}" \
    MIGRATION_MODE=roundtrip \
    VNET_E2E_FAIL_ACTION="migration reverse 383d55a1-2d78-4ec2-927e-0575312ccc0d compute2 master"; then
  echo "failed reverse migration was incorrectly accepted" >&2
  exit 1
fi
assert_ordered_subsequence "${action_log}" \
  "migration forward 383d55a1-2d78-4ec2-927e-0575312ccc0d master compute2" \
  "continuity stop forward" \
  "continuity start reverse" \
  "migration reverse 383d55a1-2d78-4ec2-927e-0575312ccc0d compute2 master" \
  "continuity abort reverse" \
  "migration restore 383d55a1-2d78-4ec2-927e-0575312ccc0d compute2 master" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "audit-cleanup"
test -s "${reverse_failure_out}/migration/reverse.err"
"${test_python}" - \
  "${reverse_failure_out}/migration/forward.json" \
  "${reverse_failure_out}/migration/recovery.json" \
  "${reverse_failure_out}/migration/roundtrip.json" \
  "${reverse_failure_out}/result-summary.json" <<'PY'
import json
import sys
from pathlib import Path

forward, recovery, roundtrip, summary = (
    json.loads(Path(path).read_text(encoding="utf-8"))
    for path in sys.argv[1:]
)
assert forward["status"] == "completed"
assert forward["final_host"] == "compute2"
assert recovery["phase"] == "restore"
assert recovery["status"] == "completed"
assert recovery["final_host"] == "master"
assert roundtrip["completed"] is False
assert roundtrip["recovery_attempted"] is True
assert roundtrip["recovery_completed"] is True
assert roundtrip["final_host"] == "master"
assert summary["status"] == "failed"
assert summary["migration_mode"] == "roundtrip"
assert summary["migration_roundtrip_completed"] is False
assert summary["cleanup_status"] == 0
PY
grep -q '"passed":true' "${reverse_failure_out}/cleanup-evidence.json"
assert_manifest_valid "${reverse_failure_out}"

delayed_metrics_out="${tmp_dir}/delayed-metrics"
: >"${action_log}"
run_smoke "${delayed_metrics_out}" VNET_E2E_DELAY_METRICS=1
test "$(grep -c '^snapshot after$' "${action_log}")" -eq 2
grep -q '"passed":true' "${delayed_metrics_out}/verification.json"
grep -q '"status":"passed"' \
  "${delayed_metrics_out}/result-summary.json"

metrics_failure_out="${tmp_dir}/metrics-failure"
: >"${action_log}"
if run_smoke "${metrics_failure_out}" VNET_E2E_NEVER_CONVERGE=1; then
  echo "non-converging metrics were incorrectly accepted" >&2
  exit 1
fi
test "$(grep -c '^snapshot after$' "${action_log}")" -eq 100
grep -q '"passed":false' "${metrics_failure_out}/verification.json"
grep -q '"status":"failed"' \
  "${metrics_failure_out}/result-summary.json"
grep -q '"dns_backend_suppressed":false' \
  "${metrics_failure_out}/result-summary.json"

preflight_out="${tmp_dir}/preflight-only"
: >"${action_log}"
run_smoke "${preflight_out}" PREFLIGHT_ONLY=1
test "$(cat "${action_log}")" = preflight
grep -q '"status":"preflight_passed"' \
  "${preflight_out}/result-summary.json"
grep -q '"preflight_only":1' "${preflight_out}/result-summary.json"
grep -q '"experiment_executed":false' \
  "${preflight_out}/result-summary.json"

cleanup_audit_only_out="${tmp_dir}/cleanup-audit-only"
: >"${action_log}"
run_smoke "${cleanup_audit_only_out}" CLEANUP_AUDIT_ONLY=1
test "$(cat "${action_log}")" = $'preflight\naudit-cleanup'
grep -q '"status":"cleanup_audit_passed"' \
  "${cleanup_audit_only_out}/result-summary.json"
grep -q '"cleanup_audit_only":1' \
  "${cleanup_audit_only_out}/result-summary.json"
grep -q '"experiment_executed":false' \
  "${cleanup_audit_only_out}/result-summary.json"
grep -q '"passed":true' \
  "${cleanup_audit_only_out}/cleanup-evidence.json"
assert_manifest_valid "${cleanup_audit_only_out}"

failure_out="${tmp_dir}/failure"
: >"${action_log}"
if run_smoke "${failure_out}" VNET_E2E_FAIL_ACTION="workload dns measured"; then
  echo "injected workload failure was incorrectly accepted" >&2
  exit 1
fi

assert_ordered_subsequence "${action_log}" \
  "workload dns measured" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-metrics-controller.service" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "service local master stop vnet-dataplane-agent.service" \
  "service remote client-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-dataplane-guest-endpoint.service" \
  "audit-cleanup"
grep -q '"status":"failed"' "${failure_out}/result-summary.json"
grep -q '"formal_rounds":0' "${failure_out}/result-summary.json"

wait_failure_out="${tmp_dir}/wait-failure"
: >"${action_log}"
if run_smoke "${wait_failure_out}" VNET_E2E_NEVER_COMMIT=1; then
  echo "uncommitted SERVER_CACHE was incorrectly accepted" >&2
  exit 1
fi
test "$(grep -c '^wait-committed server 73$' "${action_log}")" -eq 3
if grep -Eq '^(snapshot before|workload (dns|grpc) measured)$' "${action_log}"; then
  echo "measurement ran without a committed SERVER_CACHE barrier" >&2
  exit 1
fi
grep -q '"status":"failed"' "${wait_failure_out}/result-summary.json"
grep -q '^audit-cleanup$' "${action_log}"

baseline_failure_out="${tmp_dir}/baseline-failure"
: >"${action_log}"
if run_smoke "${baseline_failure_out}" \
    VNET_E2E_FAIL_ACTION="wait-committed bypass 72"; then
  echo "uncommitted initial BYPASS was incorrectly accepted" >&2
  exit 1
fi
assert_ordered_subsequence "${action_log}" \
  "wait-committed bypass 72" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-metrics-controller.service" \
  "wait-committed bypass 72 shutdown" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "service local master stop vnet-dataplane-agent.service" \
  "service remote client-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-lab-grpc-backend.service" \
  "service remote backend-guest stop vnet-lab-dns-backend.service" \
  "audit-cleanup"
if grep -Eq '^(snapshot|workload) ' "${action_log}"; then
  echo "workload or snapshot ran without the initial BYPASS barrier" >&2
  exit 1
fi
grep -q '"status":"failed"' "${baseline_failure_out}/result-summary.json"
grep -q '"cleanup_status":0' "${baseline_failure_out}/result-summary.json"

coordinator_start_failure_out="${tmp_dir}/coordinator-start-failure"
: >"${action_log}"
if run_smoke "${coordinator_start_failure_out}" \
    VNET_E2E_FAIL_ACTION="service local master start vnet-dataplane-epoch-coordinator.service"; then
  echo "partial coordinator start failure was incorrectly accepted" >&2
  exit 1
fi
assert_ordered_subsequence "${action_log}" \
  "service local master start vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-epoch-coordinator.service" \
  "service local master stop vnet-dataplane-metrics-controller.service" \
  "wait-committed bypass 72 shutdown" \
  "service remote compute2 stop vnet-dataplane-agent.service" \
  "service local master stop vnet-dataplane-agent.service" \
  "service remote client-guest stop vnet-dataplane-guest-endpoint.service" \
  "service remote backend-guest stop vnet-dataplane-guest-endpoint.service" \
  "audit-cleanup"
if grep -Eq '^(snapshot|workload) ' "${action_log}"; then
  echo "workload ran after a partial coordinator start failure" >&2
  exit 1
fi
grep -q '"status":"failed"' \
  "${coordinator_start_failure_out}/result-summary.json"

cleanup_failure_out="${tmp_dir}/cleanup-failure"
: >"${action_log}"
if run_smoke "${cleanup_failure_out}" VNET_E2E_FAIL_ACTION=audit-cleanup; then
  echo "cleanup audit failure was incorrectly accepted" >&2
  exit 1
fi
grep -q '^audit-cleanup$' "${action_log}"
grep -q '"status":"failed"' "${cleanup_failure_out}/result-summary.json"
grep -q '"cleanup_status":1' "${cleanup_failure_out}/result-summary.json"

missing_cleanup_evidence_out="${tmp_dir}/missing-cleanup-evidence"
: >"${action_log}"
if run_smoke "${missing_cleanup_evidence_out}" \
    VNET_E2E_SKIP_CLEANUP_EVIDENCE=1; then
  echo "missing cleanup evidence was incorrectly accepted" >&2
  exit 1
fi
grep -q '^audit-cleanup$' "${action_log}"
grep -q '"status":"failed"' \
  "${missing_cleanup_evidence_out}/result-summary.json"
grep -q '"cleanup_status":1' \
  "${missing_cleanup_evidence_out}/result-summary.json"

echo "openstack_systemd_dynamic_e2e_lifecycle_test: PASS"
