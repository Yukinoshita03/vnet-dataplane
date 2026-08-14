#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${BUILD_DIR:-${repo_dir}/build}"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/arp-proxy-bench/$(date +%Y%m%d-%H%M%S)}"
monitor_bin="${DNS_MONITOR_BIN:-${build_dir}/dns_monitor}"
bpf_object="${DNS_SERVER_OBJECT:-${build_dir}/dns_xdp_monitor.bpf.o}"
probe_bin="${ARP_BENCH_BIN:-${build_dir}/arp_request_bench}"
repetitions="${REPETITIONS:-6}"
requests="${REQUESTS:-100000}"
warmup="${WARMUP:-1000}"
client_cpu="${CLIENT_CPU:-0}"

if [[ "$(uname -s)" != Linux ]]; then
  echo "ARP proxy benchmark requires Linux" >&2
  exit 1
fi
if (( EUID != 0 )); then
  echo "Run ARP proxy benchmark as root" >&2
  exit 1
fi
if ! [[ "${repetitions}" =~ ^[1-9][0-9]*$ &&
        "${requests}" =~ ^[1-9][0-9]*$ &&
        "${warmup}" =~ ^[0-9]+$ ]]; then
  echo "REPETITIONS/REQUESTS must be positive integers and WARMUP non-negative" >&2
  exit 2
fi

for command in ip taskset cc awk sort sha256sum tcpdump; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done
test -x "${monitor_bin}"
test -r "${bpf_object}"

mkdir -p "${build_dir}" "${out_dir}/nohook" "${out_dir}/xdp" \
  "${out_dir}/health"
if [[ ! -x "${probe_bin}" ]]; then
  cc -std=c11 -O2 -g -Wall -Wextra -Werror \
    "${repo_dir}/bench/arp_request_bench.c" -o "${probe_bin}"
fi

tag=$(( $$ % 100000 ))
client_ns="apc${tag}"
server_ns="aps${tag}"
client_host="apch${tag}"
client_peer="apcp${tag}"
server_host="apsh${tag}"
server_peer="apsp${tag}"
bridge="apb${tag}"
client_ip="198.19.0.2"
server_ip="198.19.0.3"
server_mac="02:00:00:00:19:03"
monitor_pid=""
capture_pid=""
policy_file="${out_dir}/arp-policy.conf"

kubernetes_snapshot()
{
  for unit in kubelet containerd kubernetes-haproxy; do
    printf '%s=%s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
  done
}

require_kubernetes_stopped()
{
  local snapshot="$1"
  if grep -q '=active$' "${snapshot}"; then
    echo "Kubernetes must remain stopped during this benchmark" >&2
    exit 1
  fi
}

cleanup()
{
  local status=$?
  trap - EXIT INT TERM
  set +e
  if [[ -n "${monitor_pid}" ]]; then
    kill -TERM "${monitor_pid}" >/dev/null 2>&1
    wait "${monitor_pid}" >/dev/null 2>&1
  fi
  if [[ -n "${capture_pid}" ]]; then
    kill -INT "${capture_pid}" >/dev/null 2>&1
    wait "${capture_pid}" >/dev/null 2>&1
  fi
  ip netns del "${client_ns}" >/dev/null 2>&1
  ip netns del "${server_ns}" >/dev/null 2>&1
  ip link del dev "${bridge}" >/dev/null 2>&1
  exit "${status}"
}
trap cleanup EXIT INT TERM

kubernetes_snapshot >"${out_dir}/health/kubernetes-before.txt"
require_kubernetes_stopped "${out_dir}/health/kubernetes-before.txt"
bpftool net >"${out_dir}/health/bpf-before.txt" 2>&1 || true
cat /proc/net/softnet_stat >"${out_dir}/health/softnet-before.txt"
uname -a >"${out_dir}/health/uname.txt"
sha256sum "${monitor_bin}" "${bpf_object}" "${probe_bin}" \
  >"${out_dir}/health/SHA256SUMS"

