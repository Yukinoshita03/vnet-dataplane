#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build/tests/xdp-action-probe}"
loader="${build_dir}/xdp_action_probe_loader"
sender="${build_dir}/xdp_action_probe_sender"
bpf_object="${build_dir}/xdp_action_probe.bpf.o"
rx_if="xap$$_rx"
tx_if="xap$$_tx"
loader_pid=""
link_created=0

cleanup() {
  if [[ -n "${loader_pid}" ]] && kill -0 "${loader_pid}" 2>/dev/null; then
    kill "${loader_pid}" 2>/dev/null || true
    wait "${loader_pid}" 2>/dev/null || true
  fi
  if (( link_created )); then
    ip link set dev "${rx_if}" xdp off 2>/dev/null || true
    ip link delete dev "${rx_if}" 2>/dev/null || true
  fi
}

wait_for_attach() {
  local log_file=$1
  local attempt

  for ((attempt = 0; attempt < 100; attempt++)); do
    if grep -q '^xdp_program_id=' "${log_file}"; then
      return 0
    fi
    if ! kill -0 "${loader_pid}" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  echo "loader did not attach native XDP" >&2
  sed -n '1,120p' "${log_file}" >&2
  return 1
}

trap cleanup EXIT INT TERM

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "local veth integration test requires Linux" >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo "local veth integration test must run as root" >&2
  exit 1
fi
command -v ip >/dev/null 2>&1 || {
  echo "missing command: ip" >&2
  exit 1
}

BUILD_ONLY=1 BUILD_DIR="${build_dir}" \
  "${repo_dir}/tests/run_xdp_action_probe_test.sh" >/dev/null 2>&1

ip link add "${rx_if}" type veth peer name "${tx_if}"
link_created=1
ip link set dev "${rx_if}" mtu 1500 up
ip link set dev "${tx_if}" mtu 1500 up
target_mac="$(<"/sys/class/net/${rx_if}/address")"

normal_log="${build_dir}/veth-normal-loader.log"
"${loader}" --dev "${rx_if}" --object "${bpf_object}" \
  --action pass --duration 1 >"${normal_log}" 2>&1 &
loader_pid=$!
wait_for_attach "${normal_log}"
"${sender}" --dev "${tx_if}" --dst-mac "${target_mac}" \
  --count 1 --sequence 77
wait "${loader_pid}"
loader_pid=""
if ip -details link show dev "${rx_if}" | grep -q 'prog/xdp'; then
  echo "native XDP program remained after normal owned detach" >&2
  exit 1
fi
echo "ok - native veth attach, AF_PACKET send, and owned detach"

replacement_log="${build_dir}/veth-replacement-loader.log"
"${loader}" --dev "${rx_if}" --object "${bpf_object}" \
  --action drop --duration 1 >"${replacement_log}" 2>&1 &
loader_pid=$!
wait_for_attach "${replacement_log}"
old_id="$(sed -n 's/^xdp_program_id=//p' "${replacement_log}")"

# Simulate a different owner replacing the probe. The non-atomic gap is local
# to this throwaway veth; it is intentionally not a physical-test procedure.
ip link set dev "${rx_if}" xdp off
ip link set dev "${rx_if}" xdp object "${bpf_object}" section xdp
replacement_id="$(
  ip -details link show dev "${rx_if}" |
    sed -n 's/.*prog\/xdp id \([0-9][0-9]*\).*/\1/p'
)"
if [[ -z "${replacement_id}" || "${replacement_id}" == "${old_id}" ]]; then
  echo "failed to install a distinct replacement XDP program" >&2
  exit 1
fi

set +e
wait "${loader_pid}"
loader_status=$?
set -e
loader_pid=""
after_id="$(
  ip -details link show dev "${rx_if}" |
    sed -n 's/.*prog\/xdp id \([0-9][0-9]*\).*/\1/p'
)"
if (( loader_status == 0 )) || [[ "${after_id}" != "${replacement_id}" ]]; then
  echo "owned detach did not preserve the replacement program" >&2
  sed -n '1,120p' "${replacement_log}" >&2
  exit 1
fi
ip link set dev "${rx_if}" xdp off
echo "ok - expected old FD preserves a replacement program"
echo "2/2 local veth integration tests passed"
