#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="${OUT_DIR:-${repo_dir}/artifacts/grpc-fast-cache-bench/$(date +%Y%m%d-%H%M%S)}"
netns="${NETNS:-grpcfastbench}"
srv_if="${SRV_IF:-veth_gfc_srv}"
cli_if="${CLI_IF:-veth_gfc_cli}"
srv_ip="${SRV_IP:-10.40.0.1}"
cli_ip="${CLI_IP:-10.40.0.2}"
backend_port="${BACKEND_PORT:-50151}"
cache_port="${CACHE_PORT:-50152}"
fallback_port="${FALLBACK_PORT:-50153}"
response_miss_port="${RESPONSE_MISS_PORT:-50154}"
requests="${REQUESTS:-1000}"
warmup="${WARMUP:-50}"
duration="${DURATION:-10}"
sudo_pass="${SUDO_PASS:-}"
pin_dir="${PIN_DIR:-/sys/fs/bpf/ebpf-network-service-cache}"
response_map="${pin_dir}/grpc_response_cache"
method="/grpc.health.v1.Health/Check"
fallback_method="/demo.Cache/Get"
serving_payload="demo"
not_serving_payload="down"
miss_payload="miss"

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
  run_sudo pkill -TERM -f "grpc_fast_cache_demo.py server" >/dev/null 2>&1 || true
  run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
  for port in "${backend_port}" "${cache_port}" "${fallback_port}" "${response_miss_port}"; do
    run_sudo fuser -k "${port}/tcp" >/dev/null 2>&1 || true
  done
  run_sudo ip netns del "${netns}" >/dev/null 2>&1 || true
  run_sudo ip link del "${srv_if}" >/dev/null 2>&1 || true
}

