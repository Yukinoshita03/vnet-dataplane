#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
  "${root_dir}/bench/openstack_dns_e2e.sh"
  "${root_dir}/bench/openstack_dynamic_cache_campaign.sh"
  "${root_dir}/bench/openstack_existing_pair_campaign.sh"
  "${root_dir}/bench/openstack_service_migration_probe.sh"
  "${root_dir}/bench/openstack_systemd_dynamic_e2e.sh"
)

for script in "${scripts[@]}"; do
  bash -n "${script}"
  if grep -n "killall" "${script}"; then
    echo "shared-name process cleanup is forbidden: ${script}" >&2
    exit 1
  fi
done

if grep -nE '/tmp/(openstack_dns_harness|openstack_grpc_harness|grpc_fast_cache|dns_monitor|dns_client_cache|dns_xdp_monitor)' "${scripts[@]}"; then
  echo "shared guest artifact path is forbidden" >&2
  exit 1
fi

if grep -nE '/sys/fs/bpf/vnet-(dynamic|migration|five-experiments)([^A-Za-z0-9_-]|$)' "${scripts[@]}"; then
  echo "shared BPF pin path is forbidden" >&2
  exit 1
fi

grep -q "guest_run_dir" "${scripts[0]}"
grep -q "guest_run_dir" "${scripts[1]}"
grep -q "run_id" "${scripts[2]}"
grep -q "run_id" "${scripts[3]}"
grep -q "run_nonce=" "${scripts[1]}"
grep -q "flock -n" "${scripts[1]}"
grep -q "host_process_start_time" "${scripts[1]}"
grep -q "MANAGE_GRPC_SECURITY_GROUP_RULE" "${scripts[1]}"
grep -q "OPENSTACK_GRPC_BACKEND_SECURITY_GROUP_ID" "${scripts[1]}"
grep -q "openstack security group rule create" "${scripts[1]}"
grep -q "openstack security group rule delete" "${scripts[1]}"
grep -q "managed_grpc_security_group_rule_verify=not_found" "${scripts[1]}"
grep -q "raw_prefix}.status" "${scripts[1]}"
grep -q 'gate_file="\${state_file}.ready"' "${scripts[1]}"
grep -q "failed_to_record_guest_workload" "${scripts[1]}"
grep -q "failed_to_release_guest_workload" "${scripts[1]}"
grep -q 'for pid in \\\"\\${pids\[@\]}\\\"' "${scripts[1]}"
grep -q 'wait \\\"\\$pid\\\" || status=1' "${scripts[1]}"
if grep -Eq '^[[:space:]]*wait[[:space:]]*$' "${scripts[1]}"; then
  echo "unqualified wait can hide workload failures" >&2
  exit 1
fi
grep -q "setsid" "${scripts[0]}"
grep -q "setsid" "${scripts[1]}"
grep -q "setsid" "${scripts[2]}"
grep -q "setsid" "${scripts[3]}"
grep -q "kill -0 --" "${scripts[0]}"
grep -q "kill -0 --" "${scripts[1]}"
grep -q "kill -0 --" "${scripts[2]}"
grep -q "kill -0 --" "${scripts[3]}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
out_dir="${tmp_dir}"
cleanup_function="$(awk '
  /^cleanup_grpc_security_group_rule\(\)/ { capture=1 }
  capture { print }
  capture && /^}$/ { exit }
' "${scripts[1]}")"
eval "${cleanup_function}"

mock_openstack_mode="not_found"
openstack() {
  case "${4:-}" in
    delete)
      return 0
      ;;
    show)
      case "${mock_openstack_mode}" in
        not_found)
          printf 'No SecurityGroupRule with this value found (404)\n' >&2
          return 1
          ;;
        api_error)
          printf 'Internal Server Error (500)\n' >&2
          return 1
          ;;
      esac
      ;;
  esac
  return 2
}

grpc_security_group_rule_id="11111111-1111-1111-1111-111111111111"
cleanup_grpc_security_group_rule
test -z "${grpc_security_group_rule_id}"
grep -q "managed_grpc_security_group_rule_verify=not_found id=11111111-1111-1111-1111-111111111111 status=1" \
  "${out_dir}/grpc-security-group-rule.txt"

mock_openstack_mode="api_error"
grpc_security_group_rule_id="22222222-2222-2222-2222-222222222222"
if cleanup_grpc_security_group_rule 2>"${tmp_dir}/expected-security-group-error.log"; then
  echo "security-group verification must fail on an API error" >&2
  exit 1
fi
test -n "${grpc_security_group_rule_id}"
grep -q "managed_grpc_security_group_rule_verify=error id=22222222-2222-2222-2222-222222222222 status=1" \
  "${out_dir}/grpc-security-group-rule.txt"

parallel_payload='pids=(); false & pids+=("$!"); true & pids+=("$!"); status=0; for pid in "${pids[@]}"; do wait "$pid" || status=1; done; exit "$status"'
if bash -c "${parallel_payload}"; then
  echo "tracked child failure was incorrectly accepted" >&2
  exit 1
fi

echo "openstack_campaign_lifecycle_test: PASS"