ip netns add "${client_ns}"
ip netns add "${server_ns}"
ip link add "${client_host}" type veth peer name "${client_peer}"
ip link add "${server_host}" type veth peer name "${server_peer}"
ip link set "${client_peer}" netns "${client_ns}"
ip link set "${server_peer}" netns "${server_ns}"
ip link add "${bridge}" type bridge
ip link set "${bridge}" up
ip link set "${client_host}" master "${bridge}"
ip link set "${server_host}" master "${bridge}"
ip link set "${client_host}" up
ip link set "${server_host}" up
ip netns exec "${client_ns}" ip link set lo up
ip netns exec "${server_ns}" ip link set lo up
ip netns exec "${client_ns}" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
ip netns exec "${server_ns}" sysctl -qw net.ipv6.conf.all.disable_ipv6=1
ip netns exec "${client_ns}" ip link set "${client_peer}" \
  address 02:00:00:00:19:02
ip netns exec "${server_ns}" ip link set "${server_peer}" \
  address "${server_mac}"
ip netns exec "${client_ns}" ip addr add "${client_ip}/24" dev "${client_peer}"
ip netns exec "${server_ns}" ip addr add "${server_ip}/24" dev "${server_peer}"
ip netns exec "${client_ns}" ip link set "${client_peer}" up
ip netns exec "${server_ns}" ip link set "${server_peer}" up

printf '%s %s %s %s\n' "${client_host}" "${server_ip}" "${server_mac}" 3600 \
  >"${policy_file}"

server_rx_packets()
{
  ip netns exec "${server_ns}" \
    cat "/sys/class/net/${server_peer}/statistics/rx_packets"
}

metric()
{
  local file="$1"
  local name="$2"
  awk -v name="${name}" \
    '{for (i=1; i<=NF; i++) {split($i, a, "="); if (a[1] == name) {print a[2]; exit}}}' \
    "${file}"
}

run_probe()
{
  local count="$1"
  local output="$2"
  ip netns exec "${client_ns}" taskset -c "${client_cpu}" \
    "${probe_bin}" "${client_peer}" "${client_ip}" "${server_ip}" \
    "${count}" "${server_mac}" >"${output}"
  grep -q 'timeout=0' "${output}"
}

start_xdp()
{
  local log="$1"
  "${monitor_bin}" --hook xdp --role server --xdp-mode generic \
    --bpf-object "${bpf_object}" --arp-policy-file "${policy_file}" \
    --arp-lease-seconds 3600 >"${log}" 2>&1 &
  monitor_pid=$!
  for _ in $(seq 1 50); do
    if ip -details link show dev "${client_host}" | grep -q 'prog/xdp'; then
      return 0
    fi
    sleep 0.1
  done
  echo "ARP XDP program did not attach" >&2
  return 1
}

stop_xdp()
{
  local log="$1"
  local expected="$2"
  local observed_request observed_tx
  kill -TERM "${monitor_pid}"
  wait "${monitor_pid}"
  monitor_pid=""
  if ip -details link show dev "${client_host}" | grep -q 'prog/xdp'; then
    echo "ARP XDP program remained attached after loader exit" >&2
    exit 1
  fi
  observed_request="$(awk '/arp_proxy request=/ {for (i=1; i<=NF; i++) {split($i,a,"="); if (a[1] == "request") value=a[2]}} END {print value+0}' "${log}")"
  observed_tx="$(awk '/arp_proxy request=/ {for (i=1; i<=NF; i++) {split($i,a,"="); if (a[1] == "tx") value=a[2]}} END {print value+0}' "${log}")"
  if (( observed_request != expected || observed_tx != expected )); then
    echo "ARP XDP counters do not match sent requests: request=${observed_request} tx=${observed_tx} expected=${expected}" >&2
    exit 1
  fi
}

run_case()
{
  local mode="$1"
  local repetition="$2"
  local output="${out_dir}/${mode}/rep-${repetition}.log"
  local warmup_output="${out_dir}/${mode}/rep-${repetition}-warmup.log"
  local loader_log="${out_dir}/${mode}/rep-${repetition}-loader.log"
  local capture_file="${out_dir}/${mode}/rep-${repetition}-server-arp.pcap"
  local capture_log="${out_dir}/${mode}/rep-${repetition}-server-arp-capture.log"
  local before after

  if [[ "${mode}" == xdp ]]; then
    start_xdp "${loader_log}"
    ip netns exec "${server_ns}" tcpdump -Q in -U -nn -i "${server_peer}" \
      -c 1 -w "${capture_file}" 'arp and arp[6:2] = 1' \
      >"${capture_log}" 2>&1 &
    capture_pid=$!
    sleep 0.1
  fi
  if (( warmup > 0 )); then
    run_probe "${warmup}" "${warmup_output}"
  fi
  before="$(server_rx_packets)"
  run_probe "${requests}" "${output}"
  after="$(server_rx_packets)"
  printf 'server_rx_delta=%s\n' "$((after - before))" >>"${output}"
  if [[ "${mode}" == xdp ]]; then
    if kill -0 "${capture_pid}" 2>/dev/null; then
      kill -INT "${capture_pid}" >/dev/null 2>&1 || true
    fi
    wait "${capture_pid}" >/dev/null 2>&1 || true
    capture_pid=""
    if tcpdump -nn -r "${capture_file}" 2>/dev/null | grep -q .; then
      echo "XDP ARP request reached the server namespace" >&2
      exit 1
    fi
    stop_xdp "${loader_log}" "$((requests + warmup))"
  elif (( after - before < requests )); then
    echo "Kernel ARP baseline did not reach the server namespace" >&2
    exit 1
  fi
}

