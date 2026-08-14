#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build}"
monitor_bin="${DNS_MONITOR_BIN:-${build_dir}/dns_monitor}"
server_object="${DNS_SERVER_OBJECT:-${build_dir}/dns_xdp_monitor.bpf.o}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ARP proxy veth tests require Linux" >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo "ARP proxy veth tests require root; run with sudo" >&2
  exit 1
fi

for command in ip cc; do
  need_cmd "${command}"
done
test -x "${monitor_bin}"
test -r "${server_object}"

test_id="$$"
namespace_a="arp-pa-${test_id}"
namespace_b="arp-pb-${test_id}"
host_a="apa${test_id}"
peer_a="apna${test_id}"
host_b="apb${test_id}"
peer_b="apnb${test_id}"
tmp_dir="$(mktemp -d)"
policy_file="${tmp_dir}/arp-policy.conf"
monitor_log="${tmp_dir}/dns-monitor.log"
probe_bin="${tmp_dir}/arp-probe"
monitor_pid=""

cc -std=c11 -O2 -Wall -Wextra -Werror \
  "${repo_dir}/tests/arp_proxy_veth_probe.c" -o "${probe_bin}"

cleanup() {
  set +e
  if [ -n "${monitor_pid}" ] && kill -0 "${monitor_pid}" 2>/dev/null; then
    kill -TERM "${monitor_pid}" 2>/dev/null
    wait "${monitor_pid}" 2>/dev/null
  fi
  ip link set dev "${host_a}" xdp off 2>/dev/null
  ip link set dev "${host_b}" xdp off 2>/dev/null
  ip netns del "${namespace_a}" 2>/dev/null
  ip netns del "${namespace_b}" 2>/dev/null
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

ip netns add "${namespace_a}"
ip netns add "${namespace_b}"
ip link add "${host_a}" type veth peer name "${peer_a}"
ip link add "${host_b}" type veth peer name "${peer_b}"
ip link set "${peer_a}" netns "${namespace_a}"
ip link set "${peer_b}" netns "${namespace_b}"
ip link set dev "${host_a}" up
ip link set dev "${host_b}" up
ip netns exec "${namespace_a}" ip link set dev lo up
ip netns exec "${namespace_a}" ip link set dev "${peer_a}" address fa:16:3e:11:22:33 up
ip netns exec "${namespace_a}" ip addr add 10.0.0.5/24 dev "${peer_a}"
ip netns exec "${namespace_b}" ip link set dev lo up
ip netns exec "${namespace_b}" ip link set dev "${peer_b}" address fa:16:3e:44:55:66 up
ip netns exec "${namespace_b}" ip addr add 10.0.0.6/24 dev "${peer_b}"

printf '%s\n' \
  "${host_a} 10.0.0.1 fa:16:3e:aa:bb:cc 30" \
  "${host_a} 10.0.0.2 fa:16:3e:dd:ee:ff 30" \
  "${host_b} 10.0.0.1 fa:16:3e:11:aa:bb 30" >"${policy_file}"

"${monitor_bin}" \
  --hook xdp \
  --role server \
  --xdp-mode generic \
  --bpf-object "${server_object}" \
  --arp-policy-file "${policy_file}" \
  --arp-lease-seconds 2 >"${monitor_log}" 2>&1 &
monitor_pid=$!
sleep 1

ip netns exec "${namespace_a}" "${probe_bin}" "${peer_a}" 10.0.0.5 \
  10.0.0.1 fa:16:3e:aa:bb:cc
ip netns exec "${namespace_b}" "${probe_bin}" "${peer_b}" 10.0.0.6 \
  10.0.0.1 fa:16:3e:11:aa:bb

if ip netns exec "${namespace_a}" "${probe_bin}" "${peer_a}" 10.0.0.5 \
  10.0.0.99 >/dev/null 2>&1; then
  echo "unconfigured ARP target unexpectedly received a reply" >&2
  exit 1
fi

kill -KILL "${monitor_pid}" 2>/dev/null || true
wait "${monitor_pid}" 2>/dev/null || true
monitor_pid=""
sleep 3
if ip netns exec "${namespace_a}" "${probe_bin}" "${peer_a}" 10.0.0.5 \
  10.0.0.1 >/dev/null 2>&1; then
  echo "ARP policy still replied after process death and lease expiry" >&2
  exit 1
fi

echo "ARP proxy multi-veth test passed"
