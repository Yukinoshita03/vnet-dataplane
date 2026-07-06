#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/dns-xdp-cache-bench/$(date +%Y%m%d-%H%M%S)}"
netns="${NETNS:-dnsbench}"
srv_if="${SRV_IF:-veth_dns_srv}"
cli_if="${CLI_IF:-veth_dns_cli}"
srv_ip="${SRV_IP:-10.10.0.1}"
cli_ip="${CLI_IP:-10.10.0.2}"
domain="${DOMAIN:-example.test}"
answer_ip="${ANSWER_IP:-10.0.0.123}"
ttl="${TTL:-60}"
duration="${DURATION:-5}"
latency_count="${LATENCY_COUNT:-10000}"
latency_warmup="${LATENCY_WARMUP:-500}"
sudo_pass="${SUDO_PASS:-}"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

cleanup() {
  run_sudo ip link set dev "${srv_if}" xdpgeneric off >/dev/null 2>&1 || true
  run_sudo pkill -f "/tmp/dns_xdp_cache_stub.py" >/dev/null 2>&1 || true
  run_sudo ip netns del "${netns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_if}" >/dev/null 2>&1 || true
}

run_sudo() {
  if [[ -n "${sudo_pass}" ]]; then
    printf '%s\n' "${sudo_pass}" | sudo -S "$@"
  else
    sudo "$@"
  fi
}

