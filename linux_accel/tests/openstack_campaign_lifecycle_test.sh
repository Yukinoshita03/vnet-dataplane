#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scripts=(
  "${root_dir}/bench/openstack_dns_e2e.sh"
  "${root_dir}/bench/openstack_dynamic_cache_campaign.sh"
  "${root_dir}/bench/openstack_existing_pair_campaign.sh"
  "${root_dir}/bench/openstack_service_migration_probe.sh"
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
grep -q "setsid" "${scripts[0]}"
grep -q "setsid" "${scripts[1]}"
grep -q "setsid" "${scripts[2]}"
grep -q "setsid" "${scripts[3]}"
grep -q "kill -0 --" "${scripts[0]}"
grep -q "kill -0 --" "${scripts[1]}"
grep -q "kill -0 --" "${scripts[2]}"
grep -q "kill -0 --" "${scripts[3]}"

echo "openstack_campaign_lifecycle_test: PASS"
