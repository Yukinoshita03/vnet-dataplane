#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dns_monitor="${root_dir}/build/dns_monitor"
controller="${root_dir}/build/dynamic_cache_controller"
stats_reader="${root_dir}/build/dns_cache_stats_reader"
server_bpf="${root_dir}/build/dns_xdp_monitor.bpf.o"
client_bpf="${root_dir}/build/dns_client_cache.bpf.o"
netns="vnet-dns-runtime-$$"
host_if="vdrh$$"
guest_if="vdrg$$"
host_ip="10.231.0.1"
guest_ip="10.231.0.2"
domain="runtime.test"
answer_ip="10.99.0.7"
pin_root="/sys/fs/bpf/vnet-dns-runtime-test-$$"
temp_dir="$(mktemp -d /tmp/vnet-dns-runtime-test.XXXXXX)"
monitor_pid=""
stub_pid=""

if [[ "$(id -u)" -ne 0 ]]; then
  echo "dns_runtime_mode_integration_test: must run as root" >&2
  exit 1
fi

for command in ip python3; do
  command -v "${command}" >/dev/null
done
for file in "${dns_monitor}" "${controller}" "${stats_reader}" \
  "${server_bpf}" "${client_bpf}"; do
  test -e "${file}"
done

cleanup_monitor() {
  if [[ -n "${monitor_pid}" ]]; then
    kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
    wait "${monitor_pid}" >/dev/null 2>&1 || true
    monitor_pid=""
  fi
}

cleanup() {
  cleanup_monitor
  if [[ -n "${stub_pid}" ]]; then
    kill -TERM "${stub_pid}" >/dev/null 2>&1 || true
    wait "${stub_pid}" >/dev/null 2>&1 || true
  fi
  ip link set dev "${host_if}" xdpgeneric off >/dev/null 2>&1 || true
  ip netns del "${netns}" >/dev/null 2>&1 || true
  ip link del "${host_if}" >/dev/null 2>&1 || true
  case "${pin_root}" in
    /sys/fs/bpf/vnet-dns-runtime-test-*)
      rm -rf -- "${pin_root}"
      ;;
    *)
      echo "dns_runtime_mode_integration_test: unsafe bpffs cleanup" >&2
      return 1
      ;;
  esac
  case "${temp_dir}" in
    /tmp/vnet-dns-runtime-test.*)
      rm -rf -- "${temp_dir}"
      ;;
    *)
      echo "dns_runtime_mode_integration_test: unsafe temp cleanup" >&2
      return 1
      ;;
  esac
}
trap cleanup EXIT

cat >"${temp_dir}/dns_stub.py" <<'PY'
import socket
import sys

listen_ip, count_path, answer_text = sys.argv[1:4]
answer = socket.inet_aton(answer_text)
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind((listen_ip, 53))
count = 0
while True:
    packet, peer = sock.recvfrom(512)
    count += 1
    with open(count_path, "w", encoding="ascii") as output:
        output.write(str(count))
    response = (
        packet[:2]
        + bytes.fromhex("81800001000100000000")
        + packet[12:]
        + bytes.fromhex("c00c000100010000003c0004")
        + answer
    )
    sock.sendto(response, peer)
PY

cat >"${temp_dir}/dns_query.py" <<'PY'
import random
import socket
import sys

server, domain, expected = sys.argv[1:4]
labels = domain.rstrip(".").split(".")
qname = b"".join(bytes([len(label)]) + label.encode("ascii") for label in labels)
qname += b"\x00"
query_id = random.randrange(0, 65536).to_bytes(2, "big")
query = query_id + bytes.fromhex("01000001000000000000") + qname + bytes.fromhex("00010001")
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2.0)
sock.sendto(query, (server, 53))
response, _ = sock.recvfrom(512)
if response[:2] != query_id or socket.inet_aton(expected) not in response:
    raise SystemExit("invalid DNS response")
PY

