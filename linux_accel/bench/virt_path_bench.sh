#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/virt-path-bench/$(date +%Y%m%d-%H%M%S)}"
client_ns="${CLIENT_NS:-virtcli}"
server_ns="${SERVER_NS:-virtsrv}"
bridge="${BRIDGE:-br_virt_bench}"
client_host_if="${CLIENT_HOST_IF:-veth_cli_host}"
client_ns_if="${CLIENT_NS_IF:-veth_cli_ns}"
server_host_if="${SERVER_HOST_IF:-veth_srv_host}"
server_ns_if="${SERVER_NS_IF:-veth_srv_ns}"
client_ip="${CLIENT_IP:-10.40.0.2}"
server_ip="${SERVER_IP:-10.40.0.3}"
bridge_ip="${BRIDGE_IP:-10.40.0.1}"
port="${PORT:-50080}"
requests="${REQUESTS:-3000}"
warmup="${WARMUP:-100}"
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
  run_sudo pkill -TERM -f "/tmp/virt_path_echo_server.py" >/dev/null 2>&1 || true
  run_sudo ip netns del "${client_ns}" >/dev/null 2>&1 || true
  run_sudo ip netns del "${server_ns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${client_host_if}" >/dev/null 2>&1 || true
  run_sudo ip link del "${server_host_if}" >/dev/null 2>&1 || true
  run_sudo ip link set "${bridge}" down >/dev/null 2>&1 || true
  run_sudo ip link del "${bridge}" type bridge >/dev/null 2>&1 || true
}

write_server() {
  cat > /tmp/virt_path_echo_server.py <<PY
import socket
import threading

host = "${server_ip}"
port = ${port}
response = b"virt-path-response"

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
s.listen(512)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
}

write_client() {
  cat > /tmp/virt_path_latency_bench.c <<C
#include <arpa/inet.h>
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
    const char payload[] = "virt-path-request";
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
    unsigned long long start = now_ns();
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) < 0) {
        close(fd);
        return -1;
    }
    if (send(fd, payload, sizeof(payload) - 1, 0) != (ssize_t)(sizeof(payload) - 1)) {
        close(fd);
        return -1;
    }
    ssize_t n = recv(fd, buf, sizeof(buf), 0);
    unsigned long long end = now_ns();
    close(fd);
    if (n <= 0) return -1;
    *latency = end - start;
    return 0;
}

int main(int argc, char **argv) {
    const char *server = argc > 1 ? argv[1] : "${server_ip}";
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
        if (i >= warmup && ok < requests) lat[ok++] = sample;
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
    printf("count=%d failed=%d qps=%.2f avg_us=%.2f p50_us=%.2f p95_us=%.2f p99_us=%.2f\n",
           ok, failed, seconds > 0 ? (double)ok / seconds : 0.0,
           ok ? (double)sum / ok / 1000.0 : 0.0,
           ok ? lat[i50] / 1000.0 : 0.0,
           ok ? lat[i95] / 1000.0 : 0.0,
           ok ? lat[i99] / 1000.0 : 0.0);
    free(lat);
    return ok > 0 ? 0 : 1;
}
C
  gcc -O2 -Wall -o /tmp/virt_path_latency_bench /tmp/virt_path_latency_bench.c
}

extract_field() {
  local name="$1"
  local file="$2"
  tr ' ' '\n' < "$file" | awk -F= -v n="$name" '$1 == n { print $2; exit }'
}

need_cmd awk
need_cmd gcc
need_cmd ip
need_cmd python3

mkdir -p "${out_dir}"
trap cleanup EXIT
cleanup
write_server
write_client

run_sudo ip netns add "${client_ns}"
run_sudo ip netns add "${server_ns}"
run_sudo ip link add "${bridge}" type bridge
run_sudo ip addr add "${bridge_ip}/24" dev "${bridge}"
run_sudo ip link set "${bridge}" up
run_sudo ip link add "${client_host_if}" type veth peer name "${client_ns_if}"
run_sudo ip link add "${server_host_if}" type veth peer name "${server_ns_if}"
run_sudo ip link set "${client_ns_if}" netns "${client_ns}"
run_sudo ip link set "${server_ns_if}" netns "${server_ns}"
run_sudo ip link set "${client_host_if}" master "${bridge}"
run_sudo ip link set "${server_host_if}" master "${bridge}"
run_sudo ip link set "${client_host_if}" up
run_sudo ip link set "${server_host_if}" up
run_sudo ip netns exec "${client_ns}" ip addr add "${client_ip}/24" dev "${client_ns_if}"
run_sudo ip netns exec "${server_ns}" ip addr add "${server_ip}/24" dev "${server_ns_if}"
run_sudo ip netns exec "${client_ns}" ip link set lo up
run_sudo ip netns exec "${server_ns}" ip link set lo up
run_sudo ip netns exec "${client_ns}" ip link set "${client_ns_if}" up
run_sudo ip netns exec "${server_ns}" ip link set "${server_ns_if}" up

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\\n' '${sudo_pass}' | sudo -S ip netns exec '${server_ns}' python3 /tmp/virt_path_echo_server.py" > "${out_dir}/server.log" 2>&1 &
else
  nohup sudo ip netns exec "${server_ns}" python3 /tmp/virt_path_echo_server.py > "${out_dir}/server.log" 2>&1 &
fi
sleep 1
run_sudo ip netns exec "${client_ns}" ping -c 3 -W 1 "${server_ip}" > "${out_dir}/ping.log"
run_sudo ip netns exec "${client_ns}" /tmp/virt_path_latency_bench "${server_ip}" "${port}" "${requests}" "${warmup}" > "${out_dir}/latency.log"
run_sudo bridge link show > "${out_dir}/bridge-link.log" 2>&1 || true
run_sudo ip -s link show "${bridge}" > "${out_dir}/bridge-stats.log" 2>&1 || true

latency_line="$(cat "${out_dir}/latency.log")"
success_count="$(extract_field count "${out_dir}/latency.log")"
failed_count="$(extract_field failed "${out_dir}/latency.log")"
qps="$(extract_field qps "${out_dir}/latency.log")"
avg_us="$(extract_field avg_us "${out_dir}/latency.log")"
p50_us="$(extract_field p50_us "${out_dir}/latency.log")"
p95_us="$(extract_field p95_us "${out_dir}/latency.log")"
p99_us="$(extract_field p99_us "${out_dir}/latency.log")"
ping_summary="$(tail -2 "${out_dir}/ping.log" | tr '\n' ' ')"

cat > "${out_dir}/summary.md" <<MD
# Virtualization Path Benchmark

topology=netns+bridge+veth
client=${client_ns}/${client_ip}
server=${server_ns}/${server_ip}:${port}
bridge=${bridge}/${bridge_ip}
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

ping: ${ping_summary}
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"