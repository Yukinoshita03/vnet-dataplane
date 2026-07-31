#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fast_cache="${root_dir}/build/grpc_fast_cache"
tmp_dir="$(mktemp -d)"
pid=""

cleanup() {
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
  fi
  rm -rf -- "${tmp_dir}"
}
trap cleanup EXIT

if [[ ! -x "${fast_cache}" ]]; then
  echo "missing grpc_fast_cache binary: ${fast_cache}" >&2
  exit 1
fi

listen_port="$((20000 + ($$ % 20000)))"
"${fast_cache}" \
  --listen "127.0.0.1:${listen_port}" \
  --backend "127.0.0.1:$((listen_port + 1))" \
  --cache-entry "/grpc.health.v1.Health/Check:default:SERVING" \
  >"${tmp_dir}/grpc-fast-cache.log" 2>&1 &
pid="$!"

listener_ready=0
for _attempt in $(seq 1 100); do
  if grep -q '^Listening for h2c gRPC cache/proxy ' \
    "${tmp_dir}/grpc-fast-cache.log"; then
    listener_ready=1
    break
  fi
  if ! kill -0 "${pid}" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if (( listener_ready != 1 )); then
  echo "grpc_fast_cache did not publish listener readiness" >&2
  cat "${tmp_dir}/grpc-fast-cache.log" >&2
  exit 1
fi

# Guest endpoint health uses a connect-only TCP probe. An empty connection is
# not a gRPC request and must not affect the controller's business counters.
python3 - "${listen_port}" <<'PY'
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1.0):
    pass
PY

# A non-empty malformed request is a real request. It must still reach the
# normal parse/fallback error accounting instead of being classified as an
# empty health probe.
python3 - "${listen_port}" <<'PY'
import socket
import sys

with socket.create_connection(
    ("127.0.0.1", int(sys.argv[1])), timeout=1.0
) as sock:
    sock.sendall(b"\x00")
    sock.shutdown(socket.SHUT_WR)
PY

expected_metrics=0
for _attempt in $(seq 1 100); do
  if grep -Eq \
    '^grpc_fast_cache .* accepted=1 empty_connection=1 .* parse_error=1 .* fallback_error=1 ' \
    "${tmp_dir}/grpc-fast-cache.log"; then
    expected_metrics=1
    break
  fi
  if ! kill -0 "${pid}" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if (( expected_metrics != 1 )); then
  echo "grpc_fast_cache did not publish the expected probe/error metrics" >&2
  cat "${tmp_dir}/grpc-fast-cache.log" >&2
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
  fi
  wait "${pid}" 2>/dev/null || true
  pid=""
  exit 1
fi

metric_lines_before_stop="$(
  grep -c '^grpc_fast_cache ' "${tmp_dir}/grpc-fast-cache.log" || true
)"
kill -TERM "${pid}"
wait_status=0
wait "${pid}" || wait_status="$?"
pid=""
if (( wait_status != 0 )); then
  echo "grpc_fast_cache exited with status ${wait_status}" >&2
  cat "${tmp_dir}/grpc-fast-cache.log" >&2
  exit 1
fi

metric_lines="$(
  grep -c '^grpc_fast_cache ' "${tmp_dir}/grpc-fast-cache.log" || true
)"
if (( metric_lines <= metric_lines_before_stop )); then
  echo "grpc_fast_cache did not publish final metrics during shutdown" >&2
  cat "${tmp_dir}/grpc-fast-cache.log" >&2
  exit 1
fi

last_metrics="$(grep '^grpc_fast_cache ' \
  "${tmp_dir}/grpc-fast-cache.log" | tail -n 1)"
python3 - "${last_metrics}" <<'PY'
import re
import sys

fields = dict(re.findall(r"([a-z_]+)=([^ ]+)", sys.argv[1]))
names = (
    "accepted",
    "empty_connection",
    "parse_error",
    "fallback_error",
)
missing = [name for name in names if name not in fields]
if missing:
    raise SystemExit(f"final metrics are missing fields: {missing}")
actual = {
    name: int(fields[name])
    for name in names
}
expected = {
    "accepted": 1,
    "empty_connection": 1,
    "parse_error": 1,
    "fallback_error": 1,
}
if actual != expected:
    raise SystemExit(
        "empty probe and malformed request metrics diverged: "
        f"expected={expected} actual={actual}"
    )
PY

echo "grpc_fast_cache probe/error metrics test passed"