# Alternate order in pairs so attach/cool-cache order does not always favor one mode.
for repetition in $(seq 1 "${repetitions}"); do
  if (( repetition % 2 == 1 )); then
    modes=(nohook xdp)
  else
    modes=(xdp nohook)
  fi
  for mode in "${modes[@]}"; do
    echo "ARP ${mode} repetition ${repetition}/${repetitions}"
    run_case "${mode}" "${repetition}"
  done
done

median_metric()
{
  local mode="$1"
  local name="$2"
  local rank=$(( (repetitions + 1) / 2 ))
  for repetition in $(seq 1 "${repetitions}"); do
    metric "${out_dir}/${mode}/rep-${repetition}.log" "${name}"
  done | sort -g | sed -n "${rank}p"
}

nohook_qps="$(median_metric nohook reply_qps)"
xdp_qps="$(median_metric xdp reply_qps)"
nohook_p50="$(median_metric nohook p50_us)"
xdp_p50="$(median_metric xdp p50_us)"
nohook_p95="$(median_metric nohook p95_us)"
xdp_p95="$(median_metric xdp p95_us)"
nohook_p99="$(median_metric nohook p99_us)"
xdp_p99="$(median_metric xdp p99_us)"
qps_speedup="$(awk -v x="${xdp_qps}" -v b="${nohook_qps}" \
  'BEGIN {printf "%.3f", x / b}')"
p50_speedup="$(awk -v x="${xdp_p50}" -v b="${nohook_p50}" \
  'BEGIN {printf "%.3f", b / x}')"
p95_speedup="$(awk -v x="${xdp_p95}" -v b="${nohook_p95}" \
  'BEGIN {printf "%.3f", b / x}')"
p99_speedup="$(awk -v x="${xdp_p99}" -v b="${nohook_p99}" \
  'BEGIN {printf "%.3f", b / x}')"

cat /proc/net/softnet_stat >"${out_dir}/health/softnet-after.txt"
kubernetes_snapshot >"${out_dir}/health/kubernetes-after.txt"
require_kubernetes_stopped "${out_dir}/health/kubernetes-after.txt"
bpftool net >"${out_dir}/health/bpf-after.txt" 2>&1 || true

{
  printf '# ARP proxy benchmark\n\n'
  printf 'Topology: netns + veth + bridge; generic XDP on the client-side host veth.\n\n'
  printf 'Repetitions: %s; requests/repetition: %s; warmup: %s.\n\n' \
    "${repetitions}" "${requests}" "${warmup}"
  printf '| mode | median reply QPS | p50 us | p95 us | p99 us | server RX/request |\n'
  printf '|---|---:|---:|---:|---:|---:|\n'
  printf '| Linux kernel ARP responder | %s | %s | %s | %s | 1.000 |\n' \
    "${nohook_qps}" "${nohook_p50}" "${nohook_p95}" "${nohook_p99}"
  printf '| linux_accel generic XDP ARP proxy | %s | %s | %s | %s | 0.000 |\n\n' \
    "${xdp_qps}" "${xdp_p50}" "${xdp_p95}" "${xdp_p99}"
  printf 'QPS speedup: %sx\n\n' "${qps_speedup}"
  printf 'Latency improvement (baseline/XDP): p50 %sx; p95 %sx; p99 %sx.\n' \
    "${p50_speedup}" "${p95_speedup}" "${p99_speedup}"
} >"${out_dir}/summary.md"

cat "${out_dir}/summary.md"
echo "artifacts=${out_dir}"
trap - EXIT INT TERM
cleanup
