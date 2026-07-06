#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/openstack-tc-attach-smoke/$(date +%Y%m%d-%H%M%S)}"
sudo_pass="${SUDO_PASS:-}"
duration="${DURATION:-5}"
grpc_port="${GRPC_PORT:-50051}"
iface_list="${IFACES:-br-int br-ex ens33}"

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

need_file() {
  if [[ ! -e "$1" ]]; then
    echo "missing required file: $1" >&2
    exit 1
  fi
}

choose_iface() {
  local iface
  for iface in ${iface_list}; do
    if ip link show "${iface}" >/dev/null 2>&1; then
      echo "${iface}"
      return 0
    fi
  done
  return 1
}

run_monitor() {
  local name="$1"
  shift
  local log="${out_dir}/${name}.log"
  local rc=0
  if [[ -n "${sudo_pass}" ]]; then
    (cd "${repo_dir}" && printf '%s\n' "${sudo_pass}" | sudo -S timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 || rc=$?
  else
    (cd "${repo_dir}" && sudo timeout --signal=INT --kill-after=2s "${duration}s" "$@") > "${log}" 2>&1 || rc=$?
  fi
  echo "${rc}" > "${out_dir}/${name}.rc"
}

extract_status() {
  local log="$1"
  if grep -q "Listening .* with tc" "${log}"; then
    echo "attached"
  elif grep -qi "Operation not supported" "${log}"; then
    echo "unsupported"
  elif grep -qi "failed" "${log}"; then
    echo "failed"
  else
    echo "unknown"
  fi
}

mkdir -p "${out_dir}"

need_file "${repo_dir}/build/dns_monitor"
need_file "${repo_dir}/build/dns_monitor.bpf.o"
need_file "${repo_dir}/build/grpc_monitor"
need_file "${repo_dir}/build/grpc_monitor.bpf.o"
command -v timeout >/dev/null

iface="$(choose_iface || true)"
if [[ -z "${iface}" ]]; then
  echo "No candidate interface found in IFACES='${iface_list}'" >&2
  exit 1
fi

ip -br link show "${iface}" > "${out_dir}/iface.log" 2>&1 || true
run_sudo tc qdisc show dev "${iface}" > "${out_dir}/tc-before.log" 2>&1 || true

run_monitor dns_tc "${repo_dir}/build/dns_monitor" --dev "${iface}" --hook tc --timeout-ms 1000
run_sudo tc qdisc show dev "${iface}" > "${out_dir}/tc-after-dns.log" 2>&1 || true

run_monitor grpc_tc "${repo_dir}/build/grpc_monitor" --dev "${iface}" --port "${grpc_port}" --timeout-ms 1000
run_sudo tc qdisc show dev "${iface}" > "${out_dir}/tc-after-grpc.log" 2>&1 || true

dns_status="$(extract_status "${out_dir}/dns_tc.log")"
grpc_status="$(extract_status "${out_dir}/grpc_tc.log")"

cat > "${out_dir}/summary.md" <<MD
# OpenStack tc Attach Smoke

This smoke test attaches existing tc monitors to a real host/OpenStack candidate interface for a short duration and then lets the monitor detach on SIGINT.

| field | value |
| --- | --- |
| interface | ${iface} |
| duration_sec | ${duration} |
| dns_tc | ${dns_status} |
| grpc_tc | ${grpc_status} |
| grpc_port | ${grpc_port} |

## Interface

\`\`\`text
$(cat "${out_dir}/iface.log")
\`\`\`

## Logs

- \`dns_tc.log\`
- \`grpc_tc.log\`
- \`tc-before.log\`
- \`tc-after-dns.log\`
- \`tc-after-grpc.log\`

This script does not create or delete OpenStack resources. It only attaches and detaches the project tc monitor programs on an existing Linux interface.
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
