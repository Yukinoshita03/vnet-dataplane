#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/dns-dual-end-cache-bench/$(date +%Y%m%d-%H%M%S)}"
cli_ns="${CLI_NETNS:-dnsdualcli}"
srv_ns="${SRV_NETNS:-dnsdualsrv}"
cli_host_if="${CLI_HOST_IF:-vdc_host}"
cli_ns_if="${CLI_NS_IF:-vdc_cli}"
srv_host_if="${SRV_HOST_IF:-vds_host}"
srv_ns_if="${SRV_NS_IF:-vds_srv}"
bridge="${BRIDGE:-br_dns_dual}"
cli_ip="${CLI_IP:-10.20.0.2}"
srv_ip="${SRV_IP:-10.20.0.53}"
alt_srv_ip="${ALT_SRV_IP:-10.20.0.54}"
untrusted_srv_ip="${UNTRUSTED_SRV_IP:-10.20.0.55}"
domain="${DOMAIN:-example.test}"
answer_ip="${ANSWER_IP:-10.0.0.123}"
alt_answer_ip="${ALT_ANSWER_IP:-10.0.0.124}"
untrusted_answer_ip="${UNTRUSTED_ANSWER_IP:-10.0.0.125}"
requests="${REQUESTS:-200}"
repeat="${REPEAT:-1}"
sudo_pass="${SUDO_PASS:-}"
monitor_seconds="${MONITOR_SECONDS:-30}"

backend_py=""
client_py=""
client_monitor_pid=""
server_monitor_pid=""
declare -a backend_pids=()

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

stop_pid() {
  local pid="$1"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill -TERM "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
  fi
}

stop_monitors() {
  stop_pid "${client_monitor_pid}"
  stop_pid "${server_monitor_pid}"
  client_monitor_pid=""
  server_monitor_pid=""
  run_sudo pkill -TERM -f "dns_monitor --dev ${cli_host_if}" >/dev/null 2>&1 || true
  run_sudo ip netns exec "${srv_ns}" pkill -TERM -f "dns_monitor --dev ${srv_ns_if}" >/dev/null 2>&1 || true
  sleep 0.2
}

stop_backends() {
  local pid
  if [[ -n "${backend_py}" ]]; then
    run_sudo ip netns exec "${srv_ns}" pkill -TERM -f "${backend_py}" >/dev/null 2>&1 || true
  fi
  for pid in "${backend_pids[@]:-}"; do
    stop_pid "${pid}"
  done
  backend_pids=()
}

cleanup_topology() {
  stop_monitors
  stop_backends
  run_sudo ip link set dev "${cli_host_if}" xdpgeneric off >/dev/null 2>&1 || true
  run_sudo ip netns exec "${srv_ns}" ip link set dev "${srv_ns_if}" xdpgeneric off >/dev/null 2>&1 || true
  run_sudo ip netns del "${cli_ns}" >/dev/null 2>&1 || true
  run_sudo ip netns del "${srv_ns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${bridge}" >/dev/null 2>&1 || true
  run_sudo ip link del "${cli_host_if}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_host_if}" >/dev/null 2>&1 || true
}

cleanup() {
  cleanup_topology
  if [[ -n "${backend_py}" ]]; then
    rm -f "${backend_py}" "${client_py}"
  fi
}