count_file="${temp_dir}/backend-count"
printf '0\n' >"${count_file}"
ip netns add "${netns}"
ip link add "${host_if}" type veth peer name "${guest_if}"
ip link set "${guest_if}" netns "${netns}"
ip addr add "${host_ip}/24" dev "${host_if}"
ip link set "${host_if}" up
ip netns exec "${netns}" ip link set lo up
ip netns exec "${netns}" ip addr add "${guest_ip}/24" dev "${guest_if}"
ip netns exec "${netns}" ip link set "${guest_if}" up

python3 "${temp_dir}/dns_stub.py" "${host_ip}" "${count_file}" \
  "${answer_ip}" >"${temp_dir}/stub.log" 2>&1 &
stub_pid=$!
sleep 0.2

query_once() {
  ip netns exec "${netns}" python3 "${temp_dir}/dns_query.py" \
    "${host_ip}" "${domain}" "${answer_ip}"
}

publish_mode() {
  local map_path="$1"
  local mode="$2"
  "${controller}" --control-map "${map_path}" \
    --initial-mode "${mode}" </dev/null >/dev/null
}

expect_count() {
  local expected="$1"
  local actual
  actual="$(tr -d '[:space:]' <"${count_file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "dns_runtime_mode_integration_test: backend count ${actual}, expected ${expected}" >&2
    exit 1
  fi
}

stat_field() {
  tr ' ' '\n' <<<"$1" | awk -F= -v wanted="$2" \
    '$1 == wanted {print $2; exit}'
}

mkdir -p "${pin_root}/server"
"${dns_monitor}" --dev "${host_if}" --hook xdp --role server \
  --xdp-mode generic --bpf-object "${server_bpf}" \
  --cache-domain "${domain}" --cache-ip "${answer_ip}" --cache-ttl 60 \
  --pin-dir "${pin_root}/server" >"${temp_dir}/server-monitor.log" 2>&1 &
monitor_pid=$!
for _ in {1..50}; do
  [[ -e "${pin_root}/server/cache_runtime_control" ]] && break
  sleep 0.1
done
test -e "${pin_root}/server/cache_runtime_control"

publish_mode "${pin_root}/server/cache_runtime_control" bypass
query_once
expect_count 1
publish_mode "${pin_root}/server/cache_runtime_control" server
query_once
expect_count 1
publish_mode "${pin_root}/server/cache_runtime_control" client
query_once
expect_count 2
publish_mode "${pin_root}/server/cache_runtime_control" dual
query_once
expect_count 2
server_stats="$("${stats_reader}" "${pin_root}/server/dns_cache_stats")"
if [[ "$(stat_field "${server_stats}" shadow_hit)" -lt 2 ]]; then
  echo "dns_runtime_mode_integration_test: missing server shadow hits" >&2
  exit 1
fi
cleanup_monitor

mkdir -p "${pin_root}/client"
"${dns_monitor}" --dev "${host_if}" --hook xdp --role client \
  --xdp-mode generic --bpf-object "${client_bpf}" \
  --trusted-dns "${host_ip}" --pin-dir "${pin_root}/client" \
  >"${temp_dir}/client-monitor.log" 2>&1 &
monitor_pid=$!
for _ in {1..50}; do
  [[ -e "${pin_root}/client/cache_runtime_control" ]] && break
  sleep 0.1
done
test -e "${pin_root}/client/cache_runtime_control"

publish_mode "${pin_root}/client/cache_runtime_control" bypass
query_once
expect_count 3
publish_mode "${pin_root}/client/cache_runtime_control" client
query_once
expect_count 3
publish_mode "${pin_root}/client/cache_runtime_control" server
query_once
expect_count 4
publish_mode "${pin_root}/client/cache_runtime_control" dual
query_once
expect_count 4
client_stats="$("${stats_reader}" "${pin_root}/client/dns_cache_stats")"
if [[ "$(stat_field "${client_stats}" shadow_hit)" -lt 1 ||
      "$(stat_field "${client_stats}" shadow_miss)" -lt 1 ]]; then
  echo "dns_runtime_mode_integration_test: missing client shadow metrics" >&2
  exit 1
fi

echo "dns_runtime_mode_integration_test: PASS"