write_python_demo() {
  cat > "${out_dir}/grpc_fast_cache_demo.py" <<'PY'
#!/usr/bin/env python3
import argparse
import socket
import struct
import sys
import time

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

def frame_header(length, typ, flags, stream_id):
    return bytes([(length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff,
                  typ & 0xff, flags & 0xff]) + struct.pack("!I", stream_id & 0x7fffffff)

def hpack_literal(name, value):
    nb = name.encode()
    vb = value.encode()
    return b"\x00" + bytes([len(nb)]) + nb + bytes([len(vb)]) + vb

def response_frames(stream_id):
    headers = b"\x88" + hpack_literal("content-type", "application/grpc")
    data = b"\x00\x00\x00\x00\x02\x08\x01"
    trailers = hpack_literal("grpc-status", "0")
    return (frame_header(0, 0x4, 0x1, 0) +
            frame_header(len(headers), 0x1, 0x4, stream_id) + headers +
            frame_header(len(data), 0x0, 0x0, stream_id) + data +
            frame_header(len(trailers), 0x1, 0x5, stream_id) + trailers)

def request_frames(method, payload):
    headers = (
        b"\x83" +  # :method POST
        b"\x86" +  # :scheme http
        hpack_literal(":path", method) +
        hpack_literal(":authority", "bench") +
        hpack_literal("content-type", "application/grpc") +
        hpack_literal("te", "trailers")
    )
    payload_bytes = payload.encode()
    data = b"\x00" + len(payload_bytes).to_bytes(4, "big") + payload_bytes
    return (PREFACE +
            frame_header(0, 0x4, 0x0, 0) +
            frame_header(len(headers), 0x1, 0x4, 1) + headers +
            frame_header(len(data), 0x0, 0x1, 1) + data)

def read_exact(conn, n):
    chunks = []
    got = 0
    while got < n:
        chunk = conn.recv(n - got)
        if not chunk:
            raise EOFError("connection closed")
        chunks.append(chunk)
        got += len(chunk)
    return b"".join(chunks)

def read_until_response(conn):
    saw_status = False
    data_status = "UNKNOWN"
    while True:
        hdr = read_exact(conn, 9)
        length = (hdr[0] << 16) | (hdr[1] << 8) | hdr[2]
        typ = hdr[3]
        flags = hdr[4]
        sid = struct.unpack("!I", hdr[5:9])[0] & 0x7fffffff
        payload = read_exact(conn, length) if length else b""
        if sid == 1 and typ == 0x1:
            saw_status = True
            if flags & 0x1:
                return data_status
        if sid == 1 and typ == 0x0 and payload.startswith(b"\x00\x00\x00\x00\x02\x08"):
            saw_status = True
            if len(payload) >= 7 and payload[6] == 1:
                data_status = "SERVING"
            elif len(payload) >= 7 and payload[6] == 2:
                data_status = "NOT_SERVING"

def handle_client(conn, delay_us):
    try:
        preface = read_exact(conn, len(PREFACE))
        if preface != PREFACE:
            return
        conn.sendall(frame_header(0, 0x4, 0x0, 0) + frame_header(0, 0x4, 0x1, 0))
        saw_stream = False
        while True:
            hdr = read_exact(conn, 9)
            length = (hdr[0] << 16) | (hdr[1] << 8) | hdr[2]
            typ = hdr[3]
            flags = hdr[4]
            sid = struct.unpack("!I", hdr[5:9])[0] & 0x7fffffff
            if length:
                read_exact(conn, length)
            if typ == 0x1 and sid:
                saw_stream = True
            if saw_stream and sid == 1 and (flags & 0x1):
                break
        time.sleep(delay_us / 1000000.0)
        conn.sendall(response_frames(1))
    except Exception:
        return

def run_server(args):
    host, port = args.listen.rsplit(":", 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((host, int(port)))
    sock.listen(1024)
    while True:
        conn, _ = sock.accept()
        with conn:
            handle_client(conn, args.delay_us)

def run_client(args):
    host, port = args.target.rsplit(":", 1)
    samples = []
    failed = 0
    serving = 0
    not_serving = 0
    req = request_frames(args.method, args.payload)
    start_all = time.time()
    for i in range(args.requests + args.warmup):
        try:
            start = time.time()
            with socket.create_connection((host, int(port)), timeout=2.0) as conn:
                conn.sendall(req)
                status = read_until_response(conn)
            elapsed = (time.time() - start) * 1000000.0
            if status == "SERVING":
                serving += 1
            elif status == "NOT_SERVING":
                not_serving += 1
            if i >= args.warmup:
                samples.append(elapsed)
        except Exception:
            failed += 1
    total = time.time() - start_all
    samples.sort()
    count = len(samples)
    def pct(p):
        if not samples:
            return 0.0
        return samples[int((len(samples) - 1) * p)]
    avg = sum(samples) / count if count else 0.0
    qps = count / total if total > 0 else 0.0
    print(f"count={count} failed={failed} serving={serving} not_serving={not_serving} qps={qps:.2f} avg_us={avg:.2f} "
          f"p50_us={pct(0.50):.2f} p95_us={pct(0.95):.2f} p99_us={pct(0.99):.2f}")
    return 0 if count else 1

def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    srv = sub.add_parser("server")
    srv.add_argument("--listen", required=True)
    srv.add_argument("--delay-us", type=int, default=300)
    cli = sub.add_parser("client")
    cli.add_argument("--target", required=True)
    cli.add_argument("--requests", type=int, default=1000)
    cli.add_argument("--warmup", type=int, default=50)
    cli.add_argument("--method", default="/grpc.health.v1.Health/Check")
    cli.add_argument("--payload", default="demo")
    args = parser.parse_args()
    if args.mode == "server":
        run_server(args)
    else:
        sys.exit(run_client(args))

if __name__ == "__main__":
    main()
PY
  chmod +x "${out_dir}/grpc_fast_cache_demo.py"
}

extract_field() {
  local name="$1"
  local file="$2"
  tr ' ' '\n' < "$file" | awk -F= -v n="$name" '$1 == n { print $2; exit }'
}

need_cmd awk
need_cmd ip
need_cmd python3

if [[ ! -x "${repo_dir}/build/grpc_monitor" || ! -x "${repo_dir}/build/grpc_fast_cache" || ! -x "${repo_dir}/build/cachectl" ]]; then
  echo "missing build artifacts; run ./scripts/build_linux.sh first" >&2
  exit 1
fi

mkdir -p "${out_dir}"
trap cleanup EXIT
cleanup
write_python_demo

run_sudo ip netns add "${netns}"
run_sudo ip link add "${srv_if}" type veth peer name "${cli_if}"
run_sudo ip link set "${cli_if}" netns "${netns}"
run_sudo ip addr add "${srv_ip}/24" dev "${srv_if}"
run_sudo ip link set "${srv_if}" up
run_sudo ip netns exec "${netns}" ip addr add "${cli_ip}/24" dev "${cli_if}"
run_sudo ip netns exec "${netns}" ip link set lo up
run_sudo ip netns exec "${netns}" ip link set "${cli_if}" up
run_sudo mkdir -p "${pin_dir}"

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S python3 '${out_dir}/grpc_fast_cache_demo.py' server --listen '${srv_ip}:${backend_port}' --delay-us 300" > "${out_dir}/backend.log" 2>&1 &
else
  nohup sudo python3 "${out_dir}/grpc_fast_cache_demo.py" server --listen "${srv_ip}:${backend_port}" --delay-us 300 > "${out_dir}/backend.log" 2>&1 &
fi
sleep 1

pushd "${repo_dir}" >/dev/null
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S timeout '$((duration + 20))s' ./build/grpc_monitor --dev '${srv_if}' --port '${cache_port}' --pin-dir '${pin_dir}'" > "${out_dir}/grpc-monitor.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 20))s" ./build/grpc_monitor --dev "${srv_if}" --port "${cache_port}" --pin-dir "${pin_dir}" > "${out_dir}/grpc-monitor.log" 2>&1 &
fi
monitor_pid=$!
popd >/dev/null
sleep 1

