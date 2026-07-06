#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/grpc-tc-monitor-bench/$(date +%Y%m%d-%H%M%S)}"
netns="${NETNS:-grpcbench}"
srv_if="${SRV_IF:-veth_grpc_srv}"
cli_if="${CLI_IF:-veth_grpc_cli}"
srv_ip="${SRV_IP:-10.20.0.1}"
cli_ip="${CLI_IP:-10.20.0.2}"
port="${PORT:-50051}"
requests="${REQUESTS:-3000}"
warmup="${WARMUP:-100}"
duration="${DURATION:-5}"
sudo_pass="${SUDO_PASS:-}"

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

cleanup() {
  run_sudo pkill -f "/tmp/grpc_tc_monitor_stub.py" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
  run_sudo ip netns del "${netns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_if}" >/dev/null 2>&1 || true
}

write_stub() {
  cat > /tmp/grpc_tc_monitor_stub.py <<PY
import socket
import threading

host = "${srv_ip}"
port = ${port}
response = b"grpc-bench-response"

def handle(conn):
    try:
        data = conn.recv(4096)
        if data:
            conn.sendall(response)
    finally:
        conn.close()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((host, port))
s.listen(256)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
}

write_latency_bench() {
  cat > /tmp/grpc_tc_monitor_latency_bench.c <<C
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static int one_request(const char *server, int port, unsigned long long *latency) {
    const char payload[] = "PRI * HTTP/2.0\\r\\n\\r\\nSM\\r\\n\\r\\n";
    char buf[256];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in dst = {0};
    dst.sin_family = AF_INET;
    dst.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, server, &dst.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    unsigned long long t0 = now_ns();
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        close(fd);
        return -1;
    }
    if (send(fd, payload, sizeof(payload) - 1, 0) != (ssize_t)(sizeof(payload) - 1)) {
        close(fd);
        return -1;
    }
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    unsigned long long t1 = now_ns();
    close(fd);
    if (n <= 0) return -1;

    *latency = t1 - t0;
    return 0;
}

int main(int argc, char **argv) {
    const char *server = argc > 1 ? argv[1] : "${srv_ip}";
    int port = argc > 2 ? atoi(argv[2]) : ${port};
    int requests = argc > 3 ? atoi(argv[3]) : ${requests};
    int warmup = argc > 4 ? atoi(argv[4]) : ${warmup};
    unsigned long long *lat = calloc(requests, sizeof(*lat));
    if (!lat) return 2;

    int ok = 0, failed = 0;
    unsigned long long start_all = now_ns();
    for (int i = 0; i < requests + warmup; i++) {
        unsigned long long sample = 0;
        if (one_request(server, port, &sample) != 0) {
            failed++;
            continue;
        }
        if (i >= warmup && ok < requests)
            lat[ok++] = sample;
    }
    unsigned long long end_all = now_ns();

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

    printf("count=%d failed=%d qps=%.2f avg_us=%.2f p50_us=%.2f p95_us=%.2f p99_us=%.2f\\n",
           ok, failed, seconds > 0 ? (double)ok / seconds : 0.0,
           ok ? (double)sum / ok / 1000.0 : 0.0,
           ok ? lat[i50] / 1000.0 : 0.0,
           ok ? lat[i95] / 1000.0 : 0.0,
           ok ? lat[i99] / 1000.0 : 0.0);
    free(lat);
    return ok > 0 ? 0 : 1;
}
C
  gcc -O2 -Wall -o /tmp/grpc_tc_monitor_latency_bench /tmp/grpc_tc_monitor_latency_bench.c
}

extract_field() {
  local name="$1"
  local file="$2"
  tr ' ' '\n' < "$file" | awk -F= -v n="$name" '$1 == n { print $2; exit }'
}

need_cmd gcc
need_cmd ip
need_cmd python3
need_cmd awk

if [[ ! -x "${repo_dir}/build/grpc_monitor" ]]; then
  echo "missing build/grpc_monitor; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT
cleanup

write_stub
write_latency_bench

run_sudo ip netns add "${netns}"
run_sudo ip link add "${srv_if}" type veth peer name "${cli_if}"
run_sudo ip link set "${cli_if}" netns "${netns}"
run_sudo ip addr add "${srv_ip}/24" dev "${srv_if}"
run_sudo ip link set "${srv_if}" up
run_sudo ip netns exec "${netns}" ip addr add "${cli_ip}/24" dev "${cli_if}"
run_sudo ip netns exec "${netns}" ip link set lo up
run_sudo ip netns exec "${netns}" ip link set "${cli_if}" up

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S python3 /tmp/grpc_tc_monitor_stub.py" > "${out_dir}/server.log" 2>&1 &
else
  nohup sudo python3 /tmp/grpc_tc_monitor_stub.py > "${out_dir}/server.log" 2>&1 &
fi
sleep 1

pushd "${repo_dir}" >/dev/null
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S timeout '$((duration + 12))s' ./build/grpc_monitor --dev '${srv_if}' --port '${port}' --verbose-events" > "${out_dir}/grpc-monitor.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 12))s" ./build/grpc_monitor --dev "${srv_if}" --port "${port}" --verbose-events > "${out_dir}/grpc-monitor.log" 2>&1 &
fi
monitor_pid=$!
popd >/dev/null

sleep 1
run_sudo ip netns exec "${netns}" /tmp/grpc_tc_monitor_latency_bench "${srv_ip}" "${port}" "${requests}" "${warmup}" > "${out_dir}/latency.log"

run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
kill -TERM "${monitor_pid}" >/dev/null 2>&1 || true
wait "${monitor_pid}" >/dev/null 2>&1 || true
sleep 1

latency_line="$(cat "${out_dir}/latency.log")"
success_count="$(extract_field count "${out_dir}/latency.log")"
failed_count="$(extract_field failed "${out_dir}/latency.log")"
qps="$(extract_field qps "${out_dir}/latency.log")"
avg_us="$(extract_field avg_us "${out_dir}/latency.log")"
p50_us="$(extract_field p50_us "${out_dir}/latency.log")"
p95_us="$(extract_field p95_us "${out_dir}/latency.log")"
p99_us="$(extract_field p99_us "${out_dir}/latency.log")"
metrics_line="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | tail -1 || true)"

cat > "${out_dir}/summary.md" <<MD
# gRPC tc Monitor Benchmark

topology=netns+veth
server=${srv_ip}:${port}
client=${cli_ip}
requests=${requests}
warmup=${warmup}

| metric | value |
| --- | ---: |
| success | ${success_count} |
| failed | ${failed_count} |
| qps | ${qps} |
| avg_us | ${avg_us} |
| p50_us | ${p50_us} |
| p95_us | ${p95_us} |
| p99_us | ${p99_us} |

latency bench: ${latency_line}

grpc monitor: ${metrics_line}
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