qname_bytes_csv() {
  local name="${1%.}"
  local out=""
  local label
  IFS='.' read -ra labels <<< "${name}"
  for label in "${labels[@]}"; do
    if [[ -z "${label}" || ${#label} -gt 63 ]]; then
      echo "invalid domain label in ${name}" >&2
      exit 1
    fi
    out+="${#label},"
    local i
    for ((i = 0; i < ${#label}; i++)); do
      printf -v out '%s%d,' "${out}" "'${label:i:1}"
    done
  done
  out+="0,0,1,0,1"
  echo "${out}"
}

write_latency_bench() {
  local qbytes="$1"
  cat > /tmp/dns_xdp_cache_latency_bench.c <<C
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int cmp_u64(const void *a, const void *b) {
    unsigned long long x = *(const unsigned long long *)a;
    unsigned long long y = *(const unsigned long long *)b;
    return (x > y) - (x < y);
}

static unsigned long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char **argv) {
    const char *server = argc > 1 ? argv[1] : "${srv_ip}";
    int n = argc > 2 ? atoi(argv[2]) : ${latency_count};
    int warmup = argc > 3 ? atoi(argv[3]) : ${latency_warmup};
    unsigned char q[] = {0x12,0x34,0x01,0x00,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00,${qbytes}};
    unsigned char buf[512];
    unsigned long long *lat = calloc(n, sizeof(*lat));
    if (!lat) return 2;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 2;
    struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in dst = {0};
    dst.sin_family = AF_INET;
    dst.sin_port = htons(53);
    if (inet_pton(AF_INET, server, &dst.sin_addr) != 1) return 2;
    int ok = 0, timeout = 0;
    unsigned long long start_all = now_ns();
    for (int i = 0; i < n + warmup; i++) {
        q[0] = (unsigned char)((i >> 8) & 0xff);
        q[1] = (unsigned char)(i & 0xff);
        unsigned long long t0 = now_ns();
        if (sendto(fd, q, sizeof(q), 0, (struct sockaddr *)&dst, sizeof(dst)) < 0) break;
        ssize_t r = recv(fd, buf, sizeof(buf), 0);
        unsigned long long t1 = now_ns();
        if (r < 0) { timeout++; continue; }
        if (i >= warmup && ok < n) lat[ok++] = t1 - t0;
    }
    unsigned long long end_all = now_ns();
    close(fd);
    qsort(lat, ok, sizeof(*lat), cmp_u64);
    unsigned long long sum = 0;
    for (int i = 0; i < ok; i++) sum += lat[i];
    int i50 = ok ? (int)(ok * 0.50) : 0;
    int i95 = ok ? (int)(ok * 0.95) : 0;
    int i99 = ok ? (int)(ok * 0.99) : 0;
    if (i50 >= ok) i50 = ok - 1;
    if (i95 >= ok) i95 = ok - 1;
    if (i99 >= ok) i99 = ok - 1;
    double seconds = (double)(end_all - start_all) / 1000000000.0;
    printf("count=%d timeout=%d qps=%.2f avg_us=%.2f p50_us=%.2f p95_us=%.2f p99_us=%.2f\\n",
           ok, timeout, seconds > 0 ? (double)ok / seconds : 0.0,
           ok ? (double)sum / ok / 1000.0 : 0.0,
           ok ? lat[i50] / 1000.0 : 0.0,
           ok ? lat[i95] / 1000.0 : 0.0,
           ok ? lat[i99] / 1000.0 : 0.0);
    free(lat);
    return ok > 0 ? 0 : 1;
}
C
  gcc -O2 -Wall -o /tmp/dns_xdp_cache_latency_bench /tmp/dns_xdp_cache_latency_bench.c
}

write_stub() {
  cat > /tmp/dns_xdp_cache_stub.py <<PY
import socket

query_suffix = bytes([${qbytes}])
answer_ip = bytes(int(part) for part in "${answer_ip}".split("."))
answer_suffix = bytes([0xc0,0x0c,0x00,0x01,0x00,0x01]) + int(${ttl}).to_bytes(4, "big") + bytes([0x00,0x04]) + answer_ip
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("${srv_ip}", 53))
while True:
    data, addr = s.recvfrom(512)
    if len(data) >= 30 and data[12:] == query_suffix:
        resp = data[:2] + bytes([0x81,0x80,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00]) + data[12:] + answer_suffix
    else:
        resp = data[:2] + bytes([0x81,0x83,0x00,0x01,0x00,0x00,0x00,0x00,0x00,0x00]) + data[12:]
    s.sendto(resp, addr)
PY
}

extract_dnsperf() {
  awk '
    /Queries sent:/ { sent=$3 }
    /Queries completed:/ { completed=$3 }
    /Queries lost:/ { lost=$3 }
    /Queries per second:/ { qps=$4 }
    /Average Latency/ { avg=$4 }
    END { printf "sent=%s completed=%s lost=%s qps=%s avg_latency_s=%s\n", sent, completed, lost, qps, avg }
  ' "$1"
}

extract_field() {
  local name="$1"
  local file="$2"
  tr ' ' '\n' < "$file" | awk -F= -v n="$name" '$1 == n { print $2; exit }'
}

need_cmd dnsperf
need_cmd gcc
need_cmd ip
need_cmd awk

mkdir -p "${out_dir}"
trap cleanup EXIT
cleanup

qbytes="$(qname_bytes_csv "${domain}")"
write_latency_bench "${qbytes}"
write_stub
printf '%s A\n' "${domain}" > "${out_dir}/queries.txt"
printf '%s %s %s\n' "${domain}" "${answer_ip}" "${ttl}" > "${out_dir}/cache.txt"

run_sudo ip netns add "${netns}"
run_sudo ip link add "${srv_if}" type veth peer name "${cli_if}"
run_sudo ip link set "${cli_if}" netns "${netns}"
run_sudo ip addr add "${srv_ip}/24" dev "${srv_if}"
run_sudo ip link set "${srv_if}" up
run_sudo ip netns exec "${netns}" ip addr add "${cli_ip}/24" dev "${cli_if}"
run_sudo ip netns exec "${netns}" ip link set lo up
run_sudo ip netns exec "${netns}" ip link set "${cli_if}" up

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S python3 /tmp/dns_xdp_cache_stub.py" > "${out_dir}/userspace-stub.log" 2>&1 &
else
  nohup sudo python3 /tmp/dns_xdp_cache_stub.py > "${out_dir}/userspace-stub.log" 2>&1 &
fi
sleep 1
run_sudo ip netns exec "${netns}" dnsperf -s "${srv_ip}" -p 53 -d "${out_dir}/queries.txt" -l "${duration}" -q 100 -T 2 -c 10 -t 1 > "${out_dir}/userspace-dnsperf.log" 2>&1
run_sudo ip netns exec "${netns}" /tmp/dns_xdp_cache_latency_bench "${srv_ip}" "${latency_count}" "${latency_warmup}" > "${out_dir}/userspace-latency.log"
run_sudo pkill -f "/tmp/dns_xdp_cache_stub.py" >/dev/null 2>&1 || true

pushd "${repo_dir}" >/dev/null
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S timeout '$((duration + 12))s' ./build/dns_monitor --dev '${srv_if}' --hook xdp --xdp-mode generic --cache-file '${out_dir}/cache.txt'" > "${out_dir}/xdp-monitor.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 12))s" ./build/dns_monitor --dev "${srv_if}" --hook xdp --xdp-mode generic --cache-file "${out_dir}/cache.txt" > "${out_dir}/xdp-monitor.log" 2>&1 &
fi
monitor_pid=$!
popd >/dev/null
sleep 1
run_sudo ip netns exec "${netns}" dnsperf -s "${srv_ip}" -p 53 -d "${out_dir}/queries.txt" -l "${duration}" -q 100 -T 2 -c 10 -t 1 > "${out_dir}/xdp-dnsperf.log" 2>&1
run_sudo ip netns exec "${netns}" /tmp/dns_xdp_cache_latency_bench "${srv_ip}" "${latency_count}" "${latency_warmup}" > "${out_dir}/xdp-latency.log"
run_sudo pkill -TERM -f "dns_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
wait "${monitor_pid}" >/dev/null 2>&1 || true
sleep 1

userspace_dnsperf="$(extract_dnsperf "${out_dir}/userspace-dnsperf.log")"
xdp_dnsperf="$(extract_dnsperf "${out_dir}/xdp-dnsperf.log")"
userspace_qps="$(echo "${userspace_dnsperf}" | tr ' ' '\n' | awk -F= '$1=="qps"{print $2}')"
xdp_qps="$(echo "${xdp_dnsperf}" | tr ' ' '\n' | awk -F= '$1=="qps"{print $2}')"
userspace_p99="$(extract_field p99_us "${out_dir}/userspace-latency.log")"
xdp_p99="$(extract_field p99_us "${out_dir}/xdp-latency.log")"
cache_line="$(grep -E 'cache_hit|cache_tx' "${out_dir}/xdp-monitor.log" | tail -1 || true)"

qps_speedup="$(awk -v x="${xdp_qps}" -v u="${userspace_qps}" 'BEGIN { if (u > 0) printf "%.2f", x / u; else print "0.00" }')"
p99_speedup="$(awk -v x="${xdp_p99}" -v u="${userspace_p99}" 'BEGIN { if (x > 0) printf "%.2f", u / x; else print "0.00" }')"

cat > "${out_dir}/summary.md" <<MD
# DNS XDP Cache Benchmark

domain=${domain}
answer_ip=${answer_ip}
topology=netns+veth

| path | dnsperf qps | p99_us | speedup |
| --- | ---: | ---: | ---: |
| userspace | ${userspace_qps} | ${userspace_p99} | 1.00x |
| xdp-cache | ${xdp_qps} | ${xdp_p99} | qps ${qps_speedup}x / p99 ${p99_speedup}x |

userspace dnsperf: ${userspace_dnsperf}

xdp dnsperf: ${xdp_dnsperf}

xdp cache metrics: ${cache_line}
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