cat > "${out_dir}/cache-policy.txt" <<POLICY
grpc ${method} 60 idempotent
grpc-cache ${method} ${serving_payload} SERVING 60
grpc-cache ${method} ${not_serving_payload} NOT_SERVING 60
POLICY
run_sudo "${repo_dir}/build/cachectl" --policy-file "${out_dir}/cache-policy.txt" \
  --grpc-map "${pin_dir}/grpc_policy_map" --grpc-response-map "${response_map}" \
  > "${out_dir}/cachectl.log"

if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S timeout '$((duration + 20))s' '${repo_dir}/build/grpc_fast_cache' --grpc-map '${pin_dir}/grpc_policy_map' --grpc-response-map '${response_map}' --cache-file '${out_dir}/cache-policy.txt' --listen '${srv_ip}:${cache_port}' --backend '${srv_ip}:${backend_port}' --method '${method}' --verbose" > "${out_dir}/grpc-fast-cache.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 20))s" "${repo_dir}/build/grpc_fast_cache" --grpc-map "${pin_dir}/grpc_policy_map" --grpc-response-map "${response_map}" --cache-file "${out_dir}/cache-policy.txt" --listen "${srv_ip}:${cache_port}" --backend "${srv_ip}:${backend_port}" --method "${method}" --verbose > "${out_dir}/grpc-fast-cache.log" 2>&1 &
fi
cache_pid=$!
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S timeout '$((duration + 20))s' '${repo_dir}/build/grpc_fast_cache' --grpc-map '${pin_dir}/grpc_policy_map' --grpc-response-map '${response_map}' --cache-file '${out_dir}/cache-policy.txt' --listen '${srv_ip}:${fallback_port}' --backend '${srv_ip}:${backend_port}' --method '${method}' --verbose" > "${out_dir}/grpc-fallback.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 20))s" "${repo_dir}/build/grpc_fast_cache" --grpc-map "${pin_dir}/grpc_policy_map" --grpc-response-map "${response_map}" --cache-file "${out_dir}/cache-policy.txt" --listen "${srv_ip}:${fallback_port}" --backend "${srv_ip}:${backend_port}" --method "${method}" --verbose > "${out_dir}/grpc-fallback.log" 2>&1 &
fi
fallback_pid=$!
if [[ -n "${sudo_pass}" ]]; then
  nohup sh -c "printf '%s\n' '${sudo_pass}' | sudo -S timeout '$((duration + 20))s' '${repo_dir}/build/grpc_fast_cache' --grpc-map '${pin_dir}/grpc_policy_map' --grpc-response-map '${response_map}' --cache-file '${out_dir}/cache-policy.txt' --listen '${srv_ip}:${response_miss_port}' --backend '${srv_ip}:${backend_port}' --method '${method}' --verbose" > "${out_dir}/grpc-response-miss.log" 2>&1 &
else
  nohup sudo timeout "$((duration + 20))s" "${repo_dir}/build/grpc_fast_cache" --grpc-map "${pin_dir}/grpc_policy_map" --grpc-response-map "${response_map}" --cache-file "${out_dir}/cache-policy.txt" --listen "${srv_ip}:${response_miss_port}" --backend "${srv_ip}:${backend_port}" --method "${method}" --verbose > "${out_dir}/grpc-response-miss.log" 2>&1 &
fi
response_miss_pid=$!
sleep 1

run_sudo ip netns exec "${netns}" python3 "${out_dir}/grpc_fast_cache_demo.py" client --target "${srv_ip}:${backend_port}" --method "${method}" --payload "${serving_payload}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/backend-latency.log"
run_sudo ip netns exec "${netns}" python3 "${out_dir}/grpc_fast_cache_demo.py" client --target "${srv_ip}:${cache_port}" --method "${method}" --payload "${serving_payload}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/cache-serving-latency.log"
run_sudo ip netns exec "${netns}" python3 "${out_dir}/grpc_fast_cache_demo.py" client --target "${srv_ip}:${cache_port}" --method "${method}" --payload "${not_serving_payload}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/cache-not-serving-latency.log"
run_sudo ip netns exec "${netns}" python3 "${out_dir}/grpc_fast_cache_demo.py" client --target "${srv_ip}:${response_miss_port}" --method "${method}" --payload "${miss_payload}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/response-miss-latency.log"
run_sudo ip netns exec "${netns}" python3 "${out_dir}/grpc_fast_cache_demo.py" client --target "${srv_ip}:${fallback_port}" --method "${fallback_method}" --payload "${miss_payload}" --requests "${requests}" --warmup "${warmup}" > "${out_dir}/fallback-latency.log"

