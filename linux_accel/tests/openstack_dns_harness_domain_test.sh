#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root_dir}/build/openstack_dns_harness"
dns_policy="${root_dir}/deploy/lab/shuka1-p1/dns-cache.policy"
port="${DNS_HARNESS_TEST_PORT:-15353}"
work_dir="$(mktemp -d)"
server_pid=""

cleanup() {
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill "${server_pid}" 2>/dev/null || true
    wait "${server_pid}" 2>/dev/null || true
  fi
  rm -rf "${work_dir}"
}
trap cleanup EXIT

if ! awk '$1 == "hot.dynamic.test" && $2 == "10.0.0.55" && $3 ~ /^[1-9][0-9]*$/ { found = 1 } END { exit !found }' \
    "${dns_policy}"; then
  echo "Shuka1 DNS cache policy does not cover the hot workload key" >&2
  exit 1
fi

if [[ ! -x "${harness}" ]]; then
  echo "missing harness: ${harness}" >&2
  exit 2
fi

"${harness}" server 127.0.0.1 "${port}" dynamic.test 10.0.0.55 60 \
  "${work_dir}/count" >"${work_dir}/server.log" 2>&1 &
server_pid=$!
sleep 0.2

"${harness}" client 127.0.0.1 "${port}" dynamic.test 10.0.0.55 4 0 \
  >"${work_dir}/matching.log"

for workload in hot stable shifting low-hit-rate; do
  "${harness}" client-workload 127.0.0.1 "${port}" dynamic.test 10.0.0.55 \
    2 0 "${workload}" 2 >"${work_dir}/${workload}.log"
done

if "${harness}" client 127.0.0.1 "${port}" example.test 10.0.0.55 1 0 \
    >"${work_dir}/mismatched.log" 2>&1; then
  echo "mismatched DNS domain unexpectedly succeeded" >&2
  exit 1
fi

if [[ "$(tail -n 1 "${work_dir}/count" | tr -d '[:space:]')" != "12" ]]; then
  echo "server accepted an unexpected DNS domain" >&2
  exit 1
fi

echo "openstack_dns_harness domain validation: ok"