write_runtime_helpers() {
  backend_py="$(mktemp /tmp/dns_dual_backend.XXXXXX.py)"
  client_py="$(mktemp /tmp/dns_dual_client.XXXXXX.py)"
  cat > "${backend_py}" <<'PY'
import os
import signal
import socket
import struct
import sys

bind_ip = os.environ["BIND_IP"]
answer_ip = os.environ["ANSWER_IP"]
count_file = os.environ["COUNT_FILE"]
ttl = int(os.environ["DNS_TTL"])
response_mode = os.environ.get("DNS_RESPONSE_MODE", "a")
domain = os.environ["DNS_DOMAIN"].rstrip(".")

qname = b"".join(bytes([len(label)]) + label.encode() for label in domain.split("."))
qname += b"\x00\x00\x01\x00\x01"
answer = (b"\xc0\x0c\x00\x01\x00\x01" + ttl.to_bytes(4, "big") +
          b"\x00\x04" + socket.inet_aton(answer_ip))
count = 0
running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((bind_ip, 53))
s.settimeout(0.2)

while running:
    try:
        data, peer = s.recvfrom(512)
    except socket.timeout:
        continue
    count += 1
    with open(count_file, "w", encoding="ascii") as output:
        output.write(str(count))
    if len(data) >= 12 and data[12:] == qname and response_mode == "nxdomain":
        response = data[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + data[12:]
    elif len(data) >= 12 and data[12:] == qname:
        response = data[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + data[12:] + answer
    else:
        response = data[:2] + b"\x81\x83\x00\x01\x00\x00\x00\x00\x00\x00" + data[12:]
    s.sendto(response, peer)
PY
  cat > "${client_py}" <<'PY'
import socket
import sys
import time

server_ip, domain, expected_ip, count_text = sys.argv[1:]
count = int(count_text)
labels = domain.rstrip(".").split(".")
question = b"".join(bytes([len(label)]) + label.encode() for label in labels)
question += b"\x00\x00\x01\x00\x01"
expected = b"" if expected_ip == "NXDOMAIN" else socket.inet_aton(expected_ip)
samples = []
failed = 0
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.0)

for request_id in range(count):
    query = request_id.to_bytes(2, "big") + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + question
    started = time.perf_counter_ns()
    try:
        s.sendto(query, (server_ip, 53))
        response, _peer = s.recvfrom(512)
        elapsed = time.perf_counter_ns() - started
        if expected_ip == "NXDOMAIN":
            valid = len(response) >= 12 and (response[3] & 0x0f) == 3
        else:
            valid = len(response) >= len(query) + 16 and response[-4:] == expected
        if not valid:
            failed += 1
            continue
        samples.append(elapsed)
    except OSError:
        failed += 1

s.close()
samples.sort()
def percentile(fraction):
    if not samples:
        return 0.0
    index = min(len(samples) - 1, int(len(samples) * fraction))
    return samples[index] / 1000.0

total_ns = sum(samples)
elapsed_s = total_ns / 1_000_000_000 if total_ns else 0.0
qps = len(samples) / elapsed_s if elapsed_s else 0.0
avg_us = total_ns / len(samples) / 1000.0 if samples else 0.0
print(f"count={len(samples)} failed={failed} qps={qps:.2f} avg_us={avg_us:.2f} "
      f"p50_us={percentile(0.50):.2f} p95_us={percentile(0.95):.2f} p99_us={percentile(0.99):.2f}")
sys.exit(0 if failed == 0 else 1)
PY
}

setup_topology() {
  cleanup_topology
  run_sudo ip netns add "${cli_ns}"
  run_sudo ip netns add "${srv_ns}"
  run_sudo ip link add "${bridge}" type bridge
  run_sudo ip link set "${bridge}" up

  run_sudo ip link add "${cli_host_if}" type veth peer name "${cli_ns_if}"
  run_sudo ip link set "${cli_ns_if}" netns "${cli_ns}"
  run_sudo ip link set "${cli_host_if}" master "${bridge}"
  run_sudo ip link set "${cli_host_if}" up
  run_sudo ip netns exec "${cli_ns}" ip addr add "${cli_ip}/24" dev "${cli_ns_if}"
  run_sudo ip netns exec "${cli_ns}" ip link set lo up
  run_sudo ip netns exec "${cli_ns}" ip link set "${cli_ns_if}" up

  run_sudo ip link add "${srv_host_if}" type veth peer name "${srv_ns_if}"
  run_sudo ip link set "${srv_ns_if}" netns "${srv_ns}"
  run_sudo ip link set "${srv_host_if}" master "${bridge}"
  run_sudo ip link set "${srv_host_if}" up
  run_sudo ip netns exec "${srv_ns}" ip addr add "${srv_ip}/24" dev "${srv_ns_if}"
  run_sudo ip netns exec "${srv_ns}" ip addr add "${alt_srv_ip}/24" dev "${srv_ns_if}"
  run_sudo ip netns exec "${srv_ns}" ip addr add "${untrusted_srv_ip}/24" dev "${srv_ns_if}"
  run_sudo ip netns exec "${srv_ns}" ip link set lo up
  run_sudo ip netns exec "${srv_ns}" ip link set "${srv_ns_if}" up
}

start_backend() {
  local tag="$1"
  local bind_ip="$2"
  local response_ip="$3"
  local ttl="$4"
  local response_mode="${5:-a}"
  local count_file="${out_dir}/${run_id}-${tag}.backend-count"
  : > "${count_file}"
  run_sudo ip netns exec "${srv_ns}" env \
    BIND_IP="${bind_ip}" ANSWER_IP="${response_ip}" DNS_TTL="${ttl}" \
    COUNT_FILE="${count_file}" DNS_DOMAIN="${domain}" \
    DNS_RESPONSE_MODE="${response_mode}" \
    python3 "${backend_py}" > "${out_dir}/${run_id}-${tag}.backend.log" 2>&1 &
  backend_pids+=("$!")
  sleep 0.2
}

backend_count() {
  local tag="$1"
  local count_file="${out_dir}/${run_id}-${tag}.backend-count"
  if [[ -s "${count_file}" ]]; then
    tr -d '[:space:]' < "${count_file}"
  else
    printf '0'
  fi
}

start_client_monitor() {
  local tag="$1"
  shift
  run_sudo timeout "${monitor_seconds}s" "${repo_dir}/build/dns_monitor" \
    --dev "${cli_host_if}" --hook xdp --role client --xdp-mode generic \
    --bpf-object "${repo_dir}/build/dns_client_cache.bpf.o" \
    --max-learn-ttl 300 --learn-window-ms 2000 "$@" \
    > "${out_dir}/${run_id}-${tag}.client-monitor.log" 2>&1 &
  client_monitor_pid="$!"
  sleep 1
}

start_server_monitor() {
  local tag="$1"
  local response_ip="$2"
  local ttl="$3"
  run_sudo ip netns exec "${srv_ns}" timeout "${monitor_seconds}s" \
    "${repo_dir}/build/dns_monitor" --dev "${srv_ns_if}" --hook xdp \
    --role server --xdp-mode generic \
    --bpf-object "${repo_dir}/build/dns_xdp_monitor.bpf.o" \
    --cache-domain "${domain}" --cache-ip "${response_ip}" --cache-ttl "${ttl}" \
    > "${out_dir}/${run_id}-${tag}.server-monitor.log" 2>&1 &
  server_monitor_pid="$!"
  sleep 1
}

run_client() {
  local tag="$1"
  local server_ip="$2"
  local expected_ip="$3"
  local count="$4"
  run_sudo ip netns exec "${cli_ns}" python3 "${client_py}" \
    "${server_ip}" "${domain}" "${expected_ip}" "${count}" \
    > "${out_dir}/${run_id}-${tag}.client.log"
}

metric_line() {
  local path="$1"
  awk '
    /dns_metrics/ {
      found = 1
      for (field_index = 1; field_index <= NF; ++field_index) {
        split($field_index, pair, "=")
        if (pair[1] == "cache_hit" || pair[1] == "cache_miss" ||
            pair[1] == "cache_expired" || pair[1] == "cache_tx" ||
            pair[1] == "cache_learned" || pair[1] == "learn_rejected" ||
            pair[1] == "pending_expired" || pair[1] == "ringbuf_drop")
          total[pair[1]] += pair[2]
      }
    }
    END {
      if (!found)
        exit
      printf "cache_hit=%d cache_miss=%d cache_expired=%d cache_tx=%d ",
        total["cache_hit"], total["cache_miss"], total["cache_expired"],
        total["cache_tx"]
      printf "cache_learned=%d learn_rejected=%d pending_expired=%d ringbuf_drop=%d",
        total["cache_learned"], total["learn_rejected"],
        total["pending_expired"], total["ringbuf_drop"]
    }
  ' "${path}"
}

record_scenario() {
  local name="$1"
  local client_log="$2"
  local backend="$3"
  local monitor_log="${4:-}"
  {
    printf '### %s\n\n' "${name}"
    printf 'client: `%s`\n\n' "$(tr -d '\n' < "${client_log}")"
    printf 'backend_requests: `%s`\n\n' "${backend}"
    if [[ -n "${monitor_log}" ]]; then
      printf 'metrics: `%s`\n\n' "$(metric_line "${monitor_log}")"
    fi
  } >> "${out_dir}/summary.md"
}

run_suite() {
  local baseline_count
  local warm_count
  local final_count

  start_backend baseline "${srv_ip}" "${answer_ip}" 60
  run_client baseline "${srv_ip}" "${answer_ip}" "${requests}"
  baseline_count="$(backend_count baseline)"
  record_scenario "baseline" "${out_dir}/${run_id}-baseline.client.log" "${baseline_count}"
  stop_backends

  start_server_monitor server-only "${answer_ip}" 60
  run_client server-only "${srv_ip}" "${answer_ip}" "${requests}"
  sleep 1
  stop_monitors
  record_scenario "server-only" "${out_dir}/${run_id}-server-only.client.log" 0 \
    "${out_dir}/${run_id}-server-only.server-monitor.log"

  start_backend client-only "${srv_ip}" "${answer_ip}" 60
  start_client_monitor client-only --trusted-dns "${srv_ip}"
  run_client client-warm "${srv_ip}" "${answer_ip}" 1
  sleep 0.2
  warm_count="$(backend_count client-only)"
  run_client client-only "${srv_ip}" "${answer_ip}" "${requests}"
  sleep 1
  final_count="$(backend_count client-only)"
  stop_monitors
  record_scenario "client-only" "${out_dir}/${run_id}-client-only.client.log" "${final_count}" \
    "${out_dir}/${run_id}-client-only.client-monitor.log"
  if [[ "${warm_count}" != 1 || "${final_count}" != "${warm_count}" ]]; then
    echo "client-only backend counter did not remain at one" >&2
    exit 1
  fi
  stop_backends

  start_server_monitor both "${answer_ip}" 60
  start_client_monitor both --trusted-dns "${srv_ip}"
  run_client both-warm "${srv_ip}" "${answer_ip}" 1
  run_client both "${srv_ip}" "${answer_ip}" "${requests}"
  sleep 1
  stop_monitors
  record_scenario "both" "${out_dir}/${run_id}-both.client.log" 0 \
    "${out_dir}/${run_id}-both.client-monitor.log"

  start_backend ttl "${srv_ip}" "${answer_ip}" 1
  start_client_monitor ttl --trusted-dns "${srv_ip}"
  run_client ttl-warm "${srv_ip}" "${answer_ip}" 1
  run_client ttl-hit "${srv_ip}" "${answer_ip}" 1
  sleep 2
  run_client ttl-expired "${srv_ip}" "${answer_ip}" 1
  sleep 1
  final_count="$(backend_count ttl)"
  stop_monitors
  record_scenario "ttl-expiry" "${out_dir}/${run_id}-ttl-expired.client.log" "${final_count}" \
    "${out_dir}/${run_id}-ttl.client-monitor.log"
  if [[ "${final_count}" != 2 ]]; then
    echo "TTL expiry did not trigger a backend request" >&2
    exit 1
  fi
  stop_backends

  start_backend isolate-primary "${srv_ip}" "${answer_ip}" 60
  start_backend isolate-alt "${alt_srv_ip}" "${alt_answer_ip}" 60
  start_client_monitor isolation --trusted-dns "${srv_ip}" --trusted-dns "${alt_srv_ip}"
  run_client isolation-primary-warm "${srv_ip}" "${answer_ip}" 1
  run_client isolation-alt-warm "${alt_srv_ip}" "${alt_answer_ip}" 1
  run_client isolation-primary "${srv_ip}" "${answer_ip}" 4
  run_client isolation-alt "${alt_srv_ip}" "${alt_answer_ip}" 4
  sleep 1
  stop_monitors
  if [[ "$(backend_count isolate-primary)" != 1 || "$(backend_count isolate-alt)" != 1 ]]; then
    echo "resolver isolation cache entries were not kept separately" >&2
    exit 1
  fi
  record_scenario "resolver-isolation" "${out_dir}/${run_id}-isolation-primary.client.log" \
    "primary=$(backend_count isolate-primary),alt=$(backend_count isolate-alt)" \
    "${out_dir}/${run_id}-isolation.client-monitor.log"
  stop_backends

  start_backend untrusted "${untrusted_srv_ip}" "${untrusted_answer_ip}" 60
  start_client_monitor untrusted --trusted-dns "${srv_ip}"
  run_client untrusted-first "${untrusted_srv_ip}" "${untrusted_answer_ip}" 1
  run_client untrusted-second "${untrusted_srv_ip}" "${untrusted_answer_ip}" 1
  sleep 1
  final_count="$(backend_count untrusted)"
  stop_monitors
  record_scenario "untrusted-resolver" "${out_dir}/${run_id}-untrusted-second.client.log" "${final_count}" \
    "${out_dir}/${run_id}-untrusted.client-monitor.log"
  if [[ "${final_count}" != 2 ]]; then
    echo "untrusted DNS response was incorrectly cached" >&2
    exit 1
  fi
  stop_backends

  start_backend nxdomain "${srv_ip}" "${answer_ip}" 60 nxdomain
  start_client_monitor nxdomain --trusted-dns "${srv_ip}"
  run_client nxdomain-first "${srv_ip}" NXDOMAIN 1
  run_client nxdomain-second "${srv_ip}" NXDOMAIN 1
  sleep 1
  final_count="$(backend_count nxdomain)"
  stop_monitors
  record_scenario "nxdomain-rejected" "${out_dir}/${run_id}-nxdomain-second.client.log" "${final_count}" \
    "${out_dir}/${run_id}-nxdomain.client-monitor.log"
  if [[ "${final_count}" != 2 ]]; then
    echo "NXDOMAIN response was incorrectly cached" >&2
    exit 1
  fi
  stop_backends
}

need_cmd ip
need_cmd python3
need_cmd timeout
need_cmd awk

if [[ ! -x "${repo_dir}/build/dns_monitor" ||
      ! -f "${repo_dir}/build/dns_client_cache.bpf.o" ]]; then
  echo "build artifacts are missing; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT
write_runtime_helpers
setup_topology
printf '# DNS Dual-End Cache Benchmark\n\n' > "${out_dir}/summary.md"
printf 'topology: `%s -> %s -> %s -> %s`\n\n' \
  "${cli_ns}/${cli_ns_if}" "${cli_host_if}" "${bridge}" "${srv_ns}/${srv_ns_if}" \
  >> "${out_dir}/summary.md"

for run_id in $(seq 1 "${repeat}"); do
  printf '## Run %s\n\n' "${run_id}" >> "${out_dir}/summary.md"
  run_suite
done

printf 'artifact=%s\n' "${out_dir}"