run_sudo pkill -TERM -f "grpc_monitor --dev ${srv_if}" >/dev/null 2>&1 || true
run_sudo pkill -TERM -f "grpc_fast_cache --grpc-map" >/dev/null 2>&1 || true
kill -TERM "${monitor_pid}" "${cache_pid}" "${fallback_pid}" "${response_miss_pid}" >/dev/null 2>&1 || true
wait "${monitor_pid}" >/dev/null 2>&1 || true
wait "${cache_pid}" >/dev/null 2>&1 || true
wait "${fallback_pid}" >/dev/null 2>&1 || true
wait "${response_miss_pid}" >/dev/null 2>&1 || true
sleep 1

backend_line="$(cat "${out_dir}/backend-latency.log")"
cache_serving_line="$(cat "${out_dir}/cache-serving-latency.log")"
cache_not_serving_line="$(cat "${out_dir}/cache-not-serving-latency.log")"
fallback_line="$(cat "${out_dir}/fallback-latency.log")"
response_miss_line="$(cat "${out_dir}/response-miss-latency.log")"
backend_qps="$(extract_field qps "${out_dir}/backend-latency.log")"
backend_p99="$(extract_field p99_us "${out_dir}/backend-latency.log")"
cache_serving_qps="$(extract_field qps "${out_dir}/cache-serving-latency.log")"
cache_serving_p99="$(extract_field p99_us "${out_dir}/cache-serving-latency.log")"
cache_not_serving_qps="$(extract_field qps "${out_dir}/cache-not-serving-latency.log")"
cache_not_serving_p99="$(extract_field p99_us "${out_dir}/cache-not-serving-latency.log")"
fallback_qps="$(extract_field qps "${out_dir}/fallback-latency.log")"
fallback_p99="$(extract_field p99_us "${out_dir}/fallback-latency.log")"
response_miss_qps="$(extract_field qps "${out_dir}/response-miss-latency.log")"
response_miss_p99="$(extract_field p99_us "${out_dir}/response-miss-latency.log")"
cache_stats="$(grep 'grpc_fast_cache' "${out_dir}/grpc-fast-cache.log" | grep 'tx_error=' | tail -1 || true)"
fallback_stats="$(grep 'grpc_fast_cache' "${out_dir}/grpc-fallback.log" | grep 'tx_error=' | tail -1 || true)"
response_miss_stats="$(grep 'grpc_fast_cache' "${out_dir}/grpc-response-miss.log" | grep 'tx_error=' | tail -1 || true)"
monitor_line="$(grep 'grpc_metrics' "${out_dir}/grpc-monitor.log" | tail -1 || true)"

qps_speedup="$(awk -v a="${cache_serving_qps}" -v b="${backend_qps}" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "0.00" }')"
p99_speedup="$(awk -v a="${backend_p99}" -v b="${cache_serving_p99}" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "0.00" }')"

cat > "${out_dir}/summary.md" <<MD
# gRPC Fast Cache Benchmark

topology=netns+veth
method=${method}
fallback_method=${fallback_method}
serving_payload=${serving_payload}
not_serving_payload=${not_serving_payload}
miss_payload=${miss_payload}
backend=${srv_ip}:${backend_port}
cache=${srv_ip}:${cache_port}
fallback=${srv_ip}:${fallback_port}
response_miss=${srv_ip}:${response_miss_port}
requests=${requests}
warmup=${warmup}

| path | qps | p99_us |
| --- | ---: | ---: |
| direct backend | ${backend_qps} | ${backend_p99} |
| cache hit SERVING | ${cache_serving_qps} | ${cache_serving_p99} |
| cache hit NOT_SERVING | ${cache_not_serving_qps} | ${cache_not_serving_p99} |
| response cache miss fallback | ${response_miss_qps} | ${response_miss_p99} |
| policy miss fallback | ${fallback_qps} | ${fallback_p99} |

speedup: qps ${qps_speedup}x, p99 ${p99_speedup}x

backend latency: ${backend_line}

cache serving latency: ${cache_serving_line}

cache not-serving latency: ${cache_not_serving_line}

fallback latency: ${fallback_line}

response miss latency: ${response_miss_line}

cache stats: ${cache_stats}

response miss stats: ${response_miss_stats}

fallback stats: ${fallback_stats}

grpc monitor: ${monitor_line}
MD

cat "${out_dir}/summary.md"
echo "Artifacts: ${out_dir}"
